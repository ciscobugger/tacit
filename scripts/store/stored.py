#!/usr/bin/env python3
"""stored.py: the Apps window's backend (store.qml). One JSON object per line on stdout.

  stored.py home                 the curated page: feature, jobs, picks, with each app's facts
  stored.py search <words>       desktop apps that match, best first
  stored.py app <package>        one app in full: screenshots, description, what's new, whether it can be got
  stored.py install <package>    gets it: progress lines, then {"result": ...}
  stored.py remove <package>     removes it, then {"result": ...}

Where things come from: names, icons, screenshots, descriptions and release notes from Arch's signed app catalogue
(archlinux-appstream-data, /usr/share/swcatalog), matched to packages by its pkgname field; versions, sizes,
licences, what is installed and what this computer can install from pacman itself; the store's own words (jobs, who
each app suits, the feature) from assets/store/editorial.json. Installs and removals go through pkexec, so the
password prompt is the desktop's own (the shell's polkit agent).

Never `pacman -Sy`: refreshing the package lists without updating the system is what leaves an Arch system half
updated. An install that would upgrade anything already installed is refused ("needs a system update first").
"""
import glob, gzip, hashlib, json, os, re, shutil, subprocess, sys, urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

SHELL = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EDITORIAL = os.path.join(SHELL, "assets", "store", "editorial.json")
CATALOGUE = "/usr/share/swcatalog"
CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "tacit-store")
LANG = "{http://www.w3.org/XML/1998/namespace}lang"
INDEX_VERSION = 4


def out(obj):
    print(json.dumps(obj), flush=True)


def run(cmd, timeout=60):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=dict(os.environ, LC_ALL="C")).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


# ---- the catalogue ---------------------------------------------------------------------------------------------

def english(c, tag):
    for e in c.findall(tag):
        if e.get(LANG) in (None, "en", "en-GB", "en-US"):
            return (e.text or "").strip()
    return ""


def paragraphs(desc):
    if desc is None:
        return []
    out_ = []
    for e in desc:
        if e.tag == "p" and (e.text or "").strip():
            out_.append(" ".join(e.text.split()))
        elif e.tag in ("ul", "ol"):
            items = [" ".join((li.text or "").split()) for li in e if (li.text or "").strip()]
            if items:
                out_.append(" · ".join(items))
    return out_


def component(c, origin):
    pkg = c.findtext("pkgname") or ""
    desc = next((d for d in c.findall("description") if d.get(LANG) is None), None)
    icon = next((i.text for i in c.findall("icon") if i.get("type") == "cached" and i.get("width") == "128"), None)
    shots = []
    sc = c.find("screenshots")
    for s in (list(sc) if sc is not None else []):
        src = next((i.text for i in s if i.tag == "image" and i.get("type") == "source" and i.get(LANG) is None), None)
        cap = next(((x.text or "").strip() for x in s if x.tag == "caption" and x.get(LANG) is None), "")
        if src:
            shots.append({"url": src.strip(), "caption": cap})
    rel = c.find("releases")
    release = None
    if rel is not None and len(rel):
        r0 = rel[0]
        rd = next((d for d in r0.findall("description") if d.get(LANG) is None), None)
        release = {"version": r0.get("version") or "", "notes": paragraphs(rd)}
    cats = c.find("categories")
    categories = [(x.text or "").strip() for x in (cats if cats is not None else []) if (x.text or "").strip()]
    keywords = []
    for k in c.findall("keywords"):
        if k.get(LANG) in (None, "en"):
            keywords += [(w.text or "").strip().lower() for w in k if (w.text or "").strip()]
    return pkg, {
        "id": c.findtext("id") or "", "name": english(c, "name"), "summary": english(c, "summary"),
        "developer": english(c, "developer_name") or (c.find("developer").findtext("name") if c.find("developer") is not None else "") or "",
        "license": c.findtext("project_license") or "",
        "homepage": next(((u.text or "").strip() for u in c.findall("url") if u.get("type") == "homepage"), ""),
        "desktop": next(((l.text or "").strip() for l in c.findall("launchable") if l.get("type") == "desktop-id"), ""),
        "icon": f"{CATALOGUE}/icons/{origin}/128x128/{icon}" if icon else "",
        "shots": shots, "release": release, "description": paragraphs(desc), "keywords": keywords, "categories": categories,
    }


