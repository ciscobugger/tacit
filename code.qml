//@ pragma UseQApplication
//@ pragma AppId graphis
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
//@ pragma Env QML_IMPORT_PATH=/home/abdul/.local/lib/qml

// The code editor: an ordinary tiled window on the shell's own design language.
// Run as its own instance (`qs -p ~/.config/quickshell/tacit/code.qml`), so a
// fault here never touches the bar, island or lock. CODE_PROJECT picks the
// project; without it the window opens on the project picker.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import "modules/code"

ApplicationWindow {
    id: root

    property var docs: []          // [{ rel, doc }]
    property int current: -1
    readonly property var cur: root.current >= 0 && root.current < root.docs.length ? root.docs[root.current].doc : null
    property bool treeShown: true
    // Praxis's 300 on a wide window; a narrow one (tiled beside another) keeps more for the text
    readonly property int railWidth: Math.round(Math.max(232, Math.min(300, root.width * 0.28)))
    property var ask: null         // { text, buttons: [{ label, run, accent }] }
    property int askAt: 0          // the button the keyboard is on
    // what is true of the open file besides its name, in one line
    readonly property string curState: !root.cur ? ""
        : root.cur.problem.length ? root.cur.problem
        : root.cur.missing ? "Gone from disk"
        : root.cur.conflicted ? "Changed on disk — answer below"
        : root.cur.held ? "Typing out change — Esc to stop" : ""
    property var typed: ({})       // files whose change was typed out in full this session: they open as written
    // Type out changes: a changed file opens as it was and each key brings the change back.
    // Off by default (a changed file opens as it is, with the diff gutter); Ctrl+Alt+T or the
    // status line turns it on, and `f` in the tree still types one change on request.
    FileView {
        id: typingFile
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/code-typing.txt`)
        blockLoading: true
        printErrors: false
    }
    // The owner's alone (2026-10-15: "typing feature exclusive to me only"): the switch, its key and `f` in the tree
    // exist only where this file does. A new install has none, so nobody else sees it; `ipc call code setTyping` makes it.
    readonly property bool typingAllowed: (typingFile.text() || "").trim().length > 0
    property bool typing: root.typingAllowed && (typingFile.text() || "").trim() === "on"
    function setTyping(on) {
        typingFile.setText(on ? "on\n" : "off\n");
        root.typing = on;
        // a file already half typed out would otherwise stay stuck holding the keyboard
        if (!on) for (const d of root.docs) if (d.doc) d.doc.abandon();
    }

    visible: true
    // An app does not reload itself when a file in the shared config changes: a reload rebuilt the
    // window as visible, so every deploy (even one only for the shell) popped a closed app back up.
    // New code arrives the next time the app starts.
    Binding { target: Quickshell; property: "watchFiles"; value: false }
    minimumWidth: 640
    minimumHeight: 400
    // The window is this editor by name, and window rules can match the suffix or its
    // appId (`graphis`).
    title: project.root.length ? `${project.name} — Graphis` : "Graphis"
    color: "transparent"

    // ── the window's own shape, as Files remembers its own (services/Files.qml windowState) ──
    FileView {
        id: shapeFile
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/code-window.txt`)
        blockLoading: true
        printErrors: false
    }
    // Read once (blockLoading), so this is the size it opens at; a resize overwrites the binding
    // and rememberShape writes what the window ended up as.
    width: root.shape.w
    height: root.shape.h
    readonly property var shape: {
        const s = (shapeFile.text() || "").trim().split(/\s+/).map(Number);
        return s.length === 2 && s[0] >= 640 && s[1] >= 400 ? ({ w: s[0], h: s[1] }) : ({ w: 1280, h: 820 });
    }
    function rememberShape() {
        if (root.width >= 640 && root.height >= 400)
            shapeFile.setText(`${Math.round(root.width)} ${Math.round(root.height)}\n`);
    }

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        Quickshell.execDetached(["mkdir", "-p", root.keptDir]);
        const dir = Quickshell.env("CODE_PROJECT");
        if (dir && dir.length) root.openProject(dir);
        else { picker.refresh(); picker.focusFilter(); }
    }

    // the project's language servers (only those installed); each open file tells its own
    LspClient {
        id: lspClient
        root: project.root
    }
    // F12 / Ctrl+click landed: a file of this project opens there; anything outside it is said, not opened
    function openAt(path, line, ch) {
        if (path.startsWith(project.root + "/")) {
            root.openFile(path.substring(project.root.length + 1), false);
            if (root.cur) root.cur.goToLineCol(line, ch);
        } else root.tell(`Defined outside this project, in ${path.replace(Quickshell.env("HOME"), "~")}`);
    }

    CodeProject {
        id: project
        awake: root.visible          // a closed window only hides: stop asking git while it is away
    }
    onActiveChanged: if (root.active) project.quicken()

    // The window material is the terminal's: the same background colour the palette
    // pipeline hands foot (OSC 11 in the generated sequences) at foot's alpha 0.85, so
    // the editor and foot read as one kind of window. Focused it is solid gray; Hyprland's
    // inactive_opacity turns both to glass when they lose focus.
    FileView {
        id: termColors
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/generated/terminal/sequences.txt`)
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property color material: {
        const m = /\]11;(#[0-9a-fA-F]{6})/.exec(termColors.text() || "");
        return ColorUtils.transparentize(m ? m[1] : Appearance.m3colors.m3surfaceContainerLow, Tacit.windowSeeThrough);
    }

    // ── the text size, Ctrl+= and Ctrl+-, kept between runs ─────────────────
    FileView {
        id: zoomFile
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/code-zoom.txt`)
        blockLoading: true
        printErrors: false
    }
    property int fontSize: { const n = parseInt(zoomFile.text()); return n >= 10 && n <= 32 ? n : 15; }
    function zoom(d) {
        root.fontSize = d === 0 ? 15 : Math.max(10, Math.min(32, root.fontSize + d));
        zoomFile.setText(`${root.fontSize}\n`);
    }
    Shortcut { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: root.zoom(1) }
    Shortcut { sequence: "Ctrl+-"; onActivated: root.zoom(-1) }
    Shortcut { sequence: "Ctrl+0"; onActivated: root.zoom(0) }

    // a right click in the text: the clipboard, then the line commands
    function textMenu(d, x, y) {
        const items = [];
        if (d.hasSelection) items.push({ label: "Cut", key: "Ctrl+X", run: () => d.cut() }, { label: "Copy", key: "Ctrl+C", run: () => d.copy() });
        items.push({ label: "Paste", key: "Ctrl+V", run: () => d.paste() },
            { label: "Select All", key: "Ctrl+A", run: () => d.selectAll() },
            { label: "Comment Line", key: "Ctrl+/", line: true, run: () => d.toggleComment() },
            { label: "Duplicate Line", key: "Ctrl+Shift+D", run: () => d.duplicateLines() },
            { label: d.wrap ? "Don't Wrap Lines" : "Wrap Lines", key: "Alt+Z", run: () => d.wrapSet = !d.wrap },
            { label: "Find", key: "Ctrl+F", line: true, run: () => find.open("find", d.selection) });
        const at = d.mapToItem(menu, x, y);
        menu.open(at.x, at.y, items);
    }

    // ── recent projects ─────────────────────────────────────────────────────
    FileView {
        id: recentFile
        path: `${Directories.state}/user/code-projects.txt`
        blockLoading: true
        printErrors: false
    }
    function recents() { return (recentFile.text() || "").split("\n").filter(l => l.length); }
    function remember(dir) {
        const list = [dir].concat(root.recents().filter(p => p !== dir)).slice(0, 20);
        recentFile.setText(list.join("\n") + "\n");
    }

    // ── projects and files ──────────────────────────────────────────────────
    // A tab restored from the last session has no doc until it is shown (materialize): opening a project with
    // twenty tabs builds one editor, not twenty.
    function unsavedDocs() { return root.docs.filter(d => d.doc && d.doc.dirty && !d.doc.session); }

    // Nothing that throws away every open buffer happens without asking first. The answer
    // arrives later, so `then` carries the rest of the work.
    function guardUnsaved(then) {
        const unsaved = root.unsavedDocs();
        if (unsaved.length === 0) { then(); return; }
        root.ask = { text: unsaved.length === 1 ? `Save changes to ${unsaved[0].rel.split("/").pop()}?`
            : `${Voice.count(unsaved.length, "file")} have unsaved changes.`, buttons: [
            { label: unsaved.length === 1 ? "Save" : "Save all", accent: true, run: () => {
                let ok = true;
                for (const d of unsaved) if (root.docs.indexOf(d) >= 0 && !d.doc.save()) ok = false;
                if (ok) then();      // a write that failed says so and keeps the file open
            } },
            { label: "Don't save", risk: true, run: () => then() },
            { label: "Cancel", run: () => {} }] };
    }

    function openProject(dir) { root.guardUnsaved(() => root.setProject(dir)); }
    // Switching: the project's name at the top of the files (or Ctrl+O) brings the picker over the editor; the open
    // files stay until another project is chosen, and Esc goes back to them.
    property bool picking: false
    function pickProject() { if (project.root.length) { root.picking = true; picker.focusFilter(); } }
    function chooseProject(dir) {
        root.picking = false;
        if (dir === project.root) root.refocus();
        else root.openProject(dir);
    }
    function setProject(dir) {
        dir = dir.replace(/\/+$/, "");
        root.saveSession();
        for (const d of root.docs) if (d.doc) d.doc.destroy();
        root.docs = []; root.current = -1;
        project.setRoot(dir);
        root.remember(dir);
        tree.forceActiveFocus();
        root.restoreSession(dir);
        root.offerKept(dir);
    }
    function clearProject() {
        root.saveSession();
        for (const d of root.docs) if (d.doc) d.doc.destroy();
        root.docs = []; root.current = -1;
        project.setRoot("");
    }

    // Wherever the keyboard should go when a surface closes or hides.
    function refocus() {
        if (root.cur) root.cur.focusEditor();
        else if (!project.root.length) picker.focusFilter();
        else if (root.treeShown) tree.forceActiveFocus();
    }

    function openFile(rel, watch) {
        let i = root.docs.findIndex(d => d.rel === rel);
        if (i >= 0 && watch) { if (root.docs[i].doc) root.docs[i].doc.destroy(); root.docs = root.docs.filter((_, j) => j !== i); i = -1; }
        if (i < 0) {
            const doc = docComp.createObject(stack, { rel: rel, abs: project.root + "/" + rel, project: project,
                status: (root.typing || watch) && !root.typed[rel] ? (project.changes[rel] || "") : "", watchOnOpen: !!watch });
            root.docs = root.docs.concat([{ rel: rel, doc: doc }]);
            i = root.docs.length - 1;
        }
        root.show(i);
    }

    function show(i) {
        root.materialize(i);
        root.current = i;
        if (root.cur) { project.reveal(root.docs[i].rel); root.cur.focusEditor(); }
        sessionLater.restart();
    }
    function materialize(i) {
        const e = root.docs[i];
        if (!e || e.doc) return;
        e.doc = docComp.createObject(stack, { rel: e.rel, abs: project.root + "/" + e.rel, project: project, status: "", watchOnOpen: false });
        if (e.cursor || e.y) e.doc.restoreView(e.cursor || 0, e.y || 0);
        root.docs = root.docs.slice();
    }

    function closeDoc(i, force) {
        const d = root.docs[i];
        if (!d) return;
        if (!force && d.doc && d.doc.dirty && !d.doc.session) {
            // the doc, not the index: closing another tab while the question is up renumbers them
            root.ask = { text: `Save changes to ${d.rel.split("/").pop()}?`, buttons: [
                { label: "Save", accent: true, run: () => { if (d.doc.save()) root.closeDoc(root.docs.indexOf(d), true); } },
                { label: "Don't save", risk: true, run: () => root.closeDoc(root.docs.indexOf(d), true) },
                { label: "Cancel", run: () => {} }] };
            return;
        }
        if (d.doc) { root.dropKept(d.doc.abs); d.doc.destroy(); }
        root.docs = root.docs.filter((_, j) => j !== i);
        sessionLater.restart();
        root.show(Math.min(i, root.docs.length - 1));
        if (root.docs.length === 0) { root.current = -1; project.active = ""; tree.forceActiveFocus(); }
    }

    function answer(i) {
        if (!root.ask) return;
        if (i < 0) { root.ask = null; return; }      // Esc on a question that can wait
        const b = root.ask.buttons[i];
        if (!b) return;
        root.ask = null;
        b.run();
    }
    onAskChanged: {
        if (root.ask === null) root.refocus();
        // a second question arriving over the first keeps the keyboard on it
        else if (askBar.visible) { root.askAt = 0; askBar.forceActiveFocus(); }
    }

    function quit() {
        root.rememberShape();
        root.saveSession();
        // saved or let go on purpose: nothing kept to offer next time
        root.guardUnsaved(() => { for (const d of root.docs) if (d.doc) root.dropKept(d.doc.abs); Qt.quit(); });
    }

    // ── the session: open files, the cursor and scroll in each, per project ──
    FileView {
        id: sessionFile
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/code-sessions.json`)
        blockLoading: true
        printErrors: false
    }
    Timer { id: sessionLater; interval: 800; onTriggered: root.saveSession() }
    Connections { target: root.cur; function onLineChanged() { sessionLater.restart(); } }
    function sessions() { try { return JSON.parse(sessionFile.text() || "{}"); } catch (e) { return {}; } }
    function saveSession() {
        if (!project.root.length) return;
        const all = root.sessions();
        all[project.root] = { current: root.current, at: Date.now(), tabs: root.docs.map(d =>
            d.doc ? { rel: d.rel, cursor: d.doc.cursorPos(), y: Math.round(d.doc.scrollY()) } : { rel: d.rel, cursor: d.cursor || 0, y: d.y || 0 }) };
        const out = {};
        for (const k of Object.keys(all).sort((a, b) => (all[b].at || 0) - (all[a].at || 0)).slice(0, 30)) out[k] = all[k];
        sessionFile.setText(JSON.stringify(out) + "\n");
    }
    function restoreSession(dir) {
        const s = root.sessions()[dir];
        if (!s || !s.tabs || !s.tabs.length) return;
        root.docs = s.tabs.map(t => ({ rel: t.rel, doc: null, cursor: t.cursor, y: t.y }));
        root.show(s.current >= 0 && s.current < root.docs.length ? s.current : 0);
        // a file deleted since the last session is not brought back as an empty tab
        if (root.cur && root.cur.missing) root.closeDoc(root.current, true);
    }

    // ── unsaved work kept aside: a crash or a power cut loses nothing ────────
    // Every file with unsaved changes is written, two seconds after its last change, to its own record in the
    // state folder; a save, a close or a quit that let the changes go removes it. A project that opens with records
    // asks once for all of them.
    readonly property string keptDir: FileUtils.trimFileProtocol(`${Directories.state}/user/graphis-unsaved`)
    function keptPath(abs) { return `${root.keptDir}/${Qt.md5(abs)}.json`; }
    property var keptText: ({})        // abs -> the text last written for it
    Timer { id: keepLater; interval: 2000; onTriggered: root.keep() }
    Component { id: keepWriter; FileView { blockWrites: true; printErrors: false } }
    function keep() {
        const now = {};
        for (const d of root.docs) {
            if (!d.doc || d.doc.session || d.doc.problem.length || !d.doc.dirty) continue;
            const t = d.doc.text();
            now[d.doc.abs] = t;
            if (root.keptText[d.doc.abs] === t) continue;
            const w = keepWriter.createObject(root, { path: root.keptPath(d.doc.abs) });
            w.setText(JSON.stringify({ abs: d.doc.abs, text: t, at: Date.now() }) + "\n");
            w.destroy();
        }
        const gone = Object.keys(root.keptText).filter(a => now[a] === undefined);
        if (gone.length) Quickshell.execDetached(["rm", "-f"].concat(gone.map(a => root.keptPath(a))));
        root.keptText = now;
    }
    function dropKept(abs) {
        const k = Object.assign({}, root.keptText); delete k[abs]; root.keptText = k;
        Quickshell.execDetached(["rm", "-f", root.keptPath(abs)]);
    }
    function offerKept(dir) {
        project.exec(["sh", "-c", 'cat "$1"/*.json 2>/dev/null', "sh", root.keptDir], (code, out) => {
            if (project.root !== dir) return;
            const recs = out.split("\n").filter(l => l.length).map(l => { try { return JSON.parse(l); } catch (e) { return null; } })
                .filter(r => r && r.abs && r.abs.startsWith(dir + "/") && typeof r.text === "string");
            if (!recs.length) return;
            const one = recs.length === 1 ? recs[0].abs.split("/").pop() : "";
            root.ask = { text: one.length ? `${one} has changes from before Graphis last closed.`
                    : `${recs.length} files have changes from before Graphis last closed.`, esc: -1, buttons: [
                { label: "Restore", accent: true, run: () => {
                    // known to the keeper, so a save or a close removes these records as it does its own
                    const k = Object.assign({}, root.keptText);
                    for (const r of recs) k[r.abs] = r.text;
                    root.keptText = k;
                    for (const r of recs) {
                        const rel = r.abs.substring(dir.length + 1);
                        const t = Object.assign({}, root.typed); t[rel] = true; root.typed = t;   // as written, never typed out
                        root.openFile(rel, false);
                        if (root.cur) root.cur.takeKept(r.text);
                    }
                } },
                { label: "Discard", risk: true, run: () => Quickshell.execDetached(["rm", "-f"].concat(recs.map(r => root.keptPath(r.abs)))) }] };
        });
    }

    // ── files in the project: new, rename, to the Trash ─────────────────────
    // A short line in the status bar says what happened, with the way back where there is one; it never takes
    // the keyboard, so several files can go in a row.
    property var note: null            // { text, label, run }
    property var lastNote: null        // what the line says while it fades out
    onNoteChanged: if (root.note) root.lastNote = root.note
    Timer { id: noteTimer; interval: 10000; onTriggered: root.note = null }
    function tell(text, label, run) { root.note = { text: text, label: label || "", run: run || null }; noteTimer.restart(); }
    function folderOf(row) {
        if (!row) return "";
        if (row.dir) return row.path;
        return row.path.includes("/") ? row.path.substring(0, row.path.lastIndexOf("/")) : "";
    }
    // where Ctrl+N makes a file: the folder of the tree's row, else of the open file
    function here() {
        const r = tree.model[tree.currentIndex];
        if (tree.activeFocus && r && !r.draft) return root.folderOf(r);
        if (root.cur) return root.folderOf({ dir: false, path: root.docs[root.current].rel });
        return "";
    }
    function startNew(parent, kind) {
        if (!project.root.length) return;
        root.treeShown = true;
        project.startDraft(parent, kind);
    }
    function inside(rel) { const parts = rel.split("/"); return rel.length > 0 && !rel.startsWith("/") && !parts.includes("..") && !parts.includes("."); }
    function create(name) {
        const d = project.draft;
        project.endDraft();
        if (!d) return;
        const rel = (d.parent.length ? d.parent + "/" : "") + name.replace(/\/+$/, "");
        const base = rel.split("/").pop();
        if (!root.inside(rel)) { root.tell("A name stays inside the project."); return; }
        const abs = project.root + "/" + rel;
        const argv = d.kind === "folder"
            ? ["sh", "-c", '[ -e "$1" ] && exit 3; mkdir -p -- "$1"', "sh", abs]
            : ["sh", "-c", '[ -e "$1" ] && exit 3; mkdir -p -- "$(dirname -- "$1")" && : > "$1"', "sh", abs];
        project.exec(argv, code => {
            if (code === 3) { root.tell(`There is already something named ${base} there.`); return; }
            if (code !== 0) { root.tell(Voice.cant(`make ${base}`)); return; }
            if (d.kind === "folder") {
                project.made = project.made.concat([rel]);
                const o = Object.assign({}, project.open); o[rel] = true; project.open = o;
                project.rebuild();
            } else root.openFile(rel, false);
            project.quicken();
        });
    }
    function rename(path, name) {
        const parent = path.includes("/") ? path.substring(0, path.lastIndexOf("/")) : "";
        const to = (parent.length ? parent + "/" : "") + name.replace(/\/+$/, "");
        if (!root.inside(to)) { root.tell("A name stays inside the project."); return; }
        project.exec(["sh", "-c", '[ -e "$2" ] && exit 3; mkdir -p -- "$(dirname -- "$2")" && mv -- "$1" "$2"', "sh",
                      project.root + "/" + path, project.root + "/" + to], code => {
            if (code === 3) { root.tell(`There is already something named ${to.split("/").pop()} there.`); return; }
            if (code !== 0) { root.tell(Voice.cant(`rename ${path.split("/").pop()}`)); return; }
            // open files go with it, unsaved edits and all
            for (const d of root.docs) if (d.rel === path || d.rel.startsWith(path + "/")) {
                d.rel = to + d.rel.substring(path.length);
                if (d.doc) { root.dropKept(d.doc.abs); d.doc.rel = d.rel; d.doc.abs = project.root + "/" + d.rel; }
            }
            project.made = project.made.map(m => m === path || m.startsWith(path + "/") ? to + m.substring(path.length) : m);
            root.docs = root.docs.slice();
            if (root.cur) project.reveal(root.docs[root.current].rel);
            project.quicken();
        });
    }
    function trash(row) {
        const abs = project.root + "/" + row.path, name = row.path.split("/").pop();
        project.exec(["gio", "trash", "--", abs], code => {
            if (code !== 0) { root.tell(Voice.cant(`move ${name} to the Trash`)); return; }
            for (let i = root.docs.length - 1; i >= 0; i--) {
                const r = root.docs[i].rel;
                if (r === row.path || r.startsWith(row.path + "/")) root.closeDoc(i, true);
            }
            project.made = project.made.filter(m => m !== row.path && !m.startsWith(row.path + "/"));
            project.quicken();
            root.tell(`${name} is in the Trash.`, "Put back", () => root.putBack(abs, name));
        });
    }
    // the newest thing in the Trash that came from `abs` goes back where it was
    function putBack(abs, name) {
        project.exec(["gio", "trash", "--list"], (code, out) => {
            const uri = out.split("\n").map(l => l.split("\t")).filter(f => f.length === 2 && f[1] === abs).map(f => f[0]).pop();
            if (!uri) { root.tell(Voice.cant(`find ${name} in the Trash`)); return; }
            project.exec(["gio", "trash", "--restore", uri], c => {
                root.tell(c === 0 ? `${name} is back.` : Voice.cant(`put ${name} back — something else is in its place`));
                project.quicken();
            });
        });
    }
    function menuFor(row, x, y) {
        if (row && row.draft) return;
        const items = [
            { label: "New File", key: "Ctrl+N", run: () => root.startNew(root.folderOf(row), "file") },
            { label: "New Folder", key: "Ctrl+Shift+N", run: () => root.startNew(root.folderOf(row), "folder") }];
        if (row && row.status !== "D") items.push(
            { label: "Rename", key: "F2", line: true, run: () => tree.renaming = row.path },
            { label: "Move to Trash", key: "Delete", run: () => root.trash(row) });
        const abs = project.root + (row ? "/" + row.path : "");
        items.push(
            { label: "Copy Path", line: true, run: () => Quickshell.clipboardText = abs },
            { label: "Show in Files", run: () => Quickshell.execDetached(["qs", "-p", Directories.shellFile, "ipc", "call", "files", "reveal", abs]) });
        const at = tree.mapToItem(menu, x, y);
        menu.open(at.x, at.y, items);
    }
    onClosing: close => { root.rememberShape(); root.saveSession(); if (root.unsavedDocs().length > 0) { close.accepted = false; root.quit(); } }

    Component {
        id: docComp
        CodeDoc {
            id: docItem
            anchors.fill: parent
            visible: root.cur === docItem
            onTypedOut: { const t = Object.assign({}, root.typed); t[docItem.rel] = true; root.typed = t; }
            onEdited: if (!keepLater.running) keepLater.start()
            fontSize: root.fontSize
            onMenuAt: (x, y) => root.textMenu(docItem, x, y)
            lsp: lspClient
            onOpenAt: (path, line, ch) => root.openAt(path, line, ch)
            onConflict: root.ask = { text: `${docItem.rel.split("/").pop()} changed on disk.`, buttons: [
                { label: "Reload", accent: true, run: () => docItem.reloadFromDisk() },
                { label: "Keep mine", run: () => docItem.keepMine() }] }
            onWriteFailed: reason => root.ask = { text: Voice.cant(`save ${docItem.rel.split("/").pop()} — ${reason}`), buttons: [
                { label: "OK", accent: true, run: () => {} }] }
            onMissingOnSave: root.ask = { text: `${docItem.rel.split("/").pop()} is no longer on disk.`, buttons: [
                { label: "Save anyway", accent: true, run: () => docItem.save(true) },
                { label: "Cancel", run: () => {} }] }
        }
    }

    IpcHandler {
        target: "code"
        // no caller out here can answer a Save prompt, so unsaved work refuses the switch
        function open(dir: string): string {
            if (root.unsavedDocs().length > 0) return JSON.stringify({ opened: false, reason: "unsaved", root: project.root });
            root.setProject(dir);
            return JSON.stringify({ opened: true, root: project.root });
        }
        function root(): string { return project.root; }
        function file(rel: string): void { if (project.root.length) root.openFile(rel, false); }
        // a file at a line (the Claude app's edits and review): 0 = where it opens
        function fileAt(rel: string, line: int): void {
            if (!project.root.length) return;
            root.openFile(rel, false);
            if (line > 0 && root.cur) root.cur.goToLine(line);
        }
        // closing the window hides it; every way in shows it again (code-file)
        function present(): void { root.visible = true; }
        function setTyping(on: bool): void { root.setTyping(on); }
        // the open file as JSON, for scripts and checks
        function state(): string { return JSON.stringify(root.cur ? root.cur.snapshot() : { rel: "" }); }
        // every open file, for Praxis's "Open here"
        function docs(): string {
            return JSON.stringify({ root: project.root, current: root.cur ? root.docs[root.current].rel : "",
                docs: root.docs.map(d => ({ rel: d.rel, dirty: !!d.doc && d.doc.dirty === true })) });
        }
        // scripted checks drive the same paths the keys do, without touching focus
        function steps(n: int): string { for (let i = 0; i < n && root.cur; i++) root.cur.step(); return state(); }
        function leave(): string { if (root.cur) root.cur.release(); return state(); }
        function search(q: string): void { finder.searchFor(q); }
        function pick(i: int): string { finder.choose(i); return state(); }
        function finderState(): string { return JSON.stringify({ shown: finder.visible, mode: finder.mode, results: finder.results.length, rg: finder.rgInfo,
            first: finder.results.length ? finder.results[0] : null }); }
        function save(): string { if (root.cur) root.cur.save(); return state(); }
        // the file actions, as the tree's keys and menu run them
        function make(parent: string, kind: string, name: string): void { project.startDraft(parent === "/" ? "" : parent, kind); root.create(name); }
        function move(path: string, name: string): void { root.rename(path, name); }
        function toTrash(path: string): void { root.trash({ path: path }); }
        function noted(): string { return JSON.stringify(root.note ? { text: root.note.text, label: root.note.label } : null); }
        function takeNote(): void { const n = root.note; root.note = null; if (n && n.run) n.run(); }
        function rows(): string { return JSON.stringify(project.rows.map(r => (r.ignored ? "~" : "") + r.path + (r.dir ? "/" : ""))); }
        function toggle(dir: string): void { project.toggle(dir); }
        function pickerType(t: string): void { root.pickProject(); picker.typeFilter(t); }
        function pickerBack(): void { picker.back(); }
        function picking(): bool { return root.picking; }
        function rowHeights(): string { let out = []; for (let i = 0; i < Math.min(tree.count, 4); i++) { const it = tree.itemAtIndex(i); out.push(it ? Math.round(it.height) : -1); } return JSON.stringify(out); }
        function pickerChoose(i: int): void { picker.chosen(picker.all[i]); }
        function pickerHits(): string { return JSON.stringify(picker.all.slice(0, 6)); }
        function docs2(): string { return JSON.stringify(root.docs.map(d => d.rel + "|" + (d.doc ? d.doc.abs : "-"))); }
        function sel(a: int, b: int): void { if (root.cur) root.cur.selectRange(a, b); }
        function cmd(name: string): string {
            const d = root.cur;
            if (!d) return "";
            if (name === "comment") d.toggleComment(); else if (name === "dup") d.duplicateLines();
            else if (name === "up") d.moveLines(true); else if (name === "down") d.moveLines(false); else if (name === "home") d.home(false);
            return JSON.stringify({ text: d.text(), cursor: d.cursorPos() });
        }
        function shot(path: string): void { ground.grabToImage(r => r.saveToFile(path)); }
        function treeMenu(i: int): void { const r = project.rows[i]; const it = tree.itemAtIndex(i); if (r && it) root.menuFor(r, 120, it.y - tree.contentY + 20); }
        function textMenuAt(x: int, y: int): void { if (root.cur) root.textMenu(root.cur, x, y); }
        function draft(parent: string): void { menu.close(); root.startNew(parent === "/" ? "" : parent, "file"); }
        function problems(): string { return root.cur ? JSON.stringify({ line: root.cur.diagLine, n: root.cur.diags.length, servers: Object.keys(lspClient.installed) }) : ""; }
        function completeAt(offset: int): void { if (root.cur) { root.cur.selectRange(offset, offset); root.cur.maybeComplete(true); } }
        function completions(): string { return root.cur ? JSON.stringify(root.cur.compShown.slice(0, 8).map(c => c.label)) : "[]"; }
        function acceptFirst(): string { if (root.cur) root.cur.acceptCompletion(); return root.cur ? root.cur.text().substring(0, 200) : ""; }
        function definitionAt(offset: int): void { if (root.cur) root.cur.goDefinition(offset); }
        function bench(n: int): int { return root.cur ? root.cur.bench(n) : -1; }
        function key(t: string): string { if (root.cur) root.cur.typeKey(t); return JSON.stringify({ text: root.cur.text(), cursor: root.cur.cursorPos() }); }
        function asked(): string { return root.ask ? root.ask.text + " | " + root.ask.buttons.map(b => b.label).join(", ") : ""; }
        function answerAsk(i: int): void { root.answer(i); }
        function quitNow(): void { root.saveSession(); Qt.quit(); }                 // a quit with no questions, as a crash would leave it
        function typeAt(t: string): void { if (root.cur) root.cur.takeKept(root.cur.text() + t); }
        function replaceAll(needle: string, with_: string): int { return root.cur ? root.cur.replaceAll(needle, with_, true) : 0; }
        function undo(): string { if (root.cur) root.cur.undo(); return state(); }
        function closeTab(): string {
            if (root.current < 0) return JSON.stringify({ closed: false, reason: "no file open" });
            const d = root.docs[root.current];
            if (d.doc && d.doc.dirty && !d.doc.session) return JSON.stringify({ closed: false, reason: "unsaved" });
            root.closeDoc(root.current, true);
            return JSON.stringify({ closed: true });
        }
    }

    // ── keys every editor has ───────────────────────────────────────────────
    Shortcut { sequence: "Ctrl+S"; onActivated: if (root.cur) root.cur.save() }
    Shortcut { sequence: "Ctrl+W"; enabled: root.ask === null; onActivated: if (root.current >= 0) root.closeDoc(root.current) }
    Shortcut { sequence: "Ctrl+B"; onActivated: { root.treeShown = !root.treeShown; root.refocus(); } }
    // Ctrl+Shift+T is "a terminal here" in Files and "reopen the closed tab" in most editors,
    // so the typing switch sits on a chord of its own.
    Shortcut { sequence: "Ctrl+Alt+T"; enabled: root.typingAllowed; onActivated: root.setTyping(!root.typing) }
    Shortcut { sequence: "Ctrl+PgDown"; onActivated: if (root.docs.length) root.show((root.current + 1) % root.docs.length) }
    Shortcut { sequence: "Ctrl+PgUp"; onActivated: if (root.docs.length) root.show((root.current - 1 + root.docs.length) % root.docs.length) }
    Shortcut { sequence: "Ctrl+O"; enabled: root.ask === null; onActivated: root.pickProject() }
    Shortcut { sequence: "Ctrl+Q"; enabled: root.ask === null; onActivated: root.quit() }
    Shortcut { sequence: "Ctrl+N"; enabled: project.root.length > 0 && root.ask === null; onActivated: root.startNew(root.here(), "file") }
    Shortcut { sequence: "Ctrl+Shift+N"; enabled: project.root.length > 0 && root.ask === null; onActivated: root.startNew(root.here(), "folder") }
    Shortcut { sequence: "Ctrl+P"; enabled: project.root.length > 0; onActivated: finder.open("files") }
    Shortcut { sequence: "Ctrl+Shift+F"; enabled: project.root.length > 0; onActivated: finder.open("search") }
    Shortcut { sequence: "Ctrl+F"; enabled: root.cur !== null; onActivated: find.open("find", root.cur.selection) }
    Shortcut { sequence: "Ctrl+G"; enabled: root.cur !== null; onActivated: find.open("line", "") }
    Shortcut { sequence: "F3"; enabled: root.cur !== null; onActivated: find.visible ? find.step(false) : find.open("find", root.cur.selection) }
    Shortcut { sequence: "Shift+F3"; enabled: root.cur !== null; onActivated: if (find.visible) find.step(true) }
    // straight to a tab, however far the strip has scrolled
    function showTab(n) { if (n >= 0 && n < root.docs.length) root.show(n); }
    Shortcut { sequence: "Alt+1"; onActivated: root.showTab(0) }
    Shortcut { sequence: "Alt+2"; onActivated: root.showTab(1) }
    Shortcut { sequence: "Alt+3"; onActivated: root.showTab(2) }
    Shortcut { sequence: "Alt+4"; onActivated: root.showTab(3) }
    Shortcut { sequence: "Alt+5"; onActivated: root.showTab(4) }
    Shortcut { sequence: "Alt+6"; onActivated: root.showTab(5) }
    Shortcut { sequence: "Alt+7"; onActivated: root.showTab(6) }
    Shortcut { sequence: "Alt+8"; onActivated: root.showTab(7) }
    Shortcut { sequence: "Alt+9"; onActivated: root.showTab(8) }

    // ── the window ──────────────────────────────────────────────────────────
    Rectangle {
        id: ground
        anchors.fill: parent
        color: root.material

        RowLayout {
            anchors.fill: parent
            spacing: 0
            visible: project.root.length > 0 && !root.picking

            // the files, on Praxis's rail (modules/claude/SessionList.qml), measure for measure: the fold and the
            // search in the top line, the one action as a soft slab, a live line, the project as the section label
            // (it opens another project), rows with the current one washed and marked by the sand tick
            Item {
                id: railOuter
                Layout.fillHeight: true
                Layout.preferredWidth: root.treeShown ? root.railWidth : 0
                Behavior on Layout.preferredWidth { Anim {} }
                visible: Layout.preferredWidth > 0
                clip: true
                Rectangle {
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    width: 1
                    color: Tacit.hairline
                    opacity: 0.4
                }
            Item {
                id: railBox
                width: root.railWidth
                height: parent.height

                MaterialSymbol {
                    id: foldGlyph
                    anchors { top: parent.top; topMargin: 16; left: parent.left; leftMargin: 20 }
                    text: "left_panel_close"
                    iconSize: 20
                    color: foldArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                    MouseArea { id: foldArea; anchors { fill: parent; margins: -6 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.treeShown = false; root.refocus(); } }
                    StyledToolTip { text: "Fold the files (Ctrl+B)"; extraVisibleCondition: foldArea.containsMouse }
                }
                MaterialSymbol {
                    id: searchGlyph
                    anchors { right: parent.right; rightMargin: 22; verticalCenter: foldGlyph.verticalCenter }
                    text: "search"
                    iconSize: 19
                    color: findArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                    MouseArea { id: findArea; anchors { fill: parent; margins: -6 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: finder.open("files") }
                    StyledToolTip { text: "Find a file (Ctrl+P)"; extraVisibleCondition: findArea.containsMouse }
                }
                // the project heads the rail, as the session heads Praxis's page; it opens another project
                Item {
                    id: projectHead
                    anchors { left: foldGlyph.right; leftMargin: 14; right: searchGlyph.left; rightMargin: 12; top: parent.top; topMargin: 10 }
                    height: 44
                    Rectangle {
                        anchors { fill: parent; leftMargin: -8; rightMargin: -6; topMargin: -2; bottomMargin: -2 }
                        radius: 8
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, headArea.pressed ? 0.9 : headArea.containsMouse ? 0.95 : 1)
                        Behavior on color { ColorAnimation { duration: 110 } }
                    }
                    StyledText {
                        id: projectName
                        anchors { left: parent.left; top: parent.top; topMargin: 2 }
                        width: Math.min(implicitWidth, parent.width - 24)
                        text: project.name
                        elide: Text.ElideRight
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        color: Tacit.inkMain
                    }
                    MaterialSymbol {
                        anchors { left: projectName.right; leftMargin: 4; verticalCenter: projectName.verticalCenter }
                        text: "unfold_more"
                        iconSize: 17
                        color: headArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                    }
                    StyledText {
                        anchors { left: parent.left; right: parent.right; top: projectName.bottom; topMargin: 2 }
                        text: picker.home(project.root)
                        elide: Text.ElideMiddle
                        font.pixelSize: 13
                        color: Tacit.inkSec
                    }
                    MouseArea {
                        id: headArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickProject()
                    }
                    StyledToolTip { text: "Open another project (Ctrl+O)"; extraVisibleCondition: headArea.containsMouse }
                }

                // the one action, as Praxis's "New session"
                Item {
                    id: newRow
                    anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 64 }
                    height: 36
                    Rectangle {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                        radius: 8
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, newArea.pressed ? 0.86 : newArea.containsMouse ? 0.9 : 0.94)
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }
                    MaterialSymbol {
                        anchors { left: parent.left; leftMargin: 20; verticalCenter: parent.verticalCenter }
                        text: "note_add"
                        iconSize: 17
                        color: Tacit.inkMain
                    }
                    StyledText {
                        anchors { left: parent.left; leftMargin: 44; verticalCenter: parent.verticalCenter }
                        text: "New file"
                        font.pixelSize: 15
                        font.weight: Font.Medium
                        color: Tacit.inkMain
                    }
                    StyledText {
                        anchors { right: parent.right; rightMargin: 24; verticalCenter: parent.verticalCenter }
                        text: "Ctrl N"
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 13
                        color: Tacit.inkMeta
                    }
                    MouseArea { id: newArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.startNew(root.here(), "file") }
                }

                // what is live, as Praxis's "2 running": what has changed, or that nothing is tracked
                Item {
                    id: liveLine
                    readonly property int changed: Object.keys(project.changes).length
                    readonly property bool plain: project.loaded && !project.repo
                    anchors { left: parent.left; right: parent.right; top: newRow.bottom }
                    height: liveLine.changed > 0 || liveLine.plain ? 34 : 0
                    clip: true
                    Rectangle {
                        x: 24 + 4
                        anchors.verticalCenter: parent.verticalCenter
                        visible: liveLine.changed > 0
                        width: 8; height: 8; radius: 4
                        color: Tacit.accent
                    }
                    StyledText {
                        x: 44
                        anchors.verticalCenter: parent.verticalCenter
                        text: liveLine.plain ? "A folder · no change tracking" : `${liveLine.changed} changed`
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 14
                        color: Tacit.inkSec
                    }
                }

                // Praxis's section label: the files and their count
                Item {
                    id: filesLabel
                    anchors { left: parent.left; right: parent.right; top: liveLine.bottom }
                    height: 40
                    Row {
                        anchors { left: parent.left; leftMargin: 20; bottom: parent.bottom; bottomMargin: 8 }
                        spacing: 8
                        StyledText {
                            id: filesWord
                            text: "Files"
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            color: Tacit.inkSec
                        }
                        StyledText {
                            anchors.baseline: filesWord.baseline
                            visible: project.files.length > 0
                            text: project.files.length
                            font.family: Appearance.font.family.numbers
                            font.pixelSize: 14
                            color: Tacit.inkMeta
                        }
                    }
                }

                CodeTree {
                    id: tree
                    anchors { left: parent.left; right: parent.right; rightMargin: 1; top: filesLabel.bottom; topMargin: 2; bottom: parent.bottom; bottomMargin: 8 }
                    project: project
                    onOpenFile: rel => root.openFile(rel, false)
                    onWatchFile: rel => { if (root.typingAllowed) root.openFile(rel, true); }
                    // a picture, an archive, a compiled object: the desktop's opener, not this editor
                    onOpenElsewhere: rel => Quickshell.execDetached(["xdg-open", project.root + "/" + rel])
                    onMenuFor: (row, x, y) => root.menuFor(row, x, y)
                    onNamed: name => root.create(name)
                    onRenamed: (path, name) => root.rename(path, name)
                    onTrash: row => root.trash(row)
                }
            }
            }

            // the open files
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                CodeTabs {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    Layout.leftMargin: root.treeShown ? 8 : 52
                    docs: root.docs
                    current: root.current
                    glyphFor: tree.glyphFor
                    onPicked: i => root.show(i)
                    onCloseRequested: i => root.closeDoc(i)
                }
                Item {
                    id: stack
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    StyledText {
                        anchors.centerIn: parent
                        visible: root.docs.length === 0
                        text: "Pick a file on the left."
                        font.pixelSize: 16
                        color: Tacit.inkMeta
                    }
                }
                FindBar {
                    id: find
                    Layout.fillWidth: true
                    doc: root.cur
                    onClosed: root.refocus()
                }
                // The status line: what the cursor is at always wins the room, the file's path gives way first
                // (cut in its middle), then the language and indentation, then the typing switch; a narrow window
                // used to print them over each other.
                Item {
                    id: statusLine
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    readonly property bool narrow: statusLine.width < 640
                    readonly property real rightEdge: position.implicitWidth + 16 + (typingSwitch.visible ? typingSwitch.implicitWidth + 18 : 0)
                    // the open file, and the way back out to the desktop: a click shows it in
                    // Files (the same IPC call the Claude app's Files pane makes)
                    StyledText {
                        id: whichFile
                        anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                        width: Math.min(implicitWidth, Math.max(60, statusLine.width - 16 - statusLine.rightEdge - 28
                            - (root.note !== null || root.curState.length ? 140 : 0)))
                        elide: Text.ElideMiddle
                        text: root.cur ? root.docs[root.current].rel : ""
                        font.pixelSize: 13
                        color: whichArea.containsMouse ? Tacit.inkMain : Tacit.inkMeta
                        MouseArea {
                            id: whichArea
                            anchors { fill: parent; margins: -6 }
                            enabled: root.cur !== null
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Quickshell.execDetached(["qs", "-p", Directories.shellFile, "ipc", "call", "files", "reveal", project.root + "/" + root.docs[root.current].rel])
                        }
                        StyledToolTip { text: "Show in Files"; extraVisibleCondition: whichArea.containsMouse && root.cur !== null }
                    }
                    StyledText {
                        id: stateText
                        readonly property bool problems: root.curState.length === 0 && !!root.cur && root.cur.diagLine.length > 0
                        anchors { left: whichFile.right; leftMargin: 14; right: parent.right; rightMargin: statusLine.rightEdge + 12; verticalCenter: parent.verticalCenter }
                        visible: root.note === null && width > 40
                        text: root.curState.length ? root.curState : stateText.problems ? `⚠ ${root.cur.diagLine}` : ""
                        elide: Text.ElideRight
                        font.pixelSize: 13
                        color: !stateText.problems ? Tacit.accent : root.cur.diagIsError ? Tacit.risk : Tacit.inkSec
                        MouseArea {
                            anchors.fill: parent
                            enabled: stateText.problems
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.cur.nextProblem(false)
                        }
                        StyledToolTip { text: "Next problem (F8)"; extraVisibleCondition: stateText.problems && parent.children[0].containsMouse }
                    }
                    Item {
                        anchors { left: whichFile.right; leftMargin: 14; right: parent.right; rightMargin: statusLine.rightEdge + 12; top: parent.top; bottom: parent.bottom }
                        opacity: root.note !== null ? 1 : 0
                        Behavior on opacity { Anim { type: Anim.FastEffects } }
                        visible: opacity > 0
                        StyledText {
                            id: noteText
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, parent.width - (noteAction.visible ? noteAction.implicitWidth + 12 : 0))
                            elide: Text.ElideRight
                            text: root.lastNote ? root.lastNote.text : ""
                            font.pixelSize: 13
                            color: Tacit.inkSec
                        }
                        StyledText {
                            id: noteAction
                            anchors { left: noteText.right; leftMargin: 12; verticalCenter: parent.verticalCenter }
                            visible: !!root.lastNote && root.lastNote.label.length > 0
                            text: root.lastNote ? root.lastNote.label : ""
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            color: noteArea.containsMouse ? Tacit.inkMain : Tacit.accent
                            MouseArea {
                                id: noteArea
                                anchors { fill: parent; margins: -6 }
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { const n = root.note; root.note = null; if (n && n.run) n.run(); }
                            }
                        }
                    }
                    // the typing switch, as quiet as the rest of the line
                    StyledText {
                        id: typingSwitch
                        anchors { right: position.left; rightMargin: 18; verticalCenter: parent.verticalCenter }
                        visible: root.typingAllowed && !statusLine.narrow
                        text: root.typing ? "Typing on" : "Typing off"
                        font.pixelSize: 13
                        color: typingArea.containsMouse ? Tacit.inkMain : Tacit.inkMeta
                        MouseArea { id: typingArea; anchors { fill: parent; margins: -6 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.setTyping(!root.typing) }
                        StyledToolTip { text: "Type out changes (Ctrl+Alt+T)"; extraVisibleCondition: typingArea.containsMouse }
                    }
                    StyledText {
                        id: position
                        anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                        text: root.cur ? `Ln ${root.cur.line}, Col ${root.cur.column}`
                            + (statusLine.narrow ? "" : `   ${root.cur.indentName}${root.cur.language ? "   " + root.cur.language : ""}`) : ""
                        font.pixelSize: 13
                        font.family: Appearance.font.family.numbers
                        color: Tacit.inkMeta
                    }
                }
            }
        }

        // folded, the toggle stays where it was, as Praxis's does
        MaterialSymbol {
            x: 20
            y: 16
            visible: !root.treeShown && project.root.length > 0 && !root.picking
            text: "left_panel_open"
            iconSize: 20
            color: unfoldArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
            MouseArea { id: unfoldArea; anchors { fill: parent; margins: -6 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.treeShown = true }
            StyledToolTip { text: "Show the files (Ctrl+B)"; extraVisibleCondition: unfoldArea.containsMouse }
        }

        Finder {
            id: finder
            anchors.fill: parent
            project: project
            glyphFor: tree.glyphFor
            typed: root.typed
            onChosen: (rel, line) => { root.openFile(rel, false); if (line > 0 && root.cur) root.cur.goToLine(line); }
            onClosed: root.refocus()
        }

        ProjectPicker {
            id: picker
            anchors.fill: parent
            readonly property bool shown: project.root.length === 0 || root.picking
            opacity: shown ? 1 : 0
            Behavior on opacity { Anim { type: Anim.FastEffects } }
            visible: opacity > 0
            enabled: shown
            recents: root.recents()
            canGoBack: root.picking
            onChosen: dir => root.chooseProject(dir)
            onBack: { root.picking = false; root.refocus(); }
        }

        CodeMenu {
            id: menu
            onClosed: root.refocus()
        }

        // a question that needs an answer: a bar along the bottom, never a pop-up window
        Rectangle {
            id: askBar
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 44 }
            visible: root.ask !== null
            width: askRow.implicitWidth + 32
            height: 60
            radius: Tacit.radius.panel
            color: Appearance.m3colors.m3surfaceContainerHigh
            border.width: 1
            border.color: Tacit.hairline
            // the keyboard sits on one of the answers (Left/Right move it), drawn as that ring lifted
            function focusAnswer() { const b = answers.itemAt(root.askAt); if (b) b.forceActiveFocus(); else askBar.forceActiveFocus(); }
            onVisibleChanged: if (askBar.visible) { root.askAt = 0; askBar.focusAnswer(); askIn.restart(); }
            ParallelAnimation {
                id: askIn
                Anim { target: askBar; property: "opacity"; from: 0; to: 1; type: Anim.FastEffects }
                Anim { target: askBar; property: "anchors.bottomMargin"; from: 30; to: 44; type: Anim.FastSpatial }
            }
            Keys.onReturnPressed: root.answer(root.askAt)
            Keys.onEnterPressed: root.answer(root.askAt)
            Keys.onEscapePressed: root.answer(root.ask ? (root.ask.esc ?? root.ask.buttons.length - 1) : 0)
            Keys.onLeftPressed: { root.askAt = Math.max(0, root.askAt - 1); askBar.focusAnswer(); }
            Keys.onRightPressed: { if (root.ask) root.askAt = Math.min(root.ask.buttons.length - 1, root.askAt + 1); askBar.focusAnswer(); }
            Row {
                id: askRow
                anchors.centerIn: parent
                spacing: 10
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.ask ? root.ask.text : ""
                    font.pixelSize: 15
                    color: Tacit.inkMain
                    rightPadding: 8
                }
                // Tacit's rings: the way forward in sand, what loses work in the risk colour with its warning
                Repeater {
                    id: answers
                    model: root.ask ? root.ask.buttons : []
                    delegate: Slab {
                        required property var modelData
                        required property int index
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        tone: modelData.accent ? "default" : modelData.risk ? "risk" : ""
                        on: askBar.color
                        onPicked: root.answer(index)
                    }
                }
            }
        }
    }
}
