import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.tacit

/**
 * A Files window: rail | header, list or grid, status line. One frost body, one hairline
 * under the header, no other chrome. The folder model lists and watches; selection, cursor,
 * history and the filter live here. Keys first: Enter opens, Backspace goes up, Alt+arrows
 * walk history, Ctrl+L edits the path, Ctrl+F filters this folder, Ctrl+Shift+F searches the
 * tree under it, Ctrl+H shows hidden files, Ctrl+1/2
 * list/grid, Ctrl+Shift+C copies the path, Ctrl+Shift+T opens a terminal here, Ctrl+W
 * closes; typing jumps to a name; Escape clears the filter, then the selection.
 */
FloatingWindow {
    id: win

    property string folder: Files.home
    property string selectPath: ""
    property string reason: ""

    title: "Files"
    color: "transparent"
    // Opens the way it was left (services/Files.qml windowState): this size when floating;
    // tiled or maximised again through the compositor, a moment after it maps.
    implicitWidth: Files.windowState.w
    implicitHeight: Files.windowState.h
    minimumSize: Qt.size(640, 400)
    visible: true
    signal closing()
    onVisibleChanged: {
        if (!visible) {
            win.rememberShape();
            win.closing();
            Files.setWindowFolder(win.hyprAddress, "");
            // a pick window closed without Choose or Cancel: the pick is over, or the next
            // Files window would open as a picker
            if (win.forPick && Files.picking !== null)
                Files.pickDone([]);
            // A drag still out when the window goes: the source would die with it, and Qt reads
            // it when the target asks for the files. Cancelling does not stop a running drag,
            // so the window stays alive (already hidden) until the drop has been served.
            if (dragProxy.Drag.active)
                closeTimer.restart();
            else
                win.destroy();
        }
    }
    Timer {
        id: closeTimer
        interval: 150
        repeat: true
        property int tries: 0
        onTriggered: {
            if (!dragProxy.Drag.active || ++tries > 60) {   // 9s, then go anyway
                stop();
                win.destroy();
            }
        }
    }
    Component.onCompleted: {
        win.forPick = Files.picking !== null;
        Files.windows++;
        restoreTimer.restart();
        addressTimer.restart();
    }
    Component.onDestruction: {
        Files.windows--;
        Files.releaseAddress(win.hyprAddress);
    }

    // The compositor's view of this window: floating? maximised? This window is made by the
    // shell instance, so it carries the shell's own appId (Quickshell.appId) rather than one of
    // its own the way Praxis and Graphis do. Every Files window carries
    // the same class and title (the Hyprland rules match on them) and two of them open at the
    // same remembered size, so a size match could answer with the other window's client - and
    // then Super+E raised it and its floating state was written over ours. The address is
    // taken once instead, from the window that has just mapped, which is the focused one.
    property string hyprAddress: ""
    // what this window shows, for `files windows`
    onHyprAddressChanged: Files.setWindowFolder(win.hyprAddress, win.folder)
    onFolderChanged: {
        Files.setWindowFolder(win.hyprAddress, win.folder);
        folderIn.restart();
        freeProbe.running = false;
        freeProbe.running = true;   // the room left on this folder's disk
    }
    Anim { id: folderIn; target: filesArea; property: "opacity"; from: 0.3; to: 1; type: Anim.FastEffects }
    function client() {
        if (win.hyprAddress.length > 0)
            return HyprlandData.windowByAddress[win.hyprAddress] ?? null;
        const mine = ToplevelManager.toplevels.values.filter(t => (t.appId ?? "") === Quickshell.appId && t.title === win.title);
        for (const t of mine) {
            const c = HyprlandData.windowByAddress[`0x${t.HyprlandToplevel?.address ?? ""}`];
            if (c && Math.abs((c.size?.[0] ?? 0) - win.width) <= 2 && Math.abs((c.size?.[1] ?? 0) - win.height) <= 2)
                return c;
        }
        return mine.length === 1 ? HyprlandData.windowByAddress[`0x${mine[0].HyprlandToplevel?.address ?? ""}`] ?? null : null;
    }
    // this window inside a `hyprctl clients` list
    function meIn(list) {
        if (win.hyprAddress.length > 0)
            return list.find(x => x.address === win.hyprAddress) ?? null;
        return list.find(x => x.class === Quickshell.appId && x.title === win.title
            && Math.abs(x.size[0] - win.width) <= 2 && Math.abs(x.size[1] - win.height) <= 2) ?? null;
    }
    Timer {
        id: addressTimer
        interval: 150
        repeat: true
        property int tries: 0
        onTriggered: {
            if (win.hyprAddress.length > 0 || ++tries > 20) {
                stop();
                return;
            }
            const t = ToplevelManager.activeToplevel;
            const a = t?.HyprlandToplevel?.address ? `0x${t.HyprlandToplevel.address}` : "";
            if (a.length > 0 && (t.appId ?? "") === Quickshell.appId && t.title === win.title && !Files.addressTaken(a)) {
                win.hyprAddress = a;
                Files.takeAddress(a);
                stop();
            }
        }
    }
    function rememberShape() {
        // a pick window floats by its nature; its shape says nothing about how Files is kept
        if (win.forPick || Date.now() < win.settleUntil)
            return;
        const c = win.client();
        if (win.dock?.tiled && c && c.floating)   // un-tiled by the keyboard (Super+Alt+Space)
            win.dock = null;
        if (win.dock?.tiled) {   // left as a tile: comes back as one (where there are tiles)
            Files.rememberWindow({ "floating": false, "maximised": false });
            return;
        }
        const floating = c ? !!c.floating : true;
        const maximised = c ? (c.fullscreen === 1 || c.fullscreen === true) : false;
        // the floating size is the one worth keeping; a tile's or a maximised size is the screen's
        if (floating && !maximised)
            Files.rememberWindow({ "w": win.width, "h": win.height, "floating": true, "maximised": false });
        else
            Files.rememberWindow({ "floating": floating, "maximised": maximised });
    }
    // ------------------------------------------------------------------ the drop
    // Super+drag is the compositor's; Files judges the drop the moment the button is let go
    // (the release bind calls `files drop`), or when Super is let go, if the window moved.
    //
    // At the left or right edge it joins the tiling layout on that side; nothing else on
    // the screen is touched - other windows are yours, and the compositor lays them out. A
    // tile dropped in the middle of the screen pulls out and floats at its own size, centred.
    // At the top edge it fills the screen.
    property var dragFrom: null
    property bool dragged: false
    property bool dropDone: false
    property var dock: null      // { side, tiled }: which half or side of the layout it holds
    property real settleUntil: 0   // no shape is remembered while windows are still gliding
    function moving(ms) { win.settleUntil = Date.now() + ms; }

    // Super pressed: one look at where the window is. Super released: one look at where it
    // is now; moved = a drag to judge. (No polling in between: a process every 150 ms on the
    // GUI thread was felt in the drag itself.)
    Connections {
        target: GlobalStates
        function onSuperDownChanged() {
            if (!win.visible)
                return;
            if (GlobalStates.superDown) {
                win.dragFrom = null;
                win.dragged = false;
                win.dropDone = false;
                dropProbe.judge = false;
                dropProbe.running = true;
            } else {
                dropTimer.restart();
                lateDropTimer.restart();
            }
        }
    }
    Connections {
        target: Files
        function onDragStartRequested() {
            if (win.visible) {
                dropProbe.judge = false;
                dropProbe.begin = true;
                dropProbe.running = true;
            }
        }
        function onDropRequested() {
            if (win.visible) {
                win.dragged = true;
                win.dropDone = false;
                dropProbe.judge = true;
                dropProbe.running = true;
            }
        }
    }
    Timer { id: dropTimer; interval: 60; onTriggered: { dropProbe.judge = true; dropProbe.running = true; } }
    Timer { id: lateDropTimer; interval: 800; onTriggered: { dropProbe.judge = true; dropProbe.running = true; } }
    Process {
        id: dropProbe
        property bool judge: false
        property bool begin: false
        command: ["bash", "-c", "hyprctl -j cursorpos; echo '@@'; hyprctl -j clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                const b = dropProbe.begin;
                dropProbe.begin = false;
                if (b)
                    win.onDragBegin(text);
                else
                    win.onProbe(text, dropProbe.judge);
            }
        }
    }
    // Super + button down on a maximised Files window: the compositor will not drag it, so
    // it becomes a floating window first, its own size, under the cursor (the hand keeps
    // the same place across its width, as on every desktop that does this).
    function onDragBegin(text) {
        let cursor = null, list = [];
        try {
            const parts = text.split("@@");
            cursor = JSON.parse(parts[0]);
            list = JSON.parse(parts[1]);
        } catch (e) { return; }
        const c = win.meIn(list);
        if (!c || c.fullscreen !== 1 || Attention.address !== c.address)
            return;
        const screen = Quickshell.screens[0];
        const top = HyprlandData.monitors[0]?.reserved?.[1] ?? 0;
        const w = Files.windowState.w, h = Files.windowState.h;
        win.moving(1500);
        Hyprland.dispatch('hl.dsp.window.fullscreen({ mode = "maximized", action = "unset" })');
        // NOTE: window.float "set" TOGGLES in this Lua API (verified 2026-09-10): only flip
        // a window that is not floating already. Unmaximising restores the mode it had.
        if (!c.floating)
            Hyprland.dispatch('hl.dsp.window.float({ action = "set" })');
        placeTimer.address = c.address;
        placeTimer.at = [Math.round(cursor.x - w * (cursor.x / screen.width)), Math.max(top, Math.round(cursor.y - 24))];
        placeTimer.restart();
    }

    function placeWindow(address, x, y, w, h) {
        Hyprland.dispatch(`hl.dsp.focus({ window = "address:${address}" })`);
        Hyprland.dispatch(`hl.dsp.window.resize({ x = ${w}, y = ${h}, "exact" })`);
        Hyprland.dispatch(`hl.dsp.window.move({ x = ${x}, y = ${y}, "exact" })`);
    }
    // Back to itself: Files at its own size in the middle.
    // (floatFirst: the window is tiled now; window.float "set" toggles, so it is called once.)
    function undock(floatFirst) {
        win.dock = null;
        win.moving(1500);
        const me = win.client();
        if (!me)
            return;
        Hyprland.dispatch(`hl.dsp.focus({ window = "address:${me.address}" })`);
        if (floatFirst)
            Hyprland.dispatch('hl.dsp.window.float({ action = "set" })');
        // the size and place a beat later: the float takes a frame, and a resize sent in
        // the same breath would land on the tile and be lost
        placeTimer.address = me.address;
        placeTimer.restart();
    }
    Timer {
        id: placeTimer
        property string address: ""
        property var at: null    // a place to land; null = the centre
        interval: 90
        onTriggered: {
            const screen = Quickshell.screens[0];
            const top = HyprlandData.monitors[0]?.reserved?.[1] ?? 0;
            const w = Files.windowState.w, h = Files.windowState.h;
            const p = at ?? [Math.round((screen.width - w) / 2), Math.round(top + (screen.height - top - h) / 2)];
            at = null;
            win.placeWindow(address, p[0], p[1], w, h);
        }
    }

    function onProbe(text, judge) {
        let cursor = null, list = [];
        try {
            const parts = text.split("@@");
            cursor = JSON.parse(parts[0]);
            list = JSON.parse(parts[1]);
        } catch (e) { return; }
        const c = win.meIn(list);
        if (!c)
            return;
        if (!judge) {
            win.dragFrom = c.at;
            return;
        }
        // the Super-release path: only a window that moved since Super went down is a drop
        if (!win.dragged && win.dragFrom !== null && (c.at[0] !== win.dragFrom[0] || c.at[1] !== win.dragFrom[1]))
            win.dragged = true;
        if (win.dropDone || !win.dragged || c.fullscreen || Attention.address !== c.address)
            return;
        const screen = Quickshell.screens[0];
        const W = screen.width, H = screen.height;
        const top = HyprlandData.monitors[0]?.reserved?.[1] ?? 0;
        const edge = 14;
        const cursorAtEdge = cursor.x <= edge || cursor.x >= W - 1 - edge || cursor.y <= top + edge;
        const side = c.at[0] <= edge ? "l" : c.at[0] + c.size[0] >= W - edge ? "r" : "";

        // A tile: the compositor's drag already put it where it was dropped. Dropped in
        // the middle of the screen it pulls out and floats; anywhere else it stays a tile,
        // and Files only notes which side it landed on.
        if (!c.floating) {
            const third = W / 3;
            if (cursor.x > third && cursor.x < W - third && cursor.y > top + edge) {
                win.dropDone = true;
                win.dragged = false;
                win.undock(true);
                return;
            }
            win.dock = { "side": side || (c.at[0] + c.size[0] / 2 < W / 2 ? "l" : "r"), "tiled": true };
            return;
        }
        if (win.dock)   // floating again after a tile (Super+Alt+Space): a plain floating window now
            win.dock = null;
        if (side === "" && c.at[1] <= top + edge) {
            win.dropDone = true;
            win.dragged = false;
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${c.address}" })`);
            Hyprland.dispatch('hl.dsp.window.fullscreen({ mode = "maximized", action = "set" })');
            return;
        }
        if (side === "")
            return;
        win.dropDone = true;
        win.dragged = false;
        win.moving(1500);
        // An edge: join the layout on that side. This is a tiling desktop; a tile beside the
        // others is what an edge means here. (Alone on a workspace it simply fills it.)
        win.dock = { "side": side, "tiled": true };
        Hyprland.dispatch(`hl.dsp.focus({ window = "address:${c.address}" })`);
        // One relayout only: dwindle splits on the side the cursor is on (force_split 0), and
        // the cursor is at that edge. Pushing the tile further with extra moves re-laid the
        // neighbours out several times in a few ms, and a terminal was left half-drawn.
        Hyprland.dispatch('hl.dsp.window.float({ action = "set" })');   // toggles: floating -> tiled
    }
    Timer {   // keep the shape current while open, so a crash or reload loses nothing
        interval: 2000
        running: win.visible
        repeat: true
        onTriggered: win.rememberShape()
    }
    Timer {
        id: restoreTimer
        interval: 350
        property int waits: 0
        onTriggered: {
            // a pick floats over the app that asked: it never goes back into the tiles
            if (win.forPick)
                return;
            // These act on a window, and without this one's address they acted on whichever had the keyboard: a
            // Files window opened without focus maximised or un-floated somebody else's. Wait for the address.
            if (win.hyprAddress.length === 0) {
                if (++waits < 12) restart();
                return;
            }
            const s = Files.windowState;
            if (s.floating && s.maximised)
                Hyprland.dispatch(`hl.dsp.window.fullscreen({ mode = "maximized", action = "set", window = "address:${win.hyprAddress}" })`);
            else if (!s.floating)
                restoreProbe.running = true;   // tiled last time: only if that would be visible now
        }
    }
    // A tile under a screen-sized floating window is invisible (floats sit above tiles). If
    // that is what the workspace looks like now, the window stays floating instead.
    Process {
        id: restoreProbe
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let list = [];
                try { list = JSON.parse(text); } catch (e) { return; }
                const screen = Quickshell.screens[0];
                const me = win.meIn(list);
                const others = list.filter(x => x.mapped && x.address !== me?.address && x.workspace?.id === me?.workspace?.id);
                const tiles = others.filter(x => !x.floating);
                const bigFloat = others.some(x => x.floating && x.fullscreen === 0 && x.size[0] * x.size[1] >= screen.width * screen.height * 0.6);
                if (me && (tiles.length > 0 || !bigFloat))
                    Hyprland.dispatch(`hl.dsp.window.float({ action = "unset", window = "address:${me.address}" })`);
            }
        }
    }

    // ------------------------------------------------------------------ state
    property var history: [win.folder]
    property int historyIndex: 0
    property var selectedMap: ({})
    readonly property var selectedPaths: Object.keys(win.selectedMap)
    // The keyboard's row is held as a path, and the index derived from it. A download
    // landing or an agent writing a file shifts every index under the window, and a bare
    // index then sent Enter, F2 and the preview column to another file than the highlighted one.
    property string cursorPath: ""
    readonly property int cursor: win.cursorPath.length > 0 && win.cursorPath in win.rowByPath ? win.rowByPath[win.cursorPath] : -1
    property int anchorIndex: -1
    property string query: ""
    property bool showHidden: false
    property string view: Files.viewFor(win.folder) || "list"   // "list" | "grid"; go() re-reads per folder
    property int sortField: FolderListModel.Name
    property bool sortReversed: false
    property string flashPath: ""
    // The filter is ours, not the model's: FolderListModel hands nameFilters to QDir
    // together with QDir::AllDirs, which is defined as never applying them to a directory
    // name, so every subfolder survived a filter and the box looked dead in a folder of
    // folders. The list keeps the hidden rows in the model and gives them no height; the
    // grid cannot leave a hole in its lattice, so there the model filters and drops
    // directories while a filter is on.
    readonly property string queryLower: win.query.toLowerCase()
    readonly property bool gridFiltering: win.view === "grid" && win.query.length > 0
    function nameShown(name) {
        return win.query.length === 0 || win.gridFiltering || (name + "").toLowerCase().includes(win.queryLower);
    }
    function rowShown(i) {
        return win.nameShown(folderModel.get(i, "fileName"));
    }
    // The next row the filter keeps, from i in direction dir; -1 past the end.
    function nextShown(i, dir) {
        let k = i;
        while (k >= 0 && k < folderModel.count && !win.rowShown(k))
            k += dir;
        return k >= 0 && k < folderModel.count ? k : -1;
    }
    // One walk of the listing, kept for the things that used to walk it themselves: the row
    // of a path (the cursor and the reveal resolve through it), the folder's names (the
    // rename field's "already here"), and how many rows the filter keeps.
    property var rowByPath: ({})
    property var dirPaths: ({})    // listed folders, for picking a folder
    property var names: ({})
    property int shownCount: 0
    function relist() {
        const n = folderModel.count;
        let byPath = ({}), names = ({}), dirs = ({}), shown = 0;
        for (let i = 0; i < n; i++) {
            const name = folderModel.get(i, "fileName") + "";
            names[name] = true;
            byPath[folderModel.get(i, "filePath")] = i;
            if (folderModel.get(i, "fileIsDir"))
                dirs[folderModel.get(i, "filePath")] = true;
            if (win.nameShown(name))
                shown++;
        }
        win.rowByPath = byPath;
        win.dirPaths = dirs;
        win.names = names;
        win.shownCount = shown;
    }
    onQueryChanged: win.relist()
    onViewChanged: win.editingIndex = -1   // the field belongs to a list row; the grid has none
    // Selected paths whose file is no longer listed: an external delete or rename would
    // otherwise leave "3 selected" naming files that are gone, and Delete would forward one.
    function pruneSelection() {
        const keep = win.selectedPaths.filter(p => p in win.rowByPath);
        if (keep.length === win.selectedPaths.length)
            return;
        let next = ({});
        for (const p of keep)
            next[p] = true;
        win.selectedMap = next;
    }
    // Deep search: Enter in the box runs fd below this folder; the hits stream into their own
    // list as they arrive (the first rows show before the search ends), each with its place
    // under this folder. Escape brings the folder back.
    property bool searching: false
    property string searchQuery: ""
    property var hits: []          // [{ path, name, rel, isDir }]
    property bool searchRunning: false
    property int searchCursor: -1
    property bool editingPath: false
    property string jumpBuffer: ""
    readonly property string home: Files.home
    // The third column: on its own when the window is wide enough to afford it (a full
    // window means browse and look at once); Space toggles it in a small one.
    property bool previewToggled: false
    // Room for the third column: a wide window, or a tall half beside another window (that
    // is where its actions are most useful: the other window is in view).
    readonly property bool wide: win.width >= 1240 || (win.width >= 900 && win.height >= 800)
    // The rail folds to glyphs by its own toggle (Ctrl+B too), remembered; a very narrow
    // window folds it regardless. Folded, it expands over the list while the pointer rests on it.
    readonly property bool railCompact: Files.railPref === "compact" || win.width < 720
    // no column over a search, the shelf, Recent or Large & old: those rows are their own view
    readonly property bool previewOpen: !win.searching && (win.wide ? !win.previewToggled : win.previewToggled)
    readonly property string previewPath: win.cursor >= 0 && win.selectedPaths.length > 0 ? win.cursorPath : ""
    readonly property double folderBytes: {
        let total = 0;
        const n = Math.min(folderModel.count, 2000);
        for (let i = 0; i < n; i++)
            if (!folderModel.get(i, "fileIsDir"))
                total += folderModel.get(i, "fileSize");
        return total;
    }
    function actionsFor(i) {
        const p = win.pathAt(i);
        if (p.length === 0)
            return [];
        const isDir = folderModel.get(i, "fileIsDir");
        if (win.inTrash)
            return (win.atTrashRoot
                ? [{ "id": "restore", "label": "Put back", "glyph": "restore_from_trash", "run": () => { if (!win.selectedMap[p]) win.selectOnly(i); win.restoreSelection(); } }]
                : []).concat([{ "id": "delete", "label": "Delete for good", "glyph": "delete_forever", "run": () => { if (!win.selectedMap[p]) win.selectOnly(i); win.deleteSelection(); } }]);
        if (!isDir) {
            const acts = Things.actions(p).filter(a => a.id !== "show");
            acts.splice(1, 0, { "id": "openwith", "label": "Open with…", "glyph": "apps", "run": () => win.openWith(p) });
            if (Things.kindOf(p) === "archive" && !/\.(iso|dmg)$/i.test(p))
                acts.splice(2, 0, { "id": "extract", "label": "Unpack here", "glyph": "unarchive", "run": () => win.run("extract", [p]) });
            return acts.concat(win.rowOps(p));
        }
        return isDir
            ? [{ "id": "open", "label": "Open", "glyph": "folder_open", "run": () => win.go(p) },
               { "id": "terminal", "label": "Open in terminal", "glyph": "terminal", "run": () => Quickshell.execDetached(["foot", "-D", p]) },
               Files.pins.includes(p) ? { "id": "unpin", "label": "Unpin from the rail", "glyph": "keep_off", "run": () => Files.unpin(p) }
                                      : { "id": "pin", "label": "Pin to the rail", "glyph": "push_pin", "run": () => Files.pin(p) },
               { "id": "park", "label": "Park on the shelf", "glyph": "stacks", "run": () => DropShelf.addItems(["file://" + p + "/"]) },
               { "id": "hand", "label": "Hand to Praxis", "glyph": "smart_toy", "run": () => Recents.launch(p, "Look around this folder. What is here, and what should I know about it?") },
               { "id": "path", "label": "Copy path", "glyph": "content_copy", "run": () => Things.copyPath(p) }].concat(win.rowOps(p))
            : [];
    }
    // Rename, the clipboard, the trash and Send to on a single item's own menu, not only on
    // a multi-selection's: without them a pointer could not rename, copy, cut or trash at
    // all. The row is resolved from its path when the action runs, not from the index it
    // had when the menu opened.
    function rowOps(p) {
        const ensure = () => { if (!win.selectedMap[p]) win.selectOnly(win.rowOf(p)); };
        return [
            { "id": "rename", "label": "Rename", "glyph": "edit", "run": () => win.renameAt(win.rowOf(p)) },
            { "id": "compress", "label": "Compress", "glyph": "folder_zip", "run": () => { ensure(); win.compressSelection(); } },
            { "id": "copy", "label": "Copy", "glyph": "content_copy", "run": () => { ensure(); win.copySelection(false); } },
            { "id": "cut", "label": "Cut", "glyph": "content_cut", "run": () => { ensure(); win.copySelection(true); } },
            { "id": "sendto", "label": "Send to…", "glyph": "send", "run": () => { ensure(); win.sendTo(); } },
            { "id": "trash", "label": "Move to the trash", "glyph": "delete", "run": () => { ensure(); win.trashSelection(); } },
            { "id": "delete", "label": "Delete for good", "glyph": "delete_forever", "run": () => { ensure(); win.deleteSelection(); } }
        ];
    }
    function rowOf(path) {
        return path in win.rowByPath ? win.rowByPath[path] : -1;
    }
    // Open with: the applications that take this file's type, from the desktop entries, the
    // system's default first. Nothing is remembered; the defaults stay yours.
    property real openWithX: 0
    property real openWithY: 0
    function openWith(path) {
        openWithX = actions.x; openWithY = actions.y;
        openWithProbe.path = path;
        openWithProbe.running = true;
    }
    Process {
        id: openWithProbe
        property string path: ""
        command: ["bash", "-c", `p='${StringUtils.shellSingleQuoteEscape(openWithProbe.path)}'; t=$(xdg-mime query filetype "$p" 2>/dev/null); d=$(xdg-mime query default "$t" 2>/dev/null); printf 'TYPE\t%s\n' "$t"; { for dir in ~/.local/share/applications /usr/share/applications; do [ -n "$d" ] && [ -f "$dir/$d" ] && { echo "$dir/$d"; break; }; done; grep -lsE "^MimeType=(.*;)?$t(;|$)" ~/.local/share/applications/*.desktop /usr/share/applications/*.desktop 2>/dev/null; } | awk '!seen[$0]++' | while read -r f; do [ "$(basename "$f")" = "$d" ] || { grep -qE '^(NoDisplay|Hidden)=true' "$f" && continue; }; n=$(grep -m1 '^Name=' "$f" | cut -d= -f2-); i=$(grep -m1 '^Icon=' "$f" | cut -d= -f2-); printf '%s\\t%s\\t%s\\t%s\\n' "$([ "$(basename "$f")" = "$d" ] && echo 1 || echo 0)" "$n" "$i" "$f"; done | sort -r`]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n").filter(l => l.length > 0);
                let type = "";
                let apps = [];
                for (const l of lines) {
                    const f = l.split("\t");
                    if (f[0] === "TYPE") { type = f[1]; continue; }
                    if (f.length < 4) continue;
                    const file = f[3], pth = openWithProbe.path;
                    // another application calling itself "Files" (Nautilus does) goes by its id here
                    let name = f[1];
                    if (name === "Files" && !file.endsWith("/quiet-files.desktop"))
                        name = file.split("/").pop().replace(/\.desktop$/, "").split(".").pop().replace(/^./, c => c.toUpperCase());
                    apps.push({ "id": file, "label": f[0] === "1" ? `${name} · default` : name, "glyph": "apps", "icon": f[2], "run": () => Quickshell.execDetached(["gio", "launch", file, pth]) });
                }
                if (apps.length === 0)
                    apps = [{ "id": "none", "label": `Nothing here opens ${type || "this"}`, "glyph": "block", "run": () => {} }];
                actions.model = apps;
                actions.x = win.openWithX;
                actions.y = Math.min(win.openWithY, body.height - (apps.length * 35 + 20));
                actions.open();
            }
        }
    }
    // The sum of a multi-selection. A binding here walked the whole folder on every change
    // of the selection, open column or not; the column asks for it when it has a sum to show.
    function selectedBytesNow() {
        let total = 0;
        for (let k = 0; k < folderModel.count; k++)
            if (win.selectedMap[folderModel.get(k, "filePath")] && !folderModel.get(k, "fileIsDir"))
                total += folderModel.get(k, "fileSize");
        return total;
    }
    readonly property var selectionActions: win.inTrash
        ? (win.atTrashRoot ? [{ "id": "restore", "label": "Put back", "glyph": "restore_from_trash", "run": () => win.restoreSelection() }] : [])
            .concat([{ "id": "delete", "label": "Delete for good", "glyph": "delete_forever", "run": () => win.deleteSelection() }])
        : [{ "id": "renamemany", "label": "Rename…", "glyph": "edit", "run": () => win.renameMany() },
           { "id": "compress", "label": "Compress", "glyph": "folder_zip", "run": () => win.compressSelection() },
           { "id": "copy", "label": "Copy", "glyph": "content_copy", "run": () => win.copySelection(false) },
           { "id": "cut", "label": "Cut", "glyph": "content_cut", "run": () => win.copySelection(true) },
           { "id": "trash", "label": "Move to the trash", "glyph": "delete", "run": () => win.trashSelection() },
           { "id": "park", "label": "Park on the shelf", "glyph": "stacks", "run": () => DropShelf.addItems(win.selectedPaths.map(p => "file://" + p)) },
           { "id": "hand", "label": "Hand to Praxis", "glyph": "smart_toy", "run": () => Recents.launch(win.folder, `Look at these files: ${win.selectedPaths.join(", ")}. What are they, and what should I do with them?`) },
           { "id": "path", "label": "Copy paths", "glyph": "content_copy", "run": () => win.copyPaths() }]
    readonly property var folderActions: [
        { "id": "terminal", "label": "Open in terminal", "glyph": "terminal", "run": () => win.terminalHere() },
        { "id": "newfolder", "label": "New folder", "glyph": "create_new_folder", "run": () => win.newFolder() },
        { "id": "newfile", "label": "New file", "glyph": "note_add", "run": () => win.newFile() },
        { "id": "paste", "label": "Paste", "glyph": "content_paste", "run": () => win.paste() },
        { "id": "park", "label": "Park on the shelf", "glyph": "stacks", "run": () => DropShelf.addItems(["file://" + win.folder + "/"]) },
        { "id": "hand", "label": "Hand to Praxis", "glyph": "smart_toy", "run": () => Recents.launch(win.folder, "Look around this folder. What is here, and what should I know about it?") },
        { "id": "path", "label": "Copy path", "glyph": "content_copy", "run": () => Things.copyPath(win.folder) }
    ].concat(Object.keys(Files.habits).length > 0 ? [{ "id": "forget", "label": "Forget where I file things", "glyph": "visibility_off", "run": () => Files.forgetHabits() }] : [])

    FolderListModel {
        id: folderModel
        folder: "file://" + win.folder
        showDirsFirst: true
        showDotAndDotDot: false
        showHidden: win.showHidden
        caseSensitive: false
        sortField: win.sortField
        sortReversed: win.sortReversed
        // see win.nameShown: the grid needs the model to filter, the list filters itself
        nameFilters: win.gridFiltering ? ["*" + win.query.replace(/[\[\]*?]/g, c => "[" + c + "]") + "*"] : []
        showDirs: !win.gridFiltering
        onStatusChanged: {
            if (status !== FolderListModel.Ready)
                return;
            if (count === 0)
                existsProbe.running = true;   // empty, or gone from under us?
            win.relist();
            win.pruneSelection();
            win.twins = ({});
            if (count > 1 && count <= 1500) { twinProc.running = false; twinProc.running = true; }
            win.decideView();
            if (win.selectPath.length > 0) {
                const want = win.selectPath;
                const idx = win.rowOf(want);
                win.selectPath = "";
                if (idx >= 0) {
                    win.selectOnly(idx);
                    win.flashPath = win.pathAt(idx);
                    flashTimer.restart();
                    positionTimer.idx = idx;
                    positionTimer.restart();
                } else {
                    // "Show in folder" on a download that has since been moved or deleted: the
                    // folder opens either way, so the status line says why nothing is lit.
                    win.reason = `${Files.placeName(want)} is not here`;
                    reasonTimer.restart();
                }
            }
            // a rename changes no count, so this is the only place a queued reveal can run
            win.tryRevealEdit();
        }
    }
    // An empty listing is checked against the disk: a folder deleted or unmounted under the
    // window sends it up to the nearest folder that still exists, and the status line says so.
    property bool unreadable: false
    Process {
        id: existsProbe
        command: ["bash", "-c", `f='${StringUtils.shellSingleQuoteEscape(win.folder)}'; p="$f"; while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done; r=0; [ -d "$f" ] && [ ! -r "$f" ] && r=1; printf '%s\t%s' "$p" "$r"`]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.split("\t");
                const nearest = (f[0] ?? "").trim();
                win.unreadable = f[1] === "1";
                if (nearest.length > 0 && nearest !== win.folder) {
                    const gone = Files.placeName(win.folder);
                    win.go(nearest);
                    win.reason = `${gone} is gone`;
                    reasonTimer.restart();
                }
            }
        }
    }
    Timer {   // and while it stays empty, look again now and then (the model does not always say)
        interval: 30000
        running: folderModel.count === 0 && win.visible && win.query.length === 0
        repeat: true
        onTriggered: existsProbe.running = true
    }
    Timer {
        id: flashTimer
        interval: 1500
        onTriggered: win.flashPath = ""
    }
    Timer {
        id: positionTimer
        property int idx: 0
        interval: 30
        onTriggered: win.currentView()?.positionViewAtIndex(idx, ListView.Center)
    }
    Timer {
        id: reasonTimer
        interval: 8000
        running: win.reason.length > 0
        onTriggered: win.reason = ""
    }
    Timer {
        id: jumpTimer
        interval: 800
        onTriggered: win.jumpBuffer = ""
    }

    // the selection's size, summed a beat after it changes (a folder of thousands is walked once, not per click)
    property real selectedBytes: 0
    onSelectedMapChanged: bytesLater.restart()
    Timer { id: bytesLater; interval: 90; onTriggered: win.selectedBytes = win.selectedPaths.length > 0 ? win.selectedBytesNow() : 0 }
    // the room left on this folder's disk, read when the folder changes
    property string freeLine: ""
    Process {
        id: freeProbe
        command: ["df", "--output=avail", "-B1", win.folder]
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseFloat((text.trim().split("\n").pop() || "").trim());
                win.freeLine = n > 0 ? `${Voice.size(n)} free` : "";
            }
        }
    }

    readonly property string statusLine: {
        if (win.activeJob)
            return Jobs.label(win.activeJob);
        if (win.recentShown)
            return Voice.facts([`${Voice.count(win.hits.length, "file")} touched this week`, win.searchRunning ? "looking" : ""]);
        if (win.shelfShown)
            return `${Voice.count(win.hits.length, "item")} parked on the notch`;
        if (win.largeOld)
            return Voice.facts([`${Voice.count(win.hits.length, "file")} over 100 MB not touched in 90 days`, win.diskLine, win.searchRunning ? "looking" : ""]);
        if (win.searching) {
            const read = win.searchPlan && (win.searchPlan.kindWord || win.searchPlan.sourceWord || win.searchPlan.timeWord || win.searchPlan.sizeWord) ? `read as ${win.readAs(win.searchPlan)}` : `for "${win.searchQuery}"`;
            return Voice.facts([`${Voice.count(win.hits.length, "hit")} ${read} under ${Files.placeName(win.folder)}`, win.searchRunning ? "searching" : "", win.hits.length >= 500 ? "first 500" : ""]);
        }
        if (win.reason.length > 0)
            return win.reason;
        if (win.jobLine.length > 0)
            return win.jobLine;
        const parts = [Voice.count(win.shownCount, "item")];
        if (win.selectedPaths.length > 0)
            parts.push(`${win.selectedPaths.length} selected` + (win.selectedBytes > 0 ? ` · ${Voice.size(win.selectedBytes)}` : ""));
        if (win.query.length > 0)
            parts.push(`matching "${win.query}"`);
        if (win.showHidden)
            parts.push("hidden shown");
        return Voice.facts(parts);
    }

    // Recent: files touched under home in the last week, newest first, in day sections, with
    // what the desktop knows about where they came from. The same rows as a search.
    property bool recentShown: false
    // Large & old: a place that exists while the disk is nearly full - the biggest files
    // not touched in three months, biggest first, so the way out is one look away.
    property bool largeOld: false
    property string diskLine: ""
    function showLargeOld() {
        win.editingIndex = -1;
        win.shelfShown = false;
        win.searching = true;
        win.recentShown = false;
        win.largeOld = true;
        win.searchQuery = "";
        win.hits = [];
        win.searchCursor = -1;
        win.clearSelection();
        fdProc.running = false;
        recentProc.running = false;
        largeProc.running = false;
        largeProc.running = true;
    }
    Process {
        id: largeProc
        command: ["bash", "-c", `df -h --output=pcent,avail "$HOME" | tail -1; find "$HOME" -xdev \\( -name '.*' -o -name node_modules \\) -prune -o -type f -size +100M -mtime +90 -printf '%s\\t%T@\\t%p\\n' 2>/dev/null | sort -rn | head -100`]
        onRunningChanged: win.searchRunning = running
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n").filter(l => l.length > 0);
                const dfl = (lines.shift() ?? "").trim().split(/\s+/);
                win.diskLine = dfl.length >= 2 ? `Disk ${dfl[0]} · ${dfl[1]} free` : "";
                win.hits = lines.filter(l => l.includes("\t")).map(l => {
                    const f = l.split("\t");
                    const path = f.slice(2).join("\t");
                    const at = parseFloat(f[1]) * 1000;
                    return { "path": path, "name": path.split("/").pop(), "rel": Files.parent(path).replace(win.home + "/", "").replace(win.home, "Home"), "isDir": false, "at": at, "bytes": parseInt(f[0]), "day": "" };
                });
            }
        }
    }
    // The shelf as a list: what is parked on the notch, each with its place and origin;
    // take one off, or clear it. Drag a row out to carry it, as from a tile.
    property bool shelfShown: false
    function showShelf() {
        win.editingIndex = -1;
        win.searching = true;
        win.recentShown = false;
        win.largeOld = false;
        win.shelfShown = true;
        win.searchQuery = "";
        win.searchCursor = -1;
        win.clearSelection();
        fdProc.running = false;
        recentProc.running = false;
        largeProc.running = false;
        win.hits = DropShelf.items.map(p => ({ "path": p.replace(/\/$/, ""), "name": p.replace(/\/$/, "").split("/").pop(), "rel": Files.parent(p.replace(/\/$/, "")).replace(win.home + "/", "").replace(win.home, "Home"), "isDir": p.endsWith("/"), "at": 0, "day": "" }));
    }
    Connections {
        target: DropShelf
        function onItemsChanged() { if (win.shelfShown) win.showShelf(); }
    }
    function showRecent() {
        win.editingIndex = -1;
        win.shelfShown = false;
        win.largeOld = false;
        win.searching = true;
        win.recentShown = true;
        win.searchQuery = "";
        win.hits = [];
        win.searchCursor = -1;
        win.clearSelection();
        fdProc.running = false;
        recentProc.running = false;
        recentProc.running = true;
    }
    Process {
        id: recentProc
        command: ["bash", "-c", `find "$HOME" -xdev \\( -name '.*' -o -name node_modules -o -name __pycache__ -o -name target -o -name build \\) -prune -o -type f -mtime -7 -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -300`]
        onRunningChanged: win.searchRunning = running
        stdout: StdioCollector {
            onStreamFinished: {
                const now = Date.now();
                const today = new Date(); today.setHours(0, 0, 0, 0);
                const dayName = t => {
                    const d = new Date(t); d.setHours(0, 0, 0, 0);
                    const days = Math.round((today.getTime() - d.getTime()) / 86400000);
                    if (days <= 0) return "Today";
                    if (days === 1) return "Yesterday";
                    if (days < 7) return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d.getDay()];
                    return "Earlier";
                };
                const rows = text.split("\n").filter(l => l.includes("\t")).map(l => {
                    const i = l.indexOf("\t");
                    const at = parseFloat(l.substring(0, i)) * 1000;
                    const path = l.substring(i + 1);
                    const home = win.home;
                    const rel = Files.parent(path).replace(home + "/", "").replace(home, "Home");
                    return { "path": path, "name": path.split("/").pop(), "rel": rel, "isDir": false, "at": at, "day": dayName(at) };
                });
                win.hits = rows;
            }
        }
    }
    // The grammar: kinds (photos, videos, pdf, docs, code, archives, music), sources ("from
    // zen", "from phone", "screenshots", "from claude"), times (today, yesterday, this/last
    // week, last month, N days), sizes (big, small). The rest is the name. Resolved with fd
    // and the origin index; the status line says how the words were read.
    property var searchPlan: null
    function parseQuery(q) {
        const words = q.toLowerCase().split(/\s+/).filter(w => w.length > 0);
        let plan = { "exts": [], "kindWord": "", "source": "", "sourceWord": "", "within": "", "timeWord": "", "size": "", "sizeWord": "", "name": [] };
        const kinds = {
            "photo": "image", "photos": "image", "picture": "image", "pictures": "image", "image": "image", "images": "image", "screenshots": "image",
            "video": "video", "videos": "video", "movie": "video", "movies": "video",
            "pdf": "pdf", "pdfs": "pdf", "doc": "doc", "docs": "doc", "document": "doc", "documents": "doc",
            "code": "code", "archive": "archive", "archives": "archive", "zip": "archive", "zips": "archive",
            "music": "audio", "audio": "audio", "song": "audio", "songs": "audio"
        };
        for (let i = 0; i < words.length; i++) {
            const w = words[i], n = words[i + 1] ?? "";
            if (kinds[w] && !plan.kindWord) {
                const k = kinds[w];
                plan.exts = Things.kinds[k].concat(k === "doc" ? Things.kinds.text : []);
                plan.kindWord = w;
                if (w === "screenshots") { plan.source = "screenshot"; plan.sourceWord = "screenshots"; }
                continue;
            }
            if (w === "from" && n) {
                if (/^(phone|mobile|pixel)$/.test(n)) plan.source = "phone";
                else if (/^(zen|browser|firefox|chromium|thorium|web)$/.test(n)) plan.source = "browser";
                else if (/^(claude|codex|agent)$/.test(n)) plan.source = "agent";
                else if (/^screenshots?$/.test(n)) plan.source = "screenshot";
                if (plan.source) { plan.sourceWord = `from ${n}`; i++; continue; }
            }
            if (w === "today") { plan.within = "1d"; plan.timeWord = "today"; continue; }
            if (w === "yesterday") { plan.within = "2d"; plan.timeWord = "since yesterday"; continue; }
            if ((w === "this" || w === "last") && n === "week") { plan.within = "7d"; plan.timeWord = "last 7 days"; i++; continue; }
            if ((w === "this" || w === "last") && n === "month") { plan.within = "31d"; plan.timeWord = "last month"; i++; continue; }
            if (/^\d+$/.test(w) && /^days?$/.test(n)) { plan.within = `${w}d`; plan.timeWord = `last ${w} days`; i++; continue; }
            if (/^(big|large|huge)$/.test(w)) { plan.size = "+50M"; plan.sizeWord = "over 50 MB"; continue; }
            if (w === "small") { plan.size = "-1M"; plan.sizeWord = "under 1 MB"; continue; }
            if (w === "files" || w === "file") continue;
            plan.name.push(w);
        }
        return plan;
    }
    function readAs(plan) {
        return Voice.facts([plan.kindWord, plan.sourceWord, plan.timeWord, plan.sizeWord, plan.name.length > 0 ? `"${plan.name.join(" ")}"` : ""]);
    }
    function hitMatchesSource(path, source) {
        const o = Origins.originFor(path);
        if (!o)
            return false;
        if (source === "phone") return o.kind === "phone";
        if (source === "screenshot") return o.kind === "screenshot";
        if (source === "agent") return o.kind === "agent";
        if (source === "browser") return o.kind === "download" && (o.app ?? "").length > 0;
        return true;
    }
    function deepSearch(q) {
        win.recentShown = false;
        win.shelfShown = false;
        const query = (q ?? "").trim();
        if (query.length === 0)
            return;
        win.searchPlan = win.parseQuery(query);
        win.searching = true;
        win.searchQuery = query;
        if (search.text !== query)
            search.text = query;   // a search asked for from outside shows its words in the box
        win.hits = [];
        win.searchCursor = -1;
        win.clearSelection();
        fdProc.running = false;
        fdProc.buffer = [];
        fdProc.running = true;
    }
    function endSearch() {
        win.editingIndex = -1;
        recentProc.running = false;
        largeProc.running = false;
        win.recentShown = false;
        win.largeOld = false;
        win.shelfShown = false;
        fdProc.running = false;
        win.searching = false;
        win.hits = [];
        win.searchCursor = -1;
        win.query = "";
        keys.forceActiveFocus();
    }
    Process {
        id: fdProc
        property var buffer: []
        command: {
            const p = win.searchPlan ?? { "exts": [], "within": "", "size": "", "name": [win.searchQuery] };
            const wantsHidden = p.name.some(w => w.startsWith("."));
            let args = `fd --color never ${wantsHidden ? "--hidden " : ""}--exclude .git --exclude node_modules --exclude .cache --exclude .local/share/Trash --max-results 500`;
            for (const e of p.exts) args += ` -e ${e}`;
            if (p.within) args += ` --changed-within ${p.within}`;
            if (p.size) args += ` --size ${p.size}`;
            if (p.exts.length > 0 || p.within || p.size) args += " --type f";
            const pattern = p.name.length > 0 ? p.name.join(".*") : ".";
            return ["bash", "-c", `cd '${StringUtils.shellSingleQuoteEscape(win.folder)}' && ${args} -- '${StringUtils.shellSingleQuoteEscape(pattern)}' . 2>/dev/null`];
        }
        onRunningChanged: win.searchRunning = running
        stdout: SplitParser {
            onRead: line => {
                const rel = line.trim().replace(/^\.\//, "");
                if (rel.length === 0)
                    return;
                const isDir = rel.endsWith("/");
                const clean = rel.replace(/\/$/, "");
                const path = win.folder === "/" ? "/" + clean : win.folder + "/" + clean;
                if (win.searchPlan?.source && !win.hitMatchesSource(path, win.searchPlan.source))
                    return;   // a source word: only what the desktop saw come from there
                fdProc.buffer.push({ "path": path, "name": clean.split("/").pop(), "rel": clean.includes("/") ? clean.substring(0, clean.lastIndexOf("/")) : "", "isDir": isDir });
                flush.restart();   // a few rows at a time, not a repaint per line
            }
        }
        onExited: { flush.stop(); win.hits = fdProc.buffer.slice(); }
    }
    Timer {
        id: flush
        interval: 40
        onTriggered: win.hits = fdProc.buffer.slice()
    }
    function openHit(i) {
        const h = win.hits[i];
        if (!h)
            return;
        if (h.isDir) {
            win.endSearch();
            win.go(h.path);
        } else if (win.forPick && Files.picking !== null) {
            if (!Files.picking.dir)
                win.pickDone([h.path]);   // searching is how a file is found in a picker
        } else {
            Things.open(h.path);
        }
    }
    function revealHit(i) {
        const h = win.hits[i];
        if (!h)
            return;
        win.endSearch();
        win.show(Files.parent(h.path), h.path, "");
    }

    // A reveal into this window: go there (if not there already) and select the file.
    function show(folder, select, why) {
        win.selectPath = select ?? "";
        win.reason = why ?? "";
        if (win.searching)   // a search or Recent gives way to the folder asked for
            win.endSearch();
        if (Files.trim(folder) !== win.folder)
            win.go(folder);
        else if (win.selectPath.length > 0)
            folderModel.statusChanged();   // same folder: run the reveal now
    }

    // ------------------------------------------------------------------ navigation
    function go(path, push) {
        const p = Files.trim(path);
        if (win.searching) { fdProc.running = false; recentProc.running = false; largeProc.running = false; win.searching = false; win.recentShown = false; win.largeOld = false; win.shelfShown = false; win.hits = []; win.searchCursor = -1; win.query = ""; }
        if (p === win.folder)
            return;
        win.folder = p;
        win.unreadable = false;
        win.query = "";
        win.selectedMap = ({});
        win.cursorPath = "";
        win.anchorIndex = -1;
        win.editingIndex = -1;
        win.editingPath = false;
        win.view = Files.viewFor(p) || "list";
        win.gridSize = Files.sizeFor(p) || 1;
        Files.remember(p);
        if (push !== false) {
            const h = win.history.slice(0, win.historyIndex + 1);
            h.push(p);
            win.history = h.slice(-50);
            win.historyIndex = win.history.length - 1;
        }
    }
    function back() {
        if (win.historyIndex <= 0)
            return;
        win.historyIndex--;
        win.go(win.history[win.historyIndex], false);
    }
    function forward() {
        if (win.historyIndex >= win.history.length - 1)
            return;
        win.historyIndex++;
        win.go(win.history[win.historyIndex], false);
    }
    function up() {
        if (win.folder !== "/")
            win.go(Files.parent(win.folder));
    }
    readonly property var crumbs: {
        const p = win.folder;
        let base = "/";
        let parts = p.split("/").filter(s => s.length > 0);
        if (p === win.home || p.startsWith(win.home + "/")) {
            base = win.home;
            parts = p.substring(win.home.length).split("/").filter(s => s.length > 0);
        }
        let list = [{ "name": base === "/" ? "/" : "Home", "path": base }];
        let acc = base === "/" ? "" : base;
        for (const part of parts) {
            acc += "/" + part;
            list.push({ "name": part, "path": acc });
        }
        // deep paths: the root, an ellipsis (to the parent of the tail), the last two
        if (list.length > 4)
            list = [list[0], { "name": "…", "path": list[list.length - 3].path }].concat(list.slice(-2));
        return list;
    }

    // The grid, once, for a folder that is mostly pictures; remembered per folder after that.
    function decideView() {
        if (Files.viewFor(win.folder).length > 0 || folderModel.count === 0)
            return;
        let images = 0;
        const n = Math.min(folderModel.count, 200);
        for (let i = 0; i < n; i++)
            if (!folderModel.get(i, "fileIsDir") && Things.kindOf(folderModel.get(i, "fileName")) === "image")
                images++;
        const v = images >= n * 0.6 ? "grid" : "list";
        win.view = v;
        if (v === "grid")   // a list is the default; remembering it for every folder visited would only grow the file
            Files.setView(win.folder, v);
    }
    // The grid's icon size: Ctrl+= and Ctrl+-, or a pinch on the touchpad; kept per folder like the view.
    readonly property var gridSizes: [0.75, 1, 1.25, 1.5, 2]
    property real gridSize: Files.sizeFor(win.folder) || 1
    function zoomGrid(step) {
        const i = win.gridSizes.indexOf(win.gridSize);
        const next = step === 0 ? 1 : win.gridSizes[Math.max(0, Math.min(win.gridSizes.length - 1, (i < 0 ? 1 : i) + step))];
        if (next === win.gridSize) return;
        win.gridSize = next;
        Files.setSize(win.folder, next);
        if (win.view !== "grid") win.setView("grid");   // a size is a grid's: asking for one shows it
    }
    function setView(v) {
        win.view = v;
        Files.setView(win.folder, v);
        if (v === "gallery" && win.cursor < 0 && folderModel.count > 0) {
            const first = win.nextShown(0, 1);
            if (first >= 0) win.selectOnly(first);
        }
    }

    // ------------------------------------------------------------------ selection
    function pathAt(i) {
        return i >= 0 && i < folderModel.count ? folderModel.get(i, "filePath") : "";
    }
    function selectOnly(i) {
        const p = win.pathAt(i);
        win.selectedMap = p.length > 0 ? ({ [p]: true }) : ({});
        win.cursorPath = p;
        win.anchorIndex = i;
    }
    function toggle(i) {
        const p = win.pathAt(i);
        let next = Object.assign({}, win.selectedMap);
        if (next[p])
            delete next[p];
        else
            next[p] = true;
        win.selectedMap = next;
        win.cursorPath = win.pathAt(i);
        win.anchorIndex = i;
    }
    function selectRange(i) {
        const a = win.anchorIndex < 0 ? i : win.anchorIndex;
        let next = ({});
        for (let k = Math.min(a, i); k <= Math.max(a, i); k++)
            if (win.rowShown(k))
                next[win.pathAt(k)] = true;
        win.selectedMap = next;
        win.cursorPath = win.pathAt(i);
    }
    // A band started on a row (its blank part): the first point is the origin.
    property var bandOrigin: null
    function bandFromScene(sx, sy) {
        const p = filesArea.mapFromItem(null, sx, sy);
        if (win.bandOrigin === null) {
            win.bandOrigin = [p.x, p.y];
            ground.banding = true;
        }
        const ox = win.bandOrigin[0], oy = win.bandOrigin[1];
        const top = Math.min(oy, p.y), bottom = Math.max(oy, p.y);
        band.x = Math.min(ox, p.x); band.y = top;
        band.width = Math.abs(p.x - ox); band.height = bottom - top;
        win.selectBand(top, bottom, Math.min(ox, p.x), Math.max(ox, p.x));
    }
    function bandStop() {
        win.bandOrigin = null;
        ground.banding = false;
    }
    // The rows between two y positions of the list (a band drawn on the ground). The grid
    // takes the cells whose box crosses the band.
    function selectBand(top, bottom, left, right) {
        let next = ({});
        let first = -1, last = -1;
        const take = k => {
            if (!win.rowShown(k))
                return;
            next[win.pathAt(k)] = true;
            if (first < 0) first = k;
            last = k;
        };
        if (win.view === "list") {
            const a = list.indexAt(10, top + list.contentY), b = list.indexAt(10, bottom + list.contentY);
            const from = a < 0 ? 0 : a, to = b < 0 ? folderModel.count - 1 : b;
            for (let k = Math.min(from, to); k <= Math.max(from, to); k++)
                take(k);
        } else {
            for (let k = 0; k < folderModel.count; k++) {
                const col = k % grid.columns, row = Math.floor(k / grid.columns);
                const cx = col * grid.cellWidth, cy = row * grid.cellHeight - grid.contentY;
                if (cx < right && cx + grid.cellWidth > left && cy < bottom && cy + grid.cellHeight > top)
                    take(k);
            }
        }
        win.selectedMap = next;
        // the keyboard follows the band, or Down after it would jump back to wherever the
        // cursor was before, collapsing the selection
        if (first >= 0) {
            win.anchorIndex = first;
            win.cursorPath = win.pathAt(last);
        }
    }
    function selectAll() {
        let next = ({});
        for (let k = 0; k < folderModel.count; k++)
            if (win.rowShown(k))
                next[win.pathAt(k)] = true;
        win.selectedMap = next;
    }
    function clearSelection() {
        win.selectedMap = ({});
    }
    // Mouse down on a row that is not selected selects it, alone, so a drag that follows
    // carries what the hand took. Modified presses wait for the release (clickAt).
    function pressAt(mouse, i) {
        keys.forceActiveFocus();
        if (mouse.button !== Qt.LeftButton || (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
            return;
        if (!win.selectedMap[win.pathAt(i)])
            win.selectOnly(i);
    }
    function clickAt(mouse, i) {
        if (mouse.modifiers & Qt.ShiftModifier)
            win.selectRange(i);
        else if (mouse.modifiers & Qt.ControlModifier)
            win.toggle(i);
        else
            win.selectOnly(i);
    }
    function moveCursor(delta, extend) {
        if (folderModel.count === 0)
            return;
        const from = win.cursor < 0 ? (delta > 0 ? -1 : folderModel.count) : win.cursor;
        const want = Math.max(0, Math.min(folderModel.count - 1, from + delta));
        const dir = delta >= 0 ? 1 : -1;
        let i = win.nextShown(want, dir);   // the filter's hidden rows are still in the model
        if (i < 0)
            i = win.nextShown(want, -dir);
        if (i < 0)
            return;
        if (extend)
            win.selectRange(i);
        else
            win.selectOnly(i);
        win.currentView()?.positionViewAtIndex(i, ListView.Contain);
    }
    function currentView() {
        return win.view === "grid" ? grid : list;
    }
    // One drag source for the whole window. A row or cell delegate can be destroyed while its
    // drag is still out (the folder changed under it, the window closed): Qt keeps a pointer to
    // the source item inside the drag's mime data and reads it when the target asks for the
    // files, which segfaulted the shell in QWaylandDataSource::data_source_send. This item
    // outlives every delegate, so the drag always has something alive behind it.
    Item {
        id: dragProxy
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    }
    function uriList(i) {
        const p = win.pathAt(i);
        const paths = win.selectedMap[p] ? win.selectedPaths : [p];
        return paths.map(x => "file://" + x).join("\r\n");
    }

    // ------------------------------------------------------------------ changing things
    // Every change is a detached job (scripts/files/job.sh via Jobs): it outlives the window,
    // reports to the status line while it runs, and carries its own undo (Ctrl+Z, or the
    // Undo pill for a minute). Nothing is lost: Delete is the trash; for good only after a
    // sheet that says how many and where.
    property int editingIndex: -1
    property var myJobs: ({})         // ids this window started
    property string undoJob: ""       // the last finished job with an undo
    property string jobLine: ""       // what just finished, for the status line
    readonly property var activeJob: Jobs.activeJobs.find(j => win.myJobs[j.id]) ?? null
    readonly property var cutMap: {   // (no Object.fromEntries in this engine)
        let m = ({});
        if (Files.clip?.op === "cut")
            for (const p of Files.clip.paths)
                m[p] = true;
        return m;
    }

    function run(op, args) {
        const id = Jobs.start(op, args);
        let m = Object.assign({}, win.myJobs);
        m[id] = true;
        win.myJobs = m;
        return id;
    }
    Connections {
        target: Jobs
        function onJobFinished(job) {
            if (!win.myJobs[job.id])
                return;
            if (job.state === "done" && job.op === "move" && job.undo?.to)
                for (const from of job.undo.to)   // where each came from -> where it went
                    Files.learnMove(from, job.dest);
            win.jobLine = Jobs.label(job);
            win.undoJob = job.state === "done" && job.undo ? job.id : "";
            jobLineTimer.restart();
            // a trash that failed for want of a trash: offer to delete for good
            if (job.state === "failed" && job.op === "trash" && (job.error + "").startsWith("no trash")) {
                const paths = job.results.length > 0 ? [] : win.pendingTrash;
                if (paths.length > 0)
                    win.askDelete(paths, "There is no trash on this disk.");
            }
            // a new folder is named right away (the model may already show it, or not yet);
            // what was renamed, pasted or dropped into this folder is selected once it shows
            if (job.state === "done" && job.results.length > 0) {
                const here = job.results.filter(r => Files.parent(r) === win.folder);
                if (job.op === "mkdir" || job.op === "touch")
                    revealEdit.path = job.results[0];
                else if (here.length > 0 && ["rename", "renames", "compress", "copy", "move", "moveback"].includes(job.op))
                    revealEdit.select = here;
                win.tryRevealEdit();
            }
        }
    }
    property var pendingTrash: []
    Timer { id: jobLineTimer; interval: 60000; onTriggered: { win.jobLine = ""; win.undoJob = ""; } }
    // a path that should be selected and put into rename as soon as the model shows it
    QtObject {
        id: revealEdit
        property string path: ""       // select and rename
        property var select: []        // select, and scroll to the first
    }
    function tryRevealEdit() {
        if (revealEdit.select.length > 0) {
            const first = win.rowOf(revealEdit.select[0]);
            if (first >= 0) {
                const want = revealEdit.select;
                revealEdit.select = [];
                let next = ({});
                for (const q of want)
                    next[q] = true;
                win.selectedMap = next;
                win.cursorPath = win.pathAt(first);
                win.anchorIndex = first;
                win.currentView()?.positionViewAtIndex(first, ListView.Contain);
            }
        }
        // a new folder's name field waits while a search or the shelf is the view: it stays
        // queued rather than pulling the window out of what it is showing
        if (revealEdit.path.length === 0 || win.searching)
            return;
        const idx = win.rowOf(revealEdit.path);
        if (idx < 0)
            return;
        revealEdit.path = "";
        win.renameAt(idx);
        win.currentView()?.positionViewAtIndex(idx, ListView.Contain);
    }
    Connections {
        target: folderModel
        function onCountChanged() { win.relist(); win.pruneSelection(); win.tryRevealEdit(); }
    }

    // Same-as: files in this folder that are byte-for-byte another one here (same size,
    // same head and tail); the newer is the copy. Found by a process after the folder loads,
    // only for folders of a reasonable size.
    property var twins: ({})   // copy path -> original name
    property var dismissed: ({})
    Process {
        id: twinProc
        command: ["bash", "-c", `cd '${StringUtils.shellSingleQuoteEscape(win.folder)}' 2>/dev/null || exit 0; find . -maxdepth 1 -type f -size +0 -printf '%s\\t%T@\\t%p\\n' 2>/dev/null | sort -n | awk -F'\\t' '{ if ($1 == prev) { if (!dup[prev]) { print prevline; dup[prev]=1 }; print } prev=$1; prevline=$0 }' | while IFS=$'\\t' read -r size at path; do h=$( { head -c 65536 -- "$path"; tail -c 65536 -- "$path"; } | md5sum | cut -c1-16); printf '%s\\t%s\\t%s\\n' "$size:$h" "$at" "$path"; done | sort -t$'\\t' -k1,1 -k2,2n | awk -F'\\t' 'function flush() { if (n > 1) { o=1; for (i=2;i<=n;i++) if (at[i] < at[o] || (at[i] == at[o] && length(nm[i]) < length(nm[o]))) o=i; for (i=1;i<=n;i++) if (i != o) print nm[o] "\\t" nm[i] } n=0 } { if ($1 != key) { flush(); key=$1 } n++; at[n]=$2; nm[n]=$3 } END { flush() }'`]
        stdout: StdioCollector {
            onStreamFinished: {
                let t = ({});
                for (const l of text.split("\n")) {
                    const f = l.split("\t");
                    if (f.length < 2) continue;
                    const orig = f[0].replace(/^\.\//, ""), copy = f[1].replace(/^\.\//, "");
                    t[win.folder + "/" + copy] = orig;
                }
                win.twins = t;
            }
        }
    }
    function offerFor(path) {
        if (win.dismissed[path])
            return null;
        const twin = win.twins[path];
        if (twin)
            return { "label": `same as ${twin} · drop the copy`, "glyph": "content_copy", "run": () => { win.run("trash", [path]); } };
        const dest = Files.offerFor(path);
        if (dest.length > 0)
            return { "label": `→ ${Files.placeName(dest)}`, "glyph": "drive_file_move", "run": () => { win.run("move", ["keep", dest, path]); } };
        return null;
    }
    function dismissOffer(path) {
        let d = Object.assign({}, win.dismissed);
        d[path] = true;
        win.dismissed = d;
    }
    function nameTaken(name, except) {
        return name !== except && win.names[name] === true;
    }
    function freeName(base) {
        if (!win.nameTaken(base, ""))
            return base;
        for (let n = 2; n < 1000; n++)
            if (!win.nameTaken(`${base} ${n}`, ""))
                return `${base} ${n}`;
        return base;
    }
    function renameAt(i) {
        if (i < 0 || i >= folderModel.count || !win.rowShown(i))
            return;
        if (win.searching)
            win.endSearch();
        if (win.view !== "list")
            win.view = "list";   // only a list row has a name field (not remembered: Ctrl+2 is still yours)
        win.selectOnly(i);
        win.editingIndex = i;
    }
    function rename(i, name) {
        const p = win.pathAt(i);
        if (p.length === 0)
            return;
        // The selection and the cursor take the new name at once: the job's report can arrive
        // before the model lists it, and until then Delete or Ctrl+C would forward a path
        // that no longer exists.
        const dir = Files.parent(p);
        const to = (dir === "/" ? "" : dir) + "/" + name;
        if (win.selectedMap[p]) {
            let next = Object.assign({}, win.selectedMap);
            delete next[p];
            next[to] = true;
            win.selectedMap = next;
        }
        if (win.cursorPath === p)
            win.cursorPath = to;
        win.run("rename", [p, name]);
    }
    function newFolder() {
        win.run("mkdir", [win.folder, win.freeName("New folder")]);
    }
    // an empty file, named in its row at once like a new folder (the stem selected, ".txt" kept)
    function newFile() {
        win.run("touch", [win.folder, win.freeName("Untitled.txt")]);
    }
    // one .zip beside them: "name.zip" for one, "Archive.zip" for several
    function compressSelection() {
        const ps = win.selectedPaths;
        if (ps.length === 0) return;
        const name = ps.length === 1 ? ps[0].split("/").pop() + ".zip" : "Archive.zip";
        win.run("compress", [Files.parent(ps[0]), name].concat(ps));
    }
    // several selected: one sheet renames them all (F2 on a selection of more than one)
    function renameMany() {
        const ps = win.selectedPaths.slice().sort((a, b) => win.rowOf(a) - win.rowOf(b));
        if (ps.length < 2) { win.renameAt(win.cursor); return; }
        renameSheet.takenNames = win.names;
        renameSheet.open(ps);
    }
    // for scripted checks (the test display): the sheet's fields and its Rename, as the keys would
    function presetRename(m, a, b) { renameSheet.preset(m, a, b); }
    function applyRenameSheet() { renameSheet.go(); }
    function renamePlan() { return JSON.stringify(renameSheet.plan.map(r => [r.old, r.name, r.bad])); }
    // the order, as a menu: a field picked again turns its direction
    function sortBy(field) {
        if (win.sortField === field) win.sortReversed = !win.sortReversed;
        else { win.sortField = field; win.sortReversed = false; }
    }
    readonly property string sortWord: ({ [FolderListModel.Name]: "Name", [FolderListModel.Time]: "Modified", [FolderListModel.Size]: "Size", [FolderListModel.Type]: "Kind" })[win.sortField] ?? "Name"
    function openMenuAt(item, model) {
        actions.model = model;
        const p = item.mapToItem(body, 0, item.height + 6);
        actions.x = Math.min(p.x, body.width - 244 - 12);
        actions.y = p.y;
        actions.open();
    }
    readonly property string trashDir: Files.trashDir
    // Every folder inside the trash is in the trash: an exact match on the root offered
    // "Move to the trash" for items already there, which nested them instead of restoring.
    readonly property bool inTrash: win.folder === win.trashDir || win.folder.startsWith(win.trashDir + "/")
    readonly property bool atTrashRoot: win.folder === win.trashDir
    function trashSelection() {
        if (win.selectedPaths.length === 0)
            return;
        if (win.inTrash) {   // already in the trash: the only way out is for good
            win.deleteSelection();
            return;
        }
        win.pendingTrash = win.selectedPaths.slice();
        win.run("trash", win.selectedPaths);
        win.clearSelection();
        win.cursorPath = "";
    }
    // In the Trash: put the selection back where it came from. Only at its root - the record
    // to restore is named after a direct child of Trash/files.
    function restoreSelection() {
        if (win.selectedPaths.length === 0 || !win.atTrashRoot)
            return;
        win.run("restore", win.selectedPaths.map(q => q.split("/").pop()));
        win.clearSelection();
        win.cursorPath = "";
    }
    function askDelete(paths, why) {
        sheet.title = `Delete ${paths.length === 1 ? Files.placeName(paths[0]) : Voice.count(paths.length, "item")} for good?`;
        sheet.lines = [why ?? "This does not go to the trash."];
        sheet.buttons = [
            { "label": "Delete", "tone": "error", "run": () => { win.run("delete", paths); win.clearSelection(); } },
            { "label": "Keep", "run": () => {} }
        ];
        sheet.open();
    }
    function deleteSelection() {
        if (win.selectedPaths.length > 0)
            win.askDelete(win.selectedPaths.slice(), "");
    }
    // A file:// URL another application can read back: percent-encoded segment by segment,
    // because a name may hold a space or a '%'.
    function fileUrl(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }
    // And back. A name with a literal '%' is not valid encoding and decodeURIComponent throws
    // on it, which killed the whole paste without a word.
    function decodePath(url) {
        try {
            return decodeURIComponent(url);
        } catch (e) {
            return url;
        }
    }
    function copySelection(cutting) {
        if (win.selectedPaths.length === 0)
            return;
        Files.clip = { "op": cutting ? "cut" : "copy", "paths": win.selectedPaths.slice(), "at": Date.now() };
        // A cut goes out as x-special/gnome-copied-files, whose first line is the verb:
        // text/uri-list carries none, so another file manager pasted our cut as a copy.
        const urls = win.selectedPaths.map(x => win.fileUrl(x));
        const body = cutting ? ["cut"].concat(urls).join("\n") : urls.join("\r\n");
        const type = cutting ? "x-special/gnome-copied-files" : "text/uri-list";
        Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(body)}' | wl-copy --type ${type}`]);
        win.reason = `${cutting ? "Cut" : "Copied"} ${Voice.count(win.selectedPaths.length, "item")}`;
        reasonTimer.restart();
    }
    // Paste, or a drop: into a folder (this one, a folder row, a place), with the collisions
    // asked about once. Names already there are checked on disk when the target is not the
    // folder shown.
    function bring(op, paths, target, fromClip) {
        const dest = target ?? win.folder;
        const list = paths.filter(x => !(Files.parent(x) === dest && op === "move") && x !== dest && !dest.startsWith(x + "/"));
        if (list.length === 0) {
            if (op === "move") {   // a cut pasted where it already is: the rows would stay faint
                Files.clip = null;
                win.reason = "Already here";
                reasonTimer.restart();
            }
            return;
        }
        if (dest !== win.folder) {
            clashProbe.op = op; clashProbe.dest = dest; clashProbe.list = list; clashProbe.fromClip = fromClip === true;
            clashProbe.running = true;
            return;
        }
        win.bringChecked(op, list, dest, list.filter(x => win.nameTaken(x.split("/").pop(), "")), fromClip === true);
    }
    Process {
        id: clashProbe
        property string op: ""
        property string dest: ""
        property var list: []
        property bool fromClip: false
        command: ["bash", "-c", `d='${StringUtils.shellSingleQuoteEscape(clashProbe.dest)}'; for f in ${clashProbe.list.map(x => `'${StringUtils.shellSingleQuoteEscape(x)}'`).join(" ")}; do [ -e "$d/$(basename -- "$f")" ] && printf '%s\n' "$f"; done; true`]
        stdout: StdioCollector {
            onStreamFinished: win.bringChecked(clashProbe.op, clashProbe.list, clashProbe.dest, text.split("\n").filter(x => x.length > 0), clashProbe.fromClip)
        }
    }
    function bringChecked(op, list, dest, clashes, fromClip) {
        const go = policy => {
            win.run(op, [policy, dest].concat(list));
            if (op === "move")
                Files.clip = null;
            // a cut is pasted once, as in GNOME Files: left on the clipboard, a second paste moved files already gone
            if (op === "move" && fromClip)
                Quickshell.execDetached(["wl-copy", "--clear"]);
        };
        if (clashes.length === 0) {
            go("keep");
            return;
        }
        sheet.title = `${Voice.count(clashes.length, "item")} already here`;
        sheet.lines = clashes.slice(0, 6).map(x => x.split("/").pop()).concat(clashes.length > 6 ? [`and ${clashes.length - 6} more`] : []);
        sheet.buttons = [
            { "label": "Replace", "tone": "error", "run": () => go("replace") },
            { "label": "Keep both", "run": () => go("keep") },
            { "label": "Skip", "run": () => go("skip") }
        ];
        sheet.open();
    }
    // The clipboard decides: the last copy wins, made in this window, another or another app. Pinax's own copy only
    // stands in for it in the moment its wl-copy may not have taken the clipboard yet.
    function paste() {
        if (!clipboardProbe.running)
            clipboardProbe.running = true;
    }
    function sameFiles(a, b) {
        return a.length === b.length && a.every((x, i) => x === b[i]);
    }
    Process {
        id: clipboardProbe
        // x-special/gnome-copied-files first: its first line says "cut" or "copy", which is
        // how every other file manager tells them apart. text/uri-list has no verb: a copy.
        command: ["bash", "-c", "t=$(wl-paste --list-types 2>/dev/null); case \"$t\" in *x-special/gnome-copied-files*) wl-paste -t x-special/gnome-copied-files 2>/dev/null;; *text/uri-list*) wl-paste -t text/uri-list 2>/dev/null;; esac; true"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split(/\r?\n/).map(l => l.trim());
                const op = lines[0] === "cut" ? "move" : "copy";
                const paths = lines.filter(l => l.startsWith("file://")).map(u => FileUtils.trimFileProtocol(win.decodePath(u)));
                const own = Files.clip;
                if (paths.length > 0) {
                    // another copy came since Pinax's: its cut rows are not cut any more
                    if (own && !win.sameFiles(own.paths, paths))
                        Files.clip = null;
                    win.bring(op, paths, undefined, true);
                } else if (own && own.paths.length > 0 && Date.now() - own.at < 1500) {
                    win.bring(own.op === "cut" ? "move" : "copy", own.paths, undefined, true);
                } else {
                    Files.clip = null;
                    win.reason = "Nothing to paste";
                    reasonTimer.restart();
                }
            }
        }
    }
    // a drop from another window or app, into `dest`: Files' own drag moves, others copy;
    // Ctrl forces a copy, Shift a move
    function dropIn(urls, modifiers, internal, dest) {
        const paths = urls.map(u => FileUtils.trimFileProtocol(win.decodePath(u.toString()))).filter(x => x.length > 0);
        if (paths.length === 0)
            return;
        const op = (modifiers & Qt.ControlModifier) ? "copy" : (modifiers & Qt.ShiftModifier) ? "move" : (internal ? "move" : "copy");
        win.bring(op, paths, dest);
    }
    function undo() {
        if (win.undoJob.length === 0)
            return;
        const id = Jobs.undo(win.undoJob);
        win.undoJob = "";
        win.jobLine = "";
        if (id) {
            let m = Object.assign({}, win.myJobs);
            m[id] = true;
            win.myJobs = m;
        }
    }
    // Send to: the places a file can go from here - the phone when it is paired and on the
    // network, the shelf, a Claude session. Real targets only; none shown that would fail.
    function sendTo() {
        const paths = win.selectedPaths.slice();
        if (paths.length === 0)
            return;
        const what = paths.length === 1 ? paths[0].split("/").pop() : Voice.count(paths.length, "item");
        let list = [];
        if (Things.phoneReachable)
            list.push({ "id": "phone", "label": `${Things.phoneName} · on the network`, "glyph": "smartphone", "run": () => { for (const p of paths) Things.toPhone(p); } });
        list.push({ "id": "shelf", "label": "The shelf · carry it anywhere", "glyph": "stacks", "run": () => DropShelf.addItems(paths.map(p => "file://" + p)) });
        list.push({ "id": "claude", "label": "Praxis · a new session here", "glyph": "smart_toy", "run": () => Recents.launch(win.folder, `Look at ${paths.join(", ")}. What is this, and what should I do about it?`) });
        sheet.title = `Send ${what} to`;
        sheet.lines = [];
        sheet.buttons = [];
        sheet.rows = list;
        sheet.safe = -1;
        sheet.open();
    }
    function stopJob() {
        if (win.activeJob)
            Jobs.cancel(win.activeJob.id);
    }
    // Mounting and unmounting are fire-and-forget; only the notch heard them fail, far from
    // the rail that was clicked. The folder an eject stepped off is still there to go back to.
    property string ejectedFrom: ""
    Connections {
        target: Devices
        function onFailed(what) {
            win.reason = `Can't: ${what}`;
            reasonTimer.restart();
            if (win.ejectedFrom.length > 0) {
                win.go(win.ejectedFrom);
                win.ejectedFrom = "";
            }
        }
        function onRemoved(dev) {
            if (dev.mountpoint === win.ejectedFrom)
                win.ejectedFrom = "";
        }
    }
    // Nothing could open the file: xdg-open is detached, so the reason is Things' to find
    // and this window's to say - otherwise a double-click looks like it never registered.
    Connections {
        target: Things
        function onOpenFailed(path, why) {
            win.reason = why;
            reasonTimer.restart();
        }
    }
    // The keys, by name: for `files act <name>` (a bind, a script, a test).
    function perform(name) {
        switch (name) {
        case "newFolder": win.newFolder(); break;
        case "rename": win.renameAt(win.cursor); break;
        case "trash": win.trashSelection(); break;
        case "delete": win.deleteSelection(); break;
        case "copy": win.copySelection(false); break;
        case "cut": win.copySelection(true); break;
        case "paste": win.paste(); break;
        case "undo": win.undo(); break;
        case "stop": win.stopJob(); break;
        case "selectAll": win.selectAll(); break;
        case "up": win.up(); break;
        case "back": win.back(); break;
        case "preview": win.previewToggled = !win.previewToggled; break;
        case "hidden": win.showHidden = !win.showHidden; break;
        case "largeold": win.showLargeOld(); break;
        case "recent": win.showRecent(); break;
        case "sendto": win.sendTo(); break;
        case "forgetHabits": Files.forgetHabits(); break;
        }
    }

    // ------------------------------------------------------------------ actions
    function openIndex(i) {
        if (i < 0 || i >= folderModel.count)
            return;
        if (folderModel.get(i, "fileIsDir"))
            win.go(folderModel.get(i, "filePath"));
        else if (win.forPick && Files.picking !== null) {
            if (!Files.picking.dir)
                win.pickDone([folderModel.get(i, "filePath")]);   // picking: a file opened is a file chosen
        }
        else
            Things.open(folderModel.get(i, "filePath"));
    }
    // a window opened for a pick closes when the pick is done
    property bool forPick: false
    // What Choose sends: the selection, or the hit the search cursor is on. Searching is the
    // normal way to find a file in a picker, and a hit never joins the selection.
    // Picking a folder: the selected folders, else the folder shown.
    readonly property var pickPaths: Files.picking?.dir === true
        ? (win.selectedPaths.filter(p => win.dirPaths[p] === true).length > 0 ? win.selectedPaths.filter(p => win.dirPaths[p] === true) : [win.folder])
        : win.selectedPaths.length > 0 ? win.selectedPaths
        : (win.searching && win.searchCursor >= 0 && win.hits[win.searchCursor] ? [win.hits[win.searchCursor].path] : [])
    function pickDone(paths) {
        Files.pickDone(paths);
        if (win.forPick)
            win.visible = false;
    }
    function openSelection() {
        if (win.cursor >= 0)
            win.openIndex(win.cursor);
    }
    function terminalHere() {
        Quickshell.execDetached(["foot", "-D", win.folder]);
    }
    function copyPaths() {
        const paths = win.selectedPaths.length > 0 ? win.selectedPaths : [win.folder];
        Things.copyPath(paths.join("\n"));
        win.reason = `Copied ${paths.length === 1 ? "the path" : paths.length + " paths"}`;
        reasonTimer.restart();
    }
    function jump(ch) {
        win.jumpBuffer += ch.toLowerCase();
        jumpTimer.restart();
        const start = win.jumpBuffer.length === 1 ? win.cursor + 1 : 0;
        for (let k = 0; k < folderModel.count; k++) {
            const i = (start + k) % folderModel.count;
            if (win.rowShown(i) && (folderModel.get(i, "fileName") + "").toLowerCase().startsWith(win.jumpBuffer)) {
                win.selectOnly(i);
                win.currentView()?.positionViewAtIndex(i, ListView.Contain);
                return;
            }
        }
    }
    function showActions(i, x, y) {
        const p = win.pathAt(i);
        if (p.length === 0)
            return;
        if (!win.selectedMap[p])
            win.selectOnly(i);
        // a right-click inside a multi-selection acts on all of it, as the column beside it does
        actions.model = win.selectedPaths.length > 1 ? win.selectionActions : win.actionsFor(i);
        const pos = body.mapFromItem(null, x, y);
        actions.x = Math.min(pos.x, body.width - 236 - 12 - 8);
        // a full row menu is tall: keep its head on screen in a short window rather than
        // pushing it off the top
        actions.y = Math.max(8, Math.min(pos.y, body.height - (actions.model.length * 35 + 12) - 8));
        actions.open();
    }

    // The Claude app's material (and the code editor's, and foot's): the terminal background
    // at foot's alpha, in place of the panel frost.
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

    // ------------------------------------------------------------------ body
    Rectangle {
        id: body
        anchors.fill: parent
        // 20, not the panels' 30: the compositor clips (and blurs) this window at its own
        // rounding, capped at 20, and the frost must end exactly where the clip does.
        radius: 20
        color: ColorUtils.transparentize(win.termBase, 0.15)

        FocusScope {
            id: keys
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (win.editingIndex >= 0) {
                    // the name field has the keys - unless nothing took them, and then Escape
                    // is the only way back to a window that answers at all
                    if (event.key === Qt.Key_Escape) {
                        win.editingIndex = -1;
                        event.accepted = true;
                    }
                    return;
                }
                if (win.searching) {
                    switch (event.key) {
                    case Qt.Key_Escape: win.endSearch(); event.accepted = true; return;
                    case Qt.Key_Down: win.searchCursor = Math.min(win.hits.length - 1, win.searchCursor + 1); hitList.positionViewAtIndex(win.searchCursor, ListView.Contain); event.accepted = true; return;
                    case Qt.Key_Up: win.searchCursor = Math.max(0, win.searchCursor - 1); hitList.positionViewAtIndex(win.searchCursor, ListView.Contain); event.accepted = true; return;
                    case Qt.Key_Return: case Qt.Key_Enter: win.openHit(win.searchCursor); event.accepted = true; return;
                    case Qt.Key_Space: win.revealHit(win.searchCursor); event.accepted = true; return;
                    }
                    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) { search.forceActiveFocus(); search.selectAll(); event.accepted = true; }
                    return;
                }
                const ctrl = event.modifiers & Qt.ControlModifier;
                const shift = event.modifiers & Qt.ShiftModifier;
                const alt = event.modifiers & Qt.AltModifier;
                if (ctrl && shift && event.key === Qt.Key_C) { win.copyPaths(); event.accepted = true; return; }
                if (ctrl && shift && event.key === Qt.Key_T) { win.terminalHere(); event.accepted = true; return; }
                // Ctrl+F filters what is in front of you, Ctrl+Shift+F looks through the whole
                // tree - the same pair as in Graphis. With nothing typed there is nothing to
                // search yet, so the box takes the keyboard.
                if (ctrl && shift && event.key === Qt.Key_F) {
                    if (win.query.trim().length > 0) win.deepSearch(win.query);
                    else { search.forceActiveFocus(); search.selectAll(); }
                    event.accepted = true; return;
                }
                if (ctrl && event.key === Qt.Key_W) { win.visible = false; event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_L) { win.editingPath = true; event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_F) { search.forceActiveFocus(); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_H) { win.showHidden = !win.showHidden; event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_A) { win.selectAll(); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_B) { Files.setRailPref(win.railCompact ? "full" : "compact"); event.accepted = true; return; }
                if (ctrl && shift && event.key === Qt.Key_N) { win.newFolder(); event.accepted = true; return; }
                if (ctrl && shift && event.key === Qt.Key_S) { win.sendTo(); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_C) { win.copySelection(false); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_X) { win.copySelection(true); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_V) { win.paste(); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_Z) { win.undo(); event.accepted = true; return; }
                if (event.key === Qt.Key_F2) { if (win.selectedPaths.length > 1) win.renameMany(); else win.renameAt(win.cursor); event.accepted = true; return; }
                if (event.key === Qt.Key_Delete) { if (shift) win.deleteSelection(); else win.trashSelection(); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_1) { win.setView("list"); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_2) { win.setView("grid"); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_3) { win.setView("gallery"); event.accepted = true; return; }
                if (ctrl && (event.key === Qt.Key_Equal || event.key === Qt.Key_Plus)) { win.zoomGrid(1); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_Minus) { win.zoomGrid(-1); event.accepted = true; return; }
                if (ctrl && event.key === Qt.Key_0) { win.zoomGrid(0); event.accepted = true; return; }
                if (ctrl && alt && event.key === Qt.Key_N) { win.newFile(); event.accepted = true; return; }
                if (alt && event.key === Qt.Key_Left) { win.back(); event.accepted = true; return; }
                if (alt && event.key === Qt.Key_Right) { win.forward(); event.accepted = true; return; }
                if (alt && event.key === Qt.Key_Up) { win.up(); event.accepted = true; return; }
                switch (event.key) {
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    win.openSelection(); event.accepted = true; return;
                case Qt.Key_Backspace:
                    win.up(); event.accepted = true; return;
                case Qt.Key_Down:
                    win.moveCursor(win.view === "grid" ? grid.columns : 1, shift); event.accepted = true; return;
                case Qt.Key_Up:
                    win.moveCursor(win.view === "grid" ? -grid.columns : -1, shift); event.accepted = true; return;
                case Qt.Key_Left:
                    if (win.view !== "list") { win.moveCursor(-1, shift); event.accepted = true; } return;
                case Qt.Key_Right:
                    if (win.view !== "list") { win.moveCursor(1, shift); event.accepted = true; }
                    else if (win.cursor >= 0) { const o = win.offerFor(win.pathAt(win.cursor)); if (o) { o.run(); event.accepted = true; } }
                    return;
                case Qt.Key_Home:
                    win.moveCursor(-folderModel.count, shift); event.accepted = true; return;
                case Qt.Key_End:
                    win.moveCursor(folderModel.count, shift); event.accepted = true; return;
                case Qt.Key_PageDown:
                    win.moveCursor(12, shift); event.accepted = true; return;
                case Qt.Key_PageUp:
                    win.moveCursor(-12, shift); event.accepted = true; return;
                case Qt.Key_Space:
                    win.previewToggled = !win.previewToggled; event.accepted = true; return;
                case Qt.Key_Escape:
                    if (win.activeJob) win.stopJob();
                    else if (win.cursor >= 0 && win.offerFor(win.pathAt(win.cursor))) win.dismissOffer(win.pathAt(win.cursor));
                    else if (Files.clip?.op === "cut") Files.clip = null;
                    else if (!win.wide && win.previewToggled) win.previewToggled = false;
                    else if (win.query.length > 0) win.query = "";
                    else win.clearSelection();
                    event.accepted = true; return;
                }
                if (!ctrl && !alt && event.text.length === 1 && /[^\s]/.test(event.text)) {
                    win.jump(event.text);
                    event.accepted = true;
                }
            }

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 0

                FilesRail {
                    id: railView
                    Layout.fillHeight: true
                    Layout.preferredWidth: implicitWidth
                    Layout.topMargin: 2
                    folder: win.folder
                    compact: win.railCompact
                    onToggle: Files.setRailPref(win.railCompact ? "full" : "compact")
                    onGo: path => win.go(path)
                    onDroppedOn: (path, urls, mods, internal) => win.dropIn(urls, mods, internal, path)
                    onDevice: dev => {
                        if (dev.mountpoint.length > 0) { win.go(dev.mountpoint); return; }
                        win.reason = `Mounting ${Devices.nameFor(dev)}`;
                        reasonTimer.restart();
                        Devices.mount(dev.path, mp => { if (mp.length > 0) { win.go(mp); win.reason = ""; } });
                    }
                    onEject: dev => {
                        win.ejectedFrom = "";
                        if (win.folder === dev.mountpoint || win.folder.startsWith(dev.mountpoint + "/")) {
                            win.ejectedFrom = win.folder;
                            win.go(win.home);   // step off it first, or it is "still in use" by us
                        }
                        Devices.unmount(dev);
                        win.reason = `${dev.usb ? "Ejecting" : "Unmounting"} ${Devices.nameFor(dev)}`;
                        reasonTimer.restart();
                    }
                    recentShown: win.recentShown
                    onRecent: win.showRecent()
                    shelfShown: win.shelfShown
                    onShelf: win.showShelf()
                    largeOldShown: win.largeOld
                    onLargeOld: win.showLargeOld()
                    onNow: item => {
                        if (item.kind === "file") win.show(Files.parent(item.path), item.path, "");
                        else if (item.kind === "device" && item.dev.mountpoint.length > 0) win.go(item.dev.mountpoint);
                        else if (item.kind === "job" && item.job.kind === "job") Jobs.cancel(item.job.id);
                    }
                    onPlaceActions: (name, path, x, y) => {
                        actions.model = [
                            { "id": "open", "label": `Open ${name}`, "glyph": "folder_open", "run": () => win.go(path) },
                            { "id": "terminal", "label": "Open in terminal", "glyph": "terminal", "run": () => Quickshell.execDetached(["foot", "-D", path]) },
                            { "id": "path", "label": "Copy path", "glyph": "content_copy", "run": () => Things.copyPath(path) }
                        ].concat(Files.pins.includes(path) ? [{ "id": "unpin", "label": "Unpin", "glyph": "keep_off", "run": () => Files.unpin(path) }] : []);
                        const pos = railView.mapToItem(body, x, y);
                        actions.x = Math.min(pos.x, body.width - 244);
                        actions.y = Math.min(pos.y, body.height - 140);
                        actions.open();
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 0

                    // ---------------------------------------------------- header
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 8
                        Layout.topMargin: 4
                        spacing: 4

                        HeaderButton { glyph: "arrow_back"; enabled: win.historyIndex > 0; onActivated: win.back() }
                        HeaderButton { glyph: "arrow_forward"; enabled: win.historyIndex < win.history.length - 1; onActivated: win.forward() }

                        // Where you are, as Praxis heads a page: the folder's name (16 DemiBold, main ink), and under it
                        // the way up (13, secondary ink; each part a step back). Or the path being edited.
                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 44
                            Layout.leftMargin: 8
                            clip: true
                            readonly property bool aView: win.recentShown || win.largeOld || win.shelfShown
                            StyledText {
                                id: headTitle
                                anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 3 }
                                visible: !win.editingPath
                                text: parent.aView ? (win.recentShown ? "Recent" : win.shelfShown ? "Shelf" : "Large & old")
                                    : win.crumbs.length ? win.crumbs[win.crumbs.length - 1].name : Files.placeName(win.folder)
                                elide: Text.ElideRight
                                font.pixelSize: 16
                                font.weight: Font.DemiBold
                                color: Tacit.inkMain
                            }
                            StyledText {
                                anchors { left: parent.left; right: parent.right; top: headTitle.bottom; topMargin: 2 }
                                visible: !win.editingPath && parent.aView
                                text: win.recentShown ? "What arrived and what you opened, newest first"
                                    : win.shelfShown ? "Parked on the notch, ready to drop anywhere"
                                    : "Big files you have not opened in a long while"
                                elide: Text.ElideRight
                                font.pixelSize: 13
                                color: Tacit.inkSec
                            }
                            Row {
                                id: crumbRow
                                anchors { top: headTitle.bottom; topMargin: 2 }
                                // wider than the header: the end nearest you stays in view
                                x: Math.min(0, parent.width - width - 8)
                                spacing: 4
                                visible: !win.editingPath && !parent.aView
                                Repeater {
                                    model: win.crumbs.slice(0, Math.max(0, win.crumbs.length - 1))
                                    delegate: Row {
                                        required property var modelData
                                        required property int index
                                        spacing: 4
                                        StyledText {
                                            visible: index > 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "›"
                                            font.pixelSize: 13
                                            color: Tacit.inkMeta
                                        }
                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.name
                                            font.pixelSize: 13
                                            color: crumbArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                                            MouseArea {
                                                id: crumbArea
                                                anchors.fill: parent
                                                anchors.margins: -4
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: win.go(modelData.path)
                                            }
                                        }
                                    }
                                }
                            }
                            MouseArea {   // the empty header ground: click to edit the path
                                anchors.fill: parent
                                z: -1
                                onClicked: win.editingPath = true
                            }
                            TextInput {
                                id: pathEdit
                                anchors.fill: parent
                                anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                visible: win.editingPath
                                font.family: Appearance.font.family.monospace
                                font.pixelSize: 14
                                color: Tacit.inkMain
                                selectionColor: Appearance.colors.colSecondaryContainer
                                selectedTextColor: Appearance.colors.colOnSecondaryContainer
                                onVisibleChanged: {
                                    if (visible) {
                                        text = win.folder;
                                        selectAll();
                                        forceActiveFocus();
                                    } else {
                                        keys.forceActiveFocus();
                                    }
                                }
                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Escape) { win.editingPath = false; event.accepted = true; }
                                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        const t = text.trim().replace(/^~/, win.home);
                                        if (t.length > 0) win.go(t);
                                        win.editingPath = false;
                                        event.accepted = true;
                                    }
                                }
                            }
                        }

                        // the views as one switch, the order as a word, hidden files, and something new
                        Row {
                            Layout.alignment: Qt.AlignVCenter
                            Layout.rightMargin: 6
                            spacing: 2
                            Repeater {
                                model: [{ v: "list", g: "view_list", t: "List (Ctrl+1)" },
                                        { v: "grid", g: "grid_view", t: "Grid (Ctrl+2)" },
                                        { v: "gallery", g: "view_carousel", t: "Gallery (Ctrl+3)" }]
                                delegate: ToolGlyph {
                                    required property var modelData
                                    glyph: modelData.g
                                    on: win.view === modelData.v
                                    tip: modelData.t
                                    onActivated: win.setView(modelData.v)
                                }
                            }
                            Item { width: 10; height: 30 }
                            ToolWord {
                                id: sortWordButton
                                text: win.sortWord + (win.sortReversed ? " ↓" : " ↑")
                                glyph: "sort"
                                compact: win.width < 900
                                tip: "Sort"
                                onActivated: win.openMenuAt(sortWordButton, [
                                    { "id": "name", "label": "Name", "glyph": win.sortField === FolderListModel.Name ? "check" : "", "run": () => win.sortBy(FolderListModel.Name) },
                                    { "id": "time", "label": "Modified", "glyph": win.sortField === FolderListModel.Time ? "check" : "", "run": () => win.sortBy(FolderListModel.Time) },
                                    { "id": "size", "label": "Size", "glyph": win.sortField === FolderListModel.Size ? "check" : "", "run": () => win.sortBy(FolderListModel.Size) },
                                    { "id": "kind", "label": "Kind", "glyph": win.sortField === FolderListModel.Type ? "check" : "", "run": () => win.sortBy(FolderListModel.Type) },
                                    { "id": "flip", "label": win.sortReversed ? "Ascending" : "Descending", "glyph": "swap_vert", "run": () => win.sortReversed = !win.sortReversed }])
                            }
                            ToolGlyph {
                                glyph: win.showHidden ? "visibility" : "visibility_off"
                                on: win.showHidden
                                tip: win.showHidden ? "Hide hidden files (Ctrl+H)" : "Show hidden files (Ctrl+H)"
                                onActivated: win.showHidden = !win.showHidden
                            }
                            ToolGlyph {
                                id: newButton
                                glyph: "add"
                                tip: "New folder or file"
                                onActivated: win.openMenuAt(newButton, [
                                    { "id": "newfolder", "label": "New folder", "glyph": "create_new_folder", "run": () => win.newFolder() },
                                    { "id": "newfile", "label": "New file", "glyph": "note_add", "run": () => win.newFile() }])
                            }
                        }

                        ToolbarTextField {
                            id: search
                            Layout.fillHeight: false
                            // tiled narrow, the path needs the room more than the field
                            Layout.preferredWidth: Math.max(140, Math.min(230, win.width * 0.3))
                            Layout.preferredHeight: 36
                            radius: Appearance.rounding.full
                            colBackground: Appearance.m3colors.m3surfaceContainerHighest
                            font.pixelSize: 15
                            leftPadding: 34
                            text: win.query
                            onTextChanged: queryDebounce.restart()
                            Timer {   // a held key must not walk the folder once per character
                                id: queryDebounce
                                interval: 120
                                onTriggered: win.query = search.text
                            }
                            Connections {   // a folder change clears the filter: the field follows
                                target: win
                                function onQueryChanged() { if (search.text !== win.query) search.text = win.query; }
                            }
                            MaterialSymbol {
                                anchors.left: parent.left
                                anchors.leftMargin: 11
                                anchors.verticalCenter: parent.verticalCenter
                                text: "search"
                                iconSize: 18
                                color: Tacit.inkSec
                            }
                            Rectangle {   // focused: a hairline in the accent
                                anchors.fill: parent
                                radius: Appearance.rounding.full
                                color: "transparent"
                                border.width: 1
                                border.color: Appearance.colors.colPrimary
                                opacity: search.activeFocus ? 0.8 : 0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                            }
                            placeholderText: win.searching && !win.recentShown && !win.largeOld && !win.shelfShown ? `Searching under ${Files.placeName(win.folder)}` : "Search"
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Escape) {
                                    if (win.searching) win.endSearch();
                                    else if (text.length > 0) text = "";
                                    else keys.forceActiveFocus();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    if (text.trim().length > 0) { win.deepSearch(text); keys.forceActiveFocus(); }
                                    else if (folderModel.count > 0) { win.selectOnly(0); keys.forceActiveFocus(); }
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Down) {
                                    keys.forceActiveFocus();
                                    if (win.searching) { win.searchCursor = Math.min(win.hits.length - 1, win.searchCursor + 1); }
                                    else win.moveCursor(1, false);
                                    event.accepted = true;
                                }
                            }
                        }
                    }
                    Rectangle {   // the one hairline
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        Layout.leftMargin: 8
                        Layout.rightMargin: 8
                        height: 1
                        color: Appearance.colors.colOutlineVariant
                        opacity: 0.5
                    }

                    // ---------------------------------------------------- columns (list only)
                    Item {
                        Layout.fillWidth: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 8
                        Layout.preferredHeight: win.view === "list" && !win.searching ? 28 : 0
                        visible: win.view === "list" && !win.searching
                        clip: true
                        component SortLabel: StyledText {
                            required property int field
                            property bool alignRight: false
                            readonly property bool active: win.sortField === field
                            font.pixelSize: 13
                            color: active ? Tacit.inkMain : Tacit.inkMeta
                            horizontalAlignment: alignRight ? Text.AlignRight : Text.AlignLeft
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    win.editingIndex = -1;   // the rows are about to move under the field
                                    if (win.sortField === parent.field) win.sortReversed = !win.sortReversed;
                                    else { win.sortField = parent.field; win.sortReversed = false; }
                                }
                            }
                        }
                        SortLabel { field: FolderListModel.Name; text: "Name" + (active ? (win.sortReversed ? " ↓" : " ↑") : ""); anchors.left: parent.left; anchors.leftMargin: 46; anchors.verticalCenter: parent.verticalCenter }
                        SortLabel { field: FolderListModel.Time; text: (active ? (win.sortReversed ? "↓ " : "↑ ") : "") + "Modified"; alignRight: true; width: 84; anchors.right: parent.right; anchors.rightMargin: 12 + 72 + 18; anchors.verticalCenter: parent.verticalCenter }
                        SortLabel { field: FolderListModel.Size; text: (active ? (win.sortReversed ? "↓ " : "↑ ") : "") + "Size"; alignRight: true; width: 72; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter }
                    }

                    // ---------------------------------------------------- the files
                    Item {
                        id: filesArea
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.leftMargin: 8
                        Layout.rightMargin: 8
                        clip: true

                        ListView {
                            id: list
                            anchors.fill: parent
                            bottomMargin: win.forPick ? 64 : 0   // the last rows scroll clear of the pick bar
                            visible: win.view === "list" && !win.searching
                            model: folderModel
                            // A row the filter hides keeps its place in the model with no height;
                            // a ListView still lays its spacing after it, so while a filter is on
                            // the rows sit flush instead of leaving a gap per hidden row.
                            spacing: win.query.length > 0 ? 0 : 1
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar { id: listBar }
                            GlideWheel { view: list }
                            function uriList(i) { return win.uriList(i); }
                            readonly property Item dragProxy: dragProxy
                            function nameTaken(name, except) { return win.nameTaken(name, except); }
                            function editNext(i) { const n = win.nextShown(i + 1, 1); if (n >= 0) win.renameAt(n); else win.editingIndex = -1; }
                            function selectedCount() { return win.selectedPaths.length; }
                            delegate: FilesRow {
                                hidden: !win.nameShown(fileName)
                                selected: win.selectedMap[filePath] === true
                                current: win.cursor === index
                                flash: win.flashPath === filePath
                                // only a list row has a field, and only while the list is the view
                                editing: win.editingIndex === index && win.view === "list" && !win.searching
                                cut: win.cutMap[filePath] === true
                                offer: win.offerFor(filePath)
                                onOfferTaken: i => { const o = win.offerFor(win.pathAt(i)); if (o) o.run(); }
                                onOfferDismissed: i => win.dismissOffer(win.pathAt(i))
                                onRenamed: (i, name) => win.rename(i, name)
                                onEditDone: { win.editingIndex = -1; keys.forceActiveFocus(); }
                                onDroppedInto: (i, urls, mods, internal) => win.dropIn(urls, mods, internal, win.pathAt(i))
                                onBand: (sx, sy) => win.bandFromScene(sx, sy)
                                onBandEnd: win.bandStop()
                                onMiddleClicked: i => { if (folderModel.get(i, "fileIsDir")) Files.openNewAt(win.pathAt(i)); }
                                onSlowClicked: i => win.renameAt(i)
                                onPressedAt: (mouse, i) => win.pressAt(mouse, i)
                                onClicked: (mouse, i) => win.clickAt(mouse, i)
                                onDoubleClicked: i => win.openIndex(i)
                                onContextRequested: (i, x, y) => win.showActions(i, x, y)
                            }
                        }
                        GridView {
                            id: grid
                            anchors.fill: parent
                            bottomMargin: win.forPick ? 64 : 0   // the last rows scroll clear of the pick bar
                            visible: win.view === "grid" && !win.searching
                            model: folderModel
                            // the cell grows by what its picture grows (120 x 100 at the made size)
                            readonly property real size: win.gridSize
                            cellWidth: Math.round(156 + 120 * (win.gridSize - 1))
                            cellHeight: Math.round(176 + 100 * (win.gridSize - 1))
                            Behavior on cellWidth { Anim { type: Anim.FastSpatial } }
                            Behavior on cellHeight { Anim { type: Anim.FastSpatial } }
                            // a pinch on the touchpad steps the size, a step per 25 % of the pinch
                            PinchHandler {
                                target: null
                                property real from: 1
                                onActiveChanged: if (active) from = activeScale
                                onActiveScaleChanged: {
                                    if (activeScale / from > 1.25) { win.zoomGrid(1); from = activeScale; }
                                    else if (activeScale / from < 0.8) { win.zoomGrid(-1); from = activeScale; }
                                }
                            }
                            readonly property int columns: Math.max(1, Math.floor(width / cellWidth))
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar { id: gridBar }
                            GlideWheel { view: grid }
                            function uriList(i) { return win.uriList(i); }
                            readonly property Item dragProxy: dragProxy
                            delegate: FilesCell {
                                selected: win.selectedMap[filePath] === true
                                current: win.cursor === index
                                flash: win.flashPath === filePath
                                cut: win.cutMap[filePath] === true
                                onPressedAt: (mouse, i) => win.pressAt(mouse, i)
                                onClicked: (mouse, i) => win.clickAt(mouse, i)
                                onDoubleClicked: i => win.openIndex(i)
                                onContextRequested: (i, x, y) => win.showActions(i, x, y)
                            }
                        }
                        GalleryView {
                            id: galleryView
                            anchors.fill: parent
                            visible: win.view === "gallery" && !win.searching
                            model: folderModel
                            cursor: win.cursor
                            selectedMap: win.selectedMap
                            shown: name => win.nameShown(name)
                            onPicked: (i, mouse) => win.clickAt(mouse, i)
                            onOpened: i => win.openIndex(i)
                            onContextRequested: (i, x, y) => win.showActions(i, x, y)
                        }
                        // deep search hits: name, its place under this folder, in the same rows
                        ListView {
                            id: hitList
                            anchors.fill: parent
                            bottomMargin: win.forPick ? 64 : 0   // the last rows scroll clear of the pick bar
                            visible: win.searching
                            model: win.hits
                            spacing: 1
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: StyledScrollBar { id: hitBar }
                            GlideWheel { view: hitList }
                            section.property: win.recentShown ? "day" : ""
                            section.delegate: Item {
                                required property string section
                                width: hitList.width
                                height: 34
                                StyledText {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.bottom: parent.bottom
                                    anchors.bottomMargin: 6
                                    text: section
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    color: Tacit.inkSec
                                }
                            }
                            delegate: Item {
                                id: hit
                                required property var modelData
                                required property int index
                                readonly property var thing: Things.describe(modelData.path + (modelData.isDir ? "/" : ""))
                                width: hitList.width
                                height: 46
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 8
                                    color: win.searchCursor === hit.index ? Appearance.colors.colSecondaryContainer
                                        : (hitArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.90) : "transparent")
                                    Behavior on color { ColorAnimation { duration: 80 } }
                                }
                                MaterialSymbol {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: hit.thing.glyph
                                    fill: hit.modelData.isDir ? 1 : 0
                                    iconSize: 22
                                    color: hit.modelData.isDir ? Appearance.colors.colPrimary : Tacit.inkSec
                                }
                                Column {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 46
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    StyledText {
                                        width: parent.width
                                        text: hit.modelData.name
                                        elide: Text.ElideMiddle
                                        font.pixelSize: 16
                                        color: win.searchCursor === hit.index ? Appearance.colors.colOnSecondaryContainer : Tacit.inkMain
                                    }
                                    StyledText {
                                        width: parent.width
                                        text: Voice.facts([hit.modelData.rel.length > 0 ? hit.modelData.rel : Files.placeName(win.folder), hit.thing.from, hit.modelData.bytes ? Voice.size(hit.modelData.bytes) : "", hit.modelData.at ? Voice.age(hit.modelData.at) : ""])
                                        elide: Text.ElideMiddle
                                        font.pixelSize: 14
                                        color: Tacit.inkSec
                                    }
                                }
                                // The window's drag source, not this row's: the hits are
                                // replaced under a live drag (a search flushes every 40 ms, the
                                // shelf rebuilds on a change) and a destroyed source left Qt
                                // reading a dead item. See FilesRow.
                                MouseArea {
                                    id: hitArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    property bool rightHeld: false
                                    drag.target: hitArea.rightHeld ? null : dragProxy
                                    drag.threshold: 10
                                    onPressed: mouse => hitArea.rightHeld = mouse.button !== Qt.LeftButton
                                    drag.onActiveChanged: {
                                        if (drag.active) {
                                            dragProxy.Drag.mimeData = { "text/uri-list": "file://" + hit.modelData.path };
                                            dragProxy.Drag.active = true;
                                        } else {
                                            dragProxy.Drag.active = false;
                                        }
                                    }
                                    onReleased: { if (dragProxy.Drag.active) dragProxy.Drag.drop(); }
                                    onClicked: mouse => {
                                        win.searchCursor = hit.index;
                                        if (mouse.button === Qt.RightButton) {
                                            actions.model = hit.modelData.isDir
                                                ? [{ "id": "open", "label": "Open", "glyph": "folder_open", "run": () => win.openHit(hit.index) },
                                                   { "id": "show", "label": "Show in its folder", "glyph": "folder", "run": () => win.revealHit(hit.index) }]
                                                : [{ "id": "show", "label": "Show in its folder", "glyph": "folder", "run": () => win.revealHit(hit.index) }].concat(Things.actions(hit.modelData.path).filter(a => a.id !== "show" && a.id !== "park"));
                                            if (win.shelfShown)
                                                actions.model = [{ "id": "unpark", "label": "Take off the shelf", "glyph": "remove", "run": () => DropShelf.remove(hit.modelData.path + (hit.modelData.isDir ? "/" : "")) },
                                                                 { "id": "clear", "label": "Clear the shelf", "glyph": "delete_sweep", "run": () => DropShelf.clear() }].concat(actions.model);
                                            const pos = body.mapFromItem(null, hit.mapToItem(null, mouse.x, mouse.y).x, hit.mapToItem(null, mouse.x, mouse.y).y);
                                            actions.x = Math.min(pos.x, body.width - 256);
                                            actions.y = Math.min(pos.y, body.height - (actions.model.length * 35 + 20));
                                            actions.open();
                                        }
                                    }
                                    onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) win.openHit(hit.index); }
                                }
                            }
                        }
                        // Files dropped here, from another window or another app: a move from
                        // Files' own drag, a copy from anywhere else; Ctrl forces a copy, Shift a move.
                        DropArea {
                            id: dropZone
                            anchors.fill: parent
                            keys: ["text/uri-list"]
                            onDropped: drop => {
                                drop.accept();
                                win.dropIn(drop.urls ?? [], drop.keyboardModifiers, drop.source !== null, win.folder);
                            }
                        }
                        Rectangle {   // the ground lights while something hovers over it
                            anchors.fill: parent
                            radius: 12
                            color: Appearance.colors.colPrimary
                            opacity: dropZone.containsDrag ? 0.06 : 0
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                        }
                        // The empty ground: a click clears the selection, a drag draws a band, a
                        // right click gives the folder's actions. It sits above the views, not
                        // under them: a Flickable accepts every left press over its own area, so
                        // beneath one this area only ever saw right presses (which a Flickable
                        // does not accept) and the band from the ground was dead code. A press on
                        // a row or on the scroll bar is declined here and reaches its own handler.
                        MouseArea {
                            id: ground
                            anchors.fill: parent
                            z: 4
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            property real bandX: 0
                            property real bandY: 0
                            property bool banding: false
                            readonly property var bar: win.searching ? hitBar : win.view === "grid" ? gridBar : listBar
                            function onGround(x, y) {
                                if (x >= ground.width - (ground.bar?.width ?? 0))
                                    return false;
                                if (win.searching)
                                    return hitList.indexAt(x, y + hitList.contentY) < 0;
                                if (win.view === "grid")
                                    return grid.indexAt(x + grid.contentX, y + grid.contentY) < 0;
                                return list.indexAt(x, y + list.contentY) < 0;
                            }
                            onPressed: mouse => {
                                if (!ground.onGround(mouse.x, mouse.y)) {
                                    mouse.accepted = false;
                                    return;
                                }
                                keys.forceActiveFocus();
                                bandX = mouse.x; bandY = mouse.y; banding = false;
                            }
                            // a drag on the ground draws a band; rows under it are the selection
                            onPositionChanged: mouse => {
                                if (!pressed || !(pressedButtons & Qt.LeftButton))
                                    return;
                                if (!banding && Math.abs(mouse.x - bandX) + Math.abs(mouse.y - bandY) < 6)
                                    return;
                                banding = true;
                                const top = Math.min(bandY, mouse.y), bottom = Math.max(bandY, mouse.y);
                                band.x = Math.min(bandX, mouse.x); band.y = top;
                                band.width = Math.abs(mouse.x - bandX); band.height = bottom - top;
                                win.selectBand(top, bottom, Math.min(bandX, mouse.x), Math.max(bandX, mouse.x));
                            }
                            onReleased: mouse => {
                                if (banding) { banding = false; return; }
                                if (mouse.button === Qt.RightButton) {
                                    actions.model = win.folderActions;
                                    const pos = ground.mapToItem(body, mouse.x, mouse.y);
                                    actions.x = Math.min(pos.x, body.width - 244);
                                    actions.y = Math.min(pos.y, body.height - 160);
                                    actions.open();
                                } else if (mouse.button === Qt.LeftButton) {
                                    win.clearSelection();
                                }
                            }
                        }
                        Rectangle {
                            id: band
                            visible: ground.banding
                            color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85)
                            border.width: 1
                            border.color: Appearance.colors.colPrimary
                            radius: 4
                            z: 5
                        }
                        StyledText {
                            anchors.centerIn: parent
                            visible: win.searching ? (!win.searchRunning && win.hits.length === 0) : (folderModel.status === FolderListModel.Ready && win.shownCount === 0)
                            text: win.searching ? "Nothing found" : win.unreadable ? "No permission to look in here" : win.query.length > 0 ? "Nothing matches" : "Nothing here"
                            font.pixelSize: 15
                            color: Tacit.inkSec
                        }
                    }

                    // ---------------------------------------------------- status
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 16
                        Layout.rightMargin: 12
                        Layout.topMargin: 4
                        Layout.bottomMargin: 2
                        spacing: 10
                        StyledText {
                            Layout.maximumWidth: parent.width - 140
                            text: win.statusLine
                            elide: Text.ElideRight
                            font.pixelSize: 15
                            color: win.activeJob?.state === "failed" || win.statusLine.startsWith("Can't") ? Appearance.colors.colError : Tacit.inkSec
                        }
                        // the answer to what just happened sits right after it, in the accent
                        StatusPill { visible: win.activeJob !== null; label: "Stop"; glyph: "close"; onActivated: win.stopJob() }
                        StatusPill { visible: win.activeJob === null && win.undoJob.length > 0; label: "Undo"; glyph: "undo"; accent: true; onActivated: win.undo() }
                        Item { Layout.fillWidth: true }
                        StyledText {
                            text: win.freeLine
                            font.pixelSize: 13
                            font.family: Appearance.font.family.numbers
                            color: Tacit.inkMeta
                        }
                    }
                }

                // ---------------------------------------------------- the third column
                FilesPreview {
                    id: previewColumn
                    showLook: win.view !== "gallery"
                    Layout.fillHeight: true
                    Layout.preferredWidth: win.previewOpen ? 300 : 0
                    Layout.leftMargin: win.previewOpen ? 8 : 0
                    visible: Layout.preferredWidth > 0
                    clip: true
                    Behavior on Layout.preferredWidth { Anim {} }
                    path: win.previewPath
                    folder: win.folder
                    isDir: win.previewPath.length > 0 ? (folderModel.get(win.cursor, "fileIsDir") ?? false) : false
                    size: win.previewPath.length > 0 ? (folderModel.get(win.cursor, "fileSize") ?? 0) : 0
                    modified: win.previewPath.length > 0 ? (folderModel.get(win.cursor, "fileModified") ?? new Date(0)) : new Date(0)
                    count: folderModel.count
                    folderBytes: win.folderBytes
                    many: win.selectedPaths.length > 1 ? win.selectedPaths.length : 0
                    manyBytes: win.previewOpen && win.selectedPaths.length > 1 ? win.selectedBytesNow() : 0
                    actions: win.selectedPaths.length > 1 ? win.selectionActions : (win.previewPath.length > 0 ? win.actionsFor(win.cursor) : win.folderActions)
                }
            }
        }

        RenameSheet {
            id: renameSheet
            visible: false
            parent: body
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 56
            onApply: pairs => win.run("renames", pairs.reduce((a, p) => a.concat(p), []))
            onCancelled: keys.forceActiveFocus()
        }

        // ---------------------------------------------------------------- actions
        Popup {
            id: actions
            property var model: []
            padding: 6
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
            // it opens from the pointer, on the quick curves Praxis and Graphis use
            transformOrigin: Item.TopLeft
            enter: Transition {
                Anim { property: "opacity"; from: 0; to: 1; type: Anim.FastEffects }
                Anim { property: "scale"; from: 0.94; to: 1; type: Anim.FastSpatial }
            }
            exit: Transition { Anim { property: "opacity"; to: 0; type: Anim.FastEffects } }
            background: Rectangle {
                radius: 14
                color: Appearance.m3colors.m3surfaceContainerHigh
                border.width: 1
                border.color: Tacit.hairline
            }
            contentItem: Column {
                spacing: 1
                Repeater {
                    model: actions.model
                    delegate: Item {
                        required property var modelData
                        width: 236
                        height: 34
                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: actArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.90) : "transparent"
                        }
                        MaterialSymbol {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !(modelData.icon ?? "")
                            text: modelData.glyph
                            iconSize: 18
                            color: Tacit.inkSec
                        }
                        IconImage {   // an application's own icon, when the row is an application
                            anchors.left: parent.left
                            anchors.leftMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            visible: (modelData.icon ?? "").length > 0
                            implicitSize: 20
                            source: (modelData.icon ?? "").length > 0 ? Quickshell.iconPath(modelData.icon, "image-missing") : ""
                        }
                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: 38
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            elide: Text.ElideRight
                            font.pixelSize: 15
                            color: Tacit.inkMain
                        }
                        MouseArea {
                            id: actArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { actions.close(); modelData.run(); }
                        }
                    }
                }
            }
        }
    }

    // Picking for another app (Files.pick): a bar floating at the window's foot on the
    // filmstrip's solid ground, not modal, so the list stays live. It names the app that asked;
    // Choose, the one filled pill, appears once something is picked; Cancel sends an empty list.
    Rectangle {
        id: pickBar
        parent: body
        z: 20
        visible: win.forPick && Files.picking !== null
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 40
        width: pickRow.implicitWidth + 40
        height: 52
        radius: 18
        readonly property string asker: Files.picking?.asker ?? ""
        readonly property string wants: Files.picking?.dir === true ? "a folder" : "a file"
        // solid, as the filmstrip's: frost over the window's own glass does not read
        color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.04)
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3outlineVariant, 0.4)
        Row {
            id: pickRow
            anchors.centerIn: parent
            spacing: 12
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: Files.picking?.dir === true ? "drive_folder_upload" : "upload_file"
                iconSize: 20
                color: Appearance.colors.colPrimary
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: pickBar.asker.length > 0 ? `${pickBar.asker} wants ${pickBar.wants}` : `Choose ${pickBar.wants}`
                font.pixelSize: 15
                color: Tacit.inkMain
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, 260)
                text: win.pickPaths.length === 0 ? (Files.picking?.dir === true ? "Pick a folder" : "Pick a file")
                    : win.pickPaths.length === 1 ? win.pickPaths[0].split("/").pop()
                    : `${win.pickPaths.length} files`
                elide: Text.ElideMiddle
                font.pixelSize: 15
                color: Tacit.inkSec
                rightPadding: 4
            }
            Repeater {
                model: [{ "label": "Cancel", "accent": false }, { "label": "Choose", "accent": true }]
                delegate: Rectangle {
                    required property var modelData
                    // Choose appears once something is picked: never a faded button to read around
                    visible: !modelData.accent || win.pickPaths.length > 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: pickText.implicitWidth + 28
                    height: 32
                    radius: Appearance.rounding.full
                    // accent: the filled primary pill of the password request's confirm (PolkitContent.qml);
                    // otherwise the palette's highlight wash
                    color: modelData.accent ? Appearance.colors.colPrimary
                        : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, pickArea.containsMouse ? 0.88 : 0.92)
                    StyledText {
                        id: pickText
                        anchors.centerIn: parent
                        text: modelData.label
                        font.pixelSize: 14
                        font.weight: modelData.accent ? Font.DemiBold : Font.Normal
                        color: modelData.accent ? Appearance.colors.colOnPrimary : Tacit.inkMain
                    }
                    MouseArea {
                        id: pickArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.pickDone(modelData.accent ? win.pickPaths : [])
                    }
                }
            }
        }
    }

    // A sheet at the foot of the list: one question, its lines, two or three answers. The
    // list stays readable behind it.
    Popup {
        id: sheet
        property string title: ""
        property var lines: []
        property var buttons: []
        property var rows: []       // choices as rows (Send to); empty for a question
        property int safe: 1        // the button Enter takes: never the one that destroys
        onAboutToShow: if (rows.length === 0 && buttons.length === 0) close()
        modal: true
        onOpened: sheetKeys.forceActiveFocus()
        onClosed: { keys.forceActiveFocus(); rows = []; safe = 1; }
        dim: false
        closePolicy: Popup.CloseOnEscape
        padding: 18
        x: Math.round((body.width - width) / 2)
        y: body.height - height - 48
        width: Math.min(460, body.width - 80)
        background: Rectangle {
            radius: 18
            color: Appearance.m3colors.m3surfaceContainerHigh
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
        }
        enter: Transition { NumberAnimation { property: "y"; from: body.height; duration: 220; easing.type: Easing.OutCubic } NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 } }
        exit: Transition { NumberAnimation { property: "opacity"; to: 0; duration: 120 } }
        contentItem: Column {
            id: sheetKeys
            spacing: 8
            focus: true
            Keys.onReturnPressed: { const b = sheet.buttons[sheet.safe]; sheet.close(); if (b) b.run(); }
            Keys.onEnterPressed: { const b = sheet.buttons[sheet.safe]; sheet.close(); if (b) b.run(); }
            StyledText {
                width: parent.width
                text: sheet.title
                wrapMode: Text.Wrap
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: Tacit.inkMain
            }
            Repeater {
                model: sheet.lines
                delegate: StyledText {
                    required property var modelData
                    width: parent.width
                    text: modelData
                    elide: Text.ElideMiddle
                    font.pixelSize: 14
                    color: Tacit.inkSec
                }
            }
            Repeater {
                model: sheet.rows
                delegate: Item {
                    required property var modelData
                    width: parent.width
                    height: 38
                    Rectangle {
                        anchors.fill: parent
                        radius: 8
                        color: rowArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.90) : "transparent"
                    }
                    MaterialSymbol {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.glyph
                        iconSize: 20
                        color: Tacit.inkSec
                    }
                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 40
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        elide: Text.ElideRight
                        font.pixelSize: 15
                        color: Tacit.inkMain
                    }
                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { sheet.close(); modelData.run(); }
                    }
                }
            }
            Item { width: 1; height: 6 }
            Row {
                anchors.right: parent.right
                spacing: 8
                Repeater {
                    model: sheet.buttons
                    delegate: RippleButton {
                        required property var modelData
                        implicitHeight: 34
                        leftPadding: 16
                        rightPadding: 16
                        buttonRadius: Appearance.rounding.full
                        colBackground: modelData.tone === "error" ? Appearance.colors.colError : Appearance.colors.colLayer2
                        colBackgroundHover: modelData.tone === "error" ? Appearance.colors.colError : Appearance.colors.colLayer2Hover
                        releaseAction: () => { sheet.close(); modelData.run(); }
                        contentItem: StyledText {
                            text: modelData.label
                            font.pixelSize: 15
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: modelData.tone === "error" ? Appearance.colors.colOnError : Appearance.colors.colOnLayer2
                        }
                    }
                }
            }
        }
    }

    component StatusPill: RippleButton {
        id: sp
        property string label: ""
        property string glyph: ""
        property bool accent: false
        signal activated
        implicitHeight: 32
        leftPadding: 12
        rightPadding: 16
        buttonRadius: Appearance.rounding.full
        colBackground: accent ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: accent ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        releaseAction: () => sp.activated()
        contentItem: Row {
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: sp.glyph
                iconSize: 18
                color: sp.accent ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: sp.label
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: sp.accent ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
            }
        }
    }

    // a header tool: a glyph, on a wash while it is the one in use (the view) or on (hidden files)
    component ToolGlyph: Item {
        id: tg
        property string glyph: ""
        property string tip: ""
        property bool on: false
        signal activated()
        width: 30
        height: 30
        Rectangle {
            anchors.fill: parent
            radius: 8
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, tg.on ? 0.88 : tgArea.containsMouse ? 0.95 : 1)
            Behavior on color { ColorAnimation { duration: 90 } }
        }
        MaterialSymbol {
            anchors.centerIn: parent
            text: tg.glyph
            iconSize: 18
            color: tg.on || tgArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
        }
        MouseArea { id: tgArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tg.activated() }
        StyledToolTip { text: tg.tip; extraVisibleCondition: tgArea.containsMouse }
    }
    // a header tool that says its state in a word (the order); narrow, only its glyph
    component ToolWord: Item {
        id: tw
        property string text: ""
        property string glyph: ""
        property string tip: ""
        property bool compact: false
        signal activated()
        width: tw.compact ? 30 : twRow.implicitWidth + 18
        height: 30
        Rectangle {
            anchors.fill: parent
            radius: 8
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, twArea.containsMouse ? 0.95 : 1)
            Behavior on color { ColorAnimation { duration: 90 } }
        }
        Row {
            id: twRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; text: tw.glyph; iconSize: 18; color: twArea.containsMouse ? Tacit.inkMain : Tacit.inkSec }
            StyledText { anchors.verticalCenter: parent.verticalCenter; visible: !tw.compact; text: tw.text; font.pixelSize: 14; color: twArea.containsMouse ? Tacit.inkMain : Tacit.inkSec }
        }
        MouseArea { id: twArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tw.activated() }
        StyledToolTip { text: tw.compact ? `${tw.tip}: ${tw.text}` : tw.tip; extraVisibleCondition: twArea.containsMouse }
    }

    component HeaderButton: RippleButton {
        id: hb
        property string glyph: ""
        signal activated
        implicitWidth: 32
        implicitHeight: 32
        padding: 0
        buttonRadius: Appearance.rounding.full
        opacity: enabled ? 1 : 0.35
        releaseAction: () => hb.activated()
        contentItem: MaterialSymbol {
            text: hb.glyph
            iconSize: 20
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: Tacit.inkMain
        }
    }
}
