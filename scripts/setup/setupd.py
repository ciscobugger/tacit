#!/usr/bin/env python3
# setupd: what Tacit's setup (setup.qml) needs from the computer, as JSON lines on stdin/stdout.
#
# On Tacit's live system (the ISO, /run/archiso) it installs for real: tacit-install (beside this file, run as root
# with sudo) puts Tacit next to what is on the disk shown, or erases it, copies the live system onto it, joins the
# network asked for and makes the account. There it also reads, as root, what "next to" needs: the partition table,
# its free room, and how small Windows can go. Anywhere else it is a PRACTICE run: it reads the computer and plays the install, but writes to no disk,
# joins no network and creates no account.
#
# TACIT_SETUP_SCENARIO=windows|bitlocker|asleep|full|empty|linux|linuxroom  shows a disk case this computer does not have
#                     two                                   two disks: Windows on one, the other empty
#                     check|unread                          Windows with a disk check waiting, or a partition not read
# TACIT_SETUP_FAIL=1                                       the practice install stops at 60 %
# TACIT_SETUP_SECONDS=90                                    how long the practice install takes
import json, os, re, select, subprocess, sys, threading, time

SCENARIO = os.environ.get("TACIT_SETUP_SCENARIO", "")
# the real install only on Tacit's live system, never with a made-up disk
REAL = os.path.isdir("/run/archiso") and not SCENARIO and os.environ.get("TACIT_SETUP_PRACTICE") != "1"
INSTALLER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tacit-install")
FAIL = os.environ.get("TACIT_SETUP_FAIL") == "1"
SECONDS = float(os.environ.get("TACIT_SETUP_SECONDS", "90"))
GB = 1_000_000_000
# Tacit itself is about 7 GB, and the swap file for hibernating is the size of the memory (tacit-install makes it only
# where 20 GB stay free): 32 GB, as for a whole disk. tacit-install refuses less
MIN_TACIT = 32 * GB
WINDOWS_DATA = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
ESP = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
lock = threading.Lock()

def emit(obj):
    with lock:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()

