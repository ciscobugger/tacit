import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.services

/**
 * The Files windows. One per request (Super+E reuses the open one; Super+Shift+E always
 * opens another); each is a real toplevel that Hyprland tiles or floats like any app.
 */
Scope {
    id: root

    Component {
        id: windowComp
        FilesWindow {}
    }
    Component {
        id: saveComp
        SaveWindow {}
    }

    property var windows: []

    function newest() {
        return root.windows.length > 0 ? root.windows[root.windows.length - 1] : null;
    }
    // A picker window turns "open this file" into the pick itself for as long as it lives, so a
    // reveal, an action or a search that landed in one would answer someone else's file chooser
    // with the user's next double-click.
    function newestOpen() {
        const open = root.windows.filter(w => !w.forPick);
        return open.length > 0 ? open[open.length - 1] : null;
    }
    function create(folder, select, reason) {
        const w = windowComp.createObject(root, { "folder": folder, "selectPath": select, "reason": reason });
        w.closing.connect(() => root.forget(w));   // never hold a destroyed window
        root.windows = root.windows.concat([w]);
    }
    function focus(target) {
        const w = target ?? root.newest();
        if (!w)
            return;
        // the window's own address once it has caught it: every Files window carries the same
        // class and title, so the first match in the list was as likely to be an older one
        if (w.hyprAddress.length > 0) {
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${w.hyprAddress}" })`);
            return;
        }
        const client = HyprlandData.windowList.find(c => (c.class ?? "").includes("quickshell") && c.title === w.title);
        if (client)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${client.address}" })`);
    }

    Connections {
        target: Files
        // a reveal or an "at" reuses the newest ordinary window; a new one only when there is none
        function onOpenRequested(folder, select, reason) {
            const w = root.newestOpen();
            if (!w) {
                root.create(folder, select, reason);
                return;
            }
            w.show(folder, select, reason);
            root.focus(w);
        }
        function onNewRequested(folder, select, reason) {
            root.create(folder, select, reason);
        }
        function onFocusRequested() {
            root.focus();
        }
        function onActRequested(name) {
            root.newestOpen()?.perform(name);
        }
        function onSearchRequested(query) {
            const w = root.newestOpen();
            if (w) w.deepSearch(query);
        }
        function onSaveRequested(folder) {
            saveComp.createObject(root, { "startFolder": folder });
        }
        function onShelfRequested() {
            const w = root.newest();
            if (w) w.showShelf();
        }
    }

    function forget(w) {
        root.windows = root.windows.filter(x => x !== w);
    }
}
