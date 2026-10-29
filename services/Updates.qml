pragma Singleton
import qs
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/*
 * Tacit's updates as the person sees them (2026-10-16, "like a Mac"): tacit-fetch-updates keeps the package list fresh
 * and downloads what is waiting (session/updates). Once all of it is here the notch says so once, with Tonight and
 * Restart, and the next start installs it (tacit-update). After that start the notch says how it went. Settings reads
 * the same state from updates.json.
 */
Singleton {
    id: root

    property bool available: true
    // A read or a check in progress (the two Processes below set it; a binding to them here read as undefined on reload)
    property bool checking: false
    property int count: 0
    property bool downloaded: false
    // Tacit's own new version when it is among them ("" when only other parts change)
    property string tacitVersion: ""
    property bool lastCheckFailed: false
    property bool asked: false          // this download was asked for in Settings: its failure is shown
    property bool fetchFailed: false
    property bool ending: false         // the download is over and its list is being read: the progress stays till then
    readonly property bool ready: root.count > 0 && root.downloaded
    // A check, from the press (2026-10-20, Discord: "Check for updates" said "Looking now" for minutes with nothing to
    // show, and afterwards nobody could tell whether anything had come): "looking" while the list is fetched, then
    // "downloading" with how far it is, then "" again and the answer.
    property string phase: ""
    property real progress: 0
    property int totalMB: 0
    property int doneMB: 0
    property double lastChecked: 0
    // the Tacit this computer runs (/usr/share/tacit/release, the tacit package's), and what changed in it and in the one
    // waiting (notes.json in the tacit package: in the downloaded package before the restart, installed after)
    property string currentVersion: ""
    property var notes: []          // [{ version, date, changes: [..] }], newest first, installed
    property var nextNotes: []      // the same for the releases waiting, newer than this one
    // turned on in Settings: look now, not at the next half hour
    readonly property bool enabled: Config.options.updates.enableCheck
    onEnabledChanged: if (root.enabled) root.refresh()

    readonly property bool updateAdvised: available && count > Config.options.updates.adviseUpdateThreshold
    readonly property bool updateStronglyAdvised: available && count > Config.options.updates.stronglyAdviseUpdateThreshold

    function load() {}
    function refresh() {
        if (!waitingProc.running && !fetchProc.running)
            waitingProc.running = true;
    }
    // Check now is the download too: the package list is otherwise only as fresh as the last timer run, so a check
    // could not find a release published an hour ago.
    function checkNow() {
        if (!root.available || root.phase !== "")
            return;
        root.phase = "looking";
        root.lastCheckFailed = false;
        root.fetchFailed = false;
        root.asked = true;
        root.progress = 0;
        fetchProc.running = true;
    }
    // the next start installs them; no password (50-tacit-updates.rules)
    function restartNow() {
        restartProc.running = true;
    }
    // the download for the install is made first; when it fails nothing restarts, and the notch says so
    Process {
        id: restartProc
        command: ["bash", "-c", "systemctl start tacit-update@now.service && systemctl reboot"]
        onExited: (code, status) => {
            if (code !== 0)
                IslandController.request("copied", { "icon": "error", "text": "Couldn't download the update" }, 65);
        }
    }
    // what changed: Settings' About, where the notes are
    function openNotes() {
        Quickshell.execDetached(["bash", "-c", '"${TACIT_BIN:-$HOME/.local/bin}"/settings-open about 2>/dev/null || settings-open about']);
    }
    function tonight() {
        Quickshell.execDetached(["systemctl", "start", "tacit-update@tonight.service"]);
        IslandController.request("copied", { "icon": "schedule", "text": "Tonight, on the charger" }, 65);
    }

    // a look two minutes after start (the night's result, and what the last download left) and every half hour
    Timer {
        interval: 2 * 60 * 1000
        running: Config.ready
        onTriggered: {
            resultFile.reload();
            root.refresh();
        }
    }
    Timer {
        interval: 30 * 60 * 1000
        repeat: true
        running: Config.ready
        onTriggered: root.refresh()
    }

    Process {
        id: waitingProc
        // what is waiting ("name old -> new"), then where each of its files is: file:// once downloaded
        // (only where Tacit installs its updates itself, tacit-session's tacit-update: not on a computer set up by hand,
        // as the owner's Book4 with its held Qt)
        command: ["bash", "-c", "[ -x /usr/lib/tacit/tacit-update ] || { echo unmanaged; exit 0; }; pacman -Qu 2>/dev/null; echo ---; pacman -Sup --print-format %l 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "unmanaged") {
                    root.available = false;
                    return;
                }
                const halves = text.split("---\n");
                if (halves.length < 2) {
                    root.lastCheckFailed = true;
                    return;
                }
                root.lastCheckFailed = root.fetchFailed;
                const waiting = halves[0].split("\n").filter(l => l.includes(" -> "));
                const files = halves[1].split("\n").filter(l => l.length > 0 && !l.startsWith(":"));
                root.count = waiting.length;
                root.downloaded = files.length > 0 && files.every(f => f.startsWith("file://"));
                const tacit = waiting.find(l => l.startsWith("tacit "));
                const ver = tacit ? tacit.split(" ") : [];
                // only a new Tacit release counts (1.4 over 1.3), not a rebuild of the same one
                root.tacitVersion = ver.length === 4 && ver[1].split("-")[0] !== ver[3].split("-")[0] ? ver[3].split("-")[0] : "";
                stateFile.setText(JSON.stringify({ "count": root.count, "ready": root.ready, "tacitVersion": root.tacitVersion,
                                                   "checked": root.lastChecked || Date.now() }));
                if (root.ready && root.tacitVersion.length > 0)
                    nextNotesProc.running = true;
                else
                    root.nextNotes = [];
                if (root.ready)
                    root.announce(waiting.join("\n"));
            }
        }
        onRunningChanged: {
            root.checking = waitingProc.running || fetchProc.running;
            if (!waitingProc.running && root.ending) {
                root.ending = false;
                root.phase = "";
            }
        }
    }

    // What the timer runs, now: refresh the list and download what is waiting, never install (no password: the polkit
    // rule allows wheel to start it). A start that fails says so, instead of reading the old list as "up to date".
    Process {
        id: fetchProc
        command: ["systemctl", "start", "--no-block", "tacit-fetch-updates-now.service"]
        onExited: (code, status) => {
            if (code !== 0) {
                root.phase = "";
                root.lastCheckFailed = true;
                return;
            }
            watchTimer.restart();
        }
        onRunningChanged: root.checking = waitingProc.running || fetchProc.running || root.phase !== ""
    }
    onPhaseChanged: root.checking = waitingProc.running || fetchProc.running || root.phase !== ""

    // How far a download is: what is waiting and its size, against what of it is here already (file://), while either
    // download runs. Pieces finish one package at a time, so it goes up in steps.
    Timer {
        id: watchTimer
        interval: 1200
        repeat: true
        running: root.phase !== "" && !root.ending
        triggeredOnStart: true
        onTriggered: if (!watchProc.running) watchProc.running = true
    }
    property int quietTicks: 0
    Process {
        id: watchProc
        // a oneshot is "activating" while it runs, never "active", and one waiting to start is "inactive" with a job queued
        command: ["bash", "-c", "a=0; for u in tacit-fetch-updates-now.service tacit-fetch-updates.service; do "
            + "case $(systemctl is-active $u) in activating|active) a=1 ;; esac; [ -n \"$(systemctl list-jobs --no-legend $u)\" ] && a=1; done; "
            + "echo \"active $a\"; echo \"result $(systemctl show -P Result tacit-fetch-updates-now.service)\"; echo \"waiting $(pacman -Qu 2>/dev/null | wc -l)\"; pacman -Sup --print-format '%s %l' 2>/dev/null | grep -v '^:'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n");
                const active = lines.some(l => l === "active 1");
                const waiting = parseInt((lines.find(l => l.startsWith("waiting ")) ?? "waiting 0").split(" ")[1]) || 0;
                let total = 0, done = 0;
                for (const l of lines) {
                    const m = l.match(/^(\d+) (\S+)$/);
                    if (!m)
                        continue;
                    total += parseInt(m[1]);
                    if (m[2].startsWith("file://"))
                        done += parseInt(m[1]);
                }
                if (waiting > 0 && total > 0 && done < total) {
                    root.phase = "downloading";
                    root.count = waiting;
                }
                root.totalMB = Math.round(total / 1e6);
                root.doneMB = Math.round(done / 1e6);
                root.progress = total > 0 ? done / total : 0;
                // over once nothing runs (a few looks, so a start that has not shown up yet is not taken for the end)
                root.quietTicks = active ? 0 : root.quietTicks + 1;
                if (root.quietTicks >= 3) {
                    root.quietTicks = 0;
                    // offline, the asked-for download fails at once: say so rather than show the old list
                    root.fetchFailed = root.asked && !lines.includes("result success");
                    root.asked = false;
                    root.lastChecked = Date.now();
                    // the phase ends with the new list read, not before (the old "to download" showed for a second)
                    root.ending = true;
                    root.refresh();
                    if (!waitingProc.running) {
                        root.ending = false;
                        root.phase = "";
                    }
                }
            }
        }
    }
    // a download already running in the background (its timer's) shows its progress too
    function follow() {
        if (root.available && root.phase === "")
            followProc.running = true;
    }
    Process {
        id: followProc
        command: ["bash", "-c", "systemctl is-active tacit-fetch-updates.service tacit-fetch-updates-now.service | grep -q activating"]
        onExited: (code, status) => {
            if (code === 0 && root.phase === "")
                root.phase = "looking";
        }
    }

    // ---- the version and what changed in it
    FileView {
        path: "/usr/share/tacit/release"
        printErrors: false
        onLoaded: {
            const m = text().match(/^VERSION="?([^"\n]+)"?/m);
            root.currentVersion = m ? m[1] : "";
        }
    }
    FileView {
        path: "/usr/share/tacit/notes.json"
        printErrors: false
        onLoaded: {
            try {
                root.notes = JSON.parse(text()).releases ?? [];
            } catch (e) {
                root.notes = [];
            }
        }
    }
    function newer(a, b) {      // a newer than b, as release versions (1.0.10 over 1.0.9)
        const x = `${a}`.split(/[.-]/).map(n => parseInt(n) || 0), y = `${b}`.split(/[.-]/).map(n => parseInt(n) || 0);
        for (let i = 0; i < Math.max(x.length, y.length); i++)
            if ((x[i] ?? 0) !== (y[i] ?? 0))
                return (x[i] ?? 0) > (y[i] ?? 0);
        return false;
    }
    // the waiting release's notes, out of its downloaded package (signed with the rest of it)
    Process {
        id: nextNotesProc
        // tacit's own package: -Sp lists the new things it needs first (playerctl before tacit-1.1.0), and the first line
        // had no notes, so the waiting release showed the installed one's
        command: ["bash", "-c", "f=$(pacman -Sp --print-format %l tacit 2>/dev/null | grep -E '^file://.*/tacit-[0-9][^/]*-any\\.pkg\\.tar' | tail -1); [ -n \"$f\" ] && bsdtar -xOf \"${f#file://}\" usr/share/tacit/notes.json 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const all = JSON.parse(text).releases ?? [];
                    root.nextNotes = all.filter(r => root.newer(r.version, root.currentVersion));
                } catch (e) {
                    root.nextNotes = [];
                }
            }
        }
    }

    // said once for each set of waiting updates
    FileView {
        id: announcedFile
        blockLoading: true
        path: `${Directories.userStateDir}/updates-announced`
        printErrors: false
    }
    function announce(key) {
        if (!Config.options.updates.enableCheck || announcedFile.text().trim() === key.trim())
            return;
        root.say("update", {
            "icon": "system_update",
            "text": root.tacitVersion.length > 0 ? `Tacit ${root.tacitVersion} is ready` : "Updates are ready"
        }, () => announcedFile.setText(key));
    }

    // A line waits until the notch can say it: it drops lines while the screen is locked, and the first look runs about
    // when the boot lock is still up (the VM install test: the result was marked said and never shown). Marked said only
    // once it is handed over.
    property var pending: []
    function say(name, data, mark) {
        root.pending = root.pending.filter(p => p.name !== name).concat([{ "name": name, "data": data, "mark": mark }]);
        root.flush();
    }
    function flush() {
        if (root.pending.length === 0 || !IslandController.enabled || IslandController.suppressed || !IslandController.warmedUp)
            return;
        if (!bootLockProc.running)
            bootLockProc.running = true;
    }
    // the boot lock is a program of its own, so the shell's own lock state misses it: a line handed over under it was
    // never seen (the VM test, "Updated"). It leaves martida-lock-ready once someone has signed in (bootlock.qml); [b] keeps pgrep off this very
    // command line.
    Process {
        id: bootLockProc
        command: ["bash", "-c", '[ -e "$XDG_RUNTIME_DIR/martida-lock-ready" ] || ! pgrep -f "[b]ootlock[.]qml" >/dev/null']
        onExited: (code, status) => {
            if (code !== 0 || root.pending.length === 0)
                return;
            const lines = root.pending;
            root.pending = [];
            for (const p of lines) {
                p.mark();
                IslandController.request(p.name, p.data, 60);
            }
        }
    }
    Timer {
        interval: 15000
        repeat: true
        running: root.pending.length > 0
        onTriggered: root.flush()
    }

    FileView {
        id: stateFile
        path: `${Directories.userStateDir}/updates.json`
        printErrors: false
    }

    // how the last install went (tacit-update install), said once
    FileView {
        id: resultFile
        path: "/var/lib/tacit/update-result"
        printErrors: false
        onLoaded: {
            let r = null;
            try {
                r = JSON.parse(resultFile.text());
            } catch (e) {
                return;
            }
            if (!r || `${r.at}` === seenFile.text().trim())
                return;
            if (r.ok && r.untouched) {
                seenFile.setText(`${r.at}`);
                return;     // there was nothing to install
            }
            // a failed one is offered again when it is downloaded again
            if (!r.ok)
                announcedFile.setText("");
            root.say("updated", {
                "icon": r.ok ? "check" : "error",
                "notes": r.ok,
                "text": r.ok ? (r.version ? `Updated to Tacit ${r.version.split("-")[0]}` : "Updated")
                    : r.untouched ? "The update didn't install · nothing changed"
                    : "The update stopped partway · it tries again"
            }, () => seenFile.setText(`${r.at}`));
        }
    }
    FileView {
        id: seenFile
        blockLoading: true
        path: `${Directories.userStateDir}/updates-seen`
        printErrors: false
    }
}