def load_index():
    files = [f"{CATALOGUE}/xml/{r}.xml.gz" for r in ("core", "extra", "multilib") if os.path.exists(f"{CATALOGUE}/xml/{r}.xml.gz")]
    stamp = [INDEX_VERSION] + [os.path.getmtime(f) for f in files]
    path = os.path.join(CACHE, "index.json")
    try:
        cached = json.load(open(path))
        if cached.get("stamp") == stamp:
            return cached["apps"]
    except (OSError, ValueError):
        pass
    apps = {}
    for f in files:
        root = ET.parse(gzip.open(f)).getroot()
        origin = root.get("origin") or ""
        for c in root:
            if c.get("type") != "desktop-application":
                continue
            pkg, info = component(c, origin)
            if not pkg:
                continue
            # a package with several apps (LibreOffice: Base, Calc, … and "LibreOffice"): keep the umbrella one,
            # whose name is the shortest
            if pkg in apps and len(apps[pkg]["name"] or "~" * 99) <= len(info["name"] or "~" * 99):
                continue
            apps[pkg] = info
    os.makedirs(CACHE, exist_ok=True)
    tmp = path + ".tmp"
    json.dump({"stamp": stamp, "apps": apps}, open(tmp, "w"))
    os.replace(tmp, path)
    return apps


# ---- pacman ------------------------------------------------------------------------------------------------------

def available():
    return set(run(["pacman", "-Slq"]).split())


def installed():
    return set(run(["pacman", "-Qq"]).split()) | bundles()


# ---- Tacit's sandbox (bundle.py) ----------------------------------------------------------------------------------
# Apps come as bundles: in their own folder, run walled off from the system and the user's other files, got and removed
# with no password. Only an app that needs parts of the system itself (a service, device rules) goes through pacman.

BUNDLE = [sys.executable, "-I", os.path.join(os.path.dirname(os.path.abspath(__file__)), "bundle.py")]
BUNDLES = os.path.join(os.path.expanduser("~"), ".local/share/tacit/bundles")


def bundles():
    return {os.path.basename(os.path.dirname(m)) for m in glob.glob(os.path.join(BUNDLES, "*/manifest.json"))}


# The apps got here through pacman (the few that need the system), one name a line: a bundle is known by its folder,
# but a pacman package does not say where it came from. Your apps lists both, the editorial's or not (Discord
# 2026-10-22: an app found by search and got here was missing from Your apps while its page said On this computer).
GOT = os.path.join(os.path.expanduser("~"), ".local/state/tacit/store-got")


def got():
    try:
        return set(open(GOT).read().split())
    except OSError:
        return set()


def remember(pkg, keep):
    names = (got() | {pkg}) if keep else (got() - {pkg})
    os.makedirs(os.path.dirname(GOT), exist_ok=True)
    tmp = GOT + ".tmp"
    open(tmp, "w").write("".join(n + "\n" for n in sorted(names)))
    os.replace(tmp, GOT)


