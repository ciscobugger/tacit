#!/usr/bin/env python3
# Activity's sampler: while the Activity window is open, one JSON line per interval on stdout
# ({"ev":"sample",..}), and the actions Activity asks for on stdin, one JSON object per line.
#
# Who holds what is worked out from processes, not from windows: each process's cgroup scope
# (app-scope puts every app in app-<id>-<pid>.scope, agent-host every session in agent-<id8>-..scope),
# with known apps carved out of the scope they were started from - a Praxis session's terminal, a
# Viewer started from a terminal, a Claude Code session inside foot. Memory is what cannot simply be
# dropped: anon + shmem + unreclaimable kernel memory + the zram share of what is swapped out.
# Page cache is not counted: the kernel gives it back on its own.
import json, os, re, select, signal, socket, subprocess, sys, threading, time

UID = os.getuid()
HOME = os.path.expanduser("~")
CG = "/sys/fs/cgroup"
USER_CG = f"/user.slice/user-{UID}.slice/user@{UID}.service"
HZ = os.sysconf("SC_CLK_TCK")
NCPU = os.cpu_count() or 1
RUN = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{UID}")
CACHE = os.path.join(HOME, ".cache", "tacit-activity")
DISK_FILE = os.path.join(CACHE, "disk.json")

# scope ids (app-scope's id, the desktop id) and window classes, to one app key
ALIAS = {"claude_app": "praxis", "claude-app": "praxis", "org.chromium.Chromium": "chromium",
         "browser-cef": "opsis", "browser": "opsis",
         "Chromium": "chromium", "code": "graphis", "zen-browser": "zen", "zen-bin": "zen",
         "footclient": "foot", "org.codeberg.dnkl.foot": "foot", "tacit-settings": "settings"}
# Tacit's own apps run as `qs -p <file>.qml`; the shell itself is part of Tacit
QML = {"claude.qml": "praxis", "code.qml": "graphis", "viewer.qml": "viewer",
       "tacit-settings.qml": "settings", "activity.qml": "activity", "welcome.qml": "welcome"}
OWN = set(QML.values())
AGENTS = {"claude": "claude", "codex": "codex", "opencode": "opencode", "pi": "pi"}
# terminals: what is left running in one after its shell or agent is gone gets a row of its own
TERMINALS = {"foot", "kitty", "alacritty", "wezterm", "ghostty", "konsole", "gnome-terminal", "xterm", "ptyxis"}
# caches that only ever hold downloads that come back on their own; never the whole ~/.cache
CACHES = [".cache/pip", ".cache/uv", ".cache/yarn", ".cache/go-build", ".cache/thumbnails", ".npm/_cacache"]
OLD_DAYS = 30

out_lock = threading.Lock()
def emit(obj):
    with out_lock:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()

def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default

def kv(text):
    d = {}
    for line in text.splitlines():
        p = line.split()
        if len(p) >= 2:
            try:
                d[p[0].rstrip(":")] = int(p[1])
            except ValueError:
                pass
    return d

def zram_ratio():
    # what one swapped-out byte costs in memory: zram's own use over what it holds
    orig = used = 0
    for dev in os.listdir("/sys/block"):
        if dev.startswith("zram"):
            f = read(f"/sys/block/{dev}/mm_stat").split()
            if len(f) >= 3:
                orig += int(f[0]); used += int(f[2])
    return used / orig if orig > 0 else 0.0

def cg_mem(path, ratio):
    s = kv(read(f"{CG}{path}/memory.stat"))
    if not s:
        return 0
    kernel = max(0, s.get("kernel", 0) - s.get("slab_reclaimable", 0))
    swap = int(read(f"{CG}{path}/memory.swap.current", "0") or 0)
    return s.get("anon", 0) + s.get("shmem", 0) + kernel + int(swap * ratio)

def proc_mem(pid, ratio):
    s = kv(read(f"/proc/{pid}/status"))
    return (s.get("RssAnon", 0) + s.get("RssShmem", 0) + int(s.get("VmSwap", 0) * ratio)) * 1024

# ------------------------------------------------------------------ processes
class P:
    __slots__ = ("pid", "ppid", "comm", "cg", "ticks", "argv")

