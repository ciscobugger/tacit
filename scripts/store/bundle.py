#!/usr/bin/env python3
"""tacit-bundle: Tacit's app format. An app made from Arch's signed packages, kept in its own folder, run in a sandbox.

  tacit-bundle plan <pkg>              what an install would fetch, as JSON
  tacit-bundle install <pkg>           fetch, verify, unpack, add to the launcher (one JSON line per step)
  tacit-bundle update <app>            the same against today's packages; only what changed is fetched
  tacit-bundle remove <app>
  tacit-bundle run <app> [-- cmd...]   start it in its sandbox (the launcher entries call this)
  tacit-bundle list

A bundle holds only the packages the system does not already have at the same version. The sandbox lays the bundle
over the system's /usr (overlayfs inside bubblewrap), so the app sees one consistent set of packages and nothing
outside the bundle changes: no password, no partial upgrade of the system. Packages come from the mirrors in
/etc/pacman.conf and are checked against the database's SHA-256 and the packager's signature (pacman's own keyring).
The app's own files (settings, caches) live in a private home; it sees the user's folders its permissions allow.
"""
import concurrent.futures, contextlib, fcntl, glob, hashlib, json, os, re, shlex, shutil, subprocess, sys, tarfile, time

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, ".local/share/tacit/bundles")
DATA = os.path.join(HOME, ".local/share/tacit/app-data")
CACHE = os.path.join(HOME, ".cache/tacit-bundle")
APPS_DIR = os.path.join(HOME, ".local/share/applications")
ICONS_DIR = os.path.join(HOME, ".local/share/icons")
KEYRING = "/etc/pacman.d/gnupg/pubring.gpg"
PERMS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../assets/store/permissions.json")
SELF = os.path.abspath(__file__)
ARCH = os.uname().machine
LOCAL_DB = "/var/lib/pacman/local"
SYSTEM_PARTS = ("usr/lib/systemd/system/", "usr/lib/udev/rules.d/", "usr/share/polkit-1/rules.d/", "usr/lib/modules/",
                "usr/lib/sysusers.d/", "usr/src/")


def say(**kw):
    print(json.dumps(kw), flush=True)


class Refused(Exception):
    """an outcome in words for the store: unavailable, installed, system, offline, space, failed"""
    def __init__(self, why, detail=""):
        super().__init__(detail or why); self.why = why; self.detail = detail


# ---- packages: the system's mirrors and its installed set ----

def repos():
    """[(name, [server urls])] in pacman.conf order"""
    out, cur = [], None
    def servers_from(path):
        try:
            return [l.split("=", 1)[1].strip() for l in open(path) if l.strip().startswith("Server")]
        except OSError:
            return []
    for line in open("/etc/pacman.conf"):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1]; cur = None if name == "options" else (name, [])
            if cur:
                out.append(cur)
        elif cur and "=" in line:
            k, v = (x.strip() for x in line.split("=", 1))
            if k == "Server":
                cur[1].append(v)
            elif k == "Include":
                cur[1].extend(servers_from(v))
    return [(n, [s.replace("$repo", n).replace("$arch", ARCH) for s in ss]) for n, ss in out]


def parse_desc(text):
    d, key = {}, None
    for line in text.splitlines():
        if line.startswith("%") and line.endswith("%"):
            key = line[1:-1]; d[key] = []
        elif line and key:
            d[key].append(line)
    return d


def refresh_sync(max_age=3600):
    """today's package lists, in our own cache (the system's own lists are never touched)"""
    os.makedirs(os.path.join(CACHE, "sync"), exist_ok=True)
    for name, servers in repos():
        dst = os.path.join(CACHE, "sync", name + ".db")
        if os.path.exists(dst) and time.time() - os.path.getmtime(dst) < max_age:
            continue
        for s in servers:
            r = subprocess.run(["curl", "-fsSL", "--max-time", "60", "-o", dst + ".part", f"{s}/{name}.db"], capture_output=True)
            if r.returncode == 0:
                os.replace(dst + ".part", dst); break
        else:
            if not os.path.exists(dst):
                raise Refused("offline", f"could not fetch the {name} package list")