def bundle_plan(pkg):
    """the sandbox's plan in the window's words, or None when the app cannot be a bundle"""
    try:
        j = json.loads(run(BUNDLE + ["plan", pkg], timeout=180).strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None
    if j.get("step") == "refused":
        return {"can": False, "why": j["why"], "count": 0} if j["why"] in ("offline", "space") else None
    need = round(j["size"] / 1e6)
    os.makedirs(BUNDLES, exist_ok=True)
    free = shutil.disk_usage(BUNDLES).free // 1_000_000
    if need + 500 > free:
        return {"can": False, "why": "space", "count": len(j["packages"]), "need": need, "freeMB": free}
    return {"can": True, "count": len(j["packages"]), "download": round(j["download"] / 1e6), "need": need}


def bundle_install(pkg):
    """get `pkg` as a bundle, saying its progress; its outcome, or "system" when it has to go through pacman"""
    # what it says on the way out (a failure's reason, a traceback) is kept rather than dropped: a failure said only "Couldn't
    # install it" (Discord 2026-10-22, Hadi: every app)
    log = os.path.join(os.path.expanduser("~"), ".cache/tacit-store/bundle.log")
    os.makedirs(os.path.dirname(log), exist_ok=True)
    proc = subprocess.Popen(BUNDLE + ["install", pkg], stdout=subprocess.PIPE, stderr=open(log, "w"), text=True, errors="replace")
    result = "failed"
    for line in proc.stdout:
        try:
            j = json.loads(line)
        except ValueError:
            continue
        st = j.get("step")
        if st == "lists":
            out({"progress": 0.03, "phase": "Getting the latest list"})
        elif st == "fetch":
            out({"progress": 0.05 + 0.75 * j["done"] / max(1, j["total"]), "phase": f"Downloading {j['done']} of {j['total']}"})
        elif st in ("unpack", "caches"):
            out({"progress": 0.85 if st == "unpack" else 0.95, "phase": "Installing"})
        elif st == "done":
            result = "ok"
        elif st == "refused":
            result = {"installed": "ok"}.get(j["why"], j["why"])
    proc.wait()
    return result


def mib(text):
    m = re.match(r"([\d.]+)\s*(B|KiB|MiB|GiB)", text or "")
    if not m:
        return 0
    return round(float(m.group(1)) * {"B": 1 / 1048576, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024}[m.group(2)] * 1.048576)   # MB


def facts(pkgs):
    """version, download and installed size (MB), licences from the repos, for several packages in one call"""
    res, cur = {}, None
    for line in run(["pacman", "-Si", *pkgs], timeout=120).splitlines():
        if ":" not in line:
            continue
        k, v = (x.strip() for x in line.split(":", 1))
        if k == "Name":
            cur = res.setdefault(v, {})
        elif cur is not None and k == "Version":
            cur["version"] = v.split(":")[-1].rsplit("-", 1)[0]
        elif cur is not None and k == "Download Size":
            cur["download"] = mib(v)
        elif cur is not None and k == "Installed Size":
            cur["size"] = mib(v)
        elif cur is not None and k == "Licenses":
            cur["licenses"] = v
    return res


def free_license(spdx):
    s = (spdx or "").lower()
    return bool(s) and "proprietary" not in s and "licenseref" not in s


# ---- pictures ----------------------------------------------------------------------------------------------------

def icon_png(src):
    """the catalogue's icons are JPEG XL, which Qt cannot read: converted once, kept"""
    if not src or not os.path.exists(src):
        return ""
    dst = os.path.join(CACHE, "icons", os.path.basename(src).rsplit(".", 1)[0] + ".png")
    if not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        subprocess.run(["magick", src, dst], capture_output=True, timeout=30)
    return dst if os.path.exists(dst) else ""


def shot(url, wide=1600):
    """a screenshot from the developer's own site, kept at most `wide` px wide as JPEG; "" when it cannot be had.
    Pictures shown across the whole window (the issue, an app's cover) are kept at up to 2560 px"""
    name = hashlib.sha1(url.encode()).hexdigest()[:20] + ("" if wide == 1600 else f"-w{wide}")
    dst = os.path.join(CACHE, "shots", name + ".jpg")
    if os.path.exists(dst):
        return dst
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    raw = dst + ".download"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Tacit Apps"})
        with urllib.request.urlopen(req, timeout=20) as r, open(raw, "wb") as f:
            f.write(r.read(40 * 1024 * 1024))
        subprocess.run(["magick", raw + "[0]", "-resize", f"{wide}x>", "-quality", "88", dst], capture_output=True, timeout=60)
    except Exception:
        pass
    finally:
        if os.path.exists(raw):
            os.remove(raw)
    return dst if os.path.exists(dst) else ""


# ---- what the window gets ----------------------------------------------------------------------------------------

def cropped(path, crop):
    """the part of a screenshot a featured picture shows (editorial.json gives it as fractions); kept beside it"""
    if not path or not crop:
        return path
    dst = path[:-4] + "-" + hashlib.sha1(json.dumps(crop).encode()).hexdigest()[:8] + ".jpg"
    if not os.path.exists(dst):
        size = run(["identify", "-format", "%w %h", path]).split()
        if len(size) != 2:
            return path
        w, h = int(size[0]), int(size[1])
        x, y, cw, ch = (round(crop[0] * w), round(crop[1] * h), round(crop[2] * w), round(crop[3] * h))
        subprocess.run(["magick", path, "-crop", f"{cw}x{ch}+{x}+{y}", "+repage", "-quality", "88", dst], capture_output=True, timeout=60)
    return dst if os.path.exists(dst) else path


def tone(path):
    """the picture's tone, worked out once per picture and kept"""
    if not path:
        return ""
    store = os.path.join(CACHE, "tones.json")
    try:
        known = json.load(open(store))
    except (OSError, ValueError):
        known = {}
    if path in known:
        return known[path]
    known[path] = measure_tone(path)
    try:
        tmp = store + ".tmp"
        json.dump(known, open(tmp, "w")); os.replace(tmp, store)
    except OSError:
        pass
    return known[path]


def brightness(path):
    """how bright the top third of a picture is (0..1): the window's header thickens its glass over bright pictures"""
    if not path:
        return 0.5
    store = os.path.join(CACHE, "tones.json")
    try:
        known = json.load(open(store))
    except (OSError, ValueError):
        known = {}
    key = "bright:" + path
    if key not in known:
        v = run(["magick", path, "-gravity", "North", "-crop", "100%x33%+0+0", "+repage", "-colorspace", "Gray", "-format", "%[fx:mean]", "info:"])
        try:
            known[key] = round(float(v.strip()), 3)
        except ValueError:
            known[key] = 0.5
        try:
            tmp = store + ".tmp"
            json.dump(known, open(tmp, "w")); os.replace(tmp, store)
        except OSError:
            pass
    return known[key]


def aspect(path):
    size = run(["identify", "-format", "%w %h", path]).split() if path else []
    return round(int(size[0]) / int(size[1]), 4) if len(size) == 2 and int(size[1]) else 1.6


def cover(pkg, ed, cat):
    """an app's picture of its work, when the store has chosen one: the issue's crop (only the work, never toolbars)"""
    sp = next((x for x in ed.get("issue", []) if x.get("pkg") == pkg and x.get("crop")), None)
    if not sp:
        return ""
    urls = [x["url"] for x in cat.get(pkg, {}).get("shots", [])]
    url = next((u for u in urls if hashlib.sha1(u.encode()).hexdigest().startswith(sp.get("shot", "-"))), "")
    return cropped(shot(url, 2560), sp["crop"]) if url else ""


def issue(ed, cat):
    """the front page as an issue: each spread with its picture cropped to the work, the picture's tone and brightness"""
    spreads = []
    for sp in ed.get("issue", []):
        sp = dict(sp)
        if sp.get("pkg"):
            urls = [x["url"] for x in cat.get(sp["pkg"], {}).get("shots", [])]
            url = next((u for u in urls if hashlib.sha1(u.encode()).hexdigest().startswith(sp.get("shot", "-"))), urls[0] if urls else "")
            pic = cropped(shot(url, 2560), sp.get("crop")) if url else ""
            sp["picture"], sp["tone"], sp["bright"] = pic, tone(pic), brightness(pic)
            sp["aspect"] = aspect(pic)
            w = run(["identify", "-format", "%w", pic]).strip() if pic else ""
            sp["px"] = int(w) if w.isdigit() else 0     # its width in pixels: a small picture is not stretched past ~1.2x
        spreads.append(sp)
    return spreads


def measure_tone(path):
    """a picture's own colour for the window to carry (a wash behind the page, the shade under words on it): of
    the picture's main colours, the one with the most colour in it that is neither near black nor near white"""
    if not path:
        return ""
    out_ = run(["magick", path, "-resize", "96x96", "-colors", "8", "-format", "%c", "histogram:info:-"], timeout=30)
    best, score = "", 0.0
    for line in out_.splitlines():
        m = re.search(r"(\d+):.*#([0-9A-Fa-f]{6})", line)
        if not m:
            continue
        n, hx = int(m.group(1)), m.group(2)
        r, g, b = (int(hx[i:i + 2], 16) / 255 for i in (0, 2, 4))
        hi, lo = max(r, g, b), min(r, g, b)
        light = (hi + lo) / 2
        sat = 0 if hi == lo else (hi - lo) / (1 - abs(2 * light - 1))
        if not 0.18 < light < 0.82:
            continue
        sc = n * (0.15 + sat) ** 2
        if sc > score:
            best, score = "#" + hx.lower(), sc
    return best


def editorial():
    return json.load(open(EDITORIAL))


def icon_ready(src):
    """the converted icon if it is already there; never converts"""
    if not src:
        return ""
    dst = os.path.join(CACHE, "icons", os.path.basename(src).rsplit(".", 1)[0] + ".png")
    return dst if os.path.exists(dst) else ""


def info(pkg, cat, ed, avail, inst, f=None, icon=True):
    c = cat.get(pkg, {})
    e = ed["apps"].get(pkg, {})
    names = [pkg] + e.get("also", [])
    have = next((n for n in names if n in inst), "")
    f = f or {}
    return {
        "pkg": pkg, "name": e.get("name") or c.get("name") or pkg, "line": e.get("line") or c.get("summary", ""), "like": e.get("like", ""),
        "developer": c.get("developer", ""), "icon": (icon_png if icon else icon_ready)(c.get("icon", "")), "desktop": c.get("desktop", ""),
        "available": pkg in avail or bool(have), "installed": bool(have), "installedAs": have,
        "version": f.get("version", ""), "download": f.get("download", 0), "size": f.get("size", 0),
        "free": free_license(c.get("license") or f.get("licenses", "")),
    }


def home():
    ed, cat, avail, inst = editorial(), load_index(), available(), installed()
    pkgs = sorted({p for j in ed["jobs"] for p in j["pkgs"]} | set(ed["picks"]) | {ed["feature"]["pkg"]}
                  | {sp["pkg"] for sp in ed.get("issue", []) if sp.get("pkg")} | {pk for sp in ed.get("issue", []) for _, pk in sp.get("say", []) if pk}
                  | bundles() | (got() & inst))
    f = facts([p for p in pkgs if p in avail])
    apps = {p: info(p, cat, ed, avail, inst, f.get(p)) for p in pkgs}
    def first_shot(p):
        return next((s for s in (shot(x["url"]) for x in cat.get(p, {}).get("shots", [])[:2]) if s), "")
    feature = dict(ed["feature"], picture=cropped(first_shot(ed["feature"]["pkg"]), ed["feature"].get("crop")))
    feature["tone"] = tone(feature["picture"])
    picks = [{"pkg": p, "picture": cropped(first_shot(p), ed["apps"].get(p, {}).get("crop"))} for p in ed["picks"]]
    for pk in picks:
        pk["tone"] = tone(pk["picture"])
    windows = None
    for path in (os.environ.get("STORE_WINDOWS_APPS", ""), os.path.expanduser("~/.local/state/tacit-setup/windows-apps.json")):
        if path and os.path.exists(path):
            windows = json.load(open(path))
            break
    page = {"arch": os.uname().machine, "feature": feature, "picks": picks, "issue": issue(ed, cat), "jobs": ed["jobs"], "apps": apps, "windows": windows,
         "installed": sorted(p for p in apps if apps[p]["installed"])}
    # kept, so the window can draw the front page the moment it opens and refresh it from this a moment later
    try:
        os.makedirs(CACHE, exist_ok=True)
        tmp = os.path.join(CACHE, "home.json.tmp")
        json.dump(page, open(tmp, "w")); os.replace(tmp, os.path.join(CACHE, "home.json"))
    except OSError:
        pass
    out(page)


# words that carry no meaning in "what do you want to do?"
QUIET = set("i im i'm want wanna to a an the my me some for with and of on in do can how something app apps program programs "
            "software tool tools thing things like need get make let lets please".split())
# what people say -> the catalogue's own categories (freedesktop main and additional categories)
SAYS = {
    "game": ["Game"], "games": ["Game"], "play": ["Game"], "gaming": ["Game"],
    "music": ["Audio", "Music"], "listen": ["Audio", "Player"], "song": ["Audio"], "songs": ["Audio"], "podcast": ["Audio"],
    "video": ["Video"], "videos": ["Video"], "watch": ["Video", "Player"], "film": ["Video"], "films": ["Video"], "movie": ["Video"], "movies": ["Video"],
    "photo": ["Photography", "Graphics"], "photos": ["Photography", "Graphics"], "picture": ["Graphics"], "pictures": ["Graphics"],
    "draw": ["RasterGraphics", "VectorGraphics"], "paint": ["RasterGraphics"], "3d": ["3DGraphics"],
    "write": ["WordProcessor", "TextEditor"], "document": ["WordProcessor", "Office"], "documents": ["WordProcessor", "Office"],
    "spreadsheet": ["Spreadsheet"], "slides": ["Presentation"], "office": ["Office"],
    "code": ["Development", "IDE"], "coding": ["Development", "IDE"], "programming": ["Development", "IDE"],
    "chat": ["Chat", "InstantMessaging"], "call": ["Telephony", "VideoConference", "InstantMessaging"], "message": ["InstantMessaging"],
    "mail": ["Email"], "email": ["Email"], "browse": ["WebBrowser"], "web": ["WebBrowser"], "internet": ["WebBrowser"],
    "record": ["Recorder", "AudioVideo"], "stream": ["AudioVideo"], "learn": ["Education"], "study": ["Education"],
    "money": ["Finance"], "budget": ["Finance"], "science": ["Science"], "map": ["Maps"], "maps": ["Maps"],
}


def plain(t):
    return re.sub(r"[^a-z0-9 ]", "", t.lower())


def scores(q, cat, ed, avail, inst):
    words = [w for w in plain(q).split() if w not in QUIET] or plain(q).split()
    whole = " ".join(words)
    scored = []
    for pkg, c in cat.items():
        if pkg not in avail and pkg not in inst:
            continue
        name, summ, keys, cats = plain(c["name"]), plain(c["summary"]), [plain(k) for k in c["keywords"]], set(c.get("categories", []))
        s = 0
        if whole and (name == whole or pkg == whole):
            s += 12
        for w in words:
            stem = w[:-1] if len(w) > 3 and w.endswith("s") else w
            if name == w or name.startswith(w):
                s += 6
            elif stem in name:
                s += 4
            if any(k == w or k == stem or stem in k for k in keys):
                s += 3
            if stem in summ:
                s += 2
            if cats & set(SAYS.get(w, [])):
                s += 3
        if s and pkg in ed["apps"]:
            s += 2
        if s:
            scored.append((-s, name, pkg))
    scored.sort()
    return [p for _, _, p in scored[:24]]


def search(words):
    q = " ".join(words).lower().strip()
    if not q:
        return out({"query": q, "apps": [], "done": True})
    ed, cat, avail, inst = editorial(), load_index(), available(), installed()
    out({"query": q, "apps": [info(p, cat, ed, avail, inst) for p in scores(q, cat, ed, avail, inst)], "done": True})


def serve():
    """one backend for the whole time the window is open: a search is answered from memory, the package lists are read
    again only when pacman's databases change, and icons that are not converted yet arrive in a second answer"""
    import threading, queue
    state = {"ed": None, "ed_m": 0, "cat": None, "stamp": None, "avail": set(), "inst": set()}
    def stamp():
        paths = ["/var/lib/pacman/local", BUNDLES] + [os.path.join("/var/lib/pacman/sync", f) for f in os.listdir("/var/lib/pacman/sync") if f.endswith(".db")]
        return [os.path.getmtime(p) for p in paths if os.path.exists(p)]
    def fresh():
        m = os.path.getmtime(EDITORIAL)
        if state["ed"] is None or m != state["ed_m"]:
            state["ed"], state["ed_m"] = editorial(), m
        if state["cat"] is None:
            state["cat"] = load_index()
        st = stamp()
        if st != state["stamp"]:
            state["stamp"], state["avail"], state["inst"] = st, available(), installed()
    lock, latest, icons = threading.Lock(), {"q": None, "pkgs": []}, queue.Queue()
    def answer(q, pkgs):
        cat, ed = state["cat"], state["ed"]
        apps = []
        for p in pkgs:
            a = info(p, cat, ed, state["avail"], state["inst"], icon=False)
            if not a["icon"] and cat.get(p, {}).get("icon"):
                icons.put(p)
            apps.append(a)
        with lock:
            out({"query": q, "apps": apps, "done": True})
    def convert():
        while True:
            p = icons.get()
            icon_png(state["cat"].get(p, {}).get("icon", ""))
            with lock:
                q, pkgs = latest["q"], latest["pkgs"]
            if p in pkgs and icons.empty():
                answer(q, pkgs)
    threading.Thread(target=convert, daemon=True).start()
    for line in sys.stdin:
        try:
            req = json.loads(line)
        except ValueError:
            continue
        if req.get("op") != "search":
            continue
        q = str(req.get("q", "")).lower().strip()
        if not q:
            out({"query": q, "apps": [], "done": True}); continue
        fresh()
        pkgs = scores(q, state["cat"], state["ed"], state["avail"], state["inst"])
        with lock:
            latest["q"], latest["pkgs"] = q, pkgs
        answer(q, pkgs)


def targets(pkg):
    """what installing `pkg` would download: [(name, MB, url)]"""
    res = []
    for line in run(["pacman", "-Sp", "--print-format", "%n %s %l", pkg], timeout=120).splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1].isdigit():
            res.append((parts[0], round(int(parts[1]) / 1e6), parts[2]))
    return res


