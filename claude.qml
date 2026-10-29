//@ pragma UseQApplication
//@ pragma AppId praxis
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

// The Claude app: every agent session on this machine, running or past, in one tiled window
// on the shell's design language. Its own instance (`qs -p ~/.config/quickshell/tacit/claude.qml`)
// like the code editor. Sessions run in agent-host (~/dev/agent-host), so closing this window
// never stops an agent.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import "modules/claude"

ApplicationWindow {
    id: root

    property var history: []       // host history, noise left out
    property var found: []         // full-text hits for the current query
    // reading every transcript can take seconds (one long session is hundreds of MB): the list says
    // so meanwhile, and says so when nothing was found
    property bool searching: false
    property var selected: null
    property bool panelOpen: false   // the side panel (Files, Review)
    // the panel slides out of the window's right edge and back, on the rail's curve; docked, the
    // conversation eases aside with it
    property real panelShown: root.panelOpen && root.selected !== null ? 1 : 0
    Behavior on panelShown { Anim {} }
    readonly property var folders: {
        const seen = {}, out = [{ path: root.home, name: "Home" }];
        seen[root.home] = true;
        for (const s of root.history) {
            const c = s.cwd || "";
            if (!c.startsWith("/") || seen[c] || c.includes("/.claude/worktrees/")) continue;
            seen[c] = true;
            out.push({ path: c, name: c.split("/").pop() });
            if (out.length >= 12) break;
        }
        return out;
    }
    // A fresh session in a folder: the one given, else the open session's, else Home; with the agent
    // last started there.
    function newSession(fkey) {
        let k = fkey || "";
        const cur = root.selected;
        if (!k.startsWith("/") && cur) k = cur.fresh ? fm.folderForPath(cur.cwd || "") : fm.folderOf(cur.id);
        if (!k.startsWith("/")) k = cur && (cur.cwd || "").startsWith("/") ? cur.cwd : root.home;
        const sel = { fresh: true, id: "", cwd: k, tool: fm.agentFor(k), title: "New session" };
        root.selected = sel;
        root.resolveAgent(sel);
        conv.focusComposer();
    }
    // Which agent a fresh session starts with: a kept folder default, else the one last started in
    // that folder (set above), else what the host resolves (Everywhere, else Claude). The host's
    // answer replaces the fresh session only while it is still the open one; a pick replaces it first.
    function resolveAgent(sel) {
        if (!accounts.available) return;
        accounts.resolve(sel.cwd, "", r => {
            if (!r || root.selected !== sel || !r.agent) return;
            const kept = String(r.from?.agent ?? "").startsWith("folder:");
            if (!kept && fm.agent[fm.folderForPath(sel.cwd)] !== undefined) return;
            if (r.agent !== sel.tool) root.selected = Object.assign({}, sel, { tool: r.agent });
        });
    }
    // A drop on a folder: a fresh session there with the files or the page, waiting for your words.
    function startIn(fkey, drop) {
        const paths = drop?.paths ?? [];
        root.newSession(fkey);
        if (paths.length) conv.take(paths);
        if (drop?.page && typeof conv.prefill === "function") conv.prefill(`Page: ${drop.page.title} ${drop.page.url}`);
        if ("desktopContext" in conv) conv.desktopContext = provenance.contextBlock(paths);
        conv.focusComposer();
    }
    readonly property string home: Quickshell.env("HOME")

    visible: true
    // An app does not reload itself when a file in the shared config changes: a reload rebuilt the
    // window as visible, so every deploy (even one only for the shell) popped a closed app back up.
    // New code arrives the next time the app starts.
    Binding { target: Quickshell; property: "watchFiles"; value: false }
    // The window is this app by name, so the taskbar, the window switcher and window rules can
    // tell it from the editor and from Files (its appId is `praxis`).
    title: root.selected ? `${root.titleOf(root.selected)} — Praxis` : "Praxis"
    color: "transparent"

    // ── the window's own shape, as Files remembers its own (services/Files.qml windowState) ──
    FileView {
        id: shapeFile
        path: `${Directories.state}/user/claude-window.txt`
        blockLoading: true
        printErrors: false
    }
    minimumWidth: 720
    minimumHeight: 420
    // Read once (blockLoading), so this is the size it opens at; a resize overwrites the binding
    // and rememberShape writes what the window ended up as.
    width: root.shape.w
    height: root.shape.h
    readonly property var shape: {
        const s = (shapeFile.text() || "").trim().split(/\s+/).map(Number);
        return s.length === 2 && s[0] >= 720 && s[1] >= 420 ? ({ w: s[0], h: s[1] }) : ({ w: 1280, h: 820 });
    }
    function rememberShape() {
        if (root.width >= 720 && root.height >= 420)
            shapeFile.setText(`${Math.round(root.width)} ${Math.round(root.height)}\n`);
    }
    // The X hides this window and the instance stays, so this is where its shape is written, and
    // where deletes still in their undo minute are sent.
    onVisibleChanged: if (!root.visible) { root.rememberShape(); fm.flushDeletes(); }
    onActiveChanged: if (root.active) presence.refresh()

    Component.onCompleted: MaterialThemeLoader.reapplyTheme()

    Host {
        id: host
        // `active` is keyboard focus, not visibility: an agent normally runs in a terminal while
        // this window is watched from beside it, so the roster stays on a 20 s floor whenever the
        // window is on screen and only quickens while it also has the keyboard.
        pollInterval: root.active ? 10000 : 20000
        // closed, the window only hides: the roster (a `claude` start every 10-20 s, 1.3 % of a core) is read
        // while it is on screen, and at once when it is shown again
        roster: root.visible
        onConnectedChanged: if (connected) root.refresh()
        onHistoryChanged: root.refresh()
    }
    // Accounts, installs and defaults, kept by agent-host; the box, the first-run notice and the
    // preferences sheet read it.
    AccountsModel { id: accounts; host: host }
    // triggeredOnStart: coming back to the window is when the list is most likely to be stale, and
    // that is exactly when this timer starts
    Timer { running: root.visible && host.connected; interval: 20000; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

    // Finishing and asking are announced by the shell's notch (services/Claude.qml), which
    // knows whether this window is showing that session: no notifications from here.

    // Same material as the code editor and foot: the terminal background at foot's alpha.
    FileView {
        id: termColors
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/generated/terminal/sequences.txt`)
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property color termBase: {
        const m = /\]11;(#[0-9a-fA-F]{6})/.exec(termColors.text() || "");
        return m ? m[1] : Appearance.m3colors.m3surfaceContainerLow;
    }
    // the frosted window as every Tacit app has it (Tacit.windowSeeThrough); what turned text grey on grey was
    // Hyprland dimming it again when unfocused, which custom/rules.lua now overrides for Praxis
    readonly property color material: ColorUtils.transparentize(root.termBase, Tacit.windowSeeThrough)
    // a sheet over the conversation (the folded list opened, the panel with no room beside it): the
    // frosted window's look, solid, so the text under it cannot show through
    readonly property color overlay: ColorUtils.mix(root.termBase, Appearance.m3colors.m3primaryContainer, 0.8)

    // ── the sidebar's fold, as Files' rail: "auto" (folded when the window is narrow), or what
    // the toggle / Ctrl+B last chose ─────────────────────────────────────────
    FileView {
        id: railFile
        path: `${Directories.state}/user/claude-rail.txt`
        blockLoading: true
        printErrors: false
    }
    property string railPref: (railFile.text() || "auto").trim()
    // the side panel open in a narrow window: the sessions fold so the conversation keeps room
    readonly property bool railCompact: root.railPref === "compact" || root.width < 900 || (root.panelOpen && root.railPref !== "full" && root.width < 1200)
    // Room for the panel beside a readable conversation (420 px): it docks; otherwise it opens
    // over the conversation, on the window's ground
    readonly property bool panelDocked: root.width - rail.width - Math.max(320, side.chosenWidth) >= 420
    // the panel's buttons: the same one again closes it, another switches to it
    function togglePanel(tab) {
        if (root.panelOpen && side.shownTab === tab) root.panelOpen = false;
        else { side.tab = tab; root.panelOpen = true; }
    }
    function setRailPref(v) { railFile.setText(v + "\n"); root.railPref = v; }

    function rename(id, title) {
        if (!title.trim().length) return;
        host.request({ op: "rename", id: id, title: title.trim() }, m => {
            if (m.ev !== "renamed") return;
            root.refresh();
            if (root.selected && root.selected.id === id) root.selected = Object.assign({}, root.selected, { title: m.title });
        });
    }

    // ── sessions ────────────────────────────────────────────────────────────
    // Benchmark runs and throwaway checks live under /tmp and ~/model-bench: not conversations.
    // Sub-agent threads (Codex marks them with their parent) and headless runs started by other
    // agents or scripts (entrypoint sdk-cli) are not conversations you had; sessions this app
    // started are headless too, and the host marks them `own`.
    function worthShowing(s) {
        if (!root.onStage(s.cwd)) return false;
        if ((s.parent ?? "").length) return false;
        if (s.entry === "sdk-cli" && !s.own) return false;
        if (root.scratch(s.cwd || "")) return false;
        return (s.title || s.lastPrompt || s.prompt || "").length > 0;
    }
    // test and bench folders: their sessions stay out of the list
    function scratch(c) { return c.startsWith("/tmp/") || c.startsWith(root.home + "/model-bench") || c.startsWith(root.home + "/bench-sb"); }
    // A demo take: $XDG_RUNTIME_DIR/notch-stage holds the demo repo's path and only its sessions
    // show, so real conversations stay off camera (the notch reads the same file).
    property string stage: ""
    FileView {
        id: stageFile
        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/notch-stage`
        watchChanges: true
        printErrors: false
        onFileChanged: stageFile.reload()
        onLoaded: root.setStage(stageFile.text().trim())
        onLoadFailed: root.setStage("")
    }
    function onStage(cwd) { const c = cwd || ""; return !root.stage.length || c === root.stage || c.startsWith(root.stage + "/"); }
    function setStage(path) {
        if (path === root.stage) return;
        root.stage = path;
        if (root.selected && !root.onStage(root.selected.cwd)) root.selected = null;
        root.refresh();
    }
    function refresh() {
        host.request({ op: "history" }, m => {
            if (m.ev !== "history") return;
            const list = m.sessions.filter(root.worthShowing);
            root.loaded = true;
            // A history that has not changed keeps its objects. A new array rebuilds every sidebar
            // row — taking a rename box being typed in with it — and rewrites claude-last.txt.
            if (JSON.stringify(list) !== JSON.stringify(root.history)) root.history = list;
            if (root.selected) {
                const s = root.history.find(x => x.id === root.selected.id);
                if (s && s !== root.selected) root.selected = s;
            } else if (!root.restored) {
                root.restored = true;
                const id = (lastFile.text() || "").trim();
                const s = root.history.find(x => x.id === id);
                if (s) root.selected = s;
            }
        });
    }
    function titleOf(s) { return (s.title || s.lastPrompt || s.prompt || "Untitled").replace(/\s*<desktop-context>[\s\S]*$/, ""); }
    function projectOf(cwd) {
        if (!cwd) return "";
        if (cwd === root.home) return "~";
        return cwd.split(/[\/\\]/).filter(x => x.length).pop() ?? "";
    }
    // A session in a terminal that is blocked on a permission prompt: `claude agents --json` only
    // ever says idle or busy, so "waiting" comes from the hooks' own state files — the ones the
    // shell's notch restores its rows from. This app is its own qs instance and cannot read
    // AgentSessions, so it asks the same helper.
    property var hookStates: ({})   // id -> the hooks' state, for sessions in a terminal
    Process {
        id: hookState
        command: [`${Directories.tacitBin}/notch-sessions-restore`]
        stdout: StdioCollector {
            onStreamFinished: {
                const states = {};
                for (const line of this.text.split("\n")) {
                    const f = line.split("\t");
                    if (f.length >= 2) states[f[0]] = f[1];
                }
                if (JSON.stringify(states) !== JSON.stringify(root.hookStates)) root.hookStates = states;
            }
        }
    }
    Timer {
        running: root.visible
        interval: 10000
        repeat: true
        triggeredOnStart: true
        onTriggered: { hookState.running = false; hookState.running = true; }
    }
    // ── the rail: FolderModel's rows, the cove, target mode, what is open on the desktop ──
    property bool loaded: false        // the first history reply: until then the rail says "Looking…"
    FolderModel {
        id: fm
        history: root.history
        live: host.live
        // a running session in a test folder showed in Recent and in the counts until it ended, though its
        // history is left out (worthShowing); one started here stays
        showLive: (id, cwd) => !!root.mine[id] || !root.scratch(cwd)
        terminals: host.terminals
        leftovers: host.leftovers
        hookStates: root.hookStates
        presence: ({ windows: presence.windows, agents: presence.agents })
        query: rail.query
        found: root.found
        searching: root.searching
        filter: rail.filter
        frozen: rail.frozen
        selectedId: root.selectedId
        host: host
        stage: root.stage
        onDeleted: (id, error) => {
            if (error.length) { rail.notice(`Not deleted: ${error}`); return; }
            if (id !== root.selectedId) return;
            // the open session went: a new one in its folder, and the keyboard stays where it was
            const f = root.activeFocusItem;
            root.newSession(fm.folderOf(root.selected));
            if (f && f !== root.activeFocusItem) f.forceActiveFocus();
        }
    }
    // A change made in the rail shows at once: while the pointer is in the rail FolderModel keeps
    // the shown order, so the rebuilds of the next 200 ms take the built order instead.
    property bool applying: false
    function applyNow() { root.applying = true; applyEnd.restart(); }
    Timer { id: applyEnd; interval: 200; onTriggered: root.applying = false }
    Connections {
        target: fm
        function onBuiltChanged() { if (root.applying && !fm.sameRows(fm.rows, fm.built)) fm.rows = fm.built; }
    }
    // A delete in its undo minute is called off when the session is used again: a message sent to
    // it from here, or the host starting to run it.
    property var deleteRan: ({})       // id -> whether the host ran it at the last look
    function hostRuns(id) { const l = host.live[id]; return !!l && l.state !== "idle"; }
    function keepIfDeleting(id) { if (id.length && fm.deleting[id]) { fm.undoDelete(id); root.applyNow(); } }
    Connections {
        target: conv
        function onPendingUserChanged() { if (conv.pendingUser.length) root.keepIfDeleting(root.selectedId); }
    }
    Connections {
        target: host
        function onLiveChanged() {
            const ran = {};
            for (const id in fm.deleting) {
                ran[id] = root.hostRuns(id);
                if (ran[id] && root.deleteRan[id] === false) root.keepIfDeleting(id);
            }
            root.deleteRan = ran;
        }
    }
    Presence {
        id: presence
        running: root.visible && rail.expanded
    }
    Provenance { id: provenance }
    // the rows as drawn: nothing until the history has answered; a fresh session's "New session"
    // row at the top of its folder until it is sent or another session is chosen
    readonly property var railRows: {
        const rows = fm.rows;
        if (!root.loaded) return [];
        const s = root.selected;
        if (!s || !s.fresh || rail.query.length || rail.filtering) return rows;
        const k = fm.folderForPath(s.cwd || "");
        const i = rows.findIndex(r => r.type === "folder" && r.fkey === k);
        if (i < 0 || rows[i].collapsed) return rows;
        const out = rows.slice();
        if (out[i + 1]?.key === "m:start:" + k) out.splice(i + 1, 1);
        out.splice(i + 1, 0, { type: "session", key: "s:new", id: "", title: "New session", tool: s.tool || "claude", context: "",
                               state: "past", placeholder: true, fkey: k, session: s });
        return out;
    }
    readonly property var agentsSeen: ["claude", "codex", "pi", "opencode"].filter(t => root.history.some(s => (s.tool || "claude") === t))
    // A verb the host lacks is left out: caps from the live session, else the host's hello
    // (protocol 5), else protocol 4's (rename for Claude only).
    function capsOf(row) {
        if (!row || !row.id) return ({});
        const tool = row.tool || "claude";
        return host.live[row.id]?.caps ?? host.agents?.[tool]?.caps ?? ({ rename: tool === "claude" });
    }
    function heldByTerminal(id) {
        return (!!host.terminals[id] && !host.live[id]) || presence.agents.some(a => a.session === id && !!a.window);
    }
    function canDelete(row) { return !!root.capsOf(row).delete && !root.heldByTerminal(row.id) && host.connected; }
    // the folder's windows and the sessions Praxis runs there, for the folder cove's "Open here"
    function presenceIn(fkey) {
        const windows = presence.windows.filter(w => !w.special && (w.cwd || "").length && fm.onStage(w.cwd) && fm.folderForPath(w.cwd) === fkey);
        const agents = [];
        for (const id in host.live) {
            const l = host.live[id];
            if (!l || !(l.alive || l.state !== "idle")) continue;
            const s = fm.byId[id];
            if ((s ? fm.folderOf(s) : fm.folderForPath(l.cwd || "")) !== fkey) continue;
            agents.push({ tool: l.tool || "claude", session: id, window: "", title: s ? fm.titleOf(s) : (l.prompt || "Session") });
        }
        return { windows: windows, agents: agents };
    }
    // a session row for one the rail does not show (folded away): Ctrl+K's verbs
    function rowFor(id) {
        const s = fm.byId[id];
        if (!s) return null;
        return { type: "session", key: "s:" + id, id: id, title: fm.titleOf(s), tool: s.tool || "claude", context: "", state: fm.stateOf(id),
                 pinned: fm.pins.includes(id), archived: fm.archived.includes(id), age: Voice.age(s.updated || s.started || Date.now()),
                 fkey: fm.folderOf(s), session: s };
    }
    function openId(id) {
        const s = root.history.find(x => x.id === id);
        const l = host.live[id];
        if (s) root.choose(s);
        else if (l) root.choose({ id: id, tool: l.tool || "claude", cwd: l.cwd, title: l.prompt || "Session", prompt: l.prompt ?? "", lastPrompt: "", started: l.started, updated: l.last });
    }
    // claudeapp open(id): its folder unfolds (Older folders and Show more open if they hold it),
    // and the row is scrolled into view
    function reveal(id) {
        const k = fm.folderOf(id);
        if (!root.railRows.some(r => r.id === id && (r.type === "session" || r.type === "hit"))
                && !fm.rows.some(r => r.key === "f:" + k) && !fm.hidden.includes(k) && !fm.older)
            fm.toggle("older");
        revealTry.id = id;
        revealTry.n = 0;
        revealTry.unfolded = false;
        revealTry.restart();
    }
    // each tick after a rebuild: the heading unfolds once (older folders open folded), then Show more
    Timer {
        id: revealTry
        property string id: ""
        property int n: 0
        property bool unfolded: false
        interval: 60
        repeat: true
        onTriggered: {
            const i = root.railRows.findIndex(r => (r.type === "session" || r.type === "hit") && r.id === revealTry.id);
            if (i >= 0) { rail.showIndex(i); revealTry.stop(); return; }
            const k = fm.folderOf(revealTry.id);
            const head = fm.rows.find(r => r.key === "f:" + k);
            if (head && head.collapsed && !revealTry.unfolded) { revealTry.unfolded = true; fm.toggleFold(k); }
            else if (head && !head.collapsed && !fm.more[k] && fm.rows.some(r => r.key === "m:more:" + k)) fm.showMore(k);
            if (++revealTry.n > 10) revealTry.stop();
        }
    }
    // Ctrl+Z in the rail: the last move, within a minute, or the last delete, within its undo row
    property var lastUndo: null
    function undoLast() {
        const u = root.lastUndo;
        root.lastUndo = null;
        if (!u) return;
        if (u.kind === "delete") fm.undoDelete(u.id);
        else if (Date.now() - u.at < 60000) {
            if (u.was === undefined) fm.unrefile(u.id);
            else fm.refile(u.id, u.was);
        }
    }
    function refile(id, fkey) {
        root.lastUndo = { kind: "move", id: id, was: fm.filed[id], at: Date.now() };
        fm.refile(id, fkey);
    }
    function fork(id) {
        host.request({ op: "fork", id: id }, m => {
            if (m.ev !== "forked") { rail.notice(`Not forked: ${m.message ?? "the background service did not answer"}`); return; }
            root.markMine(m.id);
            const src = fm.byId[id] ?? ({});
            if (fm.filed[id]) fm.refile(m.id, fm.filed[id]);
            root.selected = { id: m.id, tool: m.tool || src.tool || "claude", cwd: src.cwd ?? "", title: src.id ? fm.titleOf(src) : "Session",
                              prompt: src.prompt ?? "", lastPrompt: "", started: Date.now(), updated: Date.now() };
            root.refresh();
            conv.focusComposer();
        });
    }
    // a Pinax window already on that folder, else a new one
    function showInPinax(row) {
        const cwd = row?.session?.cwd || "";
        if (!cwd.startsWith("/")) return;
        const w = presence.windows.find(x => x.kind === "files" && !x.special && x.cwd === cwd);
        if (!(w && presence.focus(w.address))) Quickshell.execDetached(fm.shellIpc.concat(["at", cwd]));
    }
    function askRename(row) {
        if (!row) return;
        if (row.type === "folder") {
            if (row.local && fm.shellUp) rail.startRename(row.key, fm.nameOf(row.fkey));
            return;
        }
        if (!root.capsOf(row).rename || !host.connected) return;
        const r = rail.rowOf(row.key) ?? root.railRows.find(x => x.id === row.id && (x.type === "session" || x.type === "hit"));
        if (r) rail.startRename(r.key, r.title);
    }
    function renameRow(key, text) {
        if (key.startsWith("f:")) fm.rename(fm.pathOf(key.slice(2)), text);
        else root.rename(key.slice(2), text);
    }
    // Pinax's folder picker; the choice comes back through `picked`
    property string pickingFor: ""
    function pickFolder() {
        root.pickingFor = "folder";
        Quickshell.execDetached(fm.shellIpc.concat(["pickdir", root.home, `${root.home}/.config/quickshell/tacit/claude.qml`, "claudeapp", "Add to Praxis"]));
    }
    // a live mark: exactly one window and no agent focuses it; anything else opens the folder's cove
    function markClicked(row) {
        const l = row.live ?? ({});
        const windows = (l.terminals ?? 0) + (l.graphis ?? 0) + (l.files ?? 0);
        const agents = (l.waiting ?? 0) + (l.working ?? 0) + (l.open ?? 0);
        const w = windows === 1 && agents === 0 ? root.presenceIn(row.fkey).windows[0] : null;
        if (!(w && presence.focus(w.address))) rail.openCove(row.key, "verbs", false, null, "rail");
    }
    // Ctrl+K: the open session's verbs, from anywhere in the window; again, it closes them
    function verbsOfOpen() {
        const id = root.selectedId;
        if (!id.length) return;
        if (cove.mode === "session" && cove.row?.id === id) { cove.close(); return; }
        const r = root.railRows.find(x => (x.type === "session" || x.type === "hit") && x.id === id);
        rail.openCove(r ? r.key : "", "verbs", true, r ? null : root.rowFor(id), rail.focused ? "rail" : "window");
    }

    // Everything the rail and the cove do: session verbs take the id, folder verbs the fkey.
    function act(verb, arg, row) {
        const folder = row?.type === "folder";
        switch (verb) {
        case "pin": if (folder) fm.pin(row.path); else fm.togglePin(arg); break;
        case "unpin": fm.unpin(folder ? row.path : arg); break;
        case "archive": fm.toggleArchive(arg); break;
        case "rename": root.askRename(row); break;
        case "move": if (row) rail.startTargets("move", { label: row.title }, { id: arg }, true); break;
        case "fork": root.fork(arg); break;
        case "files": root.showInPinax(row); break;
        case "delete":
            if (row && root.canDelete(row)) {
                fm.scheduleDelete(arg);
                root.lastUndo = { kind: "delete", id: arg };
                root.deleteRan = Object.assign({}, root.deleteRan, { [arg]: root.hostRuns(arg) });
            }
            break;
        case "new": root.newSession(arg); break;
        case "hide": fm.hide(arg); break;
        case "unhide": fm.unhide(arg); break;
        case "focus": presence.focus(arg); break;
        case "graphis": presence.openGraphis(arg); break;
        case "select": root.openId(arg); break;
        case "fold": fm.toggleFold(arg); break;
        case "more":
            if (arg.startsWith("more:")) fm.showMore(arg.slice(5));
            else if (arg.startsWith("start:")) root.newSession(arg.slice(6));
            else fm.toggle(arg);
            break;
        case "undo": if (arg) fm.undoDelete(arg); else root.undoLast(); break;
        case "shift": if (folder) fm.move(row.path, fm.folderPins.indexOf(row.path) + arg); break;
        case "pickFolder": root.pickFolder(); break;
        case "startIn": root.startIn(arg.fkey, arg.drop); break;
        case "refile": root.refile(arg.id, arg.fkey); break;
        case "addFolder": fm.pin(arg); break;
        case "reorder":
            if (arg.index < 0) fm.unpin(arg.path);
            else { fm.pin(arg.path); fm.move(arg.path, arg.index); }
            break;
        }
        if (["pin", "unpin", "archive", "hide", "unhide", "shift", "refile", "addFolder", "reorder", "undo"].includes(verb)) root.applyNow();
    }

    // ── arrivals: a session from the notch, a fork or another client gets the sand wash ──
    // The host announces a session before it answers `started`, so an id is checked a beat later
    // against the ones this window started.
    property var liveSeen: null        // ids seen since connecting; null until the first list
    property var mine: ({})
    property var arriving: []
    function markMine(id) { const m = Object.assign({}, root.mine); m[id] = true; root.mine = m; }
    Connections {
        target: host
        function onLiveChanged() {
            const ids = Object.keys(host.live);
            if (root.liveSeen === null) {
                if (!host.connected) return;
                const seen = {};
                for (const id of ids) seen[id] = true;
                root.liveSeen = seen;
                return;
            }
            const fresh = ids.filter(id => !root.liveSeen[id]);
            if (!fresh.length) return;
            const seen = Object.assign({}, root.liveSeen);
            for (const id of fresh) seen[id] = true;
            root.liveSeen = seen;
            root.arriving = root.arriving.concat(fresh);
            arrivalCheck.restart();
        }
    }
    Timer {
        id: arrivalCheck
        interval: 400
        onTriggered: {
            for (const id of root.arriving)
                if (!root.mine[id] && root.selectedId !== id) fm.arrived(id);
            root.arriving = [];
        }
    }

    // full-text search, once typing pauses
    Timer {
        id: searchLater
        interval: 300
        onTriggered: {
            const q = rail.query.trim();
            if (q.length < 3) { root.found = []; root.searching = false; return; }
            root.searching = true;
            host.request({ op: "search", q: q }, m => {
                if (m.q !== undefined && m.q !== rail.query.trim()) return;   // an older query's answer
                root.searching = false;
                if (m.ev === "search") root.found = m.results.filter(root.worthShowing);
            });
        }
    }
    Connections {
        target: rail
        function onQueryChanged() { root.found = []; root.searching = rail.query.trim().length >= 3; searchLater.restart(); }
    }

    readonly property var noChanges: ({ files: [], add: 0, del: 0 })
    function choose(s) {
        if (!s) return;
        const t = Date.now();
        root.selected = s;
        if (Quickshell.env("PRAXIS_TEST") === "1") console.warn(`TESTSWITCH choose took ${Date.now() - t} ms`);
    }
    // the last session you had open comes back on reopen (and after a reload of the app itself)
    FileView {
        id: lastFile
        path: `${Directories.state}/user/claude-last.txt`
        blockLoading: true
        printErrors: false
    }
    onSelectedChanged: {
        if (root.selected && !root.selected.fresh && root.selected.id.length) lastFile.setText(root.selected.id);
        // the history refresh swaps in a new object for the same session: only another session clears the list
        if ((root.agentsInfo?.id ?? "") !== root.idOf(root.selected)) root.agentsInfo = null;
        root.loadAgents();
    }

    // ── Claude Code ready: installed, and signed in ─────────────────────────
    // Asked of the CLI itself; only a clear "not installed" or "not signed in" blocks the window.
    // An answer in another shape says nothing, so a changed CLI never locks anyone out.
    // Used only until a host has reported its agents; after that readiness is accounts.anyReady.
    property string claudeNeed: ""     // "" | missing | signedOut
    // a host that keeps accounts has said which agents there are, on this connection or before a drop
    readonly property bool accountsHeard: Object.keys(accounts.agents).length > 0
    Process {
        id: claudeCheck
        command: ["bash", "-c", "command -v claude >/dev/null 2>&1 || { echo '{\"missing\":true}'; exit 0; }; claude auth status --json 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                let d = null;
                try { d = JSON.parse(this.text); } catch (e) { return; }
                root.claudeNeed = d.missing === true ? "missing" : d.loggedIn === false ? "signedOut" : "";
            }
        }
    }
    function checkClaude() { claudeCheck.running = false; claudeCheck.running = true; }
    Timer { running: root.visible && !root.accountsHeard; interval: root.claudeNeed.length ? 5000 : 300000; repeat: true; triggeredOnStart: true; onTriggered: root.checkClaude() }

    // ── the host's line: reconnecting (quietly, the first ten seconds), unreachable, outdated ──
    property real hostLostAt: Date.now()
    property real hostClock: Date.now()
    Connections {
        target: host
        function onConnectedChanged() {
            root.hostLostAt = Date.now();
            root.liveSeen = null;
            if (host.connected && !root.accountsHeard) root.checkClaude();
        }
    }
    Timer { running: !host.connected; interval: 1000; repeat: true; onTriggered: root.hostClock = Date.now() }
    readonly property string hostNote: host.connected ? (host.protoMismatch ? "outdated" : "")
        : root.hostClock - root.hostLostAt < 2000 ? "" : root.hostClock - root.hostLostAt < 10000 ? "reconnecting" : "unreachable"
    function restartHost() { Quickshell.execDetached(["systemctl", "--user", "restart", "agent-host.service"]); root.hostLostAt = Date.now(); }

    // ── what runs beside the conversation: sub-agents, workflow runs, background commands ──
    // Read by agent-host from what Claude Code writes beside the session; asked again every two
    // seconds while anything runs (or the turn does), else every fifteen.
    property var agentsInfo: null
    property real clock: Date.now()
    function idOf(s) { return s && !s.fresh ? (s.id || "") : ""; }
    readonly property string selectedId: root.idOf(root.selected)
    readonly property bool agentsRunning: !!root.agentsInfo && ((root.agentsInfo.agents ?? []).some(a => a.state === "running")
        || (root.agentsInfo.workflows ?? []).some(w => w.state === "running") || (root.agentsInfo.shells ?? []).some(x => x.state === "running"))
    // Stop is a control request to the process: only a session this app's host runs can take one
    readonly property bool canStop: root.selectedId.length > 0 && !!(host.live[root.selectedId]?.alive)
    // one `agents` request at a time: a slow read is not asked again by the timers; any reply,
    // the disconnect one included, ends it
    property bool agentsAsking: false
    function loadAgents() {
        const id = root.idOf(root.selected);
        if (!id.length || !host.connected || root.agentsAsking) return;
        root.agentsAsking = true;
        host.request({ op: "agents", id: id }, m => {
            root.agentsAsking = false;
            // another session was opened meanwhile: its own read was skipped
            if (root.idOf(root.selected) !== id) { root.loadAgents(); return; }
            if (m.ev !== "agents") return;
            delete m.tag;
            // an unchanged reply keeps its object: a new one rebuilds every row bound to it
            if (JSON.stringify(m) !== JSON.stringify(root.agentsInfo)) root.agentsInfo = m;
        });
    }
    function stopTask(task) {
        const id = root.idOf(root.selected);
        if (!id.length || !task.length) return;
        host.request({ op: "stop_task", id: id, task: task }, () => agentsSoon.restart());
    }
    Timer { id: agentsSoon; interval: 600; onTriggered: root.loadAgents() }
    Timer {
        running: root.visible && host.connected && root.selectedId.length > 0
        interval: root.agentsRunning || conv.busy ? 2000 : 15000
        repeat: true
        triggeredOnStart: true   // a host that has just connected, a window just shown: asked at once
        onTriggered: root.loadAgents()
    }
    Timer { running: root.visible && root.agentsRunning; interval: 1000; repeat: true; onTriggered: root.clock = Date.now() }
    property bool restored: false

    // The preferences sheet and the rail's menu are never open together.
    function openPrefs(path) { cove.close(); prefsSheet.openFor(path ?? (root.selected?.cwd ?? "")); }
    function togglePrefs() { if (prefsSheet.open) prefsSheet.close(); else root.openPrefs(); }

    // Closing the window hides it and the instance stays, so the next open is instant; every
    // way in shows it again (claude-hand then focuses it).
    IpcHandler {
        target: "claudeapp"
        function rail(pref: string): void { root.setRailPref(pref); }   // auto | compact | full
        function find(q: string): void { conv.find(q); }
        // the preferences sheet, opened on a folder's sentence when one is given
        function prefs(folder: string): string { if (folder === "close") prefsSheet.close(); else root.openPrefs(folder); return String(prefsSheet.open); }
        // the box's run or agent menu ("setup" is the agent menu as first run shows it)
        function cove(kind: string): string {
            if (kind === "run") conv.openRunCove();
            else if (kind === "agent") conv.openAgentCove(false);
            else if (kind === "setup") conv.openAgentCove(true);
            else return "unknown kind: " + kind;
            return kind;
        }
        function review(open: bool): void { side.tab = "review"; root.panelOpen = open; }
        function panel(tab: string): void { if (tab.length) { side.tab = tab; root.panelOpen = true; } else root.panelOpen = false; }
        function openFile(path: string, line: int): void { side.openFile(path, line, ""); }
        // for scripts and checks: the commit sheet, and a comment on the first changed line
        function reviewCommit(): void { side.review.openCommit(); }
        function reviewComment(text: string): void {
            const f = side.review.shownFiles.find(x => (x.hunks ?? []).length);
            if (!f) return;
            const h = f.hunks[0];
            side.review.comments = side.review.comments.concat([{ path: side.review.rel(f), line: h.line, text: text, quote: "", hunk: h.id }]);
        }
        function present(): void { root.visible = true; }   // not "show": qs parses `ipc call x show` as `ipc show`
        function state(): string {
            return JSON.stringify({ connected: host.connected, history: root.history.length, rows: root.railRows.length,
                labels: root.railRows.filter(r => r.type === "label").map(r => r.text), projects: root.railRows.filter(r => r.type === "folder").length, live: Object.keys(host.live).length,
                terminals: Object.keys(host.terminals).length, selected: root.selected ? root.selected.id : "", cwd: root.selected ? root.selected.cwd || "" : "",
                title: root.title, items: conv.items.length, total: conv.total, found: root.found.length });
        }
        function rowsJson(n: int): string {
            return JSON.stringify(root.railRows.slice(0, n).map(r => ({ type: r.type, key: r.key, text: r.text ?? r.name ?? r.title, age: r.age,
                state: r.state, context: r.context, snippet: r.snippet })));
        }
        function select(id: string): string { root.choose(root.history.find(s => s.id === id)); return state(); }
        // scripts/praxis/check.py (PRAXIS_TEST=1): its own sessions, running ones too, which select's history lacks
        function testOpen(id: string): string {
            const mine = (Quickshell.env("PRAXIS_TEST_SESSIONS") ?? "").split(",");
            if (Quickshell.env("PRAXIS_TEST") !== "1" || !mine.includes(id)) return "refused";
            const l = host.live[id];
            root.choose(root.history.find(s => s.id === id) ?? fm.byId[id]
                        ?? { id: id, tool: l?.tool || "claude", cwd: l?.cwd || "", title: l?.prompt || "Test", prompt: l?.prompt ?? "", lastPrompt: "",
                             started: l?.started ?? 0, updated: l?.last ?? 0 });
            return state();
        }
        function selectRow(i: int): string { const r = root.railRows[i]; if (r && r.session && !r.placeholder) root.choose(r.session); return state(); }
        function search(q: string): void { rail.setQuery(q); }
        // the window as a PNG, for checks that must not put it on screen
        function shot(path: string): void { surface.grabToImage(r => r.saveToFile(path)); }
        function newSession(): string { root.newSession(""); return state(); }
        // the desktop's way in (claude-hand): start a session somewhere, or show one
        function handoff(cwd: string, prompt: string): void {
            root.visible = true;
            root.selected = { fresh: true, id: "", cwd: cwd.length ? cwd : root.home, tool: "claude", title: "New session" };
            conv.send(prompt);
        }
        // a file for the open session (the region selector's "Ask Claude"): a session in a
        // terminal cannot take it, so that case starts a new one in the same folder
        function attach(path: string): void {
            root.visible = true;
            if (!root.selected || conv.locked) root.newSession("");
            conv.take([path]);
        }
        function open(id: string): void {
            root.visible = true;
            root.openId(id);
            root.reveal(id);
        }
        // Files' pick mode hands its choice back here
        // (the list can arrive as JSON text, as one path, or already unwrapped to a string)
        function picked(json: string): void {
            let paths;
            try { paths = JSON.parse(json); } catch (e) { paths = json; }
            if (typeof paths === "string") paths = paths.split("\n");
            paths = (paths ?? []).filter(p => typeof p === "string" && p.trim().length).map(p => p.trim());
            // the rail's "Add a folder" asked: the folder is pinned (in Pinax too)
            if (root.pickingFor === "folder") {
                root.pickingFor = "";
                if (paths.length) { fm.pin(paths[0]); root.applyNow(); }
                return;
            }
            conv.take(paths);
        }
        function folder(path: string): void { if (root.selected) root.selected = Object.assign({}, root.selected, { cwd: path }); }
        function mode(m: string): void { conv.chosenMode = m; }
        function answer(allow: bool): string {
            const p = conv.pending[0];
            if (p) conv.answer({ op: "answer", id: root.selected.id, request: p.request, allow: allow });
            return p ? p.tool : "nothing pending";
        }
        function send(text: string): string { conv.send(text); return state(); }
        function live(): string { return JSON.stringify({ working: conv.working, running: conv.running, locked: conv.locked, pending: conv.pending.length,
            partial: conv.partialText.length, thinking: conv.partialThinking.length, offset: conv.offset, rows: conv.items.length, changes: conv.changes.files.length }); }
        function pin(): string { if (root.selected) fm.togglePin(root.selected.id); return state(); }
        // for tests: a drop's path ({paths, page}), and a cove verb on a row by key. railAct also takes
        // peek / verbs (the cove on that row) and drop / move / new / reorder (target mode).
        function dropOn(fkey: string, json: string): string {
            let d = {};
            try { d = JSON.parse(json); } catch (e) {}
            root.startIn(fkey, { paths: d.paths ?? [], page: d.page ?? null });
            return state();
        }
        function railAct(verb: string, key: string): string {
            const r = root.railRows.find(x => x.key === key) ?? null;
            if (verb === "peek" || verb === "verbs") rail.openCove(key, verb, false, null, "rail");
            else if (verb === "drop" || verb === "move" || verb === "new" || verb === "reorder") {
                if (verb === "move" && r) rail.startTargets("move", { label: r.title }, { id: r.id }, true);
                else if (verb === "reorder" && r) rail.startTargets("reorder", { label: r.name, path: r.path, isFolder: true }, {}, true);
                else if (verb === "new") rail.startTargets("new", {}, {}, true);
            } else if (r) root.act(verb, r.type === "folder" ? r.fkey : r.id, r);
            return JSON.stringify({ cove: cove.mode, coveKey: cove.row?.key ?? "", targets: rail.targetPurpose, row: r ? r.key : "" });
        }
    }

    Shortcut { sequence: "Ctrl+P"; onActivated: { cove.close(); rail.focusSearch(); } }
    // Ctrl+Q does what the X does: this instance stays warm, and a message typed but not sent
    // cannot be thrown away by a keystroke. Ctrl+K is the palette's row menu everywhere.
    Shortcut { sequence: "Ctrl+Q"; onActivated: root.visible = false }
    Shortcut { sequence: "Ctrl+N"; onActivated: { cove.close(); root.newSession(rail.cursorFolder()); } }
    Shortcut { sequence: "Ctrl+Shift+N"; onActivated: { cove.close(); rail.startTargets("new", {}, {}, true); } }
    Shortcut { sequence: "Ctrl+K"; onActivated: root.verbsOfOpen() }
    Shortcut { sequence: "Alt+P"; onActivated: conv.openRunCove() }
    Shortcut { sequence: "Alt+A"; onActivated: conv.openAgentCove(false) }
    Shortcut { sequence: "Ctrl+,"; onActivated: root.togglePrefs() }
    Shortcut { sequence: "Ctrl+F"; onActivated: { cove.close(); conv.openFind(); } }
    Shortcut { sequence: "Ctrl+B"; onActivated: root.setRailPref(root.railCompact ? "full" : "compact") }   // Files' key
    Shortcut { sequence: "Ctrl+Alt+B"; onActivated: root.panelOpen = !root.panelOpen }
    Shortcut { sequence: "Alt+Down"; onActivated: { cove.close(); rail.move(1); } }
    Shortcut { sequence: "Alt+Up"; onActivated: { cove.close(); rail.move(-1); } }

    // Signals of packages that may land after this one: connected by name, ignored until they exist.
    Connections {
        target: conv
        ignoreUnknownSignals: true
        function onAgentChosen(tool) {
            if (!root.selected) return;
            root.selected = Object.assign({}, root.selected, { tool: tool });
            fm.rememberAgent(fm.folderForPath(root.selected.cwd || ""), tool);
        }
    }
    Connections {
        target: side
        ignoreUnknownSignals: true
        function onAttachRequested(path) { conv.take([path]); }
    }

    // ── the window ──────────────────────────────────────────────────────────
    Rectangle {
        id: surface
        anchors.fill: parent
        color: root.material

        RowLayout {
            anchors.fill: parent
            spacing: 0

            SessionList {
                id: rail
                Layout.fillHeight: true
                Layout.preferredWidth: implicitWidth
                compact: root.railCompact
                ground: root.overlay
                onToggle: root.setRailPref(root.railCompact ? "full" : "compact")
                rows: root.railRows
                currentId: root.selected ? root.selected.id : ""
                counts: fm.counts
                marks: fm.marks
                targetFolders: fm.targets
                agents: root.agentsSeen
                provenance: provenance
                cove: cove
                shellUp: fm.shellUp
                saveFailed: fm.saveFailed
                onChosen: s => root.choose(s)
                onAct: (verb, arg, row) => root.act(verb, arg, row)
                onRenameAsked: row => root.askRename(row)
                onRenameRequested: (key, text) => root.renameRow(key, text)
                onMarkClicked: row => root.markClicked(row)
                onTyped: e => conv.typeInto(e)
                onGiveBack: conv.focusComposer()
                Rectangle {
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    z: -1   // under the panel when it opens over the conversation
                    width: 1
                    color: Appearance.colors.colOutlineVariant
                    opacity: 0.4
                }
            }

            Conversation {
                id: conv
                Layout.fillWidth: true
                Layout.fillHeight: true
                host: host
                session: root.selected
                pinned: root.selected ? fm.pins.includes(root.selected.id) : false
                folders: root.folders
                viewer: mediaViewer
                files: side
                panelOpen: root.panelOpen && side.visible
                onPinToggled: if (root.selected) fm.togglePin(root.selected.id)
                // a turn's View changes: that turn in the review; again on the same turn closes it
                onChangesViewed: edits => {
                    if (root.panelOpen && side.shownTab === "review" && side.review.keyOf(edits) === side.review.turnKey) root.panelOpen = false;
                    else { side.review.showTurn(edits); side.tab = "review"; root.panelOpen = true; }
                }
                // the header's panel button shows and hides the panel on the tab it was on, as Ctrl+Alt+B
                // does; it switched to Files when another tab showed instead of closing
                onFilesToggled: root.panelOpen = !root.panelOpen
                agentsInfo: root.agentsInfo
                clock: root.clock
                canStop: root.canStop
                openAgent: root.panelOpen && side.shownTab === "agents" && side.agents.view === "agent" ? side.agents.shownAgent : ""
                openRun: root.panelOpen && side.shownTab === "agents" && side.agents.view === "run" ? side.agents.shownRun : ""
                onAgentOpened: a => side.openAgent(a)
                onRunOpened: r => side.openRun(r)
                onStopTask: t => root.stopTask(t)
                // the list, not the agent or run a report left open
                onAgentsToggled: { if (!(root.panelOpen && side.shownTab === "agents")) side.agents.showList(); root.togglePanel("agents"); }
                need: root.accountsHeard ? "" : root.claudeNeed
                accounts: accounts
                ground: root.overlay
                onPrefsRequested: root.openPrefs()
                onSettingsRequested: anchor => accounts.openSettings(anchor)
                hostNote: root.hostNote
                onRecheck: root.checkClaude()
                onRestartHost: root.restartHost()
                onStarted: s => { root.markMine(s.id); root.selected = s; }
                onFolderChosen: path => root.selected = Object.assign({}, root.selected, { cwd: path })
            }

            // the docked panel's room (the panel itself is laid over this column)
            Item {
                Layout.fillHeight: true
                Layout.preferredWidth: root.panelDocked && side.visible ? side.width * root.panelShown : 0
            }
        }

        SidePanel {
            id: side
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            // no room beside the conversation: it takes the conversation's whole width (over half of
            // it, every line ran on under its edge)
            width: root.panelDocked ? implicitWidth : surface.width - rail.width
            visible: root.panelShown > 0
            transform: Translate { x: Math.max(0, 1 - root.panelShown) * side.width }   // the curve's overshoot must not lift it off the edge
            maxWidth: root.panelDocked ? Math.max(320, surface.width - rail.width - 420) : surface.width - rail.width
            over: !root.panelDocked
            base: root.overlay
            // fed only while it shows: closed, it recomputed files and diffs on every switch and every follow
            changes: root.panelShown > 0 ? conv.changes : root.noChanges
            items: root.panelShown > 0 ? conv.items : []
            locked: conv.locked
            fresh: root.selected ? !!root.selected.fresh : true
            sessionId: root.selected ? (root.selected.id || "") : ""
            cwd: root.selected ? (root.selected.cwd || "") : ""
            onSendRequested: text => conv.send(text)
            host: host
            agentsInfo: root.agentsInfo
            canStop: root.canStop
            clock: root.clock
            onStopRequested: t => root.stopTask(t)
            onPictureRequested: p => mediaViewer.show(p)
            onShowRequested: root.panelOpen = true
            onCloseRequested: root.panelOpen = false
        }

        PrefsSheet {
            id: prefsSheet
            anchors.fill: parent
            accounts: accounts
            folder: root.selected?.cwd ?? ""
            folders: fm.targets
            ground: root.overlay
            railEdgeX: rail.width
            onSettingsRequested: anchor => accounts.openSettings(anchor)
            onClosed: if (cove.mode === "") conv.focusComposer()
        }

        // a session's verbs, a folder's "Open here" and verbs: a small menu anchored at the row
        RailMenu {
            id: cove
            anchors.fill: parent
            ground: root.overlay
            live: host.live
            caps: root.capsOf(cove.row)
            heldByTerminal: !!cove.row && !!cove.row.id && root.heldByTerminal(cove.row.id)
            presence: cove.row && cove.row.type === "folder" ? root.presenceIn(cove.row.fkey) : ({ windows: [], agents: [] })
            shellUp: fm.shellUp
            hostUp: host.connected
            workspace: Hyprland.focusedWorkspace?.id ?? -1   // the focused one: Praxis's, as a click in it opens the menu
            onAct: (verb, arg) => root.act(verb, arg, cove.vrow)
            onDismissed: rail.coveDismissed()
            onModeChanged: { if (cove.mode !== "") prefsSheet.close(); if (cove.mode === "folder") presence.refresh(); }
        }

        // closing the picture gives the keyboard back to the message box
        MediaViewer { id: mediaViewer; anchors.fill: parent; onClosed: conv.focusComposer() }
    }
}
