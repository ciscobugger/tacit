pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * What is happening right now, as one list: a browser download growing in ~/Downloads
 * (its .part / .crdownload, sampled by the notch's watcher every two seconds), and Files'
 * own copies, moves, renames and trashings. Three views read it: the notch sheet's top row,
 * Files' status line, the recap. A download knows its size and rate; a percent only when a
 * length is known, so none is shown for it.
 *
 * Files' operations run detached (scripts/files/job.sh, setsid) and report to
 * state/user/files/jobs/<id>.json; this watches those files. A job outlives the window, a
 * reload and a crash; whatever finished while nobody looked is still here on the next open.
 * Every finished job carries its undo; `undo(id)` runs it as a new job.
 */
Singleton {
    id: root

    property var running: []   // downloads: [{ id, kind:"download", path, name, bytes, rate, at, updated }]
                               // files:     [{ id, kind:"job", op, dest, state, total, done, bytes, bytesDone, current, error, started, ended, results, undo }]
    property var finished: []  // the last file jobs, newest first (for undo and the recap)
    readonly property var byId: {
        const m = ({});
        for (const j of root.running)
            m[j.id] = j;
        for (const j of root.finished)
            m[j.id] = j;
        return m;
    }
    readonly property var activeJobs: root.running.filter(j => j.kind === "job")
    readonly property string jobsDir: FileUtils.trimFileProtocol(`${Directories.state}/user/files/jobs`)
    readonly property string runner: Quickshell.shellPath("scripts/files/job.sh")
    signal jobFinished(var job)

    // ------------------------------------------------------------------ downloads
    function sampleDownload(path, bytes) {
        const now = Date.now();
        const id = "download:" + path;
        const prev = root.byId[id];
        const rate = prev && now > prev.updated ? Math.max(0, (bytes - prev.bytes) * 1000 / (now - prev.updated)) : 0;
        const job = {
            "id": id,
            "kind": "download",
            "path": path,
            "name": path.split("/").pop().replace(/\.(part|crdownload|tmp)$/i, ""),
            "bytes": bytes,
            "rate": prev ? (prev.rate * 0.5 + rate * 0.5) : rate,   // smoothed
            "at": prev?.at ?? now,
            "updated": now
        };
        root.running = root.running.filter(j => j.id !== id).concat([job]);
    }
    Timer {   // a partial not seen for two ticks has finished (renamed into place) or was cancelled
        interval: 2500
        running: root.running.some(j => j.kind === "download")
        repeat: true
        onTriggered: {
            const now = Date.now();
            const alive = root.running.filter(j => j.kind !== "download" || now - j.updated < 5500);
            if (alive.length !== root.running.length)
                root.running = alive;
        }
    }

    // ------------------------------------------------------------------ file jobs
    // The jobs this session asked for. A mkdir or a rename writes its report and exits in a few
    // tens of milliseconds, so the first read of it often already says "done" and the job was
    // never seen running - and everything the window does afterwards (the status line, Undo, the
    // name field on a new folder) hangs off jobFinished.
    readonly property var startedHere: ({})
    // start("copy", ["keep", "/dest", "/a", "/b"]) -> id
    function start(op, args) {
        const id = `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
        Quickshell.execDetached(["setsid", "-f", root.runner, id, op].concat(args));
        root.startedHere[id] = true;
        root.watch(id);
        return id;
    }
    function cancel(id) {
        Quickshell.execDetached(["touch", `${root.jobsDir}/${id}.cancel`]);
    }
    // The undo a finished job carries, run as a job of its own.
    function undo(id) {
        const j = root.byId[id];
        const u = j?.undo;
        if (!u)
            return "";
        root.finished = root.finished.filter(x => x.id !== id);
        switch (u.op) {
        case "move-back": {
            // The story goes back with the file: the moveback job carries no undo of its own, so
            // nothing else would map the origin from the new path to the restored one, and the
            // hourly prune would drop it. u.from is where the file is now, u.to where it came from.
            let pairs = [];
            for (let i = 0; i < u.from.length; i++) {
                Origins.moved(u.from[i], u.to[i]);
                pairs.push(u.from[i], u.to[i]);
            }
            return root.start("moveback", pairs);
        }
        case "delete":          // what a copy or a new folder made: to the trash, never gone for good
            return root.start("trash", u.paths);
        case "restore-paths":
            return root.start("restore-paths", u.paths);
        }
        return "";
    }

    readonly property var watchers: ({})
    function watch(id) {
        if (root.watchers[id])
            return;
        root.watchers[id] = watcherComp.createObject(root, { "id": id });
    }
    function forget(id) {
        delete root.startedHere[id];
        const w = root.watchers[id];
        if (!w)
            return;
        delete root.watchers[id];
        w.destroy();
    }
    Component {
        id: watcherComp
        Scope {   // a FileView takes no children of its own, so the retry timer sits beside it
            id: w
            property string id: ""
            property int tries: 0
            FileView {
                id: fv
                path: Qt.resolvedUrl(`${root.jobsDir}/${w.id}.json`)
                watchChanges: true
                onFileChanged: fv.reload()
                onLoaded: {
                    w.tries = 0;
                    root.absorb(w.id, fv.text());
                }
                // the runner has not written yet - but one that never got as far as writing must
                // not leave this reloading a missing path for the rest of the session
                onLoadFailed: {
                    w.tries += 1;
                    if (w.tries > 40) {
                        console.warn(`[Jobs] no report from job ${w.id} after 6 s; stopped watching`);
                        root.forget(w.id);
                    } else {
                        retry.restart();
                    }
                }
            }
            Timer {
                id: retry
                interval: 150
                onTriggered: fv.reload()
            }
        }
    }
    function absorb(id, text) {
        let j = null;
        try { j = JSON.parse(text); } catch (e) { return; }
        if (!j || j.id !== id)
            return;
        j.kind = "job";
        if (j.state === "running") {
            root.running = root.running.filter(x => x.id !== id).concat([j]);
            return;
        }
        const wasRunning = root.running.some(x => x.id === id);
        const mine = root.startedHere[id] === true;
        root.running = root.running.filter(x => x.id !== id);
        root.finished = [j].concat(root.finished.filter(x => x.id !== id)).slice(0, 20);
        // Where a file went, its story goes: a move-back undo names every old path and its new
        // one, so a renamed photo keeps "from Pixel 10 Pro" and a filed invoice keeps "from zen".
        if (j.state === "done" && j.undo?.op === "move-back" && Array.isArray(j.undo.from) && Array.isArray(j.undo.to)) {
            for (let i = 0; i < j.undo.from.length && i < j.undo.to.length; i++)
                Origins.moved(j.undo.to[i], j.undo.from[i]);
        }
        // The startup sweep's reports are the ones to stay quiet about: they finished before
        // this session, or while nobody was looking.
        if (wasRunning || mine || j.state === "failed")
            root.jobFinished(j);
        root.forget(id);
    }

    // On start: whatever the runner left behind - still running (a reload mid-copy), or done
    // while the shell was down. Reports older than a day are dropped.
    Process {
        id: sweep
        running: true
        command: ["bash", "-c", `d='${StringUtils.shellSingleQuoteEscape(root.jobsDir)}'; mkdir -p "$d"; find "$d" -name '*.json' -mtime +1 -delete; find "$d" -name '*.cancel' -mmin +60 -delete; ls -t "$d" | grep '\\.json$' | head -30 | sed 's/\\.json$//'`]
        stdout: SplitParser {
            onRead: line => { const id = line.trim(); if (id.length > 0) root.watch(id); }
        }
    }

    // ------------------------------------------------------------------ words
    function verb(op) {
        switch (op) {
        case "copy": return "Copying";
        case "move": return "Moving";
        case "trash": return "Trashing";
        case "restore": case "restore-paths": return "Putting back";
        case "rename": return "Renaming";
        case "mkdir": return "Making";
        case "delete": return "Deleting";
        case "moveback": return "Moving back";
        case "extract": return "Unpacking";
        case "touch": return "Making";
        case "compress": return "Compressing";
        case "renames": return "Renaming";
        }
        return op;
    }
    // the sentence for a finished job, with what and where in their places
    function past(op, what, to) {
        switch (op) {
        case "copy": return `Copied ${what}${to}`;
        case "move": return `Moved ${what}${to}`;
        case "trash": return `Moved ${what} to the trash`;
        case "restore": case "restore-paths": return `Put ${what} back`;
        case "rename": return `Renamed to ${what}`;
        case "mkdir": return `Made ${what}`;
        case "delete": return `Deleted ${what}`;
        case "moveback": return `Moved ${what} back`;
        case "extract": return `Unpacked into ${what}`;
        case "touch": return `Made ${what}`;
        case "compress": return `Compressed into ${what}`;
        case "renames": return `Renamed ${what}`;
        }
        return `Done: ${what}`;
    }
    function label(job) {
        if (job.kind === "download") {
            const parts = [job.name, Voice.size(job.bytes)];
            if (job.rate > 20000)
                parts.push(`${Voice.size(job.rate)}/s`);
            return parts.join(" · ");
        }
        const one = job.current || (job.results?.length > 0 ? job.results[0].split("/").pop() : "") || "1 item";
        const what = job.total === 1 ? one : Voice.count(job.total, "item");
        const to = job.dest ? ` to ${Files.placeName(job.dest)}` : "";
        if (job.state === "running") {
            const pct = job.bytes > 0 ? ` · ${Math.min(100, Math.round(job.bytesDone * 100 / job.bytes))} %` : (job.total > 1 ? ` · ${job.done} of ${job.total}` : "");
            return `${root.verb(job.op)} ${what}${to}${pct}`;
        }
        if (job.state === "failed")
            return Voice.cant(job.error || `${root.verb(job.op).toLowerCase()} ${what}`);
        if (job.state === "cancelled")
            return `Stopped · ${job.done} of ${job.total} done`;
        return root.past(job.op, what, to);
    }

    IpcHandler {
        target: "jobs"
        // the command line splits its arguments on commas, so these come newline-separated:
        //   qs -c tacit ipc call jobs start copy $'keep\n/dest\n/a\n/b'
        function start(op: string, args: string): string { return root.start(op, args.split("\n").filter(a => a.length > 0)); }
        function cancel(id: string): void { root.cancel(id); }
        function undo(id: string): string { return root.undo(id); }
    }
}