def gone(urls):
    """the files the server no longer has. This computer's list of packages is only refreshed by a system update; once
    the server has moved on, the versions it names are deleted there (403/404) and installing them cannot work"""
    def status(u):
        try:
            req = urllib.request.Request(u, method="HEAD", headers={"User-Agent": "Tacit Apps"})
            with urllib.request.urlopen(req, timeout=8) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code
        except Exception:
            return 0        # no answer: not proof that it is gone (offline is said when installing)
    with ThreadPoolExecutor(8) as pool:
        return [u for u, code in zip(urls, pool.map(status, urls)) if code in (403, 404, 410)]


def pending(pkg=""):
    """what getting `pkg` together with the waiting updates would bring: the updates' count and size and the app's own, from
    this computer's package list, which Tacit's updater keeps fresh as root (no password; nothing is refreshed here)"""
    def sizes(args):
        out_ = []
        for line in run(["pacman", *args, "--print-format", "%n %s %l"], timeout=120).splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1].isdigit():
                out_.append((parts[0], int(parts[1]), parts[2].startswith("file://")))   # file:// = already downloaded
        return out_
    ups = sizes(["-Sup"])
    app = [x for x in sizes(["-Sp", pkg]) if x[0] not in {n for n, _, _ in ups}] if pkg else []
    mb = lambda xs: round(sum(sz for _, sz, _ in xs) / 1e6)
    return {"updates": len(ups), "updatesMB": mb(ups), "appMB": mb(app),
            "toDownloadMB": mb([x for x in ups + app if not x[2]])}