pinfo = {}   # (pid, starttime) -> (argv, cgroup); a pid's command line does not change

def scan():
    procs = {}
    seen = set()
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        st = read(f"/proc/{pid}/stat")
        if not st:
            continue
        r = st.rfind(")")
        f = st[r + 2:].split()
        p = P()
        p.pid = pid
        p.comm = st[st.find("(") + 1:r]
        p.ppid = int(f[1])
        p.ticks = int(f[11]) + int(f[12])
        key = (pid, f[19])
        if key not in pinfo:
            argv = read(f"/proc/{pid}/cmdline").split("\0")
            cg = read(f"/proc/{pid}/cgroup").strip().split("::", 1)[-1]
            pinfo[key] = (argv, cg)
        p.argv, p.cg = pinfo[key]
        procs[pid] = p
        seen.add(key)
    for k in list(pinfo):
        if k not in seen:
            del pinfo[k]
    return procs

def norm(app_id):
    # app-scope writes "google-chrome" as "google_chrome"; the window class keeps the hyphen
    dashed = app_id.replace("_", "-")
    return ALIAS.get(app_id) or ALIAS.get(dashed) or dashed

def scope_of(cg):
    """(kind, id, unit) for a cgroup path: an app scope, an agent session scope, or Tacit."""
    unit = cg.rsplit("/", 1)[-1]
    m = re.match(r"app-(.+)-(\d+)\.scope$", unit)
    if m and "/app.slice/" in cg and "dbus" not in m.group(1):
        return ("app", norm(m.group(1)), unit)
    m = re.match(r"agent-([0-9a-f]{8})-.*\.scope$", unit)
    if m:
        return ("agent", m.group(1), unit)
    return ("tacit", "tacit", unit)

def own_identity(p):
    """An identity a process carries itself, whatever scope it was started in."""
    a0 = os.path.basename(p.argv[0]) if p.argv and p.argv[0] else ""
    if a0 in ("qs", "quickshell") or p.comm in ("qs", "quickshell"):
        for i, a in enumerate(p.argv):
            if a == "-p" and i + 1 < len(p.argv):
                q = os.path.basename(p.argv[i + 1])
                if q in QML:
                    return ("app", QML[q])
            if a == "-c":
                return ("tacit", "tacit")     # the shell
        return None
    tool = AGENTS.get(a0) or AGENTS.get(p.comm)
    if not tool and a0 in ("node", "bun") and len(p.argv) > 1:
        tool = AGENTS.get(os.path.basename(p.argv[1]))
    if tool and "--version" not in p.argv:
        return ("cli", tool)
    return None

# Gecko names its processes; Chromium and CEF say --type= (both rewrite argv into one string)
GECKO = {"Web Content": "Web pages", "Isolated Web Co": "Web pages", "Privileged Cont": "Web pages",
         "WebExtensions": "Extensions", "GPU Process": "Graphics", "RDD Process": "Video and sound",
         "Socket Process": "Network", "Utility Process": "Helpers", "forkserver": "Helpers"}

def role(p):
    """What a process of an app is for, in words a person knows."""
    if p.comm in GECKO:
        return GECKO[p.comm]
    m = re.search(r"--type=([a-z-]+)", " ".join(p.argv))
    if m:
        return {"renderer": "Web pages", "gpu-process": "Graphics"}.get(m.group(1), "Helpers")
    return None

# ------------------------------------------------------------------ agent-host
def host(req, wait=True):
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(1.5)
        s.connect(f"{RUN}/agent-host.sock")
        s.sendall((json.dumps(req) + "\n").encode())
        if not wait:
            s.close(); return None
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        return json.loads(buf.split(b"\n")[0]) if buf else None
    except (OSError, ValueError):
        return None