def run(*cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

# ------------------------------------------------------------------ languages and keyboards
# the five offered first, then the rest; names in their own language
LANGUAGES = [("en_GB", "English", "gb"), ("sv_SE", "Svenska", "se"), ("so_SO", "Soomaali", "us"), ("ar_SA", "العربية", "ara"),
             ("de_DE", "Deutsch", "de"), ("en_US", "English (US)", "us"), ("fr_FR", "Français", "fr"), ("es_ES", "Español", "es"),
             ("it_IT", "Italiano", "it"), ("nl_NL", "Nederlands", "nl"), ("nb_NO", "Norsk bokmål", "no"), ("da_DK", "Dansk", "dk"),
             ("fi_FI", "Suomi", "fi"), ("pl_PL", "Polski", "pl"), ("pt_PT", "Português", "pt"), ("pt_BR", "Português (Brasil)", "br"),
             ("tr_TR", "Türkçe", "tr"), ("fa_IR", "فارسی", "ir"), ("ur_PK", "اردو", "pk"), ("hi_IN", "हिन्दी", "in"),
             ("ru_RU", "Русский", "ru"), ("uk_UA", "Українська", "ua"), ("el_GR", "Ελληνικά", "gr"), ("he_IL", "עברית", "il"),
             ("zh_CN", "中文 (简体)", "cn"), ("ja_JP", "日本語", "jp"), ("ko_KR", "한국어", "kr"), ("am_ET", "አማርኛ", "et"),
             ("sw_KE", "Kiswahili", "ke"), ("ti_ER", "ትግርኛ", "et")]
RTL = {"ar_SA", "fa_IR", "ur_PK", "he_IL"}

def layouts():
    out, on = [], False
    try:
        for line in open("/usr/share/X11/xkb/rules/evdev.lst"):
            if line.startswith("! layout"):
                on = True; continue
            if line.startswith("!"):
                if on: break
                continue
            if on and line.strip():
                code, name = line.strip().split(None, 1)
                if code != "custom":        # "A user-defined custom Layout": not something a person picks here
                    out.append({"code": code, "name": name})
    except OSError:
        pass
    return sorted(out, key=lambda l: l["name"])

# ------------------------------------------------------------------ Wi-Fi (read only)
def wifi():
    nets = {}
    for line in run("nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "dev", "wifi", "list").splitlines():
        p = [re.sub(r"\\(.)", r"\1", f) for f in re.findall(r"((?:\\.|[^:\\])*)(?::|$)", line)]
        if len(p) < 4 or not p[1]:
            continue
        ssid = p[1]
        n = {"ssid": ssid, "signal": int(p[2] or 0), "secure": p[3] not in ("", "--"), "inUse": p[0] == "*"}
        if ssid not in nets or n["signal"] > nets[ssid]["signal"]:
            nets[ssid] = n
    return sorted(nets.values(), key=lambda n: (not n["inUse"], -n["signal"]))[:8]

# A cable that connects this computer (NetworkManager's ethernet device connected): Setup says so instead of "No
# networks found", which is all it said on a cable (the VM test, 2026-10-16)
def wired():
    return any(l.split(":")[1:2] == ["connected"] for l in run("nmcli", "-t", "-f", "TYPE,STATE", "dev").splitlines()
               if l.startswith("ethernet:"))

# The time zone where this computer is, from its internet address (Ubuntu's lookup, which its installer uses for the
# same), set on the live system so Setup's clock is right, and handed to tacit-install; "" offline or for a name the
# system does not have, and the installed system keeps UTC. Every install was UTC until 2026-10-16.
zone = {"name": ""}
def find_zone():
    m = re.search(r"<TimeZone>([A-Za-z0-9_+/-]+)</TimeZone>", run("curl", "-fsS", "--max-time", "6", "https://geoip.ubuntu.com/lookup", timeout=8))
    if m and os.path.isfile(f"/usr/share/zoneinfo/{m.group(1)}"):
        zone["name"] = m.group(1)
        as_root("timedatectl", "set-timezone", zone["name"])

# ------------------------------------------------------------------ disks (read only)
def as_root(*cmd):
    """A read that needs root: only on the live system, where sudo asks for nothing."""
    if not REAL:
        return None
    try:
        return subprocess.run(["sudo", "-n", *cmd], input="", capture_output=True, text=True, errors="replace", timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None

def gaps(t):
    """The disk's free stretches in sectors, (first, last), starting on a 1 MiB boundary (as tacit-install works them out)."""
    align = max(1, 1024 * 1024 // t["sectorsize"])
    out, at = [], t["firstlba"]
    for start, size in sorted((p["start"], p["size"]) for p in t["partitions"]) + [(t["lastlba"] + 1, 0)]:
        first = -(-at // align) * align
        if start - 1 >= first:
            out.append((first, start - 1))
        at = max(at, start + size)
    return out

def layout(name, parts):
    """What "next to" needs: GPT, an EFI partition, the biggest free stretch; for Windows how small its own partition can
    go, and whether it shut down fully (Fast Startup leaves it hibernated)."""
    r = as_root("sfdisk", "--json", name)
    try:
        t = json.loads(r.stdout)["partitiontable"]
    except (AttributeError, ValueError, KeyError):
        return {}
    out = {"gpt": t.get("label") == "gpt", "esp": any(p["type"].lower() == ESP for p in t["partitions"]),
           "free": max([(b - a + 1) * t["sectorsize"] for a, b in gaps(t)] or [0])}
    # the partitions tacit-install checks: Windows data (Recovery and OEM are NTFS too)
    data = {p["node"].rsplit("/", 1)[-1] for p in t["partitions"] if p["type"].lower() == WINDOWS_DATA}
    ntfs = [p for p in parts if p.get("fstype") == "ntfs" and p["name"] in data]
    if ntfs:
        win = max(ntfs, key=lambda p: p["size"])
        node = "/dev/" + win["name"]
        # Fast Startup's image sits on the system volume but caches every NTFS volume, so each one is looked at
        stopped = None
        for p in ntfs:
            n = "/dev/" + p["name"]
            i = as_root("ntfsresize", "--info", "--no-action", n)
            h = as_root("sh", "-c", 'ntfscat "$1" hiberfil.sys 2>/dev/null | head -c 4', "sh", n)
            if i and (i.returncode != 0 or (h and h.stdout.lower() == "hibr")):
                stopped = stopped or (i, h)
            if p is win:
                info = i
        m = re.search(r"You might resize at (\d+) bytes", info.stdout if info else "")
        if stopped:
            out.update(asleep=True, **windows_stopped(*stopped))
        elif m:
            out.update(used=int(m.group(1)), winSize=win["size"])
    return out

def windows_stopped(info, hib):
    """Why Windows' partition cannot be sized now, from ntfsresize's own sentences. Every refusal used to read "Windows
    didn't shut down fully"; a disk check Windows had waiting looked the same (ygnk, 2026-10-30). All it said goes to
    /tmp/tacit-windows.log, and a reason that is none of these is shown in its words."""
    said = "\n".join(s for s in (info.stderr, info.stdout) if s).strip()
    try:
        with open("/tmp/tacit-windows.log", "w") as f:
            f.write(said + "\n")
    except OSError:
        pass
    low = said.lower()
    if (hib and hib.stdout.lower() == "hibr") or "hibernat" in low or "journal file is unclean" in low:
        return {"why": "asleep"}
    if "scheduled for check" in low or "chkdsk" in low:
        return {"why": "check"}
    lines = [l.strip() for l in said.splitlines() if l.strip() and not l.startswith("ntfsresize v")]
    return {"why": "other", "says": " ".join(lines[-2:])[:240]}

# the disk picked in Setup's disk list (op "disk"); None until then
chosen = {"name": None}

def all_disks():
    """Every disk inside this computer, each with what is on it. Never the stick setup runs from, nor any USB disk."""
    if SCENARIO:
        return fake_disks(SCENARIO)
    try:
        d = json.loads(run("lsblk", "-J", "-b", "-o", "NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL,TRAN,RM,MOUNTPOINTS"))
    except ValueError:
        return []
    # the stick itself, however it is attached (a card reader, a VM's disk): the disk under the live system's boot files
    src = run("findmnt", "-nro", "SOURCE", "/run/archiso/bootmnt").strip()
    stick = run("lsblk", "-nrso", "NAME", src).split()[-1:] if src else []
    return [describe(b) for b in d.get("blockdevices", [])
            if b.get("type") == "disk" and not b.get("rm") and b.get("tran") != "usb" and not b["name"].startswith(("zram", "loop")) and not re.fullmatch(r"mmcblk\d+(boot\d+|rpmb)", b["name"])
            and b["name"] not in stick]

def disks():
    """The disk Tacit would go on: the one picked, else an empty one (nothing to lose), else the biggest. It was always
    the biggest, with no choice: with Windows on a big disk and an empty one beside it, Tacit went next to Windows or
    erased it (a Reddit reader, 2026-10-18)."""
    ds = all_disks()
    if not ds:
        return {"case": "none"}
    picked = next((d for d in ds if d["name"] == chosen["name"]), None)
    empty = [d for d in ds if d["case"] == "empty" and d["size"] >= MIN_TACIT]
    return picked or max(empty or ds, key=lambda d: d["size"])

def describe(best):
    parts = best.get("children", [])
    fs = [p.get("fstype") or "" for p in parts]
    disk = {"name": "/dev/" + best["name"], "model": (best.get("model") or "").strip() or "this disk", "size": best["size"]}
    if "BitLocker" in fs:
        return dict(disk, case="bitlocker")
    # what Windows uses and the free room need root: a practice run says so rather than guess
    room = layout(disk["name"], parts) if parts else {}
    if "ntfs" in fs:
        return dict(disk, case="asleep", why=room.get("why", "asleep"), says=room.get("says", "")) if room.get("asleep") \
            else dict(disk, case="windows", **{"used": None, **room})
    if any(f in ("ext4", "btrfs", "xfs", "f2fs") for f in fs):
        return dict(disk, case="linux", **room)
    return dict(disk, case="empty" if not parts and not best.get("fstype") else "other", **room)

def fake_disks(case):
    if case == "two":
        return [dict(fake_disk("windows"), name="/dev/sda", model="Seagate Barracuda", size=1000 * GB, winSize=998 * GB),
                fake_disk("empty")]
    return [fake_disk(case)]

def fake_disk(case):
    disk = {"name": "/dev/nvme0n1", "model": "Samsung SSD", "size": 512 * GB, "fake": True, "gpt": True, "esp": True, "free": 0}
    if case == "windows":
        return dict(disk, case="windows", used=140 * GB, winSize=510 * GB)
    if case == "full":
        return dict(disk, case="windows", used=480 * GB, winSize=510 * GB)
    if case == "linuxroom":
        return dict(disk, case="linux", free=120 * GB)
    if case == "check":
        return dict(disk, case="asleep", why="check", says="")
    if case == "unread":
        return dict(disk, case="asleep", why="other", says="This software has detected that the NTFS volume is already "
                    "opened by another software thus it refuses to progress to preserve data consistency.")
    return dict(disk, case=case)

def plan(d):
    """Next to what is on the disk: in its free room, or for Windows in room made by shrinking it, Windows keeping what it
    uses and room to grow. Tacit needs 64 GB at least; without GPT and an EFI partition there is no "next to"."""
    if d.get("case") not in ("windows", "linux", "other") or not (d.get("gpt") and d.get("esp")):
        return None
    if d.get("free", 0) >= MIN_TACIT:
        return {"windowsKeeps": None, "tacitGets": d["free"], "room": True}
    if d["case"] != "windows" or d.get("used") is None:
        return {"windowsKeeps": None, "tacitGets": d.get("free", 0), "room": False}
    # the free space split evenly, Windows keeping at least 25 GB of it for its updates and files (tacit-install refuses
    # under 20 GB): about 65 GB free is enough. It was a quarter more than Windows used and 47 GB, at least 100 GB, and
    # keeping Windows wanted about 120 GB free (owner 2026-10-17: "120gb to install os ? how")
    keep = min(d["used"] + max(25 * GB, (d["winSize"] - d["used"]) // 2), d["winSize"])
    return {"windowsKeeps": keep, "tacitGets": d["winSize"] - keep, "room": d["winSize"] - keep >= MIN_TACIT}

# The plan each disk was shown with. Install measures the disk again, and a second read could disagree with the one the
# person decided on: it refused "no room next to it" right after showing room (Discord 2026-10-23, Tamrawii)
shown = {}
def show(d):
    shown[d.get("name")] = plan(d)
    return shown[d.get("name")]

def no_room(d, pl):
    """Why "next to" cannot go on this disk, in the words Setup shows after "What stopped it:"."""
    if d.get("case") == "bitlocker":
        return "BitLocker is on for this disk"
    if d.get("case") == "asleep" and d.get("why") == "check":
        return "Windows has a disk check waiting (restart Windows twice, then shut it down)"
    if d.get("case") == "asleep" and d.get("why") == "other":
        return "Setup could not read Windows' partition safely"
    if d.get("case") == "asleep":
        return "Windows is hibernated rather than shut down (turn off Fast Startup in Windows, then shut it down)"
    if not d.get("gpt"):
        return "this disk uses the older MBR layout"
    if not d.get("esp"):
        return "this disk has no EFI partition"
    if d.get("case") == "windows" and d.get("used") is None:
        return "Setup could not read how much of Windows' partition is in use"
    return f"Tacit needs {MIN_TACIT // GB} GB and only {(pl or {}).get('tacitGets', 0) // GB} GB can be made free"

# ------------------------------------------------------------------ power
def power():
    base = "/sys/class/power_supply"
    ac, pct, battery = False, None, False
    try:
        for n in os.listdir(base):
            t = open(f"{base}/{n}/type").read().strip()
            if t == "Mains" and open(f"{base}/{n}/online").read().strip() == "1":
                ac = True
            battery = battery or t == "Battery"
            if t == "Battery" and pct is None:
                c = open(f"{base}/{n}/capacity").read().strip()
                if c.isdigit() and int(c) > 0:
                    pct = int(c)
    except OSError:
        pass
    # a computer without a battery (a desktop) is always on the charger: Setup asked it to plug one in
    return {"ac": ac or not battery, "battery": pct}

# ------------------------------------------------------------------ the practice install
install = {"running": False}

def practice_install():
    install["running"] = True
    t0 = time.time()
    while True:
        f = min(1.0, (time.time() - t0) / SECONDS)
        if FAIL and f >= 0.6:
            emit({"ev": "install", "state": "failed", "done": f, "untouched": True})
            break
        left = SECONDS * (1 - f)
        # no time for the first 15 s: there is nothing to measure yet
        emit({"ev": "install", "state": "done" if f >= 1 else "running", "done": round(f, 3),
              "left": None if time.time() - t0 < 15 else round(left)})
        if f >= 1:
            break
        time.sleep(1)
    install["running"] = False

# ------------------------------------------------------------------ the real install (tacit-install as root)
def real_install(disk, place, keep):
    install["running"] = True
    t0 = time.time()
    p = subprocess.Popen(["sudo", "-n", "python3", "-I", INSTALLER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=open("/tmp/tacit-install.log", "w"), text=True)   # what it says on the way, for a failure
    install["proc"] = p
    p.stdin.write(json.dumps({"disk": disk, "place": place, "keep": keep}) + "\n")
    p.stdin.flush()
    ended = False
    for line in p.stdout:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        done = m.get("done", 0)
        # time left from the pace so far, once there is a pace to go by
        left = None if time.time() - t0 < 15 or done <= 0.02 else round((time.time() - t0) * (1 - done) / done)
        ev = {"ev": "install", "state": m["state"], "done": done, "left": left, "other": m.get("other")}
        if m["state"] == "failed":
            # the installer's own reasons are plain words ("the disk is smaller than 32 GB"); a tool's failure ("sgdisk failed:
            # ...") is plumbing, shown as nothing more than "didn't finish" and kept in /tmp/tacit-install.log
            reason = m.get("reason", "")
            ev.update(untouched=m.get("untouched", False), reason="" if re.match(r"\S+ failed:", reason) else reason)
        emit(ev)
        ended = m["state"] in ("done", "failed")
    p.wait()
    if not ended:
        emit({"ev": "install", "state": "failed", "done": 0, "untouched": False, "reason": "the installer stopped"})
    install["running"] = False

def send_answers():
    p = install.get("proc")
    if p and p.poll() is None and not install.get("sent"):
        install["sent"] = True
        p.stdin.write(json.dumps({"answers": install["answers"]}) + "\n")
        p.stdin.flush()

# ------------------------------------------------------------------ requests
def act(req):
    op = req.get("op")
    if op == "hello":
        if REAL:
            threading.Thread(target=find_zone, daemon=True).start()
        d = disks()
        # the disk list only where there is a choice to make
        many = all_disks()
        listed = [dict(x, plan=show(x)) for x in many] if len(many) > 1 else []
        emit({"ev": "hello", "practice": not REAL, "disks": listed, "languages": [{"code": c, "name": n, "layout": k, "rtl": c in RTL} for c, n, k in LANGUAGES],
              "layouts": layouts(), "wifi": wifi(), "wired": wired(), "disk": d, "plan": show(d), "power": power(), "scenario": SCENARIO})
    elif op == "wifi":
        emit({"ev": "wifi", "wifi": wifi(), "wired": wired()})
    elif op == "disk":
        if not install["running"]:
            chosen["name"] = req.get("name")
        d = disks()
        emit({"ev": "disk", "disk": d, "plan": show(d)})
    elif op == "power":
        emit({"ev": "power", "power": power()})
    elif op == "join":
        if REAL:
            # NetworkManager joins it (and keeps it, so the installed system has it too); the password stays in argv
            # only for nmcli's own run on this live system
            # nmcli gives up on its own (--wait) before our timeout; a run that still overruns, or cannot start, is a
            # join that did not happen, and Setup is always answered
            cmd = ["nmcli", "--wait", "30", "dev", "wifi", "connect", req.get("ssid", "")] + (["password", req.get("password", "")] if req.get("secure") else [])
            try:
                ok = subprocess.run(cmd, capture_output=True, timeout=45).returncode == 0
            except (subprocess.TimeoutExpired, OSError):
                ok = False
        else:
            # practice: nothing is joined. A password under 8 characters is "wrong", so that screen can be seen.
            time.sleep(1.2)
            ok = not req.get("secure") or len(req.get("password", "")) >= 8
        if ok and REAL and not zone["name"]:
            threading.Thread(target=find_zone, daemon=True).start()
        emit({"ev": "join", "ssid": req.get("ssid"), "ok": ok})
    elif op == "install":
        if not install["running"]:
            # a retry's new installer has had no answers: the person answers again after this request, and only those go
            install.pop("answers", None)
            install["sent"] = False
            if REAL:
                d = disks()
                pl = plan(d)
                # "next to" is never turned into an erase: without room it stops before anything changes. Room shown
                # earlier goes ahead on the shown plan: tacit-install measures again before it shrinks anything and stops
                # with the disk untouched, in its own words, where there is none
                if req.get("place") == "next" and not (pl and pl["room"]):
                    seen = shown.get(d.get("name"))
                    with open("/tmp/tacit-setup-plan.log", "a") as log:
                        print(json.dumps({"disk": d, "now": pl, "shown": seen}), file=log)
                    if not (seen and seen["room"]):
                        emit({"ev": "install", "state": "failed", "done": 0, "untouched": True, "reason": no_room(d, pl)})
                        return
                    pl = seen
                place = "next" if req.get("place") == "next" else "instead"
                keep = pl["windowsKeeps"] if place == "next" else None
                threading.Thread(target=real_install, args=(d.get("name"), place, keep), daemon=True).start()
            else:
                threading.Thread(target=practice_install, daemon=True).start()
    elif op == "answers":
        if REAL:
            install["answers"] = {k: v for k, v in req.items() if k != "op"}
            install["answers"]["timezone"] = zone["name"]
            send_answers()
            emit({"ev": "answers", "ok": True})
            return
        # practice: kept for review only, never the password
        a = {k: v for k, v in req.items() if k not in ("op", "password")}
        os.makedirs(os.path.expanduser("~/.cache/tacit-setup"), exist_ok=True)
        with open(os.path.expanduser("~/.cache/tacit-setup/answers.json"), "w") as f:
            json.dump(a, f, indent=1)
        emit({"ev": "answers", "ok": True})
    elif op == "restart":
        restart()
    elif op == "off":
        if REAL:
            subprocess.run(["sudo", "-n", "systemctl", "poweroff"])

def restart():
    if REAL:
        subprocess.run(["sudo", "-n", "systemctl", "reboot"])

def main():
    # os.read, not sys.stdin: a buffered readline() keeps lines select() can no longer see
    fd, buf = sys.stdin.fileno(), b""
    while True:
        r, _, _ = select.select([fd], [], [], 10)
        if not r:
            emit({"ev": "power", "power": power()})
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            return
        buf += chunk
        *lines, buf = buf.split(b"\n")
        for line in lines:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            threading.Thread(target=act, args=(req,), daemon=True).start()

if __name__ == "__main__":
    main()