def plan(pkg, inst, ask=True):
    """whether `pkg` can be got now, and if not why, in the window's words"""
    return bundle_plan(pkg) or system_plan(pkg, inst, ask)


def system_plan(pkg, inst, ask=True):
    """the same for an install through pacman"""
    t = targets(pkg)
    if not t:
        return {"can": False, "why": "unavailable", "count": 0}
    upgrades = [n for n, _, _ in t if n in inst and n != pkg]
    waiting = run(["pacman", "-Qu"]).strip() != ""
    if upgrades or waiting or gone([u for _, _, u in t]):
        # the app needs the waiting updates with it (or this computer's list is out of date): say what that brings
        return dict({"can": False, "why": "update", "count": len(t)}, **(pending(pkg) if ask else {}))
    f = facts([n for n, _, _ in t])
    need = sum(f.get(n, {}).get("size", 0) for n, _, _ in t)
    free = shutil.disk_usage("/").free // 1_000_000
    if need + 500 > free:
        return {"can": False, "why": "space", "count": len(t), "need": need, "freeMB": free}
    return {"can": True, "count": len(t), "download": sum(s for _, s, _ in t), "need": need}


def app(pkg):
    ed, cat, avail, inst = editorial(), load_index(), available(), installed()
    f = facts([pkg]) if pkg in avail else {}
    a = info(pkg, cat, ed, avail, inst, f.get(pkg))
    c = cat.get(pkg, {})
    with ThreadPoolExecutor(4) as pool:   # the developers' sites, all at once
        paths = list(pool.map(shot, [x["url"] for x in c.get("shots", [])[:4]]))
    a["shots"] = [{"path": p, "caption": x["caption"]} for p, x in zip(paths, c.get("shots", [])[:4]) if p]
    # the hero: the work alone when the store has a crop for it (shown across the window), else its first screenshot as it is
    # (shown framed, as a window); its aspect so the page can lay it out before it loads
    work = cover(pkg, ed, cat) or (cropped(a["shots"][0]["path"], ed["apps"][pkg]["crop"]) if a["shots"] and ed["apps"].get(pkg, {}).get("crop") else "")
    a["hero"] = work or (a["shots"][0]["path"] if a["shots"] else "")
    a["heroWork"] = bool(work)
    a["heroAspect"] = aspect(a["hero"]) if a["hero"] else 1.6
    a["tone"] = tone(a["hero"] or a["icon"])
    a["description"] = c.get("description", [])[:2]
    rel = c.get("release")
    # "what's new" only for the version this computer would get: the catalogue can lag the repos
    a["whatsNew"] = [n for n in rel["notes"] if len(n) > 24][:2] if rel and a["version"] and rel["version"] and a["version"].startswith(rel["version"]) else []
    a["homepage"] = c.get("homepage", "")
    a["plan"] = {"can": False, "why": "installed"} if a["installed"] else (plan(pkg, inst) if a["available"] else {"can": False, "why": "unavailable"})
    out(a)