# ------------------------------------------------------------------ battery
def battery():
    base = "/sys/class/power_supply"
    bat = None
    for d in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        if read(f"{base}/{d}/type").strip() == "Battery" and read(f"{base}/{d}/present", "1").strip() == "1":
            cap = read(f"{base}/{d}/capacity").strip()
            if cap and int(cap) > 0:
                bat = d; break
    if not bat:
        return None
    g = lambda k: read(f"{base}/{bat}/{k}").strip()
    num = lambda k: int(g(k)) if g(k).lstrip("-").isdigit() else None
    v = num("voltage_now"); c = num("current_now"); pw = num("power_now")
    watts = abs(pw) / 1e6 if pw is not None else (abs(c) * v / 1e12 if c is not None and v else None)
    wh = None
    if num("energy_now") is not None:
        wh = num("energy_now") / 1e6
    elif num("charge_now") is not None and v:
        wh = num("charge_now") * v / 1e12
    whFull = None
    if num("energy_full") is not None:
        whFull = num("energy_full") / 1e6
    elif num("charge_full") is not None and v:
        whFull = num("charge_full") * v / 1e12
    light = None
    for d in os.listdir("/sys/class/backlight") if os.path.isdir("/sys/class/backlight") else []:
        b = read(f"/sys/class/backlight/{d}/brightness").strip(); m = read(f"/sys/class/backlight/{d}/max_brightness").strip()
        if b.isdigit() and m.isdigit() and int(m) > 0:
            light = int(b) / int(m); break
    ac = any(read(f"{base}/{d}/online").strip() == "1" for d in os.listdir(base)
             if read(f"{base}/{d}/type").strip() == "Mains")
    return {"pct": num("capacity"), "status": g("status"), "watts": watts, "wh": wh, "whFull": whFull,
            "light": light, "ac": ac}

# ------------------------------------------------------------------ disk (slow; its own thread, cached)
disk_state = {"busy": False}

def du(path):
    try:
        r = subprocess.run(["nice", "-n", "19", "ionice", "-c3", "du", "-sxb", "--", path],
                           capture_output=True, text=True, timeout=300)
        return int(r.stdout.split()[0]) if r.stdout else 0
    except (OSError, subprocess.SubprocessError, ValueError):
        return 0

def newest_mtime(e, cap=20000):
    """A folder's own mtime ignores edits inside it: take the newest in the tree (first `cap` entries)."""
    m = e.stat(follow_symlinks=False).st_mtime
    if not e.is_dir(follow_symlinks=False):
        return m
    n = 0
    for root, dirs, files in os.walk(e.path):
        for name in dirs + files:
            try:
                m = max(m, os.lstat(os.path.join(root, name)).st_mtime)
            except OSError:
                pass
            n += 1
            if n >= cap:
                return m
    return m

def old_downloads():
    d = os.path.join(HOME, "Downloads"); cut = time.time() - OLD_DAYS * 86400
    out = []
    try:
        for e in os.scandir(d):
            try:
                if newest_mtime(e) < cut:
                    out.append(e.path)
            except OSError:
                pass
    except OSError:
        pass
    return out

def disk_scan():
    if disk_state["busy"]:
        return
    disk_state["busy"] = True
    try:
        sv = os.statvfs("/")
        total = sv.f_blocks * sv.f_frsize; free = sv.f_bavail * sv.f_frsize
        folders = []; hidden = 0; home_sum = 0
        for e in os.scandir(HOME):
            if e.is_symlink():
                continue
            size = du(e.path) if e.is_dir(follow_symlinks=False) else (e.stat(follow_symlinks=False).st_size if e.is_file(follow_symlinks=False) else 0)
            home_sum += size
            if e.name == ".cache":
                folders.append({"name": "Caches", "path": e.path, "size": size, "hidden": True})
            elif e.name.startswith("."):
                hidden += size
            elif e.is_dir(follow_symlinks=False):
                folders.append({"name": e.name, "path": e.path, "size": size})
        folders.append({"name": "App data", "path": "", "size": hidden, "hidden": True})
        folders.append({"name": "Tacit and apps", "path": "", "size": max(0, total - free - home_sum), "hidden": True})
        old = old_downloads()
        caches = [p for p in (os.path.join(HOME, c) for c in CACHES) if os.path.isdir(p)]
        res = {"t": time.time(), "total": total, "free": free, "folders": sorted(folders, key=lambda f: -f["size"]),
               "old": {"n": len(old), "size": sum(du(p) for p in old)},
               "caches": {"size": sum(du(p) for p in caches)}}
        os.makedirs(CACHE, exist_ok=True)
        with open(DISK_FILE + ".tmp", "w") as f:
            json.dump(res, f)
        os.replace(DISK_FILE + ".tmp", DISK_FILE)
        emit({"ev": "disk", "disk": res})
    finally:
        disk_state["busy"] = False

