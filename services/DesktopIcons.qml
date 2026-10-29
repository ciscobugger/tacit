pragma Singleton
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * The files of the person's Desktop folder, shown on the desktop as tags (modules/ii/desktopIcons).
 * This keeps what the tags need: the list, where a person has put each one (saved by file name in
 * state/user/desktopicons.json), what is selected, and the actions. Every file operation is a Files
 * job (Jobs, scripts/files/job.sh), so each one has its Undo and reports as Files' do.
 * A file with no saved place joins the column; one that has been moved keeps where it was put.
 */
Singleton {
    id: root

    readonly property string home: FileUtils.trimFileProtocol(Directories.home)
    property string dir: root.home + "/Desktop"
    property bool hidden: false
    property var places: ({})          // file name -> [x, y]
    property var entries: []           // [{ name, path, dir, glyph, picture }], folders first, then oldest first
    property var selected: []          // names
    property string cursor: ""         // the keyboard's tag
    property string editing: ""        // the tag whose name is a field
    property int dropCount: 0          // files held over the desktop (the ghost tag says what letting go does)
    property bool dropArmed: false     // a picture held long enough to become the wallpaper: no ghost then
    readonly property bool dropShown: root.dropCount > 0 && !root.dropArmed && !root.hidden
    property string undoJob: ""        // the last finished job of ours that has an undo
    signal said(string text, string words)   // the line for the Notice; words "Undo" or ""

    // ------------------------------------------------------------------ the folder
    Process {
        id: whereProc
        running: true
        command: ["bash", "-c", "d=$(xdg-user-dir DESKTOP 2>/dev/null); [ -z \"$d\" -o \"$d\" = \"$HOME\" ] && d=\"$HOME/Desktop\"; mkdir -p \"$d\"; printf '%s' \"$d\""]
        stdout: StdioCollector {
            onStreamFinished: if (text.trim().length > 0) root.dir = text.trim()
        }
    }
    FolderListModel {
        id: folder
        folder: "file://" + root.dir.split("/").map(encodeURIComponent).join("/")
        showDirs: true
        showFiles: true
        showHidden: false
        showDotAndDotDot: false
        sortField: FolderListModel.Name
    }
    Connections {
        target: folder
        function onCountChanged() { rebuild.restart(); }
        function onStatusChanged() { rebuild.restart(); }
        function onDataChanged() { rebuild.restart(); }
    }
    Timer { id: rebuild; interval: 40; onTriggered: root.refresh() }

    function refresh() {
        const list = [];
        for (let i = 0; i < folder.count; i++) {
            const name = folder.get(i, "fileName");
            const isDir = folder.get(i, "fileIsDir");
            const path = FileUtils.trimFileProtocol(folder.get(i, "filePath").toString());
            const kind = Things.kindOf(path + (isDir ? "/" : ""));
            list.push({
                "name": name, "path": path, "dir": isDir,
                "glyph": Things.glyphFor(kind),
                "picture": !isDir && /\.(jpe?g|png|webp|gif|bmp)$/i.test(name) ? "file://" + path.split("/").map(encodeURIComponent).join("/") : "",
                "at": folder.get(i, "fileModified").getTime()
            });
        }
        // folders first, then the oldest: a new file joins the end of the column
        list.sort((a, b) => (a.dir === b.dir ? 0 : a.dir ? -1 : 1) || a.at - b.at || a.name.localeCompare(b.name));
        root.entries = list;
        const have = list.map(e => e.name);
        root.selected = root.selected.filter(n => have.includes(n));
        if (!have.includes(root.cursor))
            root.cursor = "";
    }
    function entry(name) { return root.entries.find(e => e.name === name) ?? null; }
    readonly property var placed: root.entries.filter(e => root.places[e.name] !== undefined)
    readonly property var joined: root.entries.filter(e => root.places[e.name] === undefined)

    // ------------------------------------------------------------------ what is saved
    readonly property string filePath: FileUtils.trimFileProtocol(`${Directories.state}/user/desktopicons.json`)
    property bool loaded: false
    function save() {
        if (root.loaded)
            saveTimer.restart();
    }
    Timer { id: saveTimer; interval: 400; onTriggered: stateFile.setText(JSON.stringify({ "hidden": root.hidden, "places": root.places })) }
    FileView {
        id: stateFile
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try {
                const s = JSON.parse(stateFile.text());
                root.hidden = s.hidden === true;
                const p = ({});
                for (const k in (s.places ?? ({})))
                    if (Array.isArray(s.places[k]) && s.places[k].length === 2)
                        p[k] = s.places[k];
                root.places = p;
            } catch (e) {}
            root.loaded = true;
        }
        onLoadFailed: root.loaded = true
        Component.onCompleted: reload()
    }
    function setHidden(v) {
        root.hidden = v;
        root.save();
    }
    function place(map) {   // { name: [x, y] }
        root.places = Object.assign({}, root.places, map);
        root.save();
    }

    // ------------------------------------------------------------------ selection
    function selectOnly(name) { root.selected = name === "" ? [] : [name]; root.cursor = name; }
    function toggle(name) {
        root.selected = root.selected.includes(name) ? root.selected.filter(n => n !== name) : root.selected.concat([name]);
        root.cursor = name;
    }
    function extendTo(name) {
        const names = root.entries.map(e => e.name);
        const a = names.indexOf(root.cursor === "" ? name : root.cursor), b = names.indexOf(name);
        if (a < 0 || b < 0) { root.selectOnly(name); return; }
        root.selected = names.slice(Math.min(a, b), Math.max(a, b) + 1);
        root.cursor = name;
    }
    function selectAll() { root.selected = root.entries.map(e => e.name); }
    function clear() { root.selected = []; root.cursor = ""; root.editing = ""; }

    // ------------------------------------------------------------------ actions (Files' jobs)
    readonly property var mine: ({})    // job id -> the sentence to say when it is done ("" = the job's own)
    function run(op, args, sentence) {
        const id = Jobs.start(op, args);
        root.mine[id] = sentence ?? "";
        return id;
    }
    Connections {
        target: Jobs
        function onJobFinished(job) {
            if (root.mine[job.id] === undefined)
                return;
            const sentence = root.mine[job.id];
            delete root.mine[job.id];
            if (job.state === "done" && job.undo)
                root.undoJob = job.id;
            if (job.state === "done" && job.op === "rename" && job.undo)
                return;                                        // the name changing in the tag is the answer
            root.said(job.state === "done" && sentence.length > 0 ? sentence : Jobs.label(job), job.state === "done" && job.undo ? "Undo" : "");
        }
    }
    Connections {
        target: Things
        function onOpenFailed(path, why) { if (path.startsWith(root.dir + "/")) root.said(why, ""); }
    }
    function undo() {
        if (root.undoJob.length === 0)
            return;
        const id = Jobs.undo(root.undoJob);
        root.undoJob = "";
        if (id)
            root.mine[id] = "";
    }
    function open(name) {
        const e = root.entry(name);
        if (!e)
            return;
        if (e.dir)
            Files.open(e.path, "");
        else
            Things.open(e.path);
    }
    function trash(names) {
        const paths = names.map(n => root.entry(n)?.path ?? "").filter(p => p.length > 0);
        if (paths.length === 0)
            return;
        root.run("trash", paths);
        root.selected = [];
    }
    function nameTaken(name, except) {
        return root.entries.some(e => e.name === name && e.name !== except);
    }
    function rename(name, to) {
        const e = root.entry(name);
        const clean = (to ?? "").trim();
        root.editing = "";
        if (!e || clean.length === 0 || clean === name || clean.includes("/") || root.nameTaken(clean, name))
            return;
        if (root.places[name] !== undefined) {
            const p = Object.assign({}, root.places);
            p[clean] = p[name];
            delete p[name];
            root.places = p;
            root.save();
        }
        root.selected = [clean];
        root.cursor = clean;
        root.run("rename", [e.path, clean]);
    }
    // files dropped on the desktop: Files' own drag moves, others copy; Ctrl forces a copy, Shift a move
    function put(urls, modifiers, internal) {
        const paths = urls.map(u => FileUtils.trimFileProtocol((() => { try { return decodeURIComponent(u.toString()); } catch (e) { return u.toString(); } })()))
            .filter(p => p.length > 0 && p !== root.dir && !root.dir.startsWith(p + "/"));
        const op = (modifiers & Qt.ControlModifier) ? "copy" : (modifiers & Qt.ShiftModifier) ? "move" : (internal ? "move" : "copy");
        const list = paths.filter(p => !(op === "move" && Files.parent(p) === root.dir));
        if (list.length === 0)
            return;
        root.run(op, ["keep", root.dir].concat(list), `Put ${Voice.count(list.length, "file")} on the Desktop`);
    }
}
