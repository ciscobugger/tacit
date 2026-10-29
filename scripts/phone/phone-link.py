#!/usr/bin/env python3
"""phone-link.py <command> [args]: the shell's one way to the phone daemon (kdeconnectd), over D-Bus with busctl.

  state                  JSON: installed, running, this computer's name, and every device it knows
  refresh                ask the daemon to look for devices again
  accept <id>            accept a pairing the phone asked for (asks for one when the phone has not)
  decline <id>           turn a pairing request down
  forget <id>            unpair
  send <id> <path>       hand one file to the daemon for that phone; exit 0 = the daemon took it
  files <path>...        print the paths that are readable files (folders and missing paths are left out)
  qr <text>              the text as a QR code: one line per row of dots, 1 = dark (needs qrencode)

Exit codes of send: 0 taken, 2 phone not reachable, 3 file missing or unreadable, 1 anything else (the reason is on
stderr). Nothing here pairs by itself: accept and forget are what the person pressed.
"""
import json
import os
import shutil
import socket
import subprocess
import sys

NAME = "org.kde.kdeconnect"
DAEMON = "/modules/kdeconnect"
I_DAEMON = "org.kde.kdeconnect.daemon"
I_DEVICE = "org.kde.kdeconnect.device"
I_SHARE = "org.kde.kdeconnect.device.share"


def bus(*args, timeout=5):
    out = subprocess.run(["busctl", "--user", "--json=short", *args], capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "busctl failed")
    return json.loads(out.stdout)["data"] if out.stdout.strip() else []


def call(path, iface, method, sig="", *args):
    return bus("call", NAME, path, iface, method, sig, *args)


def prop(path, name):
    # a property comes back as the value itself, a call's reply as a list of values
    return bus("get-property", NAME, path, I_DEVICE, name)


def dev_path(i):
    return f"{DAEMON}/devices/{i}"


def computer_name():
    try:
        return call(DAEMON, I_DAEMON, "announcedName")[0]
    except Exception:
        return socket.gethostname()


def device(i):
    p = dev_path(i)
    d = {"id": i, "name": "", "paired": False, "reachable": False, "asked": False, "key": ""}
    try:
        d["name"] = prop(p, "name")
        d["reachable"] = bool(prop(p, "isReachable"))
        d["paired"] = bool(prop(p, "isPaired"))
    except Exception:
        return None
    # the phone asked us to pair: the code both screens must show is the verification key
    try:
        d["asked"] = bool(call(p, I_DEVICE, "isPairRequestedByPeer")[0])
        if d["asked"] or call(p, I_DEVICE, "isPairRequested")[0]:
            d["key"] = call(p, I_DEVICE, "verificationKey")[0]
    except Exception:
        pass
    return d


def state():
    s = {"installed": shutil.which("kdeconnect-cli") is not None, "running": False, "name": socket.gethostname(), "devices": []}
    try:
        ids = call(DAEMON, I_DAEMON, "devices", "bb", "false", "false")[0]
    except Exception:
        return s
    s["running"] = True
    s["name"] = computer_name()
    s["devices"] = [d for d in (device(i) for i in ids) if d]
    return s


def send(i, path):
    if not os.path.isfile(path) or not os.access(path, os.R_OK):
        print("file missing or unreadable", file=sys.stderr)
        return 3
    try:
        if not prop(dev_path(i), "isReachable"):
            print("phone not reachable", file=sys.stderr)
            return 2
        bus("call", NAME, f"{dev_path(i)}/share", I_SHARE, "shareUrl", "s", "file://" + path)
    except Exception as e:
        print(e, file=sys.stderr)
        return 1
    return 0


def qr(text):
    try:
        out = subprocess.run(["qrencode", "-t", "ASCII", "-m", "0", "-o", "-", text], capture_output=True, text=True, timeout=5)
    except OSError:
        return 1   # no qrencode: the page shows no code
    if out.returncode != 0:
        return 1
    for line in out.stdout.splitlines():
        # two characters make one dot
        print("".join("1" if line[k] == "#" else "0" for k in range(0, len(line) - 1, 2)))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd, rest = argv[1], argv[2:]
    try:
        if cmd == "state":
            print(json.dumps(state()))
        elif cmd == "refresh":
            call(DAEMON, I_DAEMON, "forceOnNetworkChange")
        elif cmd == "accept":
            p = dev_path(rest[0])
            call(p, I_DEVICE, "acceptPairing" if call(p, I_DEVICE, "isPairRequestedByPeer")[0] else "requestPairing")
        elif cmd == "decline":
            call(dev_path(rest[0]), I_DEVICE, "cancelPairing")
        elif cmd == "forget":
            call(dev_path(rest[0]), I_DEVICE, "unpair")
        elif cmd == "send":
            return send(rest[0], rest[1])
        elif cmd == "files":
            for f in rest:
                if os.path.isfile(f) and os.access(f, os.R_OK):
                    print(f)
        elif cmd == "qr":
            return qr(rest[0])
        else:
            print(__doc__)
            return 1
    except (IndexError, RuntimeError, subprocess.TimeoutExpired) as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
