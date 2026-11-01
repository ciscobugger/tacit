pragma Singleton
import qs
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * The day record: one append-only file of what happened on this machine, one JSON object per
 * line - {"t": epoch ms, "kind": ..., ...}. Written by the Claude Code hooks
 * (~/.local/bin/notch-session: session start / prompt / waiting / done / end) and by the
 * shell (screenshots, downloads, faults, lock and unlock). Read by the island's away brief on
 * unlock - through since(), which reaches back past midnight into the rolled files; the ledger
 * and a today strip are meant to read it and do not yet.
 *
 * The hook keeps one day per file (it rolls events.jsonl to events-<date>.jsonl), so what is
 * parsed here is one day's records - but the roll replaces the file the watch holds.
 *
 * Kinds: session.start session.working session.waiting session.done session.end
 *        file.screenshot file.download fault.charger fault.disk lock unlock pr.<state>
 */
Singleton {
    id: root

    readonly property string dir: FileUtils.trimFileProtocol(`${Directories.home}/.local/state/crew`)
    readonly property string path: `${root.dir}/events.jsonl`

    property var events: []      // today's, oldest first
    property real dayStart: 0

    function log(kind, fields) {
        const rec = Object.assign({ "t": Date.now(), "kind": kind }, fields ?? ({}));
        Quickshell.execDetached(["bash", "-c", 'mkdir -p "$(dirname "$2")"; printf "%s\\n" "$1" >> "$2"', "_", JSON.stringify(rec), root.path]);
    }

    property int retries: 0
    // Same floor as Threads: crew's events file is only there once something has been logged,
    // and until then every reload fails with a warning. Back off, reset on a successful read.
    property int floorInterval: 30000

    FileView {
        id: file
        path: Qt.resolvedUrl("file://" + root.path)
        watchChanges: true
        onFileChanged: file.reload()
        onLoaded: {
            root.retries = 0;
            root.floorInterval = 30000;
            root.parse(file.text());
        }
        // Mid-roll the file is gone for an instant: come back for it, and keep the day already
        // read rather than show an empty one.
        onLoadFailed: {
            if (root.retries < 10) {
                root.retries += 1;
                retry.restart();
            }
        }
    }
    Timer {
        id: retry
        interval: 500
        onTriggered: file.reload()
    }
    Timer {   // the floor under the watch, which the roll's rename drops
        interval: root.floorInterval
        running: true
        repeat: true
        onTriggered: {
            file.reload();
            // no events yet: 30 s -> 60 -> 120 -> 240 -> 300 s, then hold
            root.floorInterval = Math.min(root.floorInterval * 2, 300000);
        }
    }
    Component.onCompleted: file.reload()

    function parse(text) {
        const start = new Date();
        start.setHours(0, 0, 0, 0);
        root.dayStart = start.getTime();
        const out = [];
        let dropped = 0;
        for (const line of (text + "").split("\n")) {
            if (!line.trim())
                continue;
            try {
                // a freeze leaves an ext4 hole ahead of a record: two lines in the history carry
                // leading NUL bytes and are otherwise valid, so strip them rather than lose them
                const e = JSON.parse(line.replace(/^[\x00-\x1f]+/, ""));
                if (e.t >= root.dayStart)
                    out.push(e);
            } catch (err) {
                dropped++;
            }
        }
        if (dropped > 0)
            console.warn(`[Journal] ${dropped} line(s) of ${root.path} could not be read`);
        root.events = out;
    }

    // ------------------------------------------------------------------ a window of the record
    // `events` is today's, so a caller asking from before midnight - the away brief after a
    // night locked - has to be answered from the day files: the one the hook is appending to and
    // the ones it has rolled (events-<date>.jsonl). Read in a process, because the whole history
    // is on the other side of that `cat`. The t of a record is its first key; awk reads it
    // without parsing the line, so the NUL-prefixed records a freeze left behind survive to be
    // cleaned up here the way parse() cleans them.
    Process {
        id: tailProc
        property var deliver: null
        stdout: StdioCollector {
            onStreamFinished: {
                const deliver = tailProc.deliver;
                tailProc.deliver = null;
                if (!deliver)
                    return;
                const out = [];
                for (const line of (text + "").split("\n")) {
                    if (!line.trim())
                        continue;
                    try {
                        out.push(JSON.parse(line.replace(/^[\x00-\x1f]+/, "")));
                    } catch (err) {}
                }
                deliver(out);
            }
        }
    }
    function since(t, deliver) {
        if (t >= root.dayStart) {
            deliver(root.events.filter(e => e.t >= t));
            return;
        }
        tailProc.running = false;
        tailProc.deliver = deliver;
        tailProc.command = ["bash", "-c",
            'cat $(ls -1 "$1"/events-*.jsonl 2>/dev/null) "$1/events.jsonl" 2>/dev/null'
            + ' | awk -v s="$2" \'match($0, /"t":[0-9]+/) && substr($0, RSTART + 4, RLENGTH - 4) + 0 >= s\'',
            "_", root.dir, String(Math.floor(t))];
        tailProc.running = true;
    }

    // ------------------------------------------------------------------ how an event reads
    function label(e) {
        const folder = (e.cwd ?? "").split("/").pop();
        switch (e.kind) {
        case "session.start":
        case "session.idle":
            return `Session started · ${folder}`;
        case "session.working":
            return `Working · ${folder}`;
        case "session.waiting":
            return `Needs you · ${folder}`;
        case "session.done":
            return `Done · ${folder}`;
        case "session.end":
            return `Session ended · ${folder}`;
        case "file.screenshot":
            return "Screenshot";
        case "file.download":
            return `Download · ${(e.path ?? "").split("/").pop()}`;
        case "fault.charger":
            return "Charger fault";
        case "fault.disk":
            return `Disk ${e.pct ?? ""}% full`;
        case "lock":
            return "Locked";
        case "unlock":
            return "Unlocked";
        }
        if ((e.kind + "").startsWith("pr."))
            return `PR ${e.number ?? ""} ${e.kind.substring(3)}${e.title ? " · " + e.title : ""}`;
        return e.kind;
    }

    // Colour by meaning, never by kind: attention, success, fault, or neutral.
    function tone(e) {
        switch (e.kind) {
        case "session.waiting":
        case "pr.review":
            return "attention";
        case "session.done":
        case "pr.merged":
            return "success";
        case "fault.charger":
        case "fault.disk":
        case "pr.failed":
            return "error";
        }
        return "neutral";
    }

    // Small dots for the frequent, quiet ones.
    function minor(e) {
        return e.kind === "session.working" || e.kind === "session.start" || e.kind === "session.idle" || e.kind === "session.end";
    }

    function time(e) {
        const d = new Date(e.t);
        return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
    }
}