def disk_start(force=False):
    try:
        with open(DISK_FILE) as f:
            cached = json.load(f)
        emit({"ev": "disk", "disk": cached})
        if not force and time.time() - cached.get("t", 0) < 600:
            return
    except (OSError, ValueError):
        pass
    threading.Thread(target=disk_scan, daemon=True).start()

# ------------------------------------------------------------------ what Tacit itself is made of
def tacit_parts(ratio, total):
    """Tacit's own memory by where it runs, scaled to the total the page shows."""
    user = f"/user.slice/user-{UID}.slice"
    def children(path):
        try:
            return [e.name for e in os.scandir(CG + path) if e.is_dir()]
        except OSError:
            return []
    desktop = sum(cg_mem(f"{user}/{c}", ratio) for c in children(user) if c.startswith("session-"))
    sound = cg_mem(f"{USER_CG}/session.slice", ratio)
    helpers = 0
    for c in children(f"{USER_CG}/app.slice"):
        if c == "app-graphical.slice" or re.match(r"(app-.+-\d+|agent-.+)\.scope$", c):
            continue
        helpers += cg_mem(f"{USER_CG}/app.slice/{c}", ratio)
    system = cg_mem("/system.slice", ratio) + cg_mem("/init.scope", ratio)
    parts = [("The desktop", "Hyprland and the shell", desktop), ("Sound and sharing", "PipeWire and the portals", sound),
             ("Helpers", "agents' host, dictation and the like", helpers), ("The system", "network, login, devices", system)]
    raw = sum(x[2] for x in parts) or 1
    return [{"name": n, "what": w, "mem": int(m * min(1.0, total / raw))} for n, w, m in parts if m > 0]

# ------------------------------------------------------------------ one sample
prev = {"t": None, "ticks": {}, "cpu": None}
busy_since = {}
groups_now = {}

def hypr_clients():
    try:
        r = subprocess.run(["hyprctl", "clients", "-j"], capture_output=True, text=True, timeout=2)
        return [c for c in json.loads(r.stdout) if c.get("mapped", True)]
    except (OSError, subprocess.SubprocessError, ValueError):
        return None     # unknown, not "no windows": nothing may be called background then