PKEXEC = ["pkexec", "--disable-internal-agent", "/usr/bin/env", "LC_ALL=C", "/usr/bin/stdbuf", "-oL", "/usr/bin/pacman"]


def why(code, lines):
    text = "\n".join(lines[-30:]).lower()
    if code in (126, 127):
        return "cancelled"
    if "unable to lock database" in text:
        return "busy"
    if "returned error: 403" in text or "returned error: 404" in text or "returned error: 410" in text:
        return "update"
    if "failed retrieving file" in text or "could not resolve" in text or "failed to download" in text:
        return "offline"
    if "not enough free disk space" in text:
        return "space"
    return "failed"


def install(pkg, everything=False):
    """get one app. With `everything`, the whole system is brought up to date in the same step (pacman -Syu <app>): the
    only safe way to get an app once this computer's list of packages is out of date (never -Sy alone)"""
    inst = installed()
    if pkg in inst:
        return out({"result": "ok"})
    if not everything:
        r = bundle_install(pkg)
        # keys older than the packages' signatures: the updates bring the new ones, and the app comes in the same step
        if r == "keys":
            return out({"result": "update", "plan": dict({"can": False, "why": "update", "count": 1}, **pending(pkg))})
        if r != "system" and r != "unavailable":
            return out({"result": r})
    if everything:
        p = {"count": 40}
    else:
        p = system_plan(pkg, inst)
        if not p["can"]:
            return out({"result": p["why"], "plan": p})
    total, dl, done_inst, n = max(1, p["count"]), 0, 0, 0
    what = "updates " if everything else ""
    out({"progress": 0.02, "phase": "Waiting for your password"})
    args = ["-Syu", "--noconfirm", "--needed", pkg] if everything else ["-S", "--noconfirm", "--needed", pkg]
    proc = subprocess.Popen(PKEXEC + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    lines = []
    for line in proc.stdout:
        line = line.rstrip()
        lines.append(line)
        m = re.match(r"Packages \((\d+)\)", line)
        if m:
            total = max(1, int(m.group(1)))
        if line.startswith(":: Synchronizing package databases"):
            out({"progress": 0.03, "phase": "Getting the latest list"})
        elif line.endswith("downloading...") or re.search(r"\sdownloading\b", line):
            dl += 1
            out({"progress": 0.05 + 0.6 * min(dl, total) / total, "phase": f"Downloading {what}{min(dl, total)} of {total}"})
        elif line.startswith(":: Processing package changes"):
            out({"progress": 0.7, "phase": "Installing"})
        else:
            m = re.match(r"\(\s*(\d+)/(\d+)\)\s+(installing|reinstalling|upgrading)\s", line)
            if m:
                done_inst, n = int(m.group(1)), int(m.group(2))
                out({"progress": 0.7 + 0.28 * done_inst / max(1, n), "phase": f"Installing {what}{done_inst} of {n}"})
    code = proc.wait()
    if code == 0:
        remember(pkg, True)
        return out({"result": "ok"})
    out({"result": why(code, lines), "detail": lines[-1] if lines else ""})


def remove(pkg):
    if pkg in bundles():
        # the app's folder and its launcher go; what it saved stays, as on a Mac, should it come back
        r = subprocess.run(BUNDLE + ["remove", pkg], capture_output=True)
        return out({"result": "ok" if r.returncode == 0 else "failed"})
    ed, inst = editorial(), installed()
    names = [pkg] + ed["apps"].get(pkg, {}).get("also", [])
    have = next((n for n in names if n in inst), None)
    if not have:
        return out({"result": "ok"})
    required = re.search(r"^Required By\s*:\s*(.+)$", run(["pacman", "-Qi", have]), re.M)
    if required and required.group(1).strip() != "None":
        return out({"result": "needed", "by": required.group(1).split()[:4]})
    proc = subprocess.run(PKEXEC + ["-Rs", "--noconfirm", have], capture_output=True, text=True, errors="replace")
    if proc.returncode == 0:
        remember(pkg, False)
    out({"result": "ok"} if proc.returncode == 0 else {"result": why(proc.returncode, (proc.stdout + proc.stderr).splitlines())})


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else ""), sys.argv[2:]
    commands = {"home": lambda: home(), "search": lambda: search(args), "serve": lambda: serve(), "app": lambda: app(args[0]),
                "install": lambda: install(args[0], "--everything" in args[1:]), "remove": lambda: remove(args[0])}
    if cmd not in commands or (cmd in ("app", "install", "remove") and not args):
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    commands[cmd]()
