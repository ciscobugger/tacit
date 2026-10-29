import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * The rail's rows and the folders behind them: Pinned, Recent, then one heading per folder.
 * Pinned folders and their names are Pinax's (files/state.json, written only through the shell's
 * `files` IPC); hidden folders, folds, "Show more", re-files and each folder's last agent are
 * Praxis's own (claude-folders.json); session pins and archive are claude-pins.txt and
 * claude-archived.txt as before.
 *
 * Inputs change rows on the next turn of the event loop, once for any number of changes. While
 * `frozen` the row order is kept: rows update in place, new rows go in after the row they follow,
 * and the full order comes back 260 ms after it thaws.
 *
 * fkey: an absolute path; "codex-chats" or "elsewhere"; "win:<path>" for a path not on this machine.
 */
Item {
    id: fm

    // ── inputs ──────────────────────────────────────────────────────────────
    property var history: []          // host history, as claude.qml filters it
    property var live: ({})           // host.live
    property var showLive: (id, cwd) => true   // a running session not in history: shown?
    property var terminals: ({})      // host.terminals
    property var leftovers: ({})      // host.leftovers
    property var hookStates: ({})     // id -> the hooks' state, for sessions in a terminal
    property var presence: ({ windows: [], agents: [] })
    property string query: ""
    property var found: []            // full-text hits, already filtered as history is
    property bool searching: false
    property var filter: ({ needs: false, running: false, range: "", agents: [] })   // range: "" | today | week
    property bool frozen: false
    property string selectedId: ""
    property var host: null           // connected, request({op: "delete", id}, cb)
    property var shellIpc: ["qs", "-p", Directories.shellFile, "ipc", "call", "files"]
    property string stage: ""         // a demo stage (notch-stage): live sessions and windows outside it are left out

    // ── outputs ─────────────────────────────────────────────────────────────
    property var rows: []
    property var counts: ({ waiting: 0, working: 0 })
    property var marks: []            // [{id, state, title}], at most 4, waiting first
    property var targets: []          // [{fkey, path, name, pinned, local, hidden, live}]
    property bool shellUp: true       // false after a `files` call exits non-zero, true after one succeeds
    property bool saveFailed: false   // a write the shell did not confirm within 2 s was undone
    signal deleted(string id, string error)   // after the host answers a delete; error "" when it went

    readonly property string home: Quickshell.env("HOME")
    readonly property var agentNames: ({ claude: "Claude", codex: "Codex", pi: "pi", opencode: "opencode" })
    // Files' fixed places, by path (Files.places; this app does not load the Files singleton)
    readonly property var placeNames: {
        const m = {};
        m[fm.home] = "Home";
        m[FileUtils.trimFileProtocol(Directories.downloads)] = "Downloads";
        m[FileUtils.trimFileProtocol(Directories.documents)] = "Documents";
        m[FileUtils.trimFileProtocol(Directories.pictures)] = "Pictures";
        m[FileUtils.trimFileProtocol(Directories.music)] = "Music";
        m[FileUtils.trimFileProtocol(Directories.videos)] = "Videos";
        m[fm.home + "/Desktop"] = "Desktop";
        return m;
    }

    // ── session pins ────────────────────────────────────────────────────────
    FileView {
        id: pinFile
        path: `${Directories.state}/user/claude-pins.txt`
        blockLoading: true
        printErrors: false
    }
    property var pins: (pinFile.text() || "").split("\n").filter(l => l.length)
    function togglePin(id) {
        const list = fm.pins.includes(id) ? fm.pins.filter(p => p !== id) : [id].concat(fm.pins);
        pinFile.setText(list.join("\n") + (list.length ? "\n" : ""));
        fm.pins = list;
    }

    // ── archived: out of the list, a row at the bottom brings them back ─────
    FileView {
        id: archiveFile
        path: `${Directories.state}/user/claude-archived.txt`
        blockLoading: true
        printErrors: false
    }
    property var archived: (archiveFile.text() || "").split("\n").filter(l => l.length)
    property bool showArchived: false
    property bool showHidden: false
    function toggleArchive(id) {
        const list = fm.archived.includes(id) ? fm.archived.filter(p => p !== id) : fm.archived.concat([id]);
        archiveFile.setText(list.join("\n") + (list.length ? "\n" : ""));
        fm.archived = list;
    }
    onPinsChanged: fm.dirty()
    onArchivedChanged: fm.dirty()

    // ── Praxis's own folder state ───────────────────────────────────────────
    property var hidden: []           // [fkey]
    property var folded: ({})         // fkey -> bool; absent: the folder's default
    property var more: ({})           // fkey -> true: every session, not the newest four
    property bool older: false        // "Older folders" open
    property var filed: ({})          // session id -> fkey (Move)
    property var agent: ({})          // fkey -> the agent last started there
    FileView {
        id: prefsFile
        path: `${Directories.state}/user/claude-folders.json`
        blockLoading: true
        printErrors: false
    }
    function loadPrefs() {
        let p;
        try { p = JSON.parse(prefsFile.text() || "{}"); } catch (e) { return; }
        fm.hidden = Array.isArray(p.hidden) ? p.hidden : [];
        fm.folded = p.folded && typeof p.folded === "object" ? p.folded : ({});
        fm.more = p.more && typeof p.more === "object" ? p.more : ({});
        fm.older = p.older === true;
        fm.filed = p.filed && typeof p.filed === "object" ? p.filed : ({});
        fm.agent = p.agent && typeof p.agent === "object" ? p.agent : ({});
    }
    Timer {
        id: saveLater
        interval: 300
        onTriggered: prefsFile.setText(JSON.stringify({ version: 1, hidden: fm.hidden, folded: fm.folded, more: fm.more,
                                                        older: fm.older, filed: fm.filed, agent: fm.agent }))
    }
    function changed() {
        saveLater.restart();
        fm.dirty();
    }

    function toggleFold(fkey) {
        const f = Object.assign({}, fm.folded);
        f[fkey] = !(fm.shut[fkey] ?? false);
        fm.folded = f;
        fm.changed();
    }
    function showMore(fkey) {
        const m = Object.assign({}, fm.more);
        if (m[fkey]) delete m[fkey]; else m[fkey] = true;
        fm.more = m;
        fm.changed();
    }
    function toggle(which) {
        if (which === "older") { fm.older = !fm.older; fm.changed(); }
        else if (which === "hidden") { fm.showHidden = !fm.showHidden; fm.dirty(); }
        else if (which === "archived") { fm.showArchived = !fm.showArchived; fm.dirty(); }
    }
    function hide(fkey) {
        if (fm.hidden.includes(fkey)) return;
        fm.hidden = fm.hidden.concat([fkey]);
        fm.changed();
    }
    function unhide(fkey) {
        if (!fm.hidden.includes(fkey)) return;
        fm.hidden = fm.hidden.filter(k => k !== fkey);
        fm.changed();
    }
    // Move re-files in Praxis only: the session keeps running in its own cwd.
    function refile(id, fkey) {
        const s = fm.byId[id];
        const f = Object.assign({}, fm.filed);
        if (s && fkey === fm.placeOf(s)) delete f[id]; else f[id] = fkey;
        fm.filed = f;
        fm.changed();
    }
    function unrefile(id) {
        if (!(id in fm.filed)) return;
        const f = Object.assign({}, fm.filed);
        delete f[id];
        fm.filed = f;
        fm.changed();
    }
    function agentFor(fkey) { return fm.agent[fkey] ?? "claude"; }
    function rememberAgent(fkey, tool) {
        if (!fkey || fm.agent[fkey] === tool) return;
        const a = Object.assign({}, fm.agent);
        a[fkey] = tool;
        fm.agent = a;
        saveLater.restart();
    }

    // ── the shared folder list (Pinax's pins and names) ─────────────────────
    // Files rewrites state.json on every folder visit, so a load that leaves pins and names as
    // they were assigns nothing. Writes go through the shell and show at once; one the file has
    // not confirmed within 2 s is undone.
    property var filePins: []
    property var fileNames: ({})
    property string filePinsJson: "[]"
    property string fileNamesJson: "{}"
    property var wantPins: null       // the pins a write asked for, until the file has them
    property real wantPinsAt: 0
    property var wantNames: ({})      // path -> {name, at}
    property var folderPins: []       // as shown: the file's, with unconfirmed writes on top
    property var folderNames: ({})
    property bool sharedSeen: false
    FileView {
        id: shared
        path: `${Directories.state}/user/files/state.json`
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: shared.reload()
        onLoaded: fm.takeShared(shared.text())
    }
    function takeShared(text) {
        let p;
        try { p = JSON.parse(text); } catch (e) { return; }
        // the shell wrote it, so it is running (the first read is only the file)
        if (fm.sharedSeen) fm.shellUp = true;
        fm.sharedSeen = true;
        const pins = Array.isArray(p.pins) ? p.pins : [];
        const names = p.names && typeof p.names === "object" ? p.names : ({});
        const pj = JSON.stringify(pins), nj = JSON.stringify(names);
        if (pj !== fm.filePinsJson) { fm.filePinsJson = pj; fm.filePins = pins; }
        if (nj !== fm.fileNamesJson) { fm.fileNamesJson = nj; fm.fileNames = names; }
        if (fm.wantPins && JSON.stringify(fm.wantPins) === pj) { fm.wantPins = null; fm.saveFailed = false; }
        let w = null;
        for (const path in fm.wantNames)
            if ((names[path] ?? "") === fm.wantNames[path].name) {
                w = w ?? Object.assign({}, fm.wantNames);
                delete w[path];
            }
        if (w) { fm.wantNames = w; fm.saveFailed = false; }
        fm.settle();
    }
    // folderPins / folderNames from the file and the writes still waiting
    function settle() {
        const pins = fm.wantPins ?? fm.filePins;
        const names = Object.assign({}, fm.fileNames);
        for (const path in fm.wantNames) {
            if (fm.wantNames[path].name.length) names[path] = fm.wantNames[path].name;
            else delete names[path];
        }
        if (JSON.stringify(pins) !== JSON.stringify(fm.folderPins)) { fm.folderPins = pins; fm.places = ({}); fm.dirty(); }
        if (JSON.stringify(names) !== JSON.stringify(fm.folderNames)) { fm.folderNames = names; fm.dirty(); }
    }
    Timer {
        id: confirmWatch
        interval: 250
        repeat: true
        running: fm.wantPins !== null || Object.keys(fm.wantNames).length > 0
        onTriggered: {
            const now = Date.now();
            let undone = false;
            if (fm.wantPins && now - fm.wantPinsAt >= 2000) { fm.wantPins = null; undone = true; }
            let w = null;
            for (const path in fm.wantNames)
                if (now - fm.wantNames[path].at >= 2000) {
                    w = w ?? Object.assign({}, fm.wantNames);
                    delete w[path];
                }
            if (w) { fm.wantNames = w; undone = true; }
            if (undone) { fm.saveFailed = true; fm.settle(); }
        }
    }
    function trimPath(path) {
        const p = FileUtils.trimFileProtocol(path ?? "");
        return p.length > 1 ? p.replace(/\/+$/, "") : p;
    }
    function wantPinList(list) {
        fm.wantPins = list;
        fm.wantPinsAt = Date.now();
        fm.settle();
    }
    function pin(path) {
        const p = fm.trimPath(path);
        if (!p.startsWith("/") || fm.folderPins.includes(p)) return;
        fm.wantPinList(fm.folderPins.concat([p]));
        fm.call(["pin", p]);
    }
    function unpin(path) {
        const p = fm.trimPath(path);
        if (!fm.folderPins.includes(p)) return;
        fm.wantPinList(fm.folderPins.filter(x => x !== p));
        fm.call(["unpin", p]);
    }
    // to position `index` among the pins (clamped), as Files.move does
    function move(path, index) {
        const p = fm.trimPath(path);
        if (!fm.folderPins.includes(p)) return;
        const rest = fm.folderPins.filter(x => x !== p);
        rest.splice(Math.max(0, Math.min(index, rest.length)), 0, p);
        if (JSON.stringify(rest) === JSON.stringify(fm.folderPins)) return;
        fm.wantPinList(rest);
        fm.call(["move", p, String(index)]);
    }
    // an empty name returns the folder to its own name; the folder never moves on disk
    function rename(path, name) {
        const p = fm.trimPath(path);
        const n = (name ?? "").trim();
        if (!p.startsWith("/") || (fm.folderNames[p] ?? "") === n) return;
        const w = Object.assign({}, fm.wantNames);
        w[p] = { name: n, at: Date.now() };
        fm.wantNames = w;
        fm.settle();
        fm.call(["rename", p, n]);
    }
    // one call at a time, in order
    property var queue: []
    function call(args) {
        fm.queue = fm.queue.concat([fm.shellIpc.concat(args)]);
        fm.pump();
    }
    function pump() {
        if (ipc.running || !fm.queue.length) return;
        ipc.command = fm.queue[0];
        fm.queue = fm.queue.slice(1);
        ipc.running = true;
    }
    Process {
        id: ipc
        onExited: (code, status) => {
            fm.shellUp = code === 0;
            Qt.callLater(fm.pump);
        }
    }

    // ── deletes: an undo row for a minute ───────────────────────────────────
    property var deleting: ({})       // id -> {at, title, tool}; at 0: due, waiting for agent-host
    property var gone: ({})           // id -> true: sent or deleted, out of the rows until history drops it
    property var sent: ({})           // id -> when the delete went to agent-host, until it answers
    function scheduleDelete(id) {
        const s = fm.byId[id];
        if (!s || fm.deleting[id]) return;
        const d = Object.assign({}, fm.deleting);
        d[id] = { at: Date.now(), title: fm.titleOf(s), tool: s.tool || "claude" };
        fm.deleting = d;
        fm.dirty();
    }
    function undoDelete(id) {
        if (!fm.deleting[id]) return;
        const d = Object.assign({}, fm.deleting);
        delete d[id];
        fm.deleting = d;
        fm.dirty();
    }
    function flushDeletes() {
        const d = {};
        for (const id in fm.deleting)
            if (!fm.sendDelete(id, fm.deleting[id].tool)) d[id] = Object.assign({}, fm.deleting[id], { at: 0 });
        fm.deleting = d;
        fm.dirty();
    }
    // Codex and opencode sessions are archived instead: hidden here, kept by the agent (owner, 2026-10-03).
    // false while agent-host is not connected: a request then would get no answer, so the undo row
    // stays and a later tick sends it.
    function sendDelete(id, tool) {
        if (tool === "codex" || tool === "opencode") {
            if (!fm.archived.includes(id)) fm.toggleArchive(id);
            return true;
        }
        if (!fm.host) { fm.deleted(id, "the background service is not answering"); return true; }
        if (!fm.host.connected) return false;
        fm.setGone(id, true);
        const s = Object.assign({}, fm.sent);
        s[id] = Date.now();
        fm.sent = s;
        fm.host.request({ op: "delete", id: id }, m => {
            const waited = id in fm.sent;
            if (waited) { const s2 = Object.assign({}, fm.sent); delete s2[id]; fm.sent = s2; }
            if (m.ev === "deleted") { fm.setGone(id, true); fm.deleted(id, ""); return; }
            if (!waited) return;   // timed out: the row is back and the error was given
            fm.setGone(id, false);
            fm.deleted(id, m.message ?? "Not deleted");
        });
        return true;
    }
    function setGone(id, on) {
        if (!!fm.gone[id] === on) return;
        const g = Object.assign({}, fm.gone);
        if (on) g[id] = true; else delete g[id];
        fm.gone = g;
        fm.dirty();
    }
    Timer {
        interval: 1000
        repeat: true
        running: Object.keys(fm.deleting).length > 0 || Object.keys(fm.sent).length > 0
        onTriggered: {
            const now = Date.now();
            // no answer within 5 s: the row comes back
            const late = Object.keys(fm.sent).filter(id => now - fm.sent[id] >= 5000);
            if (late.length) {
                const s = Object.assign({}, fm.sent);
                for (const id of late) delete s[id];
                fm.sent = s;
                for (const id of late) { fm.setGone(id, false); fm.deleted(id, "the background service did not answer"); }
            }
            const due = Object.keys(fm.deleting).filter(id => now - fm.deleting[id].at >= 60000);
            if (!due.length) return;
            const d = Object.assign({}, fm.deleting);
            for (const id of due) if (fm.sendDelete(id, d[id].tool)) delete d[id];
            if (Object.keys(d).length === Object.keys(fm.deleting).length) return;
            fm.deleting = d;
            fm.dirty();
        }
    }

    // ── arrivals: the row is flagged for 1.5 s ──────────────────────────────
    property var arrivals: ({})       // id -> until (ms)
    function arrived(id) {
        const a = Object.assign({}, fm.arrivals);
        a[id] = Date.now() + 1500;
        fm.arrivals = a;
        arrivalEnd.restart();
        fm.dirty();
    }
    Timer {
        id: arrivalEnd
        interval: 1500
        onTriggered: {
            const now = Date.now(), a = {};
            let left = 0;
            for (const id in fm.arrivals)
                if (fm.arrivals[id] > now) { a[id] = fm.arrivals[id]; left = Math.max(left, fm.arrivals[id] - now); }
            fm.arrivals = a;
            if (left > 0) { arrivalEnd.interval = left; arrivalEnd.restart(); } else arrivalEnd.interval = 1500;
            fm.dirty();
        }
    }

    // ── states ──────────────────────────────────────────────────────────────
    // working / waiting / open (a live process or terminal) / past. Codex, pi and opencode in a
    // terminal (presence agents) are "open" only; an agent the host also runs is counted once.
    property var stateCache: null
    function states() {
        if (fm.stateCache) return fm.stateCache;
        const st = {};
        for (const id in fm.live) {
            const l = fm.live[id];
            if (l && (l.alive || l.state !== "idle")) st[id] = l.state === "idle" ? "open" : l.state;
        }
        for (const id in fm.terminals)
            if (!st[id]) st[id] = fm.hookStates[id] === "waiting" ? "waiting" : (fm.terminals[id].status === "busy" ? "working" : "open");
        for (const id in fm.leftovers)
            if (!st[id]) st[id] = fm.leftovers[id].status === "busy" ? "working" : "open";
        const special = fm.specialWindows();
        for (const a of fm.presence?.agents ?? [])
            if (a.session && !st[a.session] && !special[a.window]) st[a.session] = "open";
        fm.stateCache = st;
        return st;
    }
    function stateOf(id) { return fm.states()[id] ?? "past"; }
    function specialWindows() {
        const m = {};
        for (const w of fm.presence?.windows ?? []) if (w.special) m[w.address] = true;
        return m;
    }

    // ── folders ─────────────────────────────────────────────────────────────
    function titleOf(s) { return (s.title || s.lastPrompt || s.prompt || "Untitled").replace(/\s*<desktop-context>[\s\S]*$/, ""); }
    // Which folder a cwd is in, before re-files. Worktrees join their repo; Codex sessions from
    // the Windows years map C:\dev\X to ~/dev/X, and its one-off desktop chats
    // (Documents\Codex\<date>\<slug>) are one folder rather than forty. Then the deepest of: the
    // pinned folders holding it (Home only itself) and its repo root (not Home), so a pinned ~/dev
    // gathers loose folders but not the repos inside it. Else the folder itself. A row without a
    // root (a live session the history has not listed yet, protocol 4) takes the deepest known one.
    property var places: ({})         // cache: cwd \n root \n local -> fkey; cleared when pins or roots change
    property var rootsAt: ({})        // cache: path -> deepest known root; cleared when roots change
    function place(cwd, root, local) {
        const k = `${cwd ?? ""}\n${root ?? ""}\n${local}`;
        let f = fm.places[k];
        if (f === undefined) { f = fm.placeNow(cwd ?? "", root ?? "", local); fm.places[k] = f; }
        return f;
    }
    function cut(path) {
        let p = path;
        const wt = p.replace(/\\/g, "/").indexOf("/.claude/worktrees/");
        if (wt >= 0) p = p.substring(0, wt);
        return p.length > 1 ? p.replace(/[\/\\]+$/, "") : p;
    }
    function placeNow(cwd, root, local) {
        if (!cwd) return "elsewhere";
        const raw = fm.cut(cwd);
        let base = raw.replace(/\\/g, "/");
        if (/^C:\/Users\/[^/]+\/Documents\/Codex(\/|$)/i.test(base)) return "codex-chats";
        // a worktree's repo is the folder above .claude/worktrees, whether the worktree is still there or not
        const wt = /[\/\\]\.claude[\/\\]worktrees[\/\\]/.test(cwd);
        let here = local !== false || (wt && base.startsWith("/"));
        // a removed Windows-era worktree joins its repo when this machine has it (C:\X is ~/X, as the host maps it)
        if (!here && wt && /^C:\//i.test(base) && fm.knownDirs[fm.home + "/" + base.substring(3)]) {
            base = fm.home + "/" + base.substring(3);
            here = true;
        }
        if (here && /^C:\/dev\//i.test(base)) base = fm.home + "/dev/" + base.substring(7);
        if (!here || !base.startsWith("/")) return "win:" + raw;
        let best = "";
        for (const p of fm.folderPins)
            if ((base === p || (p !== fm.home && base.startsWith(p === "/" ? "/" : p + "/"))) && p.length > best.length) best = p;
        const r = wt ? base : root ? fm.cut(root) : "";
        if (r && r !== fm.home && r.length > best.length && (base === r || base.startsWith(r + "/"))) best = r;
        return best || base;
    }
    // repo roots seen in history: a window's folder uses the deepest one holding it
    property var roots: []
    property var knownDirs: ({})      // the roots and the folders local sessions run in, Home included
    property string knownSig: ""
    function rootFor(path) {
        let root = fm.rootsAt[path];
        if (root !== undefined) return root;
        const p = (path ?? "").replace(/\\/g, "/");
        root = "";
        for (const r of fm.roots) if (r.length > root.length && (p === r || p.startsWith(r + "/"))) root = r;
        fm.rootsAt[path] = root;
        return root;
    }
    function folderForPath(path) {
        const p = fm.trimPath(path);
        return fm.place(p, fm.rootFor(p), undefined);
    }
    // before re-files
    function placeOf(s) { return fm.place(s.cwd, s.root ?? fm.rootFor(s.cwd ?? ""), s.local); }
    function folderOf(s) {
        const x = typeof s === "string" ? fm.byId[s] : s;
        if (!x) return "elsewhere";
        return fm.filed[x.id] ?? fm.placeOf(x);
    }
    function pathOf(fkey) { return fkey.startsWith("/") ? fkey : fkey.startsWith("win:") ? fkey.substring(4) : ""; }
    // Files' names, then the fixed place, then the folder's own name
    function nameOf(fkey) {
        if (fkey === "codex-chats") return "Codex chats";
        if (fkey === "elsewhere") return "Elsewhere";
        const p = fm.pathOf(fkey);
        if (fkey.startsWith("/")) {
            const n = fm.folderNames[p] ?? fm.placeNames[p];
            if (n) return n;
        }
        return p === "/" ? "/" : p.split(/[\/\\]/).filter(x => x.length).pop() ?? p;
    }
    // Q1: in a folder the word is the agent, and only for codex, pi and opencode; in Pinned,
    // Recent and search it is the folder, after the agent for those three.
    function contextWord(row, inGroup) {
        const a = row.tool && row.tool !== "claude" ? (fm.agentNames[row.tool] ?? row.tool) : "";
        if (inGroup) return a;
        const where = fm.nameOf(row.fkey);
        return a ? `${a} · ${where}` : where;
    }

    // ── building ────────────────────────────────────────────────────────────
    property var byId: ({})           // the last build's sessions, live ones without history included
    property var freshSeen: ({})      // live sessions without history: id -> {j, s}
    property var shut: ({})           // the last build's folded state per fkey
    property var built: []            // the last build's rows, as if not frozen
    property string builtMode: ""
    function dirty() { Qt.callLater(fm.rebuild); }

    onHistoryChanged: {
        const seen = {}, r = [], dirs = {};
        for (const s of fm.history) {
            const x = s.root ? fm.cut(s.root) : "";
            if (x) dirs[x] = true;
            if (x && !seen[x] && x !== fm.home) { seen[x] = true; r.push(x); }
            if (s.local !== false && (s.cwd ?? "").startsWith("/")) dirs[fm.cut(s.cwd)] = true;
        }
        const sig = Object.keys(dirs).sort().join("\n");
        if (JSON.stringify(r) !== JSON.stringify(fm.roots) || sig !== fm.knownSig) {
            fm.roots = r;
            fm.knownDirs = dirs;
            fm.knownSig = sig;
            fm.places = ({});
            fm.rootsAt = ({});
        }
        const g = {};
        let pruned = false;
        for (const id in fm.gone) { if (fm.history.some(s => s.id === id)) g[id] = true; else pruned = true; }
        if (pruned) fm.gone = g;
        fm.dirty();
    }
    onLiveChanged: { fm.stateCache = null; fm.dirty(); }
    onTerminalsChanged: { fm.stateCache = null; fm.dirty(); }
    onLeftoversChanged: { fm.stateCache = null; fm.dirty(); }
    onHookStatesChanged: { fm.stateCache = null; fm.dirty(); }
    onPresenceChanged: { fm.stateCache = null; fm.dirty(); }
    onQueryChanged: fm.dirty()
    onFoundChanged: fm.dirty()
    onSearchingChanged: fm.dirty()
    onFilterChanged: fm.dirty()
    onSelectedIdChanged: fm.dirty()
    onStageChanged: fm.dirty()
    onFrozenChanged: {
        if (fm.frozen) thaw.stop();
        else thaw.restart();
    }
    Timer {
        id: thaw
        interval: 260
        onTriggered: if (!fm.frozen && !fm.sameRows(fm.rows, fm.built)) fm.rows = fm.built
    }
    Component.onCompleted: {
        fm.loadPrefs();
        if (!fm.sharedSeen && shared.text()) fm.takeShared(shared.text());
        fm.rebuild();
    }

    function rebuild() {
        const b = fm.build();
        fm.built = b.rows;
        // the order stays through the 260 ms after a thaw as well
        const merge = (fm.frozen || thaw.running) && b.mode === fm.builtMode;
        fm.builtMode = b.mode;
        const next = merge ? fm.mergeFrozen(fm.rows, b.rows) : b.rows;
        if (!fm.sameRows(fm.rows, next)) fm.rows = next;
        if (JSON.stringify(b.counts) !== JSON.stringify(fm.counts)) fm.counts = b.counts;
        if (JSON.stringify(b.marks) !== JSON.stringify(fm.marks)) fm.marks = b.marks;
        if (JSON.stringify(b.targets) !== JSON.stringify(fm.targets)) fm.targets = b.targets;
    }

    function sameRows(a, b) {
        if (a === b) return true;
        if (!a || !b || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) {
            const x = a[i], y = b[i];
            if (x === y) continue;
            if (x.key !== y.key) return false;
            for (const k in y) {
                if (x[k] === y[k]) continue;
                if (k === "live" && JSON.stringify(x[k]) === JSON.stringify(y[k])) continue;
                return false;
            }
        }
        return true;
    }
    // Frozen: the shown order stays; rows gone from the build go; a new row goes in after the row
    // it follows in the build (a new session at the top of its folder, an undo row in its session's place).
    function mergeFrozen(prev, next) {
        const fresh = {};
        for (const r of next) fresh[r.key] = r;
        const out = prev.filter(r => fresh[r.key]).map(r => fresh[r.key]);
        const at = {};
        out.forEach((r, i) => at[r.key] = true);
        for (let i = 0; i < next.length; i++) {
            const r = next[i];
            if (at[r.key]) continue;
            const after = i > 0 ? out.findIndex(x => x.key === next[i - 1].key) : -1;
            out.splice(after + 1, 0, r);
            at[r.key] = true;
        }
        return out;
    }

    function onStage(cwd) { return !fm.stage.length || cwd === fm.stage || cwd.startsWith(fm.stage + "/"); }
    function blankLive() { return { waiting: 0, working: 0, open: 0, terminals: 0, graphis: 0, files: 0 }; }
    function lit(l) { return !!l && (l.waiting + l.working + l.open + l.terminals + l.graphis + l.files) > 0; }
    function since(range) {
        const d = new Date();
        d.setHours(0, 0, 0, 0);
        if (range === "week") d.setDate(d.getDate() - (d.getDay() + 6) % 7);
        return d.getTime();
    }
    function emptyText(f) {
        const st = f.needs && f.running ? "waiting or running" : f.needs ? "waiting for you" : f.running ? "running" : "";
        const when = f.range === "today" ? "today" : f.range === "week" ? "this week" : "";
        const who = (f.agents ?? []).map(a => fm.agentNames[a] ?? a).join(" or ");
        if (!who && !when && st) return `Nothing ${st}.`;
        return `No ${who ? who + " " : ""}sessions${st ? " " + st : ""}${when ? " " + when : ""}.`;
    }

    function build() {
        const now = Date.now();
        const st = fm.states();
        const f = fm.filter ?? {};
        const agents = f.agents ?? [];
        const filtering = !!(f.needs || f.running || f.range || agents.length);
        const q = fm.query.trim().toLowerCase();
        const from = f.range ? fm.since(f.range) : 0;
        const keep = (s, state) => (!(f.needs || f.running) || (f.needs && state === "waiting") || (f.running && state === "working"))
                                   && (!from || (s.updated || s.started || 0) >= from)
                                   && (!agents.length || agents.includes(s.tool || "claude"));

        // sessions the host just started have no transcript title yet
        const byId = {};
        for (const s of fm.history) byId[s.id] = s;
        // an unchanged one keeps its object, so its row is not replaced
        const fresh = [], freshSeen = {};
        for (const id in fm.live) {
            const l = fm.live[id];
            if (byId[id] || !st[id] || st[id] === "past") continue;
            const c = l.cwd || "";
            if (!fm.onStage(c) || !fm.showLive(id, c)) continue;
            const o = { id: id, tool: l.tool || "claude", cwd: c, title: l.prompt || "New session", prompt: l.prompt ?? "",
                        lastPrompt: "", started: l.started, updated: l.last };
            const j = JSON.stringify(o), was = fm.freshSeen[id];
            freshSeen[id] = was && was.j === j ? was : { j: j, s: o };
            fresh.push(freshSeen[id].s);
        }
        fm.freshSeen = freshSeen;
        fresh.sort((a, b) => (b.updated || 0) - (a.updated || 0));
        for (const s of fresh) byId[s.id] = s;
        fm.byId = byId;
        const all = fresh.length ? fresh.concat(fm.history) : fm.history;
        const fk = {};
        for (const s of all) fk[s.id] = fm.filed[s.id] ?? fm.placeOf(s);

        // live per folder: sessions by state, and the windows open there
        const live = {};
        const liveOf = k => live[k] ?? (live[k] = fm.blankLive());
        let waiting = 0, working = 0;
        const needy = [];
        for (const id in st) {
            const state = st[id];
            const s = byId[id];
            const cwd = s ? s.cwd || "" : fm.live[id]?.cwd || fm.terminals[id]?.cwd || (fm.presence?.agents ?? []).find(a => a.session === id)?.cwd || "";
            if (!fm.onStage(cwd) || (!s && !fm.showLive(id, cwd))) continue;
            const k = s ? fk[id] : fm.folderForPath(cwd);
            if (state === "waiting") { liveOf(k).waiting++; waiting++; }
            else if (state === "working") { liveOf(k).working++; working++; }
            else if (state === "open") liveOf(k).open++;
            if (state === "waiting" || state === "working")
                needy.push({ id: id, state: state, title: s ? fm.titleOf(s) : (fm.live[id]?.prompt || fm.terminals[id]?.name || "Session"),
                             at: s ? (s.updated || s.started || 0) : (fm.live[id]?.last || 0) });
        }
        for (const w of fm.presence?.windows ?? []) {
            if (w.special || !w.cwd || !fm.onStage(w.cwd)) continue;
            const l = liveOf(fm.folderForPath(w.cwd));
            if (w.kind === "terminal") l.terminals++;
            else if (w.kind === "graphis") l.graphis++;
            else if (w.kind === "files") l.files++;
        }
        needy.sort((a, b) => (a.state === b.state ? b.at - a.at : a.state === "waiting" ? -1 : 1));
        const marks = needy.slice(0, 4).map(n => ({ id: n.id, state: n.state, title: n.title }));

        // folders: every one a session is in, and the pinned ones
        const archivedSet = {}, pinSet = {}, hiddenSet = {};
        for (const id of fm.archived) archivedSet[id] = true;
        for (const id of fm.pins) pinSet[id] = true;
        for (const k of fm.hidden) hiddenSet[k] = true;
        const pinnedFolder = {};
        for (const p of fm.folderPins) pinnedFolder[p] = true;
        const here = byId[fm.selectedId] ? fk[fm.selectedId] : "";

        const names = {};             // filled once the folders are known, below
        const nameFor = k => names[k] ?? (names[k] = fm.nameOf(k));
        const folderRow = (k, collapsed, count) => {
            const path = fm.pathOf(k), local = k.startsWith("/");
            return { type: "folder", key: "f:" + k, fkey: k, path: path, name: nameFor(k),
                     suffix: k.startsWith("win:") ? "not on this machine" : "", pinned: !!pinnedFolder[k], hidden: !!hiddenSet[k],
                     collapsed: collapsed, count: count, local: local, canPin: local, canStart: local, here: k === here,
                     live: live[k] ?? fm.blankLive() };
        };
        const sessionRow = (s, inGroup, snippet) => {
            const id = s.id;
            if (fm.deleting[id]) return { type: "undo", key: "u:" + id, id: id, title: fm.deleting[id].title };
            const r = { type: snippet !== undefined ? "hit" : "session", key: (snippet !== undefined ? "h:" : "s:") + id, id: id,
                        title: fm.titleOf(s), tool: s.tool || "claude", context: "", state: st[id] ?? "past",
                        pinned: !!pinSet[id], archived: !!archivedSet[id], age: Voice.age(s.updated || s.started || now, now),
                        fkey: fk[id] ?? fm.folderOf(s), session: s, arrived: !!fm.arrivals[id] };
            r.context = fm.contextWord(r, inGroup);
            if (snippet !== undefined) r.snippet = snippet ?? "";
            return r;
        };
        const label = text => ({ type: "label", key: "l:" + text, text: text });
        // folder table: newest activity and the sessions each holds
        const groups = {};
        const order = [];
        for (const s of all) {
            if (archivedSet[s.id] || fm.gone[s.id]) continue;
            const k = fk[s.id];
            let g = groups[k];
            if (!g) { g = groups[k] = { k: k, all: [], newest: 0 }; order.push(k); }
            g.all.push(s);
            g.newest = Math.max(g.newest, s.updated || s.started || 0);
        }
        const recentCut = now - 7 * 86400000;
        const others = order.filter(k => !pinnedFolder[k]);
        others.sort((a, b) => groups[b].newest - groups[a].newest);
        const every = fm.folderPins.concat(others);
        // two folders with one name (~/dev/Wedding, ~/Wedding): each says where it lives, in the
        // headings and the targets alike, whichever of them are shown
        const byName = {};
        for (const k of every) { const n = fm.nameOf(k); (byName[n] = byName[n] ?? []).push(k); }
        for (const n in byName)
            for (const k of byName[n]) {
                if (byName[n].length < 2 || !k.startsWith("/")) { names[k] = n; continue; }
                const up = k.substring(0, k.lastIndexOf("/")).replace(fm.home, "~").split("/");
                names[k] = `${n} · ${up.length > 2 ? "…/" + up.slice(-2).join("/") : up.join("/")}`;
            }
        const targetsOut = every.map(k => ({ fkey: k, path: fm.pathOf(k), name: nameFor(k), pinned: !!pinnedFolder[k],
                                             local: k.startsWith("/"), hidden: !!hiddenSet[k], live: live[k] ?? fm.blankLive() }));

        const out = [];
        const result = mode => ({ mode: mode, rows: out, counts: { waiting: waiting, working: working }, marks: marks, targets: targetsOut });

        // ── search: titles, prompts and folders, then the transcripts ──
        if (q.length) {
            const named = [];
            const seen = {};
            for (const s of fm.history) {
                if (named.length >= 50) break;
                if (!`${fm.titleOf(s)} ${s.prompt} ${s.cwd}`.toLowerCase().includes(q)) continue;
                seen[s.id] = true;
                if (filtering && !keep(s, st[s.id] ?? "past")) continue;
                named.push(s);
            }
            const inside = fm.found.filter(s => !seen[s.id] && (!filtering || keep(s, st[s.id] ?? "past")));
            if (named.length) { out.push(label("Sessions")); for (const s of named) out.push(sessionRow(s, false)); }
            if (inside.length) { out.push(label("In transcripts")); for (const s of inside) out.push(sessionRow(s, false, s.snippet)); }
            if (fm.searching) out.push(label("Searching transcripts…"));
            else if (!out.length && q.length >= 3) out.push(label("Nothing found"));
            return result("q:" + q);
        }

        // ── filters: matches under their folders, all open, at most 100 ──
        if (filtering) {
            const hits = {};
            let n = 0, more = 0;
            for (const s of all) {
                if (archivedSet[s.id] || fm.gone[s.id] || !keep(s, st[s.id] ?? "past")) continue;
                if (n >= 100) { more++; continue; }
                (hits[fk[s.id]] = hits[fk[s.id]] ?? []).push(s);
                n++;
            }
            for (const k of every) {
                const list = hits[k];
                if (!list) continue;
                out.push(folderRow(k, false, list.length));
                for (const s of list) out.push(sessionRow(s, true));
            }
            if (!out.length) out.push({ type: "note", key: "n:filter", text: fm.emptyText(f) });
            // the cap said nothing: a filter with more matches looked complete
            if (more) out.push({ type: "note", key: "n:more", text: `The newest 100 are shown, ${more} older are not.` });
            return result("f:" + JSON.stringify(f));
        }

        // ── the rail: Pinned, Recent, Folders, Older, Hidden, Archived ──
        const above = {};
        const pinned = [];
        for (const id of fm.pins) {
            const s = byId[id];
            if (s && !archivedSet[id] && !fm.gone[id]) { pinned.push(s); above[id] = true; }
        }
        const recent = [];
        for (const s of all) {
            if (recent.length >= 5) break;
            if (above[s.id] || archivedSet[s.id] || fm.gone[s.id] || hiddenSet[fk[s.id]]) continue;
            recent.push(s);
            above[s.id] = true;
        }
        if (!pinned.length && !recent.length)
            out.push({ type: "note", key: "n:empty", text: "Sessions you start here or in a terminal show up under their folder." });
        if (pinned.length) { out.push(label("Pinned")); for (const s of pinned) out.push(sessionRow(s, false)); }
        if (recent.length) { out.push(label("Recent")); for (const s of recent) out.push(sessionRow(s, false)); }

        const shut = {};
        // a folded folder still shows what is waiting or working in it
        const emit = (k, defFolded, pinnedHere, onlyNeedy) => {
            const g = groups[k];
            const list = g ? g.all.filter(s => !above[s.id]) : [];
            const collapsed = onlyNeedy || (fm.folded[k] ?? defFolded);
            shut[k] = collapsed;
            out.push(folderRow(k, collapsed, list.length));
            if (!collapsed && pinnedHere && !g) out.push({ type: "more", key: "m:start:" + k, text: "Start a session here", act: "start:" + k });
            const all_ = !collapsed && fm.more[k];
            let shown = 0;
            for (let i = 0; i < list.length; i++) {
                const s = list[i], state = st[s.id];
                if (all_ || (!collapsed && i < 4) || state === "waiting" || state === "working") { out.push(sessionRow(s, true)); shown++; }
            }
            if (!collapsed && shown < list.length)
                out.push({ type: "more", key: "m:more:" + k, text: `Show ${list.length - shown} more`, act: "more:" + k });
            // opened all the way: the way back (showMore toggles)
            else if (all_ && list.length > 4)
                out.push({ type: "more", key: "m:less:" + k, text: "Show fewer", act: "more:" + k });
        };

        const pinnedShown = fm.folderPins.filter(k => !hiddenSet[k]);
        const active = [], old = [];
        for (const k of others) {
            if (hiddenSet[k]) continue;
            const g = groups[k];
            const hasRows = g.all.some(s => !above[s.id]);
            if (g.newest >= recentCut || fm.lit(live[k])) { if (hasRows || fm.lit(live[k])) active.push(k); }
            else if (hasRows) old.push(k);
        }
        const hiddenAll = fm.folderPins.filter(k => hiddenSet[k]).concat(others.filter(k => hiddenSet[k]));
        if (pinnedShown.length || active.length || old.length) out.push(label("Folders"));
        for (const k of pinnedShown) emit(k, false, true, false);
        if (pinnedShown.length && (active.length || old.length)) out.push({ type: "pause", key: "p:" });
        for (const k of active) emit(k, false, false, false);
        if (old.length) {
            out.push({ type: "more", key: "m:older", text: `Older folders · ${old.length}`, act: "older", open: fm.older });
            if (fm.older) for (const k of old) emit(k, true, false, false);
        }
        if (hiddenAll.length) {
            out.push({ type: "more", key: "m:hidden", text: `Hidden · ${hiddenAll.length}`, act: "hidden", open: fm.showHidden });
            for (const k of hiddenAll) {
                if (fm.showHidden) emit(k, true, !!pinnedFolder[k], false);
                else if (live[k] && live[k].waiting + live[k].working > 0) emit(k, true, false, true);
            }
        }
        const gone = fm.history.filter(s => archivedSet[s.id] && !fm.gone[s.id]);
        if (gone.length) {
            out.push({ type: "more", key: "m:archived", text: `Archived · ${gone.length}`, act: "archived", open: fm.showArchived });
            if (fm.showArchived) for (const s of gone) out.push(sessionRow(s, false));
        }
        fm.shut = shut;
        return result("rows");
    }
}