def load_sync():
    pkgs, provides = {}, {}
    for name, servers in repos():
        path = os.path.join(CACHE, "sync", name + ".db")
        if not os.path.exists(path):
            continue
        with tarfile.open(path) as t:
            for m in t:
                if not m.name.endswith("/desc"):
                    continue
                d = parse_desc(t.extractfile(m).read().decode("utf-8", "replace"))
                n = d["NAME"][0]
                if n in pkgs:            # the first repo wins, as in pacman
                    continue
                p = dict(name=n, version=d["VERSION"][0], depends=d.get("DEPENDS", []), provides=d.get("PROVIDES", []),
                         filename=d["FILENAME"][0], sha256=d.get("SHA256SUM", [""])[0], csize=int(d.get("CSIZE", ["0"])[0]),
                         isize=int(d.get("ISIZE", ["0"])[0]), repo=name, servers=servers)
                pkgs[n] = p
                for pr in p["provides"]:
                    pn, _, pv = pr.partition("=")
                    provides.setdefault(pn, []).append((n, pv or None))
    return pkgs, provides


def load_host():
    host, provides = {}, {}
    for desc in glob.glob(os.path.join(LOCAL_DB, "*/desc")):
        d = parse_desc(open(desc, encoding="utf-8", errors="replace").read())
        n = d["NAME"][0]
        host[n] = d["VERSION"][0]
        for pr in d.get("PROVIDES", []):
            pn, _, pv = pr.partition("=")
            provides.setdefault(pn, []).append((n, pv or None))
    return host, provides


_vc = {}
def vercmp(a, b):
    if (a, b) not in _vc:
        _vc[(a, b)] = int(subprocess.run(["vercmp", a, b], capture_output=True, text=True).stdout.strip() or 0)
    return _vc[(a, b)]


DEP = re.compile(r"^([^<>=]+)(<=|>=|=|<|>)?(.*)$")
def satisfies(have, op, want):
    if not op:
        return True
    if have is None:
        return False
    if "-" not in want.split(":")[-1] and "-" in have:      # "foo>=1.2" ignores the package release
        have = have.rsplit("-", 1)[0]
    c = vercmp(have, want)
    return {"=": c == 0, ">=": c >= 0, "<=": c <= 0, ">": c > 0, "<": c < 0}[op]


def resolve(target):
    """the packages a bundle of `target` must carry: everything it needs that the system lacks or has at another
    version. Returns ({name: pkg}, [host packages relied on])."""
    pkgs, sprov = load_sync()
    host, hprov = load_host()
    if target not in pkgs:
        raise Refused("unavailable", f"{target} is not in the package lists")
    if target in host:
        raise Refused("installed", f"{target} is installed on this computer")
    bundle, used, queue = {}, set(), [target]
    while queue:
        dep = queue.pop()
        name, op, want = DEP.match(dep).groups()
        name = name.strip()
        if any((p["name"] == name and satisfies(p["version"], op, want)) or
               any(pr.partition("=")[0] == name and satisfies(pr.partition("=")[2] or p["version"], op, want) for pr in p["provides"])
               for p in bundle.values()):
            continue
        # the system has it, unchanged since today's lists: share it
        cands = ([(name, host[name])] if name in host else []) + [(h, v or host[h]) for h, v in hprov.get(name, [])]
        hit = next((h for h, v in cands if satisfies(v, op, want) and (h not in pkgs or pkgs[h]["version"] == host[h])), None)
        if hit:
            used.add(hit); continue
        # otherwise the bundle carries it, at today's version
        opts = ([name] if name in pkgs and satisfies(pkgs[name]["version"], op, want) else []) + \
               [p for p, v in sprov.get(name, []) if satisfies(v or pkgs[p]["version"], op, want)]
        if not opts:
            raise Refused("unavailable", f"nothing provides {dep}")
        pick = next((o for o in opts if o in host), opts[0])        # the one the system already uses, if any
        bundle[pick] = pkgs[pick]
        queue.extend(pkgs[pick]["depends"])
    return bundle, sorted(used)


