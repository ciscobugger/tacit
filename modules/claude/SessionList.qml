import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The sessions down the left: Pinned, Recent, then one heading per folder (FolderModel builds the
 * rows; claude.qml acts on them). Titles only; the mark at the left says working, waiting, open
 * in a process or past. Labels, row tones and radii are the shell's own (Files' "Now"/"Recent",
 * the code editor's selection).
 *
 * Rows are kept by key (ScriptModel), so a refresh updates them in place. A session row opens in
 * place after a dwell (its last reply and one fact line); the rail drives the menu (RailMenu, in
 * claude.qml's top layer, anchored at its row) and target mode (RailTargets, over the list).
 * Everything that changes data goes out through act(verb, arg, row).
 *
 * Folds like Files' rail: the toggle at the top leaves the New and Search glyphs and the live
 * marks; resting the pointer on the strip opens it over the conversation (it does not push it) as
 * a plain slab with a hairline, and it folds back when the pointer leaves. The toggle is
 * remembered by claude.qml.
 */
Item {
    id: rail

    property var rows: []
    property string currentId: ""
    property var counts: ({ waiting: 0, working: 0 })
    property var marks: []                  // [{id, state, title}]: the folded strip's live marks
    property var targetFolders: []          // FolderModel.targets, for target mode
    property var agents: ["claude"]         // the agents that have sessions: filter words
    property var provenance: null           // Provenance: a dropped file's origin line
    property Item cove: null                // RailMenu: opened and anchored by the rail; its `live` is host.live
    property bool shellUp: true
    property bool saveFailed: false
    property bool compact: false
    property color ground: "transparent"   // the window's tone, for the panel lying over the conversation
    readonly property string query: field.text
    property var filter: ({ needs: false, running: false, range: "", agents: [] })
    readonly property bool filtering: rail.filter.needs || rail.filter.running || rail.filter.range !== "" || rail.filter.agents.length > 0
    readonly property bool searchOpen: field.activeFocus || field.text.length > 0 || rail.filtering || words.activeFocus
    readonly property bool focused: list.activeFocus
    readonly property string targetPurpose: targets.purpose
    // the order holds while the pointer is in the rail, the menu or target mode is open, or a rename or drag runs
    readonly property bool frozen: panelHover.hovered || rail.menuOpen || targets.active
        || rail.renamingKey.length > 0 || rail.dragging

    signal chosen(var session)
    signal act(string verb, var arg, var row)
    signal renameAsked(var row)
    signal renameRequested(string key, string text)
    signal markClicked(var row)     // a heading's live mark
    signal typed(var event)         // a printable key in the rail: the composer takes it
    signal giveBack()               // the keyboard goes back to the composer
    signal toggle()

    property string renamingKey: ""
    property string renamingText: ""   // what is typed: the box is rebuilt if its row scrolls away and back
    property bool renameFresh: false
    property bool renameFocused: false
    function startRename(key, text) {
        rail.fold();
        rail.renamingText = text;
        rail.renameFresh = true;
        rail.renamingKey = key;
    }
    function commitRename() {
        const key = rail.renamingKey;
        rail.renamingKey = "";
        if (key.length) rail.renameRequested(key, rail.renamingText);
        list.forceActiveFocus();
    }
    // Only a real click away ends a rename: a rebuilt box takes the focus straight back.
    Timer { id: renameBlur; interval: 1; onTriggered: if (!rail.renameFocused) rail.renamingKey = "" }

    readonly property int fullWidth: 300
    readonly property int compactWidth: 60
    // expanded over the conversation while folded and hovered, or while it is used
    property bool dragHold: false      // something is dragged over the folded strip
    readonly property bool expanded: !rail.compact || hoverHold.hovering || field.activeFocus || rail.renamingKey.length > 0
        || rail.dragHold || targets.active || rail.menuOpen
    implicitWidth: rail.compact ? rail.compactWidth : rail.fullWidth
    Behavior on implicitWidth { Anim {} }
    z: 2

    // Files' rail: a beat before it opens under a passing pointer, a beat before it folds
    QtObject {
        id: hoverHold
        property bool hovering: false
        property bool armed: true     // false right after the toggle, until the pointer leaves
    }
    Timer { id: openTimer; interval: 160; onTriggered: hoverHold.hovering = true }
    Timer { id: closeTimer; interval: 260; onTriggered: hoverHold.hovering = false }

    function focusSearch() { field.forceActiveFocus(); field.selectAll(); }
    // a heading's count: the sessions (or, under Folders, the folders) until the next heading
    function countAfter(key) {
        const i = rail.indexOf(key);
        if (i < 0) return 0;
        const folders = key === "l:Folders";
        let n = 0;
        for (let j = i + 1; j < rail.rows.length; j++) {
            const r = rail.rows[j];
            if (r.type === "label") break;
            if (folders ? r.type === "folder" : (r.type === "session" || r.type === "hit") && !r.placeholder) n++;
        }
        return n;
    }
    // "Older folders", "Hidden", "Archived" close the list: the first of them sits apart
    function isFooter(r) { return !!r && r.type === "more" && ["older", "hidden", "archived"].includes(r.act); }
    function firstFooter(r) { return rail.isFooter(r) && !rail.isFooter(rail.rows[rail.indexOf(r.key) - 1]); }
    // a title as the rail shows it: a leading emoji (a ❌ in a prompt) is not part of its name here
    function shownTitle(t) {
        return String(t ?? "").replace(/^(?:[\u2190-\u2BFF\u2600-\u27BF\uFE0F\u200D\u20E3]|[\uD83C-\uD83E][\uDC00-\uDFFF])+\s*/, "") || String(t ?? "");
    }
    // a search hit's snippet: markdown marks out, the words searched for in sand
    function markedSnippet(t, q) {
        const esc = x => x.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        let out = esc(String(t ?? "").replace(/[`*#>_]{1,3}/g, ""));
        const w = String(q ?? "").trim();
        if (w.length < 2) return out;
        const re = new RegExp(esc(w).replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi");
        return out.replace(re, m => `<font color="${Appearance.colors.colPrimary}"><b>${m}</b></font>`);
    }
    function setQuery(q) { field.text = q; }
    function rowOf(key) { return rail.rows.find(r => r.key === key) ?? null; }
    function indexOf(key) { return rail.rows.findIndex(r => r.key === key); }
    function showIndex(i) { list.positionViewAtIndex(i, ListView.Contain); }
    function move(step) {
        const sessions = rail.rows.filter(r => (r.type === "session" || r.type === "hit") && !r.placeholder);
        if (sessions.length === 0) return;
        const at = sessions.findIndex(r => r.id === rail.currentId);
        const next = sessions[Math.max(0, Math.min(sessions.length - 1, at + step))];
        rail.chosen(next.session);
        list.positionViewAtIndex(rail.rows.indexOf(next), ListView.Contain);
    }
    // Ctrl+N's folder: the one under the rail's cursor while the rail has the keyboard
    function cursorFolder() {
        if (!list.activeFocus) return "";
        const r = rail.rowOf(rail.cursorKey);
        return r && (r.type === "folder" || r.type === "session" || r.type === "hit") ? r.fkey ?? "" : "";
    }

    // ── notices: a write the shell did not confirm, a delete or fork refused ──
    property string noticeText: ""
    function notice(text) { rail.noticeText = text; noticeTimer.restart(); }
    Timer { id: noticeTimer; interval: 6000; onTriggered: rail.noticeText = "" }
    // saveFailed stays set until a later write is confirmed: the line shows for the notice's 6 s
    onSaveFailedChanged: if (rail.saveFailed) rail.notice("Couldn't save: the shell isn't answering")
    readonly property string shownNotice: rail.noticeText

    // ── a row opened in place; the menu on ⋯, a right-click or the keyboard ──
    // After a dwell on a session row (the pointer's, or the keyboard's cursor) the row grows its
    // last reply and one fact line. It hands over to the next row only once that row's dwell ends;
    // the pointer resting as long where nothing opens folds it, and so does the pointer leaving the
    // list (the keyboard's: the list losing the keyboard). It holds while its menu shows.
    // A row folding above the pointer scrolls the list with it as far as the list can scroll, so
    // the row under the pointer stays still; what still moves under it (at the list's top) arms
    // no dwell until the pointer moves, and takes no click while it moves.
    property string openKey: ""        // the row grown in place
    property string openBy: ""         // pointer | keys
    property string dwellKey: ""
    property string dwellBy: ""
    property string hoverKey: ""
    property string coveKey: ""        // the menu's row
    property string coveFocus: ""      // where the keyboard goes when it closes: rail | window
    readonly property bool menuOpen: rail.cove !== null && rail.cove.mode !== ""
    function sessionRow(r) { return !!r && (r.type === "session" || r.type === "hit") && !r.placeholder; }
    function ask(p) {
        const i = p.input ?? {};
        if (p.tool === "AskUserQuestion") return (i.questions ?? [])[0]?.question ?? "a question";
        const target = i.file_path ? i.file_path.split("/").pop() : (i.command ?? i.url ?? i.pattern ?? i.query ?? "");
        return `${p.tool ?? ""} ${target}`.trim();
    }
    // the fact line: what it waits on, else what it changed (a repo) or made; null when nothing
    function factOf(r) {
        const s = r.session ?? {};
        const f = s.files ?? {};
        if (r.state === "waiting") {
            const p = (rail.cove?.live?.[r.id]?.pending ?? [])[0];
            return { needs: true, text: p ? `Needs you · ${rail.ask(p)}` : "Needs you" };
        }
        if ((f.n ?? 0) > 0)
            return s.repo === true ? { n: f.n, add: f.add ?? 0, del: f.del ?? 0 } : { text: `Made ${Voice.count(f.n, "file")}` };
        return null;
    }
    // the last reply as plain words: links keep their text, marks go
    function replyOf(r) { return (r.session?.lastReply ?? "").replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1").replace(/[`*#>]+/g, "").replace(/\s+/g, " ").trim(); }
    // the open session's row opens only from the keyboard: the conversation already shows it
    function openable(key, byKeys) {
        const r = rail.rowOf(key);
        if (!rail.sessionRow(r) || r.key === rail.renamingKey) return false;
        if (!byKeys && rail.currentId.length && r.id === rail.currentId) return false;
        return rail.replyOf(r).length > 0 || rail.factOf(r) !== null;
    }
    function armDwell(key, by) {
        dwell.stop();
        // a row opens from the keyboard only: growing under a passing pointer was annoying (owner 2026-10-09)
        if (by === "pointer") return;
        if (rail.menuOpen || targets.active || rail.dragging || key === rail.openKey) return;
        const can = rail.openable(key, by === "keys");
        if (!can && !(by === "pointer" && rail.openBy === "pointer")) return;
        rail.dwellKey = can ? key : "";   // "": the pointer's open row folds
        rail.dwellBy = by;
        dwell.restart();
    }
    function openNow(key, by) {
        dwell.stop();
        if (!rail.openable(key, by === "keys")) return;
        rail.setOpen(key, by, by === "pointer");
        if (by === "keys") revealOpen.restart();
    }
    function fold(steady) {
        dwell.stop();
        if (rail.menuOpen) return;
        rail.setOpen("", "", steady === true);
    }
    function setOpen(key, by, steady) {
        const was = rail.openKey;
        if (key !== was && listHover.hovered) {
            // rows at or above the pointer's change height: what is under it moves
            const h = rail.hoverKey.length ? rail.indexOf(rail.hoverKey) : rail.rows.length;
            const a = was.length ? rail.indexOf(was) : -1, b = key.length ? rail.indexOf(key) : -1;
            if ((a >= 0 && a <= h) || (b >= 0 && b < h)) {
                const p = listHover.point.scenePosition;
                rail.staleAt = Qt.point(p.x, p.y);
                settle.restart();
            }
            const it = steady && a >= 0 && a < h ? list.itemAtIndex(a) : null;
            const shrink = it ? it.height - it.base : 0;
            if (shrink > 0) {
                steadyScroll.from = list.contentY;
                steadyScroll.to = Math.max(list.originY - list.topMargin, list.contentY - shrink);
                steadyScroll.restart();
            }
        }
        rail.openKey = key;
        rail.openBy = by;
    }
    // ── folds in Tacit's motion: the rows a fold opens grow in on the spatial curve, the rows it
    // closes shrink away before they leave the list (the list's own transitions are off, below) ──
    property var leaving: ({})        // keys shrinking ahead of the fold that takes them out
    property var shownBefore: ({})    // the keys there when a fold opened: any other row grows in
    property real openedAt: 0
    Timer {
        id: leaveWait
        property var args: []
        interval: Appearance.animation.elementMoveExit.duration
        onTriggered: rail.act(args[0], args[1], args[2])
    }
    // what closing `row` takes away: a folder's rows (its waiting and working sessions stay), the
    // sessions past the first four for Show fewer, the folders under Older or Hidden
    function closingKeys(row) {
        const rows = rail.rows, out = {};
        const at = rows.findIndex(r => r.key === row.key);
        if (at < 0) return out;
        const needy = r => r.type === "session" && (r.state === "waiting" || r.state === "working");
        if (row.type === "folder" && !row.collapsed) {
            const k = row.fkey;
            for (let j = at + 1; j < rows.length; j++) {
                const r = rows[j];
                if (r.type === "folder" || r.type === "label" || r.type === "pause" || (r.type === "more" && !r.key.endsWith(":" + k))) break;
                if (!needy(r)) out[r.key] = true;
            }
        } else if (row.type === "more" && row.key.startsWith("m:less:")) {
            let i = 0;
            const head = rows.findIndex(r => r.key === "f:" + row.key.substring(7));
            for (let j = head + 1; j < at; j++) {
                const r = rows[j];
                if (r.type !== "session" && r.type !== "undo") continue;
                if (i++ >= 4 && !needy(r)) out[r.key] = true;
            }
        } else if ((row.key === "m:older" || row.key === "m:hidden") && row.open) {
            for (let j = at + 1; j < rows.length; j++) {
                const r = rows[j];
                if (r.type === "label" || r.key === "m:hidden") break;
                out[r.key] = true;
            }
        }
        return out;
    }
    function toggleRows(verb, arg, row) {
        if (leaveWait.running) return;
        const going = rail.closingKeys(row);
        if (Object.keys(going).length) {
            rail.leaving = going;
            leaveWait.args = [verb, arg, row];
            leaveWait.restart();
            return;
        }
        const was = {};
        for (const r of rail.rows) was[r.key] = true;
        rail.shownBefore = was;
        rail.openedAt = Date.now();
        rail.act(verb, arg, row);
    }
    // a row the last fold brought in; Show more and Show fewer swap one line for the other in place
    function grows(key) {
        if (Date.now() - rail.openedAt > 400 || rail.shownBefore[key]) return false;
        const m = /^m:(more|less):(.*)$/.exec(key);
        return !(m && (rail.shownBefore["m:more:" + m[2]] || rail.shownBefore["m:less:" + m[2]]));
    }
    function hoverRow(key, on) {
        if (on) rail.hoverKey = key;
        else if (rail.hoverKey === key) rail.hoverKey = "";
        if (settle.running) rail.hoverStale = true;
        // a pointer passing off the rows leaves the keyboard's dwell alone
        if (rail.hoverStale || (!rail.hoverKey.length && dwell.running && rail.dwellBy === "keys")) return;
        rail.armDwell(rail.hoverKey, "pointer");
    }
    // the dwell: new, for the owner to tune on the device
    Timer {
        id: dwell
        interval: 450
        onTriggered: {
            if (rail.dwellKey === "") {
                if (rail.openBy === "pointer" && rail.hoverKey !== rail.openKey) rail.fold(true);
                return;
            }
            const still = rail.dwellBy === "keys" ? list.activeFocus && rail.cursorKey === rail.dwellKey : rail.hoverKey === rail.dwellKey;
            if (still && !rail.menuOpen && !rail.dragging && !targets.active) rail.openNow(rail.dwellKey, rail.dwellBy);
        }
    }
    // the rows' motion under the pointer (FastSpatial, 350 ms); staleAt: where the pointer was as it began
    property bool hoverStale: false    // the hovered row changed under a still pointer
    property point staleAt
    Timer { id: settle; interval: 360; onTriggered: rail.pointerMoved() }
    NumberAnimation { id: steadyScroll; target: list; property: "contentY"; duration: 260; easing.type: Easing.OutCubic }
    function stillPointer() {
        const p = listHover.point.scenePosition;
        return p.x === rail.staleAt.x && p.y === rail.staleAt.y;
    }
    function shifting() { return settle.running && rail.stillPointer(); }
    function pointerMoved() {
        if (!rail.hoverStale || settle.running || rail.stillPointer()) return;
        rail.hoverStale = false;
        rail.armDwell(rail.hoverKey, "pointer");
    }
    // opened from the keyboard: its new lines are scrolled into view once grown
    Timer { id: revealOpen; interval: 360; onTriggered: { const i = rail.indexOf(rail.openKey); if (i >= 0) list.positionViewAtIndex(i, ListView.Contain); } }

    // the row's rect in the menu's frame, inside the row's fill; the New row when it is not laid out
    function anchorOf(key) {
        const i = rail.indexOf(key);
        const it = (i >= 0 ? list.itemAtIndex(i) : null) ?? newRow;
        const p = it.mapToItem(rail.cove, 8, 0);
        return Qt.rect(p.x, p.y, it.width - 16, it.height);
    }
    // `row` stands in when the session has no row (folded away): the menu then opens at the New row.
    // "peek" (the IPC's) opens the row in place.
    function openCove(key, mode, keyboard, row, from) {
        if (mode === "peek") { rail.openNow(key, "keys"); return; }
        if (!rail.cove || targets.active) return;
        const r = rail.rowOf(key) ?? row ?? null;
        if (!r) return;
        dwell.stop();
        rail.coveKey = r.key;
        rail.coveFocus = from ?? "rail";
        const i = rail.indexOf(r.key);
        if (i >= 0) list.positionViewAtIndex(i, ListView.Contain);
        rail.cove.row = r;
        rail.cove.anchor = rail.anchorOf(r.key);
        rail.cove.openFor(keyboard);
    }
    function coveDismissed() {
        const f = rail.coveFocus;
        rail.coveFocus = "";
        if (f === "rail") list.forceActiveFocus();
        else if (f === "window") rail.giveBack();
        if (rail.openBy === "pointer" ? !listHover.hovered : !list.activeFocus) rail.fold();
        else if (rail.openBy === "pointer" && !rail.hoverStale) rail.armDwell(rail.hoverKey, "pointer");
    }
    // while open it follows its row through rebuilds and scrolls, and closes once the row is
    // scrolled out of the list; a row that went keeps what it shows
    function followCove() {
        if (!rail.menuOpen) return;
        const r = rail.rowOf(rail.coveKey);
        if (!r) return;
        if (rail.cove.row !== r) rail.cove.row = r;
        const a = rail.anchorOf(r.key);
        const top = list.mapToItem(rail.cove, 0, 0).y;
        if (a.y + a.height < top || a.y > top + list.height) { rail.cove.close(); return; }
        rail.cove.anchor = a;
    }
    onRowsChanged: {
        if (rail.menuOpen) Qt.callLater(rail.followCove);
        if (!leaveWait.running) rail.leaving = ({});
    }

    // ── target mode: what is carried over the rail turns it into its folders ──
    property string carryPurpose: ""
    property var carryPayload: null    // drop: {paths, page}; move: {id}
    property bool dragging: false      // a row or heading is being dragged
    function startTargets(purpose, carrying, payload, keyboard) {
        if (rail.cove) rail.cove.close();
        rail.fold();
        if (rail.renamingKey.length) rail.renamingKey = "";
        rail.carryPurpose = purpose;
        rail.carryPayload = payload ?? ({});
        targets.carrying = carrying ?? ({});
        targets.purpose = purpose;
        if (keyboard) targets.forceActiveFocus();
    }
    function endTargets() {
        const had = targets.activeFocus;
        targets.purpose = "";
        rail.carryPurpose = "";
        dropLeave.restart();
        if (had) rail.giveBack();
    }
    function beginDrag(purpose, r) {
        rail.dragging = true;
        if (purpose === "move") rail.startTargets("move", { label: r.title }, { id: r.id }, false);
        else rail.startTargets("reorder", { label: r.name, path: r.path, isFolder: true }, {}, false);
    }
    // a drag inside the rail: the pointer in `item`'s frame; leaving the rail cancels
    function dragTo(item, x, y) {
        if (!targets.active) return;
        const p = item.mapToItem(targets, x, y);
        if (p.x < 0 || p.x > panel.width) {
            targets.cancel();
            return;
        }
        targets.pointAt(p.y);
        targets.edgeScroll(p.y);
    }
    function endDrag() {
        rail.dragging = false;
        if (targets.active) targets.commit();
    }

    // an external drop: files (text/uri-list) or an Opsis page; "" when it carries neither
    function localPath(u) {
        if (!u.startsWith("file://")) return "";
        const raw = u.slice(7);
        try { return decodeURIComponent(raw); } catch (e) { return raw; }   // a literal % is not an escape
    }
    function dropPayload(d) {
        if ((d.formats ?? []).includes("application/x-tacit-page")) {
            try {
                const p = JSON.parse(d.getDataAsString("application/x-tacit-page"));
                if (p && p.url) return { paths: [], page: { title: p.title ?? "", url: p.url } };
            } catch (e) {}
        }
        const paths = (d.urls ?? []).map(u => rail.localPath(u.toString())).filter(p => p.startsWith("/"));
        return paths.length ? { paths: paths, page: null } : null;
    }
    function dropCarrying(p) {
        if (p.page) {
            const host = /^[a-z]+:\/\/([^/?#]+)/i.exec(p.page.url)?.[1] ?? "";
            return { label: p.page.title || host, lines: [Voice.facts(["from Thyris", host])], isFolder: false, path: "" };
        }
        const name = x => x.split("/").filter(s => s.length).pop() ?? x;
        return { label: p.paths.length === 1 ? name(p.paths[0]) : `${p.paths.length} files`,
                 lines: rail.provenance ? rail.provenance.lines(p.paths) : [], isFolder: false,
                 path: p.paths.length === 1 ? p.paths[0] : "" };
    }
    // the same path as a real drop, for the IPC and tests
    function dropStart(payload) {
        rail.startTargets("drop", rail.dropCarrying(payload), payload, false);
        if (payload.paths.length === 1) {
            dirCheck.path = payload.paths[0];
            dirCheck.running = false;
            dirCheck.running = true;
        }
    }
    // one directory dragged in: the Add slot shows once it is known to be one
    Process {
        id: dirCheck
        property string path: ""
        command: ["test", "-d", dirCheck.path]
        onExited: code => {
            if (code === 0 && targets.purpose === "drop" && (targets.carrying?.path ?? "") === dirCheck.path)
                targets.carrying = Object.assign({}, targets.carrying, { isFolder: true });
        }
    }
    Timer { id: dropLeave; interval: 260; onTriggered: if (!targets.active) rail.dragHold = false }

    // ── filters: words under the search field ──────────────────────────────
    readonly property var agentNames: ({ claude: "Claude", codex: "Codex", pi: "pi", opencode: "opencode" })
    readonly property var wordList: [{ key: "needs", label: "Needs you", line: 0 }, { key: "running", label: "Running", line: 0 },
        { key: "today", label: "Today", line: 0 }, { key: "week", label: "This week", line: 0 }]
        .concat(rail.agents.map(a => ({ key: "agent:" + a, label: rail.agentNames[a] ?? a, line: 1 })))
    function wordOn(key) {
        const f = rail.filter;
        if (key === "needs") return f.needs;
        if (key === "running") return f.running;
        if (key === "today" || key === "week") return f.range === key;
        return f.agents.includes(key.slice(6));
    }
    // Needs you OR Running; Today and This week replace each other; agents OR; the lines AND
    function toggleWord(key) {
        const f = Object.assign({}, rail.filter);
        if (key === "needs") f.needs = !f.needs;
        else if (key === "running") f.running = !f.running;
        else if (key === "today" || key === "week") f.range = f.range === key ? "" : key;
        else {
            const a = key.slice(6);
            f.agents = f.agents.includes(a) ? f.agents.filter(x => x !== a) : f.agents.concat([a]);
        }
        rail.filter = f;
    }
    function clearFilter() { rail.filter = { needs: false, running: false, range: "", agents: [] }; }
    // the live line's parts: the one session, or search with that filter on
    function liveClicked(state) {
        const n = state === "waiting" ? rail.counts.waiting : rail.counts.working;
        const m = rail.marks.filter(x => x.state === state);
        if (n === 1 && m.length === 1) {
            rail.act("select", m[0].id, null);
            return;
        }
        rail.filter = { needs: state === "waiting", running: state === "working", range: "", agents: [] };
        field.forceActiveFocus();
    }
    function escapeSearch() {
        if (field.text.length) field.text = "";
        else if (rail.filtering) rail.clearFilter();
        else list.forceActiveFocus();
    }

    // ── the keyboard, with the rail focused ────────────────────────────────
    property string cursorKey: ""
    function navigable(r) {
        return r.type === "session" || r.type === "hit" || r.type === "folder" || r.type === "more" || r.type === "undo" || r.key === "l:Folders";
    }
    function stepCursor(n) {
        const rows = rail.rows;
        let i = rail.indexOf(rail.cursorKey);
        if (i < 0) i = rows.findIndex(r => (r.type === "session" || r.type === "hit") && r.id === rail.currentId);
        if (i < 0) i = n > 0 ? -1 : rows.length;
        let to = -1;
        for (let j = i + n; j >= 0 && j < rows.length; j += n)
            if (rail.navigable(rows[j])) { to = j; break; }
        if (to < 0) return;
        const r = rows[to];
        if (rail.openBy === "keys") rail.fold();
        rail.cursorKey = r.key;
        list.positionViewAtIndex(to, ListView.Contain);
        if ((r.type === "session" || r.type === "hit") && !r.placeholder) {
            // opening a session hands the composer the keyboard (Conversation's closeFind): the rail keeps it
            rail.chosen(r.session);
            list.forceActiveFocus();
            rail.armDwell(r.key, "keys");
        }
    }
    function key(e) {
        const r = rail.rowOf(rail.cursorKey) ?? rail.rows.find(x => (x.type === "session" || x.type === "hit") && x.id === rail.currentId) ?? null;
        const mods = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier);
        const k = e.key;
        const session = !!r && (r.type === "session" || r.type === "hit") && !r.placeholder;
        e.accepted = true;
        if (mods === (Qt.AltModifier | Qt.ShiftModifier) && (k === Qt.Key_Up || k === Qt.Key_Down)) {
            if (r && r.type === "folder" && r.pinned) rail.act("shift", k === Qt.Key_Up ? -1 : 1, r);
        } else if (mods === Qt.ControlModifier && k === Qt.Key_Z) {
            rail.act("undo", "", null);
        } else if ((mods === Qt.ShiftModifier && k === Qt.Key_F10) || k === Qt.Key_Menu) {
            if (r && (session || r.type === "folder")) rail.openCove(r.key, "verbs", true, null, "rail");
        } else if (mods === 0 && (k === Qt.Key_Up || k === Qt.Key_Down)) {
            rail.stepCursor(k === Qt.Key_Up ? -1 : 1);
        } else if (mods === 0 && (k === Qt.Key_Left || k === Qt.Key_Right)) {
            if (r && r.type === "folder" && (k === Qt.Key_Left) !== r.collapsed) rail.toggleRows("fold", r.fkey, r);
        } else if (mods === 0 && (k === Qt.Key_Return || k === Qt.Key_Enter)) {
            if (!r || session) rail.typed(e);
            else if (r.type === "folder") rail.toggleRows("fold", r.fkey, r);
            else if (r.type === "more") rail.toggleRows("more", r.act, r);
            else if (r.type === "undo") rail.act("undo", r.id, r);
            else if (r.key === "l:Folders" && rail.shellUp) rail.act("pickFolder", "", r);
        } else if (mods === 0 && k === Qt.Key_Space) {
            // the cursor's row opens or folds at once, the open session included (↑↓ opens it)
            if (session) {
                if (rail.openKey === r.key) rail.fold();
                else rail.openNow(r.key, "keys");
            }
        } else if (mods === 0 && k === Qt.Key_F2) {
            if (r && (session || r.type === "folder")) rail.renameAsked(r);
        } else if (mods === 0 && k === Qt.Key_Delete) {
            if (session) rail.act("delete", r.id, r);
            else if (r && r.type === "folder" && !r.hidden) rail.act("hide", r.fkey, r);
        } else if (mods === 0 && k === Qt.Key_Escape) {
            rail.fold();
        } else {
            e.accepted = false;
            rail.typed(e);
        }
    }

    // The panel: as wide as the rail, or over the conversation while expanded from folded.
    // Its content keeps the full width and is clipped, so rows never re-wrap as it moves.
    Rectangle {
        id: panel
        width: rail.expanded ? rail.fullWidth : rail.compactWidth
        height: parent.height
        // over the conversation it is a plain slab on the window's look, solid, with a hairline
        // where it meets the conversation (as the side panel over it)
        color: "transparent"
        Rectangle {
            anchors.fill: parent
            visible: rail.compact && rail.expanded
            color: rail.ground
            Rectangle {
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: 1
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            }
        }
        Behavior on width { Anim {} }
        clip: true
        HoverHandler {
            id: panelHover
            onHoveredChanged: {
                if (hovered) {
                    closeTimer.stop();
                    if (rail.compact && hoverHold.armed)
                        openTimer.restart();
                } else {
                    hoverHold.armed = true;
                    openTimer.stop();
                    closeTimer.restart();
                }
            }
        }

        // One drop area for the rail and the folded strip: hover does not fire during a drag, so a
        // drag entering the strip opens the sheet at once; it closes 260 ms after the drag leaves.
        DropArea {
            id: dropArea
            anchors.fill: parent
            keys: ["text/uri-list", "application/x-tacit-page"]
            function point(x, y) {
                const p = dropArea.mapToItem(targets, x, y);
                targets.pointAt(p.y);
                targets.edgeScroll(p.y);
            }
            onEntered: d => {
                const payload = rail.dropPayload(d);
                if (!payload || targets.active) {
                    d.accepted = false;
                    return;
                }
                d.accept(Qt.CopyAction);
                dropLeave.stop();
                rail.dragHold = true;
                rail.dropStart(payload);
                dropArea.point(d.x, d.y);
            }
            onPositionChanged: d => {
                if (targets.purpose === "drop") dropArea.point(d.x, d.y);
            }
            onExited: {
                if (targets.purpose === "drop") targets.cancel();
                dropLeave.restart();
            }
            onDropped: d => {
                if (targets.purpose !== "drop") return;
                dropArea.point(d.x, d.y);
                d.accept(Qt.CopyAction);
                targets.commit();
            }
        }

        Item {
            id: content
            width: rail.fullWidth
            height: parent.height

            // the toggle, in line with the conversation's header
            RippleButton {
                id: toggleButton
                anchors { top: parent.top; topMargin: 10; left: parent.left; leftMargin: 14 }
                implicitWidth: 32
                implicitHeight: 32
                padding: 0
                buttonRadius: Appearance.rounding.full
                releaseAction: () => {
                    hoverHold.armed = false;
                    openTimer.stop();
                    hoverHold.hovering = false;
                    rail.toggle();
                }
                contentItem: MaterialSymbol {
                    text: rail.compact ? "left_panel_open" : "left_panel_close"
                    iconSize: 20
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    color: Appearance.colors.colInkSecondary
                }
                StyledToolTip { text: rail.compact ? "Show the sessions" : "Fold the sessions" }
            }
            MaterialSymbol {
                anchors { right: parent.right; rightMargin: 22; verticalCenter: toggleButton.verticalCenter }
                visible: rail.expanded && !rail.searchOpen && !targets.active
                text: "search"
                iconSize: 19
                color: searchArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                MouseArea { id: searchArea; anchors { fill: parent; margins: -6 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rail.focusSearch() }
                StyledToolTip { text: "Search every session (Ctrl+P)"; extraVisibleCondition: searchArea.containsMouse }
            }

            // everything under the toggle gives way to target mode; never hidden, because a row being
            // dragged keeps the pointer only while it is visible
            Item {
                id: body
                anchors.fill: parent
                opacity: 1 - targets.shown

                // "New session", first thing in the sidebar as in OpenChamber
                Item {
                    id: newRow
                    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 48 }
                    height: 36
                    // a button, as the side panel's Back: a soft fill that is there at rest
                    Rectangle {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        radius: 8
                        color: rail.expanded ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, newArea.pressed ? 0.86 : newArea.containsMouse ? 0.9 : 0.94)
                             : newArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    MaterialSymbol {
                        id: newGlyph
                        anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
                        text: "edit_square"
                        iconSize: 17
                        color: Appearance.colors.colInkMain
                    }
                    StyledText {
                        anchors { left: parent.left; leftMargin: 44; verticalCenter: parent.verticalCenter }
                        text: "New session"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        color: Appearance.colors.colInkMain
                        opacity: rail.expanded ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 140 } }
                    }
                    StyledText {
                        anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
                        text: "Ctrl N"
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 13
                        color: Appearance.colors.colInkMeta
                        opacity: rail.expanded ? 1 : 0
                    }
                    MouseArea { id: newArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rail.act("new", "", null) }
                }

                // what is live, in the notch's words; a part opens its one session or the filter
                Item {
                    id: liveLine
                    readonly property bool on: rail.expanded && rail.counts.waiting + rail.counts.working > 0
                    anchors { left: parent.left; right: parent.right; top: newRow.bottom }
                    height: liveLine.on ? 34 : 0
                    Behavior on height { NumberAnimation { duration: 140 } }
                    clip: true
                    Rectangle {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12; topMargin: 2; bottomMargin: 2 }
                        radius: 8
                        color: liveHover.hovered ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
                    }
                    HoverHandler { id: liveHover }
                    StyledToolTip { text: "Show the sessions that need you or are running"; extraVisibleCondition: liveHover.hovered }
                    LiveDot {
                        x: 24
                        anchors.verticalCenter: parent.verticalCenter
                        breathing: rail.counts.waiting === 0
                    }
                    Row {
                        x: 44
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText {
                            visible: rail.counts.waiting > 0
                            text: `${rail.counts.waiting} need${rail.counts.waiting === 1 ? "s" : ""} you`
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 14
                            font.weight: Font.Medium
                            color: Appearance.colors.colPrimary
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: rail.liveClicked("waiting") }
                        }
                        StyledText {
                            visible: rail.counts.waiting > 0 && rail.counts.working > 0
                            text: " · "
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 14
                            color: Appearance.colors.colInkSecondary
                        }
                        StyledText {
                            visible: rail.counts.working > 0
                            text: `${rail.counts.working} running`
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 14
                            color: Appearance.colors.colInkSecondary
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: rail.liveClicked("working") }
                        }
                    }
                }

                Item {
                    id: noticeLine
                    anchors { left: parent.left; right: parent.right; top: liveLine.bottom }
                    height: rail.expanded && rail.shownNotice.length ? noticeText.implicitHeight + 8 : 0
                    clip: true
                    StyledText {
                        id: noticeText
                        x: 20
                        y: 4
                        width: parent.width - 40
                        text: rail.shownNotice
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 13
                        color: Appearance.colors.colInkSecondary
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    id: fieldBox
                    anchors { left: parent.left; top: noticeLine.bottom; margins: 12; topMargin: 6 }
                    // folded, a square around the glyph
                    width: rail.expanded ? parent.width - 24 : 36
                    Behavior on width { Anim {} }
                    height: !rail.expanded || rail.searchOpen ? 36 : 0
                    visible: height > 0
                    clip: true
                    radius: Appearance.rounding.small
                    color: rail.expanded || foldedSearch.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                    MaterialSymbol {
                        id: fieldGlyph
                        anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                        text: "search"
                        iconSize: 18
                        color: Appearance.colors.colInkSecondary
                    }
                    StyledTextInput {
                        id: field
                        anchors { left: fieldGlyph.right; leftMargin: 8; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        font.pixelSize: 15
                        color: Appearance.colors.colInkMain
                        clip: true
                        Keys.onDownPressed: rail.move(1)
                        Keys.onUpPressed: rail.move(-1)
                        Keys.onTabPressed: { words.cursor = 0; words.forceActiveFocus(); }
                        Keys.onEscapePressed: rail.escapeSearch()
                    }
                    StyledText {
                        anchors { left: fieldGlyph.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                        visible: field.text.length === 0
                        text: "Search every session"
                        font.pixelSize: 15
                        color: Appearance.colors.colInkSecondary
                        opacity: rail.expanded ? 1 : 0
                    }
                    // folded: the glyph opens the search
                    MouseArea {
                        id: foldedSearch
                        anchors.fill: parent
                        visible: !rail.expanded
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: rail.focusSearch()
                    }
                }

                // the filter words, by PanelTabs' rule: on in full tone and weight, quiet otherwise, no frames.
                // Tab walks them from the field, Space toggles one.
                Item {
                    id: words
                    property int cursor: -1
                    readonly property bool on: rail.expanded && rail.searchOpen
                    anchors { left: parent.left; right: parent.right; top: fieldBox.bottom; topMargin: 2 }
                    height: words.on ? wordFlow.implicitHeight + 10 : 0
                    visible: height > 0
                    clip: true
                    onActiveFocusChanged: if (!activeFocus) words.cursor = -1
                    Keys.onPressed: e => {
                        const n = rail.wordList.length;
                        e.accepted = true;
                        if (e.key === Qt.Key_Tab || e.key === Qt.Key_Right) words.cursor = Math.min(n - 1, words.cursor + 1);
                        else if (e.key === Qt.Key_Backtab || e.key === Qt.Key_Left) {
                            if (words.cursor <= 0) field.forceActiveFocus();
                            else words.cursor--;
                        } else if (e.key === Qt.Key_Space) {
                            if (words.cursor >= 0) rail.toggleWord(rail.wordList[words.cursor].key);
                        } else if (e.key === Qt.Key_Escape) rail.escapeSearch();
                        else if (e.key === Qt.Key_Down || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) list.forceActiveFocus();
                        else e.accepted = false;
                    }
                    Flow {
                        id: wordFlow
                        x: 12
                        y: 4
                        width: parent.width - 24
                        spacing: 6
                        Repeater {
                            model: rail.wordList
                            delegate: Rectangle {
                                id: word
                                required property var modelData
                                readonly property bool on: rail.wordOn(word.modelData.key)
                                readonly property bool chosen: words.activeFocus && words.cursor >= 0 && rail.wordList[words.cursor]?.key === word.modelData.key
                                width: wordText.implicitWidth + 22
                                height: 26
                                radius: 13
                                color: word.on ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
                                     : wordArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                                border.width: word.on ? 0 : 1
                                border.color: word.chosen ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.86)
                                Behavior on color { ColorAnimation { duration: 80 } }
                                StyledText {
                                    id: wordText
                                    anchors.centerIn: parent
                                    text: word.modelData.label
                                    font.family: Appearance.font.family.compact
                                    font.pixelSize: 13
                                    font.weight: word.on ? Font.Medium : Font.Normal
                                    color: word.on || wordArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                                }
                                MouseArea { id: wordArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rail.toggleWord(word.modelData.key) }
                            }
                        }
                    }
                }

                // folded: one mark per live session, waiting first
                Column {
                    anchors { left: parent.left; top: fieldBox.bottom; topMargin: 6 }
                    width: rail.compactWidth
                    opacity: rail.expanded ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    Repeater {
                        model: rail.marks
                        delegate: Item {
                            id: mark
                            required property var modelData
                            width: rail.compactWidth
                            height: 36
                            Rectangle {
                                anchors.centerIn: parent
                                width: 36
                                height: 32
                                radius: 8
                                color: markArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                            }
                            LiveDot {
                                visible: mark.modelData.state === "waiting" || mark.modelData.state === "working"
                                anchors.centerIn: parent
                                breathing: mark.modelData.state === "working"
                            }
                            MouseArea { id: markArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rail.act("select", mark.modelData.id, null) }
                            StyledToolTip { text: mark.modelData.title; extraVisibleCondition: markArea.containsMouse }
                        }
                    }
                }

                StyledListView {
                    id: list
                    anchors { left: parent.left; right: parent.right; top: words.bottom; topMargin: 4; bottom: parent.bottom; bottomMargin: 8 }
                    clip: true
                    opacity: rail.expanded ? 1 : 0
                    enabled: rail.expanded
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    // kept by key: a refresh updates rows in place instead of rebuilding them
                    model: ScriptModel { values: rail.rows; objectProp: "key" }
                    spacing: 0
                    animateAppearance: false
                    popin: false
                    keyNavigationEnabled: false
                    // rows come and go in place: StyledListView's transitions have no animations here, and
                    // with them a removed row stayed drawn under the row that took its place
                    add: null
                    remove: null
                    addDisplaced: null
                    displaced: null
                    move: null
                    moveDisplaced: null
                    FastWheel { view: list }
                    Keys.onPressed: e => rail.key(e)
                    onActiveFocusChanged: if (!activeFocus && rail.openBy === "keys") rail.fold()
                    HoverHandler {
                        id: listHover
                        onHoveredChanged: if (!listHover.hovered) { rail.hoverStale = false; if (rail.openBy === "pointer") rail.fold(); }
                        onPointChanged: if (rail.hoverStale) rail.pointerMoved()
                    }
                    // the menu follows its row
                    onContentYChanged: rail.followCove()

                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        // ScriptModel leaves a moved row's modelData as it was: the row at this index is
                        // read instead while its key matches
                        readonly property var d: {
                            const r = rail.rows[row.index];
                            return r && r.key === row.modelData.key ? r : row.modelData;
                        }
                        readonly property string type: row.d.type
                        readonly property bool isSession: row.type === "session" || row.type === "hit"
                        readonly property bool current: row.isSession && (row.d.placeholder === true || (rail.currentId.length > 0 && row.d.id === rail.currentId))
                        readonly property bool hovered: hov.hovered
                        readonly property bool cursor: list.activeFocus && rail.cursorKey === row.d.key && !row.isSession
                        readonly property bool renaming: rail.renamingKey.length > 0 && rail.renamingKey === row.d.key
                        readonly property bool arrived: row.d.arrived === true
                        readonly property bool keyFocus: list.activeFocus && rail.cursorKey === row.d.key
                        readonly property bool held: rail.menuOpen && rail.coveKey === row.d.key   // its menu shows
                        // opening in place, as a tool line opens: height, clip and fade on one value
                        // in on Tacit's fast spatial curve, out on its quick effects curve
                        property real progress: rail.openKey === row.d.key ? 1 : 0
                        Behavior on progress { Anim { type: rail.openKey === row.d.key ? Anim.FastSpatial : Anim.FastEffects } }
                        readonly property real base: row.type === "more" && rail.firstFooter(row.d) ? 50
                            : ({ label: 46, folder: 40, session: 32, hit: 56, more: 32, undo: 32, pause: 14 })[row.type]
                            ?? (part.item ? part.item.implicitHeight : 32)
                        // in and out with a fold: in on Tacit's spatial curve, out on its exit curve. The
                        // model fills rows in place, so a row is new when its key changes, not when made
                        readonly property string rowKey: row.d.key ?? ""
                        readonly property bool going: rail.leaving[row.rowKey] === true
                        property real grow: 1
                        property real stay: 1
                        Anim { id: growIn; target: row; property: "grow"; from: 0; to: 1; type: Anim.DefaultSpatial }
                        NumberAnimation {
                            id: shrink
                            target: row; property: "stay"; to: 0
                            duration: Appearance.animation.elementMoveExit.duration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.animationCurves.emphasizedAccel
                        }
                        onGoingChanged: {
                            if (row.going) { shrink.restart(); return; }
                            shrink.stop();
                            row.stay = 1;
                        }
                        onRowKeyChanged: {
                            shrink.stop();
                            row.stay = 1;
                            growIn.stop();
                            row.grow = 1;
                            if (rail.grows(row.rowKey)) growIn.start();
                        }
                        readonly property real fold: Math.max(0, row.grow) * Math.max(0, row.stay)
                        opacity: Math.min(1, row.fold)
                        clip: row.fold < 1 || (row.progress > 0 && row.progress < 1)
                        width: ListView.view.width
                        height: (row.base + (part.item?.grownH ?? 0) * row.progress) * row.fold
                        onYChanged: if (row.held) rail.followCove()
                        onHeightChanged: if (row.held) rail.followCove()

                        HoverHandler { id: hov; onHoveredChanged: rail.hoverRow(row.d.key, hov.hovered) }

                        Rectangle {
                            visible: row.isSession || row.cursor || row.type === "more"
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8; topMargin: row.type === "more" && rail.firstFooter(row.d) ? 19 : 1; bottomMargin: 1 }
                            radius: 8
                            color: row.current ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
                                : row.cursor ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)
                                : (row.isSession || row.type === "more") && (row.hovered || row.held) && !rail.dragging ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
                            Behavior on color { ColorAnimation { duration: 80 } }
                        }
                        // the session you are in: a sand bar at the row's edge, as the panel's tab line
                        Rectangle {
                            visible: row.current
                            x: 8
                            y: 8
                            width: 3
                            height: 16
                            radius: 1.5
                            color: Appearance.colors.colPrimary
                        }
                        // a session from elsewhere (the notch, a fork, another client): sand, fading to clear
                        Rectangle {
                            id: arrivalWash
                            visible: row.isSession
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8; topMargin: 1; bottomMargin: 1 }
                            radius: 8
                            color: "transparent"
                            ColorAnimation on color {
                                id: washOut
                                running: false
                                from: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.84)
                                to: ColorUtils.transparentize(Appearance.colors.colPrimary, 1)
                                duration: 1200
                                easing.type: Easing.OutCubic
                            }
                        }
                        onArrivedChanged: if (row.arrived) washOut.restart()
                        Component.onCompleted: {
                            if (row.arrived) washOut.restart();
                            if (rail.grows(row.rowKey)) growIn.start();
                        }

                        MouseArea {
                            id: area
                            property point at
                            property bool dragged: false
                            anchors.fill: parent
                            enabled: row.isSession || row.type === "folder" || row.type === "more"
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            preventStealing: true   // a drag here is a move or a reorder, not a flick
                            cursorShape: row.type === "more" || row.type === "folder" ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onPressed: m => {
                                area.at = Qt.point(m.x, m.y);
                                area.dragged = false;
                                dwell.stop();
                            }
                            onPositionChanged: m => {
                                if (!area.pressed || !(m.buttons & Qt.LeftButton)) return;
                                if (!area.dragged) {
                                    const far = Math.hypot(m.x - area.at.x, m.y - area.at.y);
                                    if (row.type === "session" && !row.d.placeholder && far >= 8) rail.beginDrag("move", row.d);
                                    else if (row.type === "folder" && row.d.canPin && far >= 6) rail.beginDrag("reorder", row.d);
                                    else return;
                                    area.dragged = true;
                                }
                                rail.dragTo(area, m.x, m.y);
                            }
                            onReleased: if (area.dragged) rail.endDrag()
                            onCanceled: if (area.dragged) { rail.dragging = false; targets.cancel(); }
                            onClicked: m => {
                                if (area.dragged || rail.shifting()) return;
                                if (!rail.compact) list.forceActiveFocus();
                                rail.cursorKey = row.d.key;
                                if (m.button === Qt.RightButton) {
                                    if ((row.isSession && !row.d.placeholder) || row.type === "folder") rail.openCove(row.d.key, "verbs", false, null, "rail");
                                    return;
                                }
                                rail.fold();
                                if (row.type === "folder") rail.toggleRows("fold", row.d.fkey, row.d);
                                else if (row.type === "more") rail.toggleRows("more", row.d.act, row.d);
                                else if (!row.d.placeholder) rail.chosen(row.d.session);
                            }
                            onDoubleClicked: m => {
                                if (m.button === Qt.LeftButton && row.isSession && !row.d.placeholder) rail.renameAsked(row.d);
                            }
                        }

                        Loader {
                            id: part
                            readonly property Item rowItem: row
                            anchors.fill: parent
                            sourceComponent: row.isSession ? sessionPart : row.type === "folder" ? folderPart : row.type === "label" ? labelPart
                                : row.type === "more" ? morePart : row.type === "undo" ? undoPart : row.type === "note" ? notePart : null
                        }

                        // the rename box, for a session or a heading
                        Loader {
                            readonly property string key: row.d.key
                            active: row.renaming
                            anchors { left: parent.left; leftMargin: row.type === "folder" ? 12 : 38; right: parent.right; rightMargin: 14 }
                            y: row.type === "hit" ? 4 : (row.base - 26) / 2
                            height: 26
                            sourceComponent: renameBox
                        }
                    }
                }

                StyledText {
                    anchors { horizontalCenter: parent.horizontalCenter; top: words.bottom; topMargin: 40 }
                    visible: rail.rows.length === 0 && rail.expanded
                    text: field.text.length ? "Nothing matches." : "Looking…"
                    font.pixelSize: 14
                    color: Appearance.colors.colInkSecondary
                }
            }

            // target mode, over the list; the folders are taken once as it opens
            RailTargets {
                id: targets
                y: 44
                width: parent.width
                height: parent.height - 44
                folders: rail.targetFolders
                onChosen: fkey => {
                    const p = rail.carryPurpose, payload = rail.carryPayload;
                    rail.endTargets();
                    if (p === "drop") rail.act("startIn", { fkey: fkey, drop: payload }, null);
                    else if (p === "move") rail.act("refile", { id: payload.id, fkey: fkey }, null);
                    else if (p === "new") rail.act("new", fkey, null);
                }
                onAddFolder: path => {
                    rail.endTargets();
                    rail.act("addFolder", path, null);
                }
                onReordered: (path, index) => {
                    rail.endTargets();
                    rail.act("reorder", { path: path, index: index }, null);
                }
                onCancelled: rail.endTargets()
            }
        }
    }

    // ── the rows' parts ─────────────────────────────────────────────────────
    // A session or a search hit: the mark, the title, and the context word that gives way to
    // pin and ⋯ under the pointer or the keyboard's cursor. Opened, its last reply and one fact
    // line grow under the title.
    Component {
        id: sessionPart
        Item {
            id: sp
            readonly property Item r: parent ? parent.rowItem : null
            readonly property var d: sp.r ? sp.r.d : ({})
            readonly property bool hit: sp.d.type === "hit"
            readonly property bool hover: !!sp.r && (sp.r.hovered || sp.r.keyFocus || sp.r.held) && !sp.d.placeholder && !sp.r.renaming && !rail.dragging
            readonly property real progress: sp.r ? sp.r.progress : 0
            readonly property bool opened: sp.progress > 0
            // open, the title shows whole (up to three lines): what it adds is part of the growth
            readonly property real lineH: fullTitle.lineCount > 0 ? fullTitle.implicitHeight / fullTitle.lineCount : 20
            readonly property real titleExtra: Math.max(0, fullTitle.implicitHeight - sp.lineH)
            readonly property real grownH: (grown.item ? grown.item.implicitHeight + 2 : 0) + sp.titleExtra
            StyledText {
                id: fullTitle
                visible: false
                width: title.width
                text: title.text
                font: title.font
                wrapMode: Text.Wrap
                maximumLineCount: 3
            }
            // working: a breathing sand dot; waiting for you: a steady one; open in a process: a ring;
            // past: nothing (a ring on every past row said nothing)
            Item {
                x: 20
                y: title.y + (sp.lineH - height) / 2
                width: 16
                height: 16
                LiveDot {
                    anchors.centerIn: parent
                    visible: sp.d.state === "working" || sp.d.state === "waiting"
                    breathing: sp.d.state === "working"
                }
                Rectangle {
                    anchors.centerIn: parent
                    visible: sp.d.state === "open"
                    width: 9
                    height: 9
                    radius: 4.5
                    color: "transparent"
                    border.width: 1.5
                    border.color: Appearance.colors.colInkSecondary
                }
                HoverHandler { id: markHover; enabled: sp.d.state !== "past" }
                StyledToolTip {
                    text: ({ working: "Working", waiting: "Waiting for you", open: "Open, idle" })[sp.d.state] ?? ""
                    extraVisibleCondition: markHover.hovered && sp.d.state !== "past"
                }
            }
            StyledText {
                id: title
                visible: !(sp.r?.renaming ?? false)
                x: 44
                y: sp.hit ? 8 : (32 - sp.lineH) / 2
                // open, the room for pin and ⋯ is kept whether or not the pointer is on it: the title
                // wraps there, and a width that followed the hover moved the rows under the pointer,
                // which moved the hover (a flicker at the rows' seams)
                width: sp.width - 44 - (sp.opened || sp.hover ? 42 + 18 + 10 : context.visible ? context.width + 20 + 10 : 20)
                text: rail.shownTitle(sp.d.title)
                font.family: Appearance.font.family.compact
                elide: Text.ElideRight
                wrapMode: sp.opened ? Text.Wrap : Text.NoWrap
                maximumLineCount: sp.opened ? 3 : 1
                font.pixelSize: 15
                font.weight: (sp.r?.current ?? false) ? Font.Medium : Font.Normal
                color: sp.d.state === "waiting" ? Appearance.colors.colPrimary
                    : (sp.r?.current ?? false) || (sp.r?.hovered ?? false) ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
            }
            StyledText {
                id: context
                visible: !sp.hover && text.length > 0 && !(sp.r?.renaming ?? false)
                anchors { right: parent.right; rightMargin: 20; top: title.top; topMargin: (sp.lineH - height) / 2 }
                width: Math.min(implicitWidth, 120)
                text: sp.d.context ?? ""
                font.family: Appearance.font.family.compact
                font.pixelSize: 13
                color: Appearance.colors.colInkMeta
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }
            StyledText {
                visible: sp.hit
                anchors { left: parent.left; leftMargin: 44; right: parent.right; rightMargin: 20; top: title.bottom; topMargin: 3 }
                textFormat: Text.StyledText
                text: rail.markedSnippet(sp.d.snippet, field.text)
                font.family: Appearance.font.family.compact
                elide: Text.ElideRight
                font.pixelSize: 14
                color: Appearance.colors.colInkMeta
            }
            Loader {
                id: acts
                active: sp.hover
                anchors { right: parent.right; rightMargin: 18; top: title.top; topMargin: (sp.lineH - height) / 2 }
                sourceComponent: Row {
                    spacing: 10
                    Repeater {
                        model: [{ glyph: "push_pin", tip: sp.d.pinned ? "Unpin" : "Pin", fill: sp.d.pinned === true, verb: "pin" },
                                { glyph: "more_horiz", tip: "More", fill: false, verb: "" }]
                        delegate: MaterialSymbol {
                            required property var modelData
                            text: modelData.glyph
                            fill: modelData.fill ? 1 : 0
                            iconSize: 16
                            color: actArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                            MouseArea {
                                id: actArea
                                anchors { fill: parent; margins: -4 }
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (rail.shifting()) return;
                                    if (modelData.verb.length) rail.act(modelData.verb, sp.d.id, sp.d);
                                    else rail.openCove(sp.d.key, "verbs", false, null, "rail");
                                }
                            }
                            StyledToolTip { text: modelData.tip; extraVisibleCondition: actArea.containsMouse }
                        }
                    }
                }
            }
            // the quiet lines under the title, built only while the row is open or folding
            Item {
                visible: sp.progress > 0
                x: 44
                y: (sp.hit ? 54 : 32) - 3 + sp.titleExtra
                width: sp.width - 44 - 20
                height: Math.max(0, (sp.grownH - sp.titleExtra) * sp.progress)
                clip: true
                Loader {
                    id: grown
                    width: parent.width
                    active: sp.progress > 0
                    opacity: sp.progress
                    sourceComponent: Column {
                        readonly property string reply: rail.replyOf(sp.d)
                        readonly property var fact: rail.factOf(sp.d)
                        width: grown.width
                        StyledText {
                            visible: parent.reply.length > 0
                            width: parent.width
                            text: parent.reply
                            textFormat: Text.PlainText
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 14
                            lineHeight: 1.15
                            color: Appearance.colors.colInkSecondary
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        // a repo's diff: "4 files · +120 −14" in the add/del tones
                        Row {
                            readonly property var f: parent.fact
                            visible: !!f && f.n !== undefined
                            StyledText {
                                text: parent.f ? Voice.count(parent.f.n, "file") + (parent.f.add + parent.f.del > 0 ? " · " : "") : ""
                                font.family: Appearance.font.family.numbers
                                font.pixelSize: 14
                                color: Appearance.colors.colInkMeta
                            }
                            StyledText {
                                visible: !!parent.f && parent.f.add > 0
                                text: `+${parent.f?.add ?? 0}`
                                font.family: Appearance.font.family.numbers
                                font.pixelSize: 14
                                color: Appearance.colors.colPrimary
                            }
                            StyledText {
                                visible: !!parent.f && parent.f.del > 0
                                text: `${parent.f?.add > 0 ? " " : ""}−${parent.f?.del ?? 0}`
                                font.family: Appearance.font.family.numbers
                                font.pixelSize: 14
                                color: Appearance.colors.colInkMeta
                            }
                        }
                        // "Made N files", or what it waits on in the attention tone
                        StyledText {
                            visible: !!parent.fact && parent.fact.text !== undefined
                            width: parent.width
                            text: parent.fact?.text ?? ""
                            textFormat: Text.PlainText
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 14
                            color: parent.fact?.needs ? Appearance.colors.colPrimary : Appearance.colors.colInkMeta
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }

    // A folder: its name ("here" a step up), " · N" when folded, the live mark; add and ⋯ under the pointer.
    Component {
        id: folderPart
        Item {
            id: fp
            readonly property Item r: parent ? parent.rowItem : null
            readonly property var d: fp.r ? fp.r.d : ({})
            readonly property bool hover: !!fp.r && (fp.r.hovered || fp.r.cursor || fp.r.held) && !fp.r.renaming && !rail.dragging
            readonly property var live: fp.d.live ?? ({})
            readonly property bool lit: (fp.live.waiting ?? 0) + (fp.live.working ?? 0) + (fp.live.terminals ?? 0) + (fp.live.graphis ?? 0) + (fp.live.files ?? 0) > 0
            readonly property real tail: (fp.hover ? icons.width + 18 + 10 : 20) + (mark.item ? mark.width + 10 : 0)
            Row {
                id: nameRow
                visible: !(fp.r?.renaming ?? false)
                x: 20
                anchors { bottom: parent.bottom; bottomMargin: 8 }
                StyledText {
                    id: nameText
                    width: Math.min(implicitWidth, fp.width - 20 - fp.tail - (suffix.visible ? suffix.implicitWidth : 0))
                    text: `${fp.d.name ?? ""}${fp.d.collapsed && (fp.d.count ?? 0) > 0 ? ` · ${fp.d.count}` : ""}`
                    font.family: Appearance.font.family.compact
                    elide: Text.ElideRight
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                    color: fp.hover || fp.d.here ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                }
                StyledText {
                    id: suffix
                    visible: (fp.d.suffix ?? "").length > 0
                    text: ` · ${fp.d.suffix}`
                    font.family: Appearance.font.family.compact
                    font.pixelSize: 14
                    color: Appearance.colors.colInkMeta
                }
            }
            Loader {
                id: mark
                active: fp.lit
                anchors { right: parent.right; rightMargin: fp.hover ? icons.width + 18 + 10 : 20; verticalCenter: nameRow.verticalCenter }
                sourceComponent: Row {
                    spacing: 10
                    Item {
                        visible: (fp.live.waiting ?? 0) + (fp.live.working ?? 0) > 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14
                        height: 14
                        LiveDot {
                            anchors.centerIn: parent
                            breathing: (fp.live.waiting ?? 0) === 0
                        }
                    }
                    Repeater {
                        model: [["terminal", fp.live.terminals ?? 0], ["code", fp.live.graphis ?? 0], ["folder", fp.live.files ?? 0]].filter(p => p[1] > 0)
                        delegate: Row {
                            id: livePart
                            required property var modelData
                            spacing: 3
                            MaterialSymbol {
                                anchors.verticalCenter: parent.verticalCenter
                                text: livePart.modelData[0]
                                iconSize: 14
                                color: Appearance.colors.colInkMeta
                            }
                            StyledText {
                                visible: livePart.modelData[1] > 1
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(livePart.modelData[1])
                                font.family: Appearance.font.family.numbers
                                font.pixelSize: 13
                                color: Appearance.colors.colInkMeta
                            }
                        }
                    }
                }
                MouseArea {
                    anchors { fill: parent; margins: -4 }
                    cursorShape: Qt.PointingHandCursor
                    onClicked: rail.markClicked(fp.d)
                }
            }
            Loader {
                id: icons
                active: fp.hover
                anchors { right: parent.right; rightMargin: 18; verticalCenter: nameRow.verticalCenter }
                sourceComponent: Row {
                    spacing: 10
                    Repeater {
                        model: [{ glyph: "add", tip: `New session in ${fp.d.name} (Ctrl+N)`, verb: "new", show: fp.d.canStart === true },
                                { glyph: "more_horiz", tip: "More", verb: "", show: true }].filter(x => x.show)
                        delegate: MaterialSymbol {
                            required property var modelData
                            text: modelData.glyph
                            iconSize: 16
                            color: iconArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                            MouseArea {
                                id: iconArea
                                anchors { fill: parent; margins: -4 }
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.verb.length) rail.act(modelData.verb, fp.d.fkey, fp.d);
                                    else rail.openCove(fp.d.key, "verbs", false, null, "rail");
                                }
                            }
                            StyledToolTip { text: modelData.tip; extraVisibleCondition: iconArea.containsMouse }
                        }
                    }
                }
            }
        }
    }

    // Pinned / Recent / Folders / Sessions / In transcripts: Files' section label; "Folders" adds one
    Component {
        id: labelPart
        Item {
            id: lp
            readonly property Item r: parent ? parent.rowItem : null
            readonly property var d: lp.r ? lp.r.d : ({})
            Row {
                id: labelText
                anchors { left: parent.left; leftMargin: 20; bottom: parent.bottom; bottomMargin: 8 }
                spacing: 8
                StyledText {
                    text: lp.d.text ?? ""
                    font.family: Appearance.font.family.compact
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colInkSecondary
                }
                StyledText {
                    readonly property int n: rail.countAfter(lp.d.key)
                    visible: n > 0
                    anchors.baseline: parent.children[0].baseline
                    text: n
                    font.family: Appearance.font.family.numbers
                    font.pixelSize: 14
                    color: Appearance.colors.colInkMeta
                }
            }
            MaterialSymbol {
                visible: lp.d.key === "l:Folders" && rail.shellUp && (lp.r?.hovered ?? false)
                anchors { right: parent.right; rightMargin: 18; verticalCenter: labelText.verticalCenter }
                text: "add"
                iconSize: 16
                color: addArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                MouseArea { id: addArea; anchors { fill: parent; margins: -4 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: rail.act("pickFolder", "", lp.d) }
                StyledToolTip { text: "Add a folder (also pins it in Pinax)"; extraVisibleCondition: addArea.containsMouse }
            }
        }
    }

    // "Show N more", "Start a session here", "Older folders · N", "Hidden · N", "Archived · N"
    Component {
        id: morePart
        Item {
            id: mp
            readonly property Item r: parent ? parent.rowItem : null
            readonly property var d: mp.r?.d ?? ({})
            readonly property bool first: rail.firstFooter(mp.d)
            readonly property string glyph: String(mp.d.act ?? "").startsWith("start:") ? "add"
                : String(mp.d.key ?? "").startsWith("m:less:") ? "expand_less"
                : String(mp.d.act ?? "").startsWith("more:") ? "expand_more"
                : mp.d.open ? "expand_more" : "chevron_right"
            Rectangle {
                visible: mp.first
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 20; rightMargin: 20; topMargin: 10 }
                height: 1
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            }
            MaterialSymbol {
                x: 20
                width: 16
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: moreText.verticalCenter
                text: mp.glyph
                iconSize: 16
                color: mp.r?.hovered ?? false ? Appearance.colors.colInkMain : Appearance.colors.colInkMeta
            }
            StyledText {
                id: moreText
                anchors { left: parent.left; leftMargin: 44; bottom: parent.bottom; bottomMargin: 7 }
                text: mp.d.text ?? ""
                font.family: Appearance.font.family.compact
                font.pixelSize: 14
                color: mp.r?.hovered ?? false ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
            }
        }
    }

    // a delete waiting out its minute
    Component {
        id: undoPart
        Item {
            id: up
            readonly property Item r: parent ? parent.rowItem : null
            readonly property var d: up.r ? up.r.d : ({})
            StyledText {
                anchors { left: parent.left; leftMargin: 44; right: undoButton.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                text: `Deleted · ${up.d.title ?? ""}`
                font.family: Appearance.font.family.compact
                font.pixelSize: 15
                color: Appearance.colors.colInkFaint
                elide: Text.ElideRight
            }
            PillButton {
                id: undoButton
                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                text: "Undo"
                onClicked: rail.act("undo", up.d.id, up.d)
            }
        }
    }

    // one line of plain words: the empty rail, or a filter that matched nothing
    Component {
        id: notePart
        Item {
            readonly property Item r: parent ? parent.rowItem : null
            implicitHeight: noteText.implicitHeight + 16
            StyledText {
                id: noteText
                x: 20
                y: 8
                width: parent.width - 40
                text: parent.r?.d?.text ?? ""
                font.family: Appearance.font.family.compact
                font.pixelSize: 14
                color: Appearance.colors.colInkSecondary
                wrapMode: Text.Wrap
            }
        }
    }

    Component {
        id: renameBox
        Rectangle {
            radius: 8
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            StyledTextInput {
                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 8; rightMargin: 8 }
                font.pixelSize: 15
                color: Appearance.colors.colInkMain
                clip: true
                // a box rebuilt in the middle of typing gets what was typed back, the caret after it
                Component.onCompleted: {
                    text = rail.renamingText;
                    if (rail.renameFresh) selectAll(); else cursorPosition = text.length;
                    rail.renameFresh = false;
                    forceActiveFocus();
                }
                onTextEdited: rail.renamingText = text
                Keys.onReturnPressed: rail.commitRename()
                Keys.onEnterPressed: rail.commitRename()
                Keys.onEscapePressed: { rail.renamingKey = ""; list.forceActiveFocus(); }
                onActiveFocusChanged: {
                    rail.renameFocused = activeFocus;
                    if (!activeFocus) renameBlur.restart();
                }
            }
        }
    }
}
