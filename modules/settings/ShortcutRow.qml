import QtQuick
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

/**
 * One shortcut in the list: its mark, what it does, "Changed" when the person changed it, its keys at the right.
 * A click selects it (nothing changes by a click alone); the selected row shows its actions under it. Taking the new
 * keys, a clash and the Undo line all happen in the row's own place.
 * mode: "" rest, "selected" (actions under it), "listening" (the box takes the next keys), "clash" (said under the row,
 * with the way out), "done" (the Undo line under it). The page decides the mode; this draws it and says what was asked.
 */
FocusScope {
    id: r
    property string glyph: ""
    property string iconSource: ""     // an app's own picture, where there is no mark
    property string name: ""
    property var keys: []
    property string mode: ""
    property string held: ""
    property bool changed: false
    property bool canChange: true
    property bool canReset: false
    property string resetWords: "Back to Tacit's keys"
    property string hint: "Press the new keys"
    property string clashText: ""
    property string takeText: ""
    property string takeNote: ""
    property string noticeText: ""
    signal selectedBy()
    signal change()
    signal reset()
    signal capturedKeys(string combo, string held)
    signal capturedHeld(string held)
    signal cancelled()
    signal takeIt()
    signal chooseOther()
    signal undone()
    signal moved(int by)

    // where the name starts in a row of a list: 2 x space.l + icon.row
    readonly property real indent: 2 * Tacit.space.l + Tacit.icon.row
    readonly property bool capturing: mode === "listening" || mode === "clash"
    readonly property bool hasTake: takeText.length > 0
    readonly property bool strip: (mode === "selected" && (canChange || canReset)) || mode === "clash"
    readonly property real stripH: strip ? extra.height + Tacit.space.s : 0
    readonly property real slotH: mode === "done" ? Tacit.height.row + 2 * Tacit.space.s : 0
    implicitHeight: row.height + stripH + slotH
    height: implicitHeight

    function listen() { capture.forceActiveFocus(); }
    function focusRow() { row.forceActiveFocus(); }

    Item {
        id: row
        width: parent.width
        height: Tacit.height.row
        activeFocusOnTab: !r.capturing
        Keys.onReturnPressed: if (r.canChange) { if (r.mode !== "selected") r.selectedBy(); r.change(); }
        Keys.onEnterPressed: if (r.canChange) { if (r.mode !== "selected") r.selectedBy(); r.change(); }
        Keys.onSpacePressed: r.selectedBy()
        Keys.onUpPressed: r.moved(-1)
        Keys.onDownPressed: r.moved(1)
        Keys.onEscapePressed: if (r.mode === "selected") r.cancelled()
        onActiveFocusChanged: if (activeFocus && r.mode === "") r.selectedBy()

        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            radius: Tacit.radius.row
            color: ColorUtils.transparentize(Tacit.inkMain, 1 - (r.mode !== "" ? Tacit.wash.current : area.containsMouse ? Tacit.wash.hover : 0))
            border.width: row.activeFocus && (row.focusReason === Qt.TabFocusReason || row.focusReason === Qt.BacktabFocusReason) ? Tacit.state.focusRing : 0
            border.color: Tacit.accent
            Behavior on color { ColorAnimation { duration: Tacit.motion.hover.ms } }
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { row.forceActiveFocus(); r.selectedBy(); }
        }
        MaterialSymbol {
            visible: r.glyph.length > 0
            x: Tacit.space.l
            anchors.verticalCenter: parent.verticalCenter
            text: r.glyph
            iconSize: Tacit.icon.row
            color: Tacit.inkMeta
        }
        Image {
            visible: r.glyph.length === 0 && r.iconSource.length > 0
            x: Tacit.space.l
            anchors.verticalCenter: parent.verticalCenter
            width: Tacit.icon.row
            height: Tacit.icon.row
            sourceSize: Qt.size(Tacit.icon.row * 2, Tacit.icon.row * 2)
            source: r.iconSource
        }
        Row {
            x: r.indent
            anchors.verticalCenter: parent.verticalCenter
            spacing: Tacit.space.m
            StyledText {
                text: r.name
                font.pixelSize: Tacit.size.row
                color: Tacit.inkMain
            }
            StyledText {
                visible: r.changed
                text: "Changed"
                font.pixelSize: Tacit.size.row
                color: Tacit.inkMeta
            }
        }
        KeyCombos {
            visible: !r.capturing
            anchors.right: parent.right
            anchors.rightMargin: Tacit.space.l + 4
            anchors.verticalCenter: parent.verticalCenter
            list: r.keys
        }
    }

    // the box that takes the next keys: window ground, the accent ring (the risk ink on a clash), "Esc cancels" in it
    FocusScope {
        id: capture
        visible: r.capturing
        anchors.right: parent.right
        anchors.rightMargin: Tacit.space.l + 4
        y: (row.height - height) / 2
        width: Tacit.width.list / 2
        height: Tacit.height.field
        Keys.onPressed: event => {
            event.accepted = true;
            if (r.mode === "clash") { if (event.key === Qt.Key_Escape) r.chooseOther(); return; }
            const bare = !(event.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier));
            if (event.key === Qt.Key_Escape && bare) { r.cancelled(); return; }
            const key = Shortcuts.keyName(event.key);
            let mods = Shortcuts.modsOf(event.modifiers);
            if (event.key === Qt.Key_Meta && !mods.includes("Super")) mods = ["Super", mods].filter(x => x !== "").join("+");
            if (key === "") { r.capturedHeld(mods); return; }
            r.capturedKeys(mods === "" ? key : `${mods}+${key}`, mods);
        }
        Keys.onReleased: event => { if (r.mode === "listening") r.capturedHeld(Shortcuts.modsOf(event.modifiers)); }
        Rectangle {
            anchors.fill: parent
            radius: Tacit.radius.row
            color: Tacit.windowGround
            border.width: Tacit.state.focusRing
            border.color: r.mode === "clash" ? Tacit.risk : Tacit.accent
            StyledText {
                visible: r.held === ""
                x: Tacit.space.m
                anchors.verticalCenter: parent.verticalCenter
                text: r.mode === "clash" ? "" : r.hint
                font.pixelSize: Tacit.size.row
                color: Tacit.inkMeta
            }
            KeyCaps {
                visible: r.held !== ""
                x: Tacit.space.s
                anchors.verticalCenter: parent.verticalCenter
                combo: r.held
                ink: Tacit.inkMain
            }
            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: Tacit.space.m
                anchors.verticalCenter: parent.verticalCenter
                text: "Esc cancels"
                font.pixelSize: Tacit.size.meta
                color: Tacit.inkMeta
            }
        }
    }

    Column {
        id: extra
        visible: r.strip
        y: row.height
        // the words of the actions start on the name's edge; their hover wash reaches a little to the left of it
        x: r.indent - Tacit.space.l
        Row {
            visible: r.mode === "selected"
            KeyWord { visible: r.canChange; text: "Change the keys"; onActivated: r.change() }
            KeyWord { visible: r.canReset; text: r.resetWords; onActivated: r.reset() }
        }
        StyledText {
            visible: r.mode === "clash"
            height: Tacit.height.action - Tacit.space.s
            leftPadding: Tacit.space.l
            text: r.clashText
            font.pixelSize: Tacit.size.row
            color: Tacit.risk
        }
        Row {
            visible: r.mode === "clash" && r.hasTake
            leftPadding: Tacit.space.l
            spacing: Tacit.space.m
            Slab { id: take; tone: "default"; text: r.takeText; onPicked: r.takeIt() }
            StyledText {
                anchors.verticalCenter: take.verticalCenter
                text: r.takeNote
                font.pixelSize: Tacit.size.meta
                color: Tacit.inkMeta
            }
        }
        KeyWord { visible: r.mode === "clash"; text: "Choose other keys"; onActivated: r.chooseOther() }
    }

    // the Undo line sits under the row it is about, with room of its own, so it covers nothing
    Item {
        id: slot
        visible: r.mode === "done"
        y: row.height
        width: parent.width
        height: r.slotH
        Rectangle {
            id: bubble
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Tacit.space.s
            height: Tacit.height.row
            width: line.implicitWidth + pill.width + 3 * Tacit.space.l
            radius: Tacit.radius.slab
            color: Tacit.overlay
            border.width: 1
            border.color: ColorUtils.transparentize(Tacit.inkMain, 0.9)
            StyledText {
                id: line
                x: Tacit.space.l
                anchors.verticalCenter: parent.verticalCenter
                text: r.noticeText
                font.pixelSize: Tacit.size.row
                color: Tacit.inkMain
            }
            Item {
                id: pill
                x: line.x + line.implicitWidth + Tacit.space.m
                anchors.verticalCenter: parent.verticalCenter
                width: pillWords.implicitWidth + 2 * Tacit.space.l
                height: Tacit.height.field - Tacit.space.xs
                activeFocusOnTab: slot.visible
                Keys.onReturnPressed: r.undone()
                Keys.onEnterPressed: r.undone()
                Keys.onSpacePressed: r.undone()
                Rectangle {
                    anchors.fill: parent
                    radius: height / 2
                    color: Tacit.accent
                    border.width: pill.activeFocus && (pill.focusReason === Qt.TabFocusReason || pill.focusReason === Qt.BacktabFocusReason) ? Tacit.state.focusRing : 0
                    border.color: Tacit.inkMain
                    Rectangle { anchors.fill: parent; radius: parent.radius; color: Tacit.inkOnAccent; opacity: pillTap.containsMouse ? Tacit.wash.hover : 0 }
                }
                StyledText {
                    id: pillWords
                    anchors.centerIn: parent
                    text: "Undo"
                    font.pixelSize: Tacit.size.row
                    font.weight: Tacit.weight.medium
                    color: Tacit.inkOnAccent
                }
                MouseArea { id: pillTap; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: r.undone() }
            }
        }
    }
}
