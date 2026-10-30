pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * Where a file came from. The desktop sees what a file manager never does: the page a
 * download was started from (the browser's title at that moment), the window a screenshot
 * shows, the phone that sent a file, the agent that wrote one, the terminal a path was
 * copied in. This index keeps that per path, so any surface can say "from zen · Tele2
 * invoice · 14m" instead of "document(3).pdf".
 *
 * Persisted at state/user/files/origins.json; entries whose file is gone are pruned on load
 * and every hour; capped. Never records a private window's title or a secret. "Forget" is
 * an action, and the whole index can be dropped from Files' settings.
 *
 *   qs -c tacit ipc call origins edited <session> <path>   (the Claude Code hook)
 */
Singleton {
    id: root

    property var index: ({})   // path -> { kind, app, title, device, session, at }
    readonly property int cap: 600
    readonly property int agentCap: 150   // the agents' own share of it
    readonly property string home: FileUtils.trimFileProtocol(Directories.home)
    readonly property string filePath: FileUtils.trimFileProtocol(`${Directories.state}/user/files/origins.json`)
    property bool loaded: false

    // A hint from a notification that names a file before the watcher sees it land
    // ("Received file IMG_2201.jpg from Pixel 10 Pro"): applied when the path arrives.
    property var hints: ({})   // file name -> origin

    function originFor(path) {
        return root.index[path] ?? null;
    }

    // "from zen · Tele2 invoice", "screenshot of foot", "from Pixel 10 Pro", "written by claude"
    function describe(path) {
        const o = root.originFor(path);
        if (!o)
            return "";
        switch (o.kind) {
        case "screenshot":
            return Voice.facts([o.app ? `screenshot of ${root.appName(o.app)}` : "screenshot", o.title]);
        case "phone":
            return `from ${o.device || "your phone"}`;
        case "agent":
            return Voice.facts([`${o.app === "codex" ? "written by codex" : "written by claude"}`, o.title]);
        case "clipboard":
            return o.app ? `copied in ${root.appName(o.app)}` : "";
        }
        return Voice.facts([o.app ? `from ${root.appName(o.app)}` : "", o.title]);
    }
    // The title alone, for a row that wants to lead with it ("Tele2 invoice" over document(3).pdf).
    function titleFor(path) {
        return root.originFor(path)?.title ?? "";
    }
    function appName(id) {
        const a = (id ?? "").toLowerCase();
        if (a.startsWith("zen"))
            return "zen";
        if (a.includes("firefox"))
            return "firefox";
        if (a === "browser" || a === "browser-cef")
            return "thyris";
        if (a.includes("chrom") || a.includes("thorium"))
            return a.includes("thorium") ? "thorium" : "chromium";
        return a.split(".").pop();
    }

    function record(path, origin) {
        if ((path ?? "").length === 0 || !origin)
            return;
        const o = Object.assign({}, origin, { "at": origin.at ?? Date.now() });
        if ((o.title ?? "").length > 0 && Recents.isSecret(o.title))
            o.title = "";
        let next = Object.assign({}, root.index);
        next[path] = o;
        root.index = root.trimmed(next);
    }

    // Agent edits arrive by the hundred - every hook call on Edit or Write is one - and in one
    // shared index they evicted the downloads and screenshots this exists for, oldest first.
    // They are held to their own share, and only then is the whole index trimmed oldest out.
    function trimmed(index) {
        let next = Object.assign({}, index);
        const agents = Object.keys(next).filter(k => next[k].kind === "agent");
        if (agents.length > root.agentCap)
            agents.sort((a, b) => next[a].at - next[b].at).slice(0, agents.length - root.agentCap).forEach(k => delete next[k]);
        const keys = Object.keys(next);
        if (keys.length > root.cap)
            keys.sort((a, b) => next[a].at - next[b].at).slice(0, keys.length - root.cap).forEach(k => delete next[k]);
        return next;
    }

    // A file that moves keeps its story: renaming a photo or filing an invoice must not turn
    // "from Pixel 10 Pro" into nothing. Jobs calls this when a move, a rename or an undo lands.
    function moved(from, to) {
        if ((from ?? "").length === 0 || (to ?? "").length === 0 || from === to)
            return;
        const o = root.index[from];
        if (!o)
            return;
        let next = Object.assign({}, root.index);
        next[to] = o;
        delete next[from];
        root.index = next;
        saveTimer.restart();
    }

    function forget(path) {
        if (!(path in root.index))
            return;
        let next = Object.assign({}, root.index);
        delete next[path];
        root.index = next;
    }

    function forgetAll() {
        root.index = ({});
    }

    // A file the download watcher just saw: a download (the focused window is the page it
    // came from, if that is a browser) or a screenshot (the focused window is what it shows).
    function recordArrival(path, isShot) {
        const name = path.split("/").pop();
        const hint = root.hints[name];
        if (hint) {
            let h = Object.assign({}, root.hints);
            delete h[name];
            root.hints = h;
            root.record(path, hint);
            return;
        }
        if (Attention.privateWindow) {
            root.record(path, { "kind": isShot ? "screenshot" : "download" });
            return;
        }
        if (isShot) {
            root.record(path, { "kind": "screenshot", "app": Attention.app, "title": Attention.title, "address": Attention.address });
            return;
        }
        root.record(path, {
            "kind": "download",
            "app": Attention.browser ? Attention.app : "",
            "title": Attention.browser ? Attention.title : "",
            "address": Attention.address
        });
    }

    function hint(name, origin) {
        if ((name ?? "").length === 0)
            return;
        let h = Object.assign({}, root.hints);
        h[name] = Object.assign({}, origin, { "at": Date.now() });
        root.hints = h;
    }

    // Agent edits arrive through the hook: kind agent, the session's folder as the title.
    function recordEdit(session, path, app) {
        // `all`, not `sessions`: the stage exists to keep other work off camera during a demo
        // take, and a row hidden there is still the session that wrote this file.
        const s = AgentSessions.all.find(x => x.id === session);
        const cwd = s?.cwd ?? "";
        // $HOME as the session's folder says nothing ("written by claude · abdul"), so no
        // title: the row keeps one line instead of growing a second for it
        const title = cwd.length > 0 && cwd !== root.home ? cwd.split("/").pop() : "";
        root.record(path, { "kind": "agent", "app": app || "claude", "session": session, "title": title });
    }

    IpcHandler {
        target: "origins"
        function edited(session: string, path: string): void {
            root.recordEdit(session, path, "claude");
        }
        function forget(path: string): void {
            root.forget(path);
        }
    }

    // ------------------------------------------------------------------ persistence
    onIndexChanged: {
        if (root.loaded)
            saveTimer.restart();
    }
    Timer {
        id: saveTimer
        interval: 800
        onTriggered: file.setText(JSON.stringify(root.index))
    }
    Component.onCompleted: file.reload()
    FileView {
        id: file
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            let parsed = ({});
            try {
                const p = JSON.parse(file.text());
                if (p && typeof p === "object" && !Array.isArray(p))
                    parsed = p;
            } catch (e) {}
            // what was recorded before the file came back wins over what the file says
            root.index = root.trimmed(Object.assign(parsed, root.index));
            root.loaded = true;
            saveTimer.restart();
            root.prune();
        }
        onLoadFailed: (error) => {
            root.loaded = true;
            if (error == FileViewError.FileNotFound)
                file.setText("{}");
        }
    }

    // Entries whose file is gone leave; on load and every hour.
    function prune() {
        const paths = Object.keys(root.index);
        if (paths.length === 0)
            return;
        pruneProc.running = false;
        pruneProc.running = true;
    }
    Process {
        id: pruneProc
        command: ["bash", "-c", `for f in ${Object.keys(root.index).map(p => `'${StringUtils.shellSingleQuoteEscape(p)}'`).join(" ")}; do [ -e "$f" ] || printf '%s\n' "$f"; done`]
        stdout: SplitParser {
            onRead: line => { const p = line.trim(); if (p.length > 0) root.forget(p); }
        }
    }
    Timer {
        interval: 3600000
        running: true
        repeat: true
        onTriggered: root.prune()
    }
}
