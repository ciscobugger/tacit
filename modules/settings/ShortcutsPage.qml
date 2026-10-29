import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

/**
 * Settings > Keyboard & touchpad > Shortcuts: every shortcut by what it does, grouped. Select a row and press the new
 * keys where it stands; a clash is said under the row with the way out; every change can be undone, and a row can go
 * back to Tacit's own keys. "Add a shortcut for an app" ends the first group. The work is in services/Shortcuts.qml.
 */
ColumnLayout {
    id: page
    spacing: 0

    // the row selected ("" none; "app<i>" for an added app's) and what it is doing; see ShortcutRow.mode
    property string sel: ""
    property string mode: ""
    property string held: ""
    property var pend: null              // the keys pressed, and what holds them, while a clash is said
    property string clashText: ""
    property string noticeText: ""
    // "Add a shortcut for an app"
    property bool addOpen: false
    property string query: ""
    property var adding: null            // the app picked, waiting for its keys
    property var items: ({})

    function rowFor(id) { return id.startsWith("app") ? Shortcuts.apps[parseInt(id.slice(3))] : Shortcuts.rowIndex[id]; }
    function doesOf(id) { return id.startsWith("app") ? `opens ${rowFor(id).name}` : rowFor(id).does; }

    function select(id) {
        if (page.mode === "listening" || page.mode === "clash") page.stopListening();
        page.sel = id;
        page.mode = id === "" ? "" : "selected";
        page.held = "";
    }
    function change(id) {
        page.sel = id;
        page.held = "";
        page.pend = null;
        page.mode = "listening";
        Shortcuts.listen(true);
        page.items[id]?.listen();
    }
    function stopListening() {
        Shortcuts.listen(false);
        page.pend = null;
        page.adding = null;
    }
    function cancel() {
        const id = page.sel;
        page.stopListening();
        page.held = "";
        if (id === "adding") { page.sel = ""; page.mode = ""; return; }
        page.mode = "selected";
        page.items[id]?.focusRow();
    }
    function captured(id, combo, held) {
        Shortcuts.listen(false);
        page.held = combo;
        const why = Shortcuts.problem(combo);
        if (why !== "") { page.clashText = why; page.pend = { combo, holder: null }; page.mode = "clash"; return; }
        const adding = id === "adding";
        if (!adding && Shortcuts.keysOf(id).some(k => Shortcuts.norm(k) === Shortcuts.norm(combo))) { page.cancel(); return; }
        const holder = Shortcuts.holder(combo, id);
        if (holder === null) { page.commit(id, combo, null); return; }
        page.clashText = `${Shortcuts.said(combo)} already ${holder.does}.`;
        page.pend = { combo, holder };
        page.mode = "clash";
    }
    function commit(id, combo, takeFrom) {
        if (page.pend?.reset) { const hs = page.pend.reset; page.finishReset(id, hs); return; }
        const what = id === "adding" ? `opens ${page.adding.name}` : page.doesOf(id);
        if (id === "adding") {
            Shortcuts.addApp(page.adding.name, page.adding.run, page.adding.icon, combo, takeFrom);
            id = `app${Shortcuts.apps.length - 1}`;
            page.adding = null;
        } else if (id.startsWith("app")) Shortcuts.setAppKeys(parseInt(id.slice(3)), combo, takeFrom);
        else Shortcuts.setKeys(id, combo, takeFrom);
        page.sel = id;
        page.held = "";
        page.pend = null;
        page.noticeText = `${Shortcuts.said(combo)} now ${what}.`;
        page.mode = "done";
        noticeTimer.restart();
    }
    function undo() {
        noticeTimer.stop();
        Shortcuts.undo();
        page.mode = "";
        page.sel = "";
    }
    function reset(id) {
        if (id.startsWith("app")) { page.sel = ""; page.mode = ""; Shortcuts.removeApp(parseInt(id.slice(3))); return; }
        const hs = Shortcuts.resetHolders(id);
        if (hs.length === 0) { page.finishReset(id, null); return; }
        // Tacit's keys are somebody's now: say so in the row, as for any other clash
        page.sel = id;
        page.clashText = `${Shortcuts.said(hs[0].combo)} already ${hs[0].holder.does}.`;
        page.pend = { combo: hs[0].combo, holder: hs[0].holder, reset: hs };
        page.mode = "clash";
    }
    function finishReset(id, takeFrom) {
        Shortcuts.resetRow(id, takeFrom);
        page.sel = id;
        page.pend = null;
        page.noticeText = `${page.rowFor(id).name} has Tacit's keys again.`;
        page.mode = "done";
        noticeTimer.restart();
    }
    function move(id, by) {
        const ids = [];
        for (const g of Shortcuts.groups) {
            for (const r of g.rows) ids.push(r.id);
            if (g.name === "Open an app") Shortcuts.apps.forEach((a, i) => ids.push(`app${i}`));
        }
        const to = ids[ids.indexOf(id) + by];
        if (to !== undefined) page.items[to]?.focusRow();
    }
    // the Undo line stays a while, longer while the pointer or keyboard is on it
    Timer { id: noticeTimer; interval: 6000; onTriggered: if (page.mode === "done") page.mode = "" }
    // Ctrl+Z is the Undo's own key while its line shows
    Shortcut { sequence: "Ctrl+Z"; enabled: page.mode === "done"; onActivated: page.undo() }
    Component.onDestruction: page.stopListening()
    // Settings losing the keyboard (another window picked) ends a listening row: no half-set keys, the compositor's keys back
    readonly property bool active: Window.active
    onActiveChanged: if (!active && (page.mode === "listening" || page.mode === "clash")) page.cancel()

    StyledText {
        Layout.fillWidth: true
        Layout.leftMargin: 20
        Layout.rightMargin: 20
        Layout.topMargin: 4
        text: "Select a shortcut to change its keys. Super is the key next to Alt."
        font.pixelSize: Tacit.size.meta
        color: Tacit.inkMeta
        wrapMode: Text.Wrap
    }
    StyledText {
        visible: Shortcuts.broken
        Layout.fillWidth: true
        Layout.leftMargin: 20
        Layout.rightMargin: 20
        Layout.topMargin: 8
        text: "The list of shortcuts you changed could not be read, so Tacit's own keys are shown. Change one to start the list again."
        font.pixelSize: Tacit.size.meta
        color: Tacit.risk
        wrapMode: Text.Wrap
    }

    Repeater {
        model: Shortcuts.groups
        Group {
            id: grp
            required property var modelData
            title: grp.modelData.name
            Repeater {
                model: grp.modelData.rows
                ShortcutRow {
                    id: sr
                    required property var modelData
                    readonly property string rid: sr.modelData.id
                    readonly property bool mine: page.sel === sr.rid
                    Layout.fillWidth: true
                    glyph: sr.modelData.glyph
                    name: sr.modelData.name
                    keys: Shortcuts.keysOf(sr.rid)
                    changed: Shortcuts.isChanged(sr.rid)
                    canChange: Shortcuts.canChange(sr.rid)
                    canReset: Shortcuts.isChanged(sr.rid)
                    mode: sr.mine ? page.mode : ""
                    held: sr.mine ? page.held : ""
                    clashText: page.clashText
                    takeText: page.pend?.holder && page.pend.holder.kind !== "other" ? `Use it for ${sr.modelData.use}` : ""
                    takeNote: page.pend?.holder && page.pend.holder.kind !== "other" ? `${page.pend.holder.name} will have no shortcut.` : ""
                    noticeText: page.noticeText
                    Component.onCompleted: page.items[sr.rid] = sr
                    onSelectedBy: page.select(sr.rid)
                    onChange: page.change(sr.rid)
                    onReset: page.reset(sr.rid)
                    onCapturedKeys: (combo, held) => page.captured(sr.rid, combo, held)
                    onCapturedHeld: held => page.held = held
                    onCancelled: page.cancel()
                    onTakeIt: page.commit(sr.rid, page.pend.combo, page.pend.holder)
                    onChooseOther: page.change(sr.rid)
                    onUndone: page.undo()
                    onMoved: by => page.move(sr.rid, by)
                }
            }
            // the apps the person added a shortcut for, then the way to add one
            Repeater {
                model: grp.modelData.name === "Open an app" ? Shortcuts.apps : []
                ShortcutRow {
                    id: ar
                    required property var modelData
                    required property int index
                    readonly property string rid: `app${ar.index}`
                    readonly property bool mine: page.sel === ar.rid
                    Layout.fillWidth: true
                    glyph: ar.modelData.icon && Quickshell.iconPath(ar.modelData.icon, true) !== "" ? "" : "apps"
                    iconSource: ar.modelData.icon ? Quickshell.iconPath(ar.modelData.icon, true) : ""
                    name: ar.modelData.name
                    keys: [ar.modelData.keys]
                    canReset: true
                    resetWords: "Remove the shortcut"
                    mode: ar.mine ? page.mode : ""
                    held: ar.mine ? page.held : ""
                    clashText: page.clashText
                    takeText: page.pend?.holder && page.pend.holder.kind !== "other" ? `Use it for ${ar.modelData.name}` : ""
                    takeNote: page.pend?.holder && page.pend.holder.kind !== "other" ? `${page.pend.holder.name} will have no shortcut.` : ""
                    noticeText: page.noticeText
                    Component.onCompleted: page.items[ar.rid] = ar
                    onSelectedBy: page.select(ar.rid)
                    onChange: page.change(ar.rid)
                    onReset: page.reset(ar.rid)
                    onCapturedKeys: (combo, held) => page.captured(ar.rid, combo, held)
                    onCapturedHeld: held => page.held = held
                    onCancelled: page.cancel()
                    onTakeIt: page.commit(ar.rid, page.pend.combo, page.pend.holder)
                    onChooseOther: page.change(ar.rid)
                    onUndone: page.undo()
                    onMoved: by => page.move(ar.rid, by)
                }
            }
            // an app just picked, taking its keys
            ShortcutRow {
                id: nr
                visible: grp.modelData.name === "Open an app" && page.adding !== null
                Layout.fillWidth: true
                glyph: page.adding && page.adding.iconSource === "" ? "apps" : ""
                iconSource: page.adding?.iconSource ?? ""
                name: page.adding?.name ?? ""
                keys: []
                canChange: false
                mode: page.sel === "adding" ? page.mode : ""
                held: page.sel === "adding" ? page.held : ""
                hint: "Press the keys"
                clashText: page.clashText
                takeText: page.pend?.holder && page.pend.holder.kind !== "other" ? `Use it for ${page.adding?.name ?? ""}` : ""
                takeNote: page.pend?.holder && page.pend.holder.kind !== "other" ? `${page.pend.holder.name} will have no shortcut.` : ""
                Component.onCompleted: page.items["adding"] = nr
                onCapturedKeys: (combo, held) => page.captured("adding", combo, held)
                onCapturedHeld: held => page.held = held
                onCancelled: page.cancel()
                onTakeIt: page.commit("adding", page.pend.combo, page.pend.holder)
                onChooseOther: page.change("adding")
            }
            AddApp {
                visible: grp.modelData.name === "Open an app"
                Layout.fillWidth: true
                open: page.addOpen
                query: page.query
                onOpened: page.addOpen = true
                onClosed: { page.addOpen = false; page.query = ""; }
                onQueryEdited: q => page.query = q
                onPicked: app => {
                    page.addOpen = false;
                    page.query = "";
                    page.adding = app;
                    page.change("adding");
                }
            }
        }
    }
}