# ---- fetching and checking ----

def fetch(p):
    """download one package into the cache; check its SHA-256 and its packager's signature. Returns its path."""
    d = os.path.join(CACHE, "pkg"); os.makedirs(d, exist_ok=True)
    dst = os.path.join(d, p["filename"])
    def sha(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        return h.hexdigest()
    if os.path.exists(dst) and os.path.exists(dst + ".sig") and sha(dst) == p["sha256"]:
        return dst
    for s in p["servers"]:
        url = f"{s}/{p['filename']}"
        ok = subprocess.run(["curl", "-fsSL", "--max-time", "900", "-o", dst + ".part", url], capture_output=True).returncode == 0 and \
             subprocess.run(["curl", "-fsSL", "--max-time", "60", "-o", dst + ".sig", url + ".sig"], capture_output=True).returncode == 0
        if ok:
            break
    else:
        raise Refused("offline", f"could not download {p['filename']}")
    if not p["sha256"] or sha(dst + ".part") != p["sha256"]:
        os.unlink(dst + ".part"); raise Refused("failed", f"{p['filename']} does not match its checksum")
    if subprocess.run(["gpgv", "--keyring", KEYRING, dst + ".sig", dst + ".part"], capture_output=True).returncode != 0:
        # on a computer whose updates stopped, its keys predate the packagers who signed today's packages: every app failed
        os.unlink(dst + ".part"); raise Refused("keys", f"{p['filename']} is not signed by a known packager")
    os.replace(dst + ".part", dst)
    return dst


def members(path):
    return subprocess.run(["bsdtar", "-tf", path], capture_output=True, text=True, check=True).stdout.split("\n")


# ---- the sandbox ----

def perms_for(app, categories):
    """what the app may reach: the catalogue's entry for it, else the defaults"""
    try:
        cat = json.load(open(PERMS))
    except (OSError, ValueError):
        cat = {}
    p = dict(network=True, files="user-folders", devices=["gpu", "audio"], x11=True, talk=[])
    p.update(cat.get("default", {}))
    p.update(cat.get("apps", {}).get(app, {}))
    return p


def user_dirs():
    out = []
    for k in ("DESKTOP", "DOCUMENTS", "DOWNLOAD", "MUSIC", "PICTURES", "VIDEOS"):
        r = subprocess.run(["xdg-user-dir", k], capture_output=True, text=True)
        d = r.stdout.strip()
        if d and d != HOME and os.path.isdir(d):
            out.append(d)
    return out


def layers(root, writable_usr=None):
    """the system's /usr, /etc, /opt with the bundle laid over them"""
    a = []
    for d in ("usr", "etc", "opt"):
        b, h = os.path.join(root, d), "/" + d
        if d == "usr" and writable_usr:
            a += ["--overlay-src", h, "--overlay", b, writable_usr, h]
        elif os.path.isdir(b) and os.path.isdir(h):
            a += ["--overlay-src", h, "--overlay-src", b, "--ro-overlay", h]
        elif os.path.isdir(b):
            a += ["--ro-bind", b, h]
        elif os.path.isdir(h):
            a += ["--ro-bind", h, h]
    for l, t in (("/bin", "usr/bin"), ("/sbin", "usr/bin"), ("/lib", "usr/lib"), ("/lib64", "usr/lib")):
        if os.path.islink(l):
            a += ["--symlink", t, l]
    return a


def refresh_caches(root):
    """the caches pacman's hooks would rebuild, rebuilt for the system and the bundle together, into the bundle"""
    usr = os.path.join(root, "usr"); os.makedirs(usr, exist_ok=True)
    work = os.path.join(os.path.dirname(root), ".work-" + os.path.basename(os.path.dirname(root)))
    wipe(work); os.makedirs(work)
    cmds = []
    if glob.glob(os.path.join(usr, "share/glib-2.0/schemas/*.xml")):
        cmds.append("glib-compile-schemas /usr/share/glib-2.0/schemas")
    if os.path.isdir(os.path.join(usr, "lib/gio/modules")):
        cmds.append("gio-querymodules /usr/lib/gio/modules")
    if glob.glob(os.path.join(usr, "lib/gdk-pixbuf-2.0/2.10.0/loaders/*")):
        cmds.append("gdk-pixbuf-query-loaders --update-cache")
    if os.path.isdir(os.path.join(usr, "share/mime/packages")):
        cmds.append("update-mime-database /usr/share/mime")
    for theme in glob.glob(os.path.join(usr, "share/icons/*/index.theme")):
        cmds.append(f"gtk-update-icon-cache -q -t -f /usr/share/icons/{os.path.basename(os.path.dirname(theme))}")
    # the bundle's own packages' hooks: VLC ships an empty plugin list that its hook fills, and without it VLC found
    # none of its windows and fell back to a command line (2026-10-17)
    for hook in sorted(glob.glob(os.path.join(usr, "share/libalpm/hooks/*.hook"))):
        text = open(hook, errors="replace").read()
        m = re.search(r"^Exec\s*=\s*(.+)$", text, re.M)
        if m and "NeedsTargets" not in text and re.search(r"^When\s*=\s*PostTransaction", text, re.M):
            cmds.append(m.group(1).strip())
    if cmds:
        subprocess.run(["bwrap", *layers(root, writable_usr=work), "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
                        "--unshare-all", "--die-with-parent", "sh", "-c", " ; ".join(c + " >/dev/null 2>&1" for c in cmds)])
    wipe(work)


def wipe(path):
    """delete a folder, including the overlay's work folder, which the kernel leaves with no permissions"""
    if os.path.lexists(path):
        subprocess.run(["chmod", "-R", "u+rwX", path], capture_output=True)
        shutil.rmtree(path)


def host_stamp():
    return int(os.stat(LOCAL_DB).st_mtime)


def run(app, cmd):
    base = os.path.join(ROOT, app)
    man = json.load(open(os.path.join(base, "manifest.json")))
    if man.get("host_stamp") != host_stamp():
        # the system changed since this bundle was made: bring the bundle in line before starting
        try:
            install(man["package"], quiet=True)
            man = json.load(open(os.path.join(base, "manifest.json")))
        except Exception:
            pass                                    # offline or a failed refresh: start what we have
    root = os.path.join(base, "root")
    perm = man["permissions"]
    uid = os.getuid(); rt = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{uid}"
    data = os.path.join(DATA, app); os.makedirs(data, exist_ok=True)
    a = ["bwrap", "--die-with-parent", "--new-session", "--unshare-all", "--clearenv", *layers(root),
         "--ro-bind", "/sys", "/sys", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--tmpfs", "/var/tmp",
         "--ro-bind-try", "/var/cache/fontconfig", "/var/cache/fontconfig", "--tmpfs", "/run", "--dir", rt, "--chmod", "0700", rt,
         "--bind", data, HOME]
    if "gpu" in perm["devices"]:
        a += ["--dev-bind-try", "/dev/dri", "/dev/dri"]
    if "camera" in perm["devices"]:
        for v in glob.glob("/dev/video*") + glob.glob("/dev/media*"):
            a += ["--dev-bind", v, v]
    if perm["network"]:
        a += ["--share-net", "--ro-bind-try", "/run/systemd/resolve", "/run/systemd/resolve"]
    # the look: Tacit's fonts, themes, cursor and text settings, read only
    for rel in (".config/gtk-3.0", ".config/gtk-4.0", ".config/fontconfig", ".config/kdeglobals", ".config/qt5ct", ".config/qt6ct",
                ".config/Kvantum", ".local/share/fonts", ".local/share/icons", ".local/share/themes", ".icons", ".themes"):
        a += ["--ro-bind-try", os.path.join(HOME, rel), os.path.join(HOME, rel)]
    if perm["files"] == "home":
        a += ["--bind", HOME, HOME]
    elif perm["files"] == "user-folders":
        for d in user_dirs():
            a += ["--bind", d, d]
    # and the person's USB drives and disks: a file opened from one did not exist inside the sandbox
    if perm["files"] in ("home", "user-folders"):
        a += ["--bind-try", f"/run/media/{os.environ.get('USER', '')}", f"/run/media/{os.environ.get('USER', '')}"]
    wl = os.environ.get("WAYLAND_DISPLAY", "wayland-1")
    a += ["--ro-bind", f"{rt}/{wl}", f"{rt}/{wl}"]
    if "audio" in perm["devices"] or "microphone" in perm["devices"]:
        a += ["--ro-bind-try", f"{rt}/pipewire-0", f"{rt}/pipewire-0", "--ro-bind-try", f"{rt}/pulse", f"{rt}/pulse"]
    env = dict(HOME=HOME, USER=os.environ.get("USER", ""), PATH="/usr/local/bin:/usr/bin", XDG_RUNTIME_DIR=rt, WAYLAND_DISPLAY=wl,
               GSETTINGS_BACKEND="keyfile", ELECTRON_OZONE_PLATFORM_HINT="auto", TACIT_BUNDLE=app)
    for k in ("LANG", "LANGUAGE", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP", "QT_QPA_PLATFORM", "QT_QPA_PLATFORMTHEME",
              "QT_STYLE_OVERRIDE", "QT_WAYLAND_DECORATION", "QT_WAYLAND_DISABLE_WINDOWDECORATION", "GTK_CSD", "GTK_THEME", "XCURSOR_THEME", "XCURSOR_SIZE", "TZ", "GDK_BACKEND"):
        if k in os.environ:
            env[k] = os.environ[k]
    env.update({k: v for k, v in os.environ.items() if k.startswith("LC_")})
    # X11 is on unless an app is known to be Wayland only: VLC's window and Java's need it (2026-10-17), and apps that
    # can use Wayland still do, as Tacit's session asks Qt and GTK for it first. What it opens up is other X11 windows.
    if perm.get("x11") and os.environ.get("DISPLAY"):
        n = os.environ["DISPLAY"].lstrip(":").split(".")[0]
        a += ["--ro-bind-try", f"/tmp/.X11-unix/X{n}", f"/tmp/.X11-unix/X{n}"]
        env["DISPLAY"] = os.environ["DISPLAY"]
        if os.environ.get("XAUTHORITY"):
            a += ["--ro-bind-try", os.environ["XAUTHORITY"], os.environ["XAUTHORITY"]]; env["XAUTHORITY"] = os.environ["XAUTHORITY"]
    # the session bus, filtered: its own names, the portals, notifications; it lives as long as the sandbox does
    bus_in = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if bus_in:
        pdir = os.path.join(rt, "tacit-bundle"); os.makedirs(pdir, exist_ok=True)
        bus = os.path.join(pdir, f"{app}-{os.getpid()}")
        r, w = os.pipe()
        # only well-formed bus names (two or more dotted parts): a launcher file named vlc.desktop gave "vlc", which the
        # proxy refused, and the app never started (2026-10-17)
        valid = [i for i in man.get("ids", []) if re.fullmatch(r"[A-Za-z_][\w-]*(\.[A-Za-z_][\w-]*)+", i)]
        names = [f"--own={n}" for i in valid for n in (i, i + ".*")] + ["--own=org.mpris.MediaPlayer2.*"]
        talk = [f"--talk={t}" for t in ["org.freedesktop.portal.*", "org.freedesktop.Notifications", "org.a11y.Bus",
                                        "org.freedesktop.FileManager1", *perm.get("talk", [])]]
        subprocess.Popen(["xdg-dbus-proxy", f"--fd={w}", bus_in, bus, "--filter", *names, *talk], pass_fds=(w,),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        os.close(w)
        if not os.read(r, 1):
            sys.exit(f"tacit-bundle: the bus filter for {app} did not start")
        os.set_inheritable(r, True)
        a += ["--bind", bus, f"{rt}/bus", "--sync-fd", str(r)]
        env["DBUS_SESSION_BUS_ADDRESS"] = f"unix:path={rt}/bus"
    for k, v in env.items():
        a += ["--setenv", k, v]
    os.execvp("bwrap", a + (cmd or man["exec"]))


# ---- install, remove ----

def plan(target):
    refresh_sync()
    bundle, used = resolve(target)
    cached = lambda p: os.path.exists(os.path.join(CACHE, "pkg", p["filename"]))
    return dict(package=target, packages=sorted(bundle), shared=len(used),
                download=sum(p["csize"] for p in bundle.values() if not cached(p)), size=sum(p["isize"] for p in bundle.values()))


def desktop_files(root, target_files):
    return [os.path.join(root, f) for f in target_files if f.startswith("usr/share/applications/") and f.endswith(".desktop")]


def integrate(app, root, target_files):
    """the app's launcher entries and icons in the user's own folders, starting it through its sandbox"""
    made, ids, execs = [], [], []
    os.makedirs(APPS_DIR, exist_ok=True)
    for src in desktop_files(root, target_files):
        name = os.path.basename(src); dst = os.path.join(APPS_DIR, name)
        if os.path.exists(dst) and "X-Tacit-Bundle=" not in open(dst, errors="replace").read():
            continue                                       # the user's own file: leave it
        out, icon, exec_ = [], None, None
        for line in open(src, encoding="utf-8", errors="replace").read().splitlines():
            if line.startswith(("TryExec=", "DBusActivatable=")):
                continue
            if line.startswith("Exec="):
                orig = line[5:]
                exec_ = exec_ or [t for t in shlex.split(orig) if not re.search(r"%[fFuUdDnNickvm]", t)]
                line = f"Exec={shlex.quote(SELF)} run {app} -- {orig}"
            if line.startswith("Icon="):
                icon = line[5:]
            out.append(line)
            if line.strip() == "[Desktop Entry]":
                out.append(f"X-Tacit-Bundle={app}")
        open(dst, "w").write("\n".join(out) + "\n"); made.append(dst)
        ids.append(name[:-8])
        if exec_:
            # the app's own start, not one of its extra entries (VLC's "Open Blu-ray" came first and VLC started on
            # "bluray://")
            execs.append((("NoDisplay=true" in out), name[:-8] != app, exec_))
        if icon and not icon.startswith("/"):
            for f in glob.glob(os.path.join(root, "usr/share/icons/hicolor/*/apps", icon + ".*")) + \
                     glob.glob(os.path.join(root, "usr/share/pixmaps", icon + ".*")):
                rel = os.path.relpath(f, os.path.join(root, "usr/share/icons")) if "/icons/" in f else os.path.join("hicolor/128x128/apps", os.path.basename(f))
                d = os.path.join(ICONS_DIR, rel); os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(f, d); made.append(d)
    subprocess.run(["update-desktop-database", APPS_DIR], capture_output=True)
    return made, ids, [e for *_, e in sorted(execs, key=lambda e: e[:2])]


def install(target, quiet=False):
    step = (lambda **kw: None) if quiet else say
    step(step="lists")
    refresh_sync(max_age=0 if not quiet else 3600)
    bundle, used = resolve(target)
    base = os.path.join(ROOT, target); old = os.path.join(base, "manifest.json")
    prev = json.load(open(old)) if os.path.exists(old) else None
    want = {n: p["version"] for n, p in bundle.items()}
    if prev and prev.get("versions") == want:
        # the catalogue's permissions as they are now: kept from the first install, a change to them reached nobody
        prev["host_stamp"] = host_stamp(); prev["permissions"] = perms_for(target, [])
        json.dump(prev, open(old, "w"), indent=1)
        refresh_caches(os.path.join(base, "root"))
        step(step="done", app=target, changed=False); return prev
    size = sum(p["isize"] for p in bundle.values())
    os.makedirs(ROOT, exist_ok=True)
    if shutil.disk_usage(ROOT).free < size * 1.3 + (1 << 28):
        raise Refused("space", f"needs {size >> 20} MB")
    # fetch and check everything before touching anything
    files, done = {}, 0
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        futs = {ex.submit(fetch, p): n for n, p in bundle.items()}
        for f in concurrent.futures.as_completed(futs):
            files[futs[f]] = f.result(); done += 1
            step(step="fetch", done=done, total=len(bundle))
    lists = {n: members(f) for n, f in files.items()}
    tfiles = [m for m in lists[target] if m and not m.startswith(".")]
    sys_parts = sorted({sp for m in tfiles for sp in SYSTEM_PARTS if m.startswith(sp)})
    if sys_parts:
        raise Refused("system", "needs parts of the system: " + ", ".join(sys_parts))
    # unpack into a fresh folder, then swap it in
    stage = base + ".new"; wipe(stage)
    root = os.path.join(stage, "root"); os.makedirs(root)
    skipped = []
    try:
        for n, f in files.items():
            step(step="unpack", package=n)
            tops = {m.split("/", 1)[0] for m in lists[n] if m and not m.startswith(".")}
            skipped += [f"{n}:{t}" for t in tops - {"usr", "etc", "opt"}]
            subprocess.run(["bsdtar", "-xpf", f, "-C", root, "--exclude", ".PKGINFO", "--exclude", ".BUILDINFO", "--exclude", ".MTREE",
                            "--exclude", ".INSTALL", "--exclude", ".CHANGELOG", *[x for t in tops - {"usr", "etc", "opt"} for x in ("--exclude", t)]],
                           check=True, capture_output=True)
        step(step="caches")
        refresh_caches(root)
    except BaseException:
        wipe(stage); raise                          # a half-unpacked folder can be hundreds of MB
    if os.path.isdir(base):
        if os.path.exists(old):
            remove(target, keep_data=True, quiet=True)
        else:
            wipe(base)                              # left by an install that died after the swap: no manifest
    os.replace(stage, base)
    root = os.path.join(base, "root")
    made = []
    try:
        made, ids, execs = integrate(target, root, tfiles)
    except BaseException:
        for f in made:
            with contextlib.suppress(OSError):
                os.unlink(f)
        wipe(base); raise
    first = next((m for m in tfiles if m.startswith("usr/bin/") and not m.endswith("/")), None)
    man = dict(package=target, version=bundle[target]["version"], versions=want, shared=used, made=made, ids=ids,
               exec=execs[0] if execs else (["/" + first] if first else []), skipped=skipped, host_stamp=host_stamp(),
               size=size, installed=int(time.time()), permissions=perms_for(target, []))
    json.dump(man, open(os.path.join(base, "manifest.json"), "w"), indent=1)
    step(step="done", app=target, changed=True, packages=len(bundle), size=size)
    return man


def remove(app, keep_data=True, quiet=False):
    base = os.path.join(ROOT, app); mp = os.path.join(base, "manifest.json")
    if not os.path.exists(mp):
        raise Refused("unavailable", f"{app} is not a Tacit bundle")
    for f in json.load(open(mp)).get("made", []):
        try:
            os.unlink(f)
        except OSError:
            pass
    wipe(base)
    if not keep_data:
        wipe(os.path.join(DATA, app))
    subprocess.run(["update-desktop-database", APPS_DIR], capture_output=True)
    if not quiet:
        say(step="removed", app=app)


def main():
    a = sys.argv[1:]
    try:
        if not a:
            print(__doc__); return
        if a[0] == "plan":
            say(**plan(a[1]))
        elif a[0] in ("install", "update"):
            install(a[1])
        elif a[0] == "remove":
            remove(a[1], keep_data="--data" not in a)
        elif a[0] == "list":
            for m in sorted(glob.glob(os.path.join(ROOT, "*/manifest.json"))):
                j = json.load(open(m)); say(app=j["package"], version=j["version"], size=j["size"], packages=len(j["versions"]))
        elif a[0] == "run":
            run(a[1], a[a.index("--") + 1:] if "--" in a else [])
        else:
            print(__doc__); sys.exit(2)
    except Refused as e:
        say(step="refused", why=e.why, detail=e.detail); sys.exit(1)


if __name__ == "__main__":
    main()