# Tray icons and the processes that show them: an icon's own id often names no app (Electron's is chrome_status_icon_1),
# so Activity finds an app's icon by process. D-Bus says which process owns each icon registered with the shell's
# watcher; a service already asked keeps its answer while it stays registered.
tray_seen = {}   # service -> (pid, icon id)
def tray_owners():
    def bus(*args):
        r = subprocess.run(["busctl", "--user", "-j", *args], capture_output=True, text=True, timeout=2)
        return json.loads(r.stdout)["data"]
    try:
        items = bus("get-property", "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                    "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems")
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        return {}
    out = {}
    for it in items:
        svc, _, path = it.partition("/")
        if svc not in tray_seen:
            try:
                pid = bus("call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                          "GetConnectionUnixProcessID", "s", svc)[0]
                tid = bus("get-property", svc, "/" + (path or "StatusNotifierItem"), "org.kde.StatusNotifierItem", "Id")
            except (OSError, subprocess.SubprocessError, ValueError, KeyError, IndexError):
                continue
            tray_seen[svc] = (pid, tid)
        out[svc] = tray_seen[svc]
    for svc in [k for k in tray_seen if k not in out]:
        del tray_seen[svc]
    return {pid: tid for pid, tid in out.values()}

def sample():
    now = time.monotonic()
    ratio = zram_ratio()
    procs = scan()
    clients = hypr_clients()
    win_known = clients is not None
    trays = tray_owners()
    win_pids = {}
    for c in clients or []:
        win_pids.setdefault(c["pid"], []).append(c)

    # identity per process: its own, else the nearest ancestor's inside the same scope, else the scope's
    ident = {}
    def who(p):
        if p.pid in ident:
            return ident[p.pid]
        k = scope_of(p.cg)
        # an agent session's own scope says who it is; an app's own process is the app; an agent
        # CLI counts as one only inside an app (a terminal), not agent-host's version probes
        mine = own_identity(p) if k[0] != "agent" else None
        if mine is not None and (mine[0] == k[0] and mine[1] == k[1] or mine[0] == "cli" and k[0] != "app"):
            mine = None
        if mine is None and p.pid in win_pids and k[0] == "app":
            cls = norm(win_pids[p.pid][0]["class"])
            if cls and cls != k[1]:
                mine = ("app", cls)     # an app started from another app's scope, with a window of its own
        if mine is None:
            par = procs.get(p.ppid)
            if par is not None and par.cg == p.cg:
                r = who(par)
                ident[p.pid] = r
                return r
            # left behind in a terminal (its parent gone, adopted by init or the user manager): the work of
            # the one agent in that terminal, or else a row of its own ("Left running in Terminal"). Never
            # the terminal itself: the scope's own process, or one with a window.
            agent = cli_in.get(p.cg)
            orphan = (p.ppid == 1 or par is None or par.comm == "systemd") and p.pid not in win_pids \
                and not k[2].endswith(f"-{p.pid}.scope")
            if orphan and agent and agent != p.pid:
                r = who(procs[agent])
            elif orphan and k[0] == "app" and k[1] in TERMINALS:
                r = ("left", k[1], k[2], p.pid)
            else:
                r = (k[0], k[1], k[2], None)
        else:
            r = (mine[0], mine[1], k[2], p.pid)     # carved: its root process
        ident[p.pid] = r
        return r
    cli_in = {}     # cgroup -> its one agent CLI process; None when there are several
    for p in procs.values():
        mine = own_identity(p)
        if mine and mine[0] == "cli" and scope_of(p.cg)[0] == "app":
            cli_in[p.cg] = p.pid if p.cg not in cli_in else None
    for p in procs.values():
        who(p)

    sessions = {}
    hl = host({"op": "list"})
    for s in (hl or {}).get("sessions", []):
        sessions[s["id"][:8]] = s

    dt = (now - prev["t"]) if prev["t"] else None
    groups = {}
    def group(kind, gid):
        key = f"{kind}:{gid}"
        g = groups.get(key)
        if g is None:
            g = groups[key] = {"key": key, "kind": kind, "id": gid, "mem": 0, "cpu": 0.0, "pids": [],
                               "scopes": {}, "carved": [], "windows": [], "parts": {}}
        return g
    carved_mem = {}     # unit -> memory of processes carved out of it
    for p in procs.values():
        kind, gid, unit, root = ident[p.pid]
        if kind == "cli":
            g = group("cli", f"{gid}:{root}")
            g["tool"] = gid
        else:
            g = group(kind, gid)
        g["pids"].append(p.pid)
        if root is not None:
            m = proc_mem(p.pid, ratio)
            carved_mem[unit] = carved_mem.get(unit, 0) + m
            g["mem"] += m
            g["carved"].append(p.pid)
        elif kind in ("app", "agent"):
            g["scopes"][unit] = p.cg
        if dt:
            d = p.ticks - prev["ticks"].get((p.pid, p.comm), p.ticks)
            g["cpu"] += max(0, d) / HZ / dt / NCPU
        r = role(p) if kind == "app" else None
        if r:
            pt = g["parts"].setdefault(r, {"n": 0, "rss": 0})
            pt["n"] += 1
            pt["rss"] += proc_mem(p.pid, ratio)
    prev["ticks"] = {(p.pid, p.comm): p.ticks for p in procs.values()}

    for g in groups.values():
        for unit, path in g["scopes"].items():
            g["mem"] += max(0, cg_mem(path, ratio) - carved_mem.get(unit, 0))
        for pid in g["pids"]:
            for c in win_pids.get(pid, []):
                g["windows"].append({"address": c["address"], "title": c.get("title", ""), "class": c.get("class", "")})

    # Tacit: every cgroup of the system and the user, less what the apps and agents hold
    total_cg = cg_mem("/user.slice", ratio) + cg_mem("/system.slice", ratio) + cg_mem("/init.scope", ratio)
    tacit = group("tacit", "tacit")
    tacit["mem"] = max(0, total_cg - sum(g["mem"] for k, g in groups.items() if g["kind"] != "tacit"))
    tacit["tacitParts"] = tacit_parts(ratio, tacit["mem"])

    # parts in proportion: process RSS double-counts shared pages; the app's total is the truth
    for g in groups.values():
        if g["kind"] == "app" and g["parts"]:
            rss = sum(pt["rss"] for pt in g["parts"].values())
            scale = min(1.0, g["mem"] / rss) if rss else 0
            g["parts"] = [{"name": k, "n": v["n"], "mem": int(v["rss"] * scale)} for k, v in g["parts"].items()]
            g["parts"].append({"name": "itself", "n": 1, "mem": max(0, g["mem"] - sum(x["mem"] for x in g["parts"]))})
        else:
            g["parts"] = []

    out = []
    for g in groups.values():
        if g["kind"] == "agent":
            s = sessions.get(g["id"])
            g["tool"] = (s or {}).get("tool", "claude")
            if s:
                g["session"] = {"id": s["id"], "cwd": s.get("cwd", ""), "state": s.get("state", ""),
                                "pending": bool(s.get("pending")), "prompt": (s.get("prompt") or "")[:120]}
        if g["kind"] == "cli":
            root = int(g["id"].split(":")[1])
            try:
                cwd = os.readlink(f"/proc/{root}/cwd")
            except OSError:
                cwd = ""
            # the terminal window it runs in: the nearest ancestor with a window
            win = None; a = procs.get(root)
            while a is not None and win is None:
                win = (win_pids.get(a.pid) or [None])[0]
                a = procs.get(a.ppid)
            g["session"] = {"cwd": cwd, "pid": root, "title": (win or {}).get("title", ""),
                            "window": (win or {}).get("address", "")}
        if g["kind"] in ("app", "agent", "cli") and g["cpu"] > 0.5:
            busy_since.setdefault(g["key"], time.time())
        else:
            busy_since.pop(g["key"], None)
        g["busyFor"] = int(time.time() - busy_since[g["key"]]) if g["key"] in busy_since else 0
        g["n"] = len(g["pids"])
        g["mem"] = int(g["mem"])
        g["cpu"] = round(g["cpu"], 4)
        if g["kind"] == "app" and g["mem"] < 1_000_000 and not g["windows"]:
            continue    # a launcher shell that only waits
        # running with no window: Tacit's own parts and Activity are not "apps in the background"
        if win_known and g["kind"] == "app" and g["pids"] and not g["windows"] and g["id"] not in OWN:
            g["background"] = True
            # its tray icon, if one of its processes shows one
            tid = next((trays[pid] for pid in g["pids"] if pid in trays), None)
            if tid is not None:
                g["tray"] = tid
        g.pop("scopes", None)
        out.append(g)
    groups_now.clear()
    groups_now.update({g["key"]: g for g in out})

    mi = kv(read("/proc/meminfo"))
    cpu_line = read("/proc/stat").split("\n", 1)[0].split()[1:]
    vals = list(map(int, cpu_line)); idle = vals[3] + vals[4]; tot = sum(vals)
    busy = None
    if prev["cpu"]:
        dtot = tot - prev["cpu"][0]; didle = idle - prev["cpu"][1]
        busy = round(1 - didle / dtot, 4) if dtot > 0 else None
    prev["cpu"] = (tot, idle)
    prev["t"] = now

    def psi(name):
        d = {}
        for line in read(f"/proc/pressure/{name}").splitlines():
            p = line.split()
            d[p[0]] = float(p[1].split("=")[1])
        return d
    pm, pc, pi_ = psi("memory"), psi("cpu"), psi("io")
    return {"ev": "sample", "t": time.time(),
          "mem": {"total": mi.get("MemTotal", 0) * 1024, "avail": mi.get("MemAvailable", 0) * 1024,
                  "swapTotal": mi.get("SwapTotal", 0) * 1024, "swapFree": mi.get("SwapFree", 0) * 1024},
          "cpu": {"busy": busy, "n": NCPU},
          "psi": {"mem": pm.get("some", 0), "memFull": pm.get("full", 0), "cpu": pc.get("some", 0), "io": pi_.get("some", 0)},
          "groups": out, "battery": battery(), "host": hl is not None}

# --top: who holds the most, for the notch's "Memory full · Zen" (one pass, no processor numbers)
TOP_NAMES = {"zen": "Zen", "foot": "Terminal", "chromium": "Chromium", "praxis": "Praxis", "graphis": "Graphis",
             "viewer": "Viewer", "settings": "Settings", "opsis": "Opsis", "claude": "Claude", "codex": "Codex",
             "opencode": "OpenCode", "pi": "pi"}

def top():
    held = {}
    for g in sample()["groups"]:
        if g["kind"] == "app" and g["id"] != "activity":
            name = g["id"]
        elif g["kind"] in ("agent", "cli"):
            name = g.get("tool", "claude")
        else:
            continue
        held[name] = held.get(name, 0) + g["mem"]
    if held:
        who = max(held, key=held.get)
        print(TOP_NAMES.get(who, who[:1].upper() + who[1:]))

# ------------------------------------------------------------------ actions

def units_of(key):
    """The scopes an app owns outright, or None when it lives inside another app's scope."""
    g = groups_now.get(key)
    if not g:
        return [], []
    if g["carved"]:
        return [], g["carved"]
    us = set()
    for pid in g["pids"]:
        cg = read(f"/proc/{pid}/cgroup").strip().split("::", 1)[-1]
        us.add(cg.rsplit("/", 1)[-1])
    return sorted(u for u in us if u.endswith(".scope") and u.startswith(("app-", "agent-"))), []

def act(req):
    op = req.get("op")
    if op == "interval":
        state["interval"] = max(0.5, req.get("ms", 2000) / 1000)
    elif op == "disk":
        disk_start(force=True)
    elif op == "quit":
        g = groups_now.get(req.get("key", ""))
        if not g or g["kind"] not in ("app", "left") or g["id"] in ("activity",):
            emit({"ev": "done", "op": op, "key": req.get("key"), "ok": False}); return
        force = bool(req.get("force"))
        if g["windows"] and not force:
            for w in g["windows"]:
                subprocess.run(["hyprctl", "dispatch", f'hl.dsp.window.close({{ window = "address:{w["address"]}" }})'],
                               capture_output=True, timeout=3)
        else:
            sig = "KILL" if force else "TERM"
            units, pids = units_of(g["key"])
            for u in units:
                subprocess.run(["systemctl", "--user", "kill", f"--signal={sig}", u], capture_output=True, timeout=5)
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
                except OSError:
                    pass
        emit({"ev": "done", "op": op, "key": g["key"], "ok": True})
    elif op in ("interrupt", "close"):
        # interrupt: the session stops what it is doing; close: its process ends (the conversation
        # stays and resumes on the next message), which is what gives the memory back
        r = host({"op": op, "id": req.get("id", "")})
        emit({"ev": "done", "op": op, "id": req.get("id"), "ok": bool(r) and r.get("ev") != "error"})
    elif op == "trashOld":
        old = old_downloads()
        ok = subprocess.run(["gio", "trash", "--"] + old, capture_output=True, timeout=120).returncode == 0 if old else True
        emit({"ev": "done", "op": op, "ok": ok, "n": len(old)})
        disk_start(force=True)
    elif op == "clearCaches":
        for c in CACHES:
            p = os.path.join(HOME, c)
            if os.path.isdir(p) and os.path.realpath(p).startswith(HOME + "/"):
                for e in os.scandir(p):
                    subprocess.run(["rm", "-rf", "--one-file-system", "--", e.path], capture_output=True, timeout=300)
        emit({"ev": "done", "op": op, "ok": True})
        disk_start(force=True)

state = {"interval": float(os.environ.get("ACTIVITY_INTERVAL", "2"))}

def main():
    if "--once" in sys.argv:
        sample(); time.sleep(1); emit(sample()); return
    if "--top" in sys.argv:
        top(); return
    disk_start()
    nxt = time.monotonic()
    while True:
        if time.monotonic() >= nxt:
            emit(sample())
            nxt = time.monotonic() + state["interval"]
        r, _, _ = select.select([sys.stdin], [], [], max(0.05, nxt - time.monotonic()))
        if r:
            line = sys.stdin.readline()
            if not line:
                return      # Activity went away
            try:
                act(json.loads(line))
            except (ValueError, OSError, subprocess.SubprocessError) as e:
                emit({"ev": "error", "message": str(e)})

if __name__ == "__main__":
    main()
