import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

/**
 * "Add a shortcut for an app": the row that ends the first group, and opened: a search of the installed apps, one line
 * of help, then the apps that match. Picking one hands it to the page, which takes its keys in a row of its own.
 */
ColumnLayout {
    id: add
    property bool open: false
    property string query: ""
    signal opened()
    signal closed()
    signal queryEdited(string q)
    signal picked(var app)
    spacing: 0

    readonly property var taken: Shortcuts.apps.map(a => a.name)
    readonly property var found: {
        const q = add.query.trim().toLowerCase();
        return Array.from(DesktopEntries.applications.values)
            .filter(e => !e.noDisplay && !e.runInTerminal && e.command.length > 0 && !add.taken.includes(e.name)
                && (q === "" || e.name.toLowerCase().includes(q)))
            .sort((a, b) => a.name.localeCompare(b.name))
            .slice(0, 8);
    }
    onOpenChanged: if (open) search.forceActiveFocus()

    // closed: a row like the others, with a plus
    Item {
        visible: !add.open
        Layout.fillWidth: true
        implicitHeight: Tacit.height.row
        activeFocusOnTab: visible
        Keys.onReturnPressed: add.opened()
        Keys.onEnterPressed: add.opened()
        Keys.onSpacePressed: add.opened()
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            radius: Tacit.radius.row
            color: ColorUtils.transparentize(Tacit.inkMain, 1 - (headArea.containsMouse ? Tacit.wash.hover : 0))
            border.width: parent.activeFocus && (parent.focusReason === Qt.TabFocusReason || parent.focusReason === Qt.BacktabFocusReason) ? Tacit.state.focusRing : 0
            border.color: Tacit.accent
        }
        MaterialSymbol { x: Tacit.space.l; anchors.verticalCenter: parent.verticalCenter; text: "add"; iconSize: Tacit.icon.row; color: Tacit.inkMeta }
        StyledText {
            x: 2 * Tacit.space.l + Tacit.icon.row
            anchors.verticalCenter: parent.verticalCenter
            text: "Add a shortcut for an app"
            font.pixelSize: Tacit.size.row
            color: Tacit.inkMain
        }
        MouseArea { id: headArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: add.opened() }
    }

    // opened: the search
    Item {
        visible: add.open
        Layout.fillWidth: true
        implicitHeight: Tacit.height.row
        MaterialSymbol { x: Tacit.space.l; anchors.verticalCenter: parent.verticalCenter; text: "add"; iconSize: Tacit.icon.row; color: Tacit.inkMeta }
        Rectangle {
            x: 2 * Tacit.space.l + Tacit.icon.row - Tacit.space.s
            anchors.verticalCenter: parent.verticalCenter
            width: Tacit.width.list / 2
            height: Tacit.height.field
            radius: Tacit.radius.row
            color: Tacit.windowGround
            border.width: Tacit.state.focusRing
            border.color: Tacit.accent
            TextInput {
                id: search
                anchors.fill: parent
                anchors.leftMargin: Tacit.space.m
                anchors.rightMargin: Tacit.space.m
                verticalAlignment: TextInput.AlignVCenter
                font.pixelSize: Tacit.size.row
                font.family: Appearance.font.family.main
                color: Tacit.inkMain
                selectionColor: Tacit.accent
                clip: true
                text: add.query
                onTextEdited: add.queryEdited(search.text)
                Keys.onEscapePressed: add.closed()
                Keys.onReturnPressed: if (add.found.length > 0) add.picked(add.appOf(add.found[0]))
                Keys.onEnterPressed: if (add.found.length > 0) add.picked(add.appOf(add.found[0]))
                Keys.onDownPressed: list.itemAt(0)?.forceActiveFocus()
                StyledText {
                    visible: search.text.length === 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Search your apps"
                    font.pixelSize: Tacit.size.row
                    color: Tacit.inkMeta
                }
            }
        }
    }
    StyledText {
        visible: add.open
        Layout.leftMargin: 2 * Tacit.space.l + Tacit.icon.row
        Layout.preferredHeight: Tacit.height.action - Tacit.space.s
        text: add.found.length > 0 ? "Pick the app, then press the keys that open it." : "No app has that name."
        font.pixelSize: Tacit.size.meta
        color: Tacit.inkMeta
    }
    function appOf(e) {
        const icon = e.icon ?? "";
        return { name: e.name, run: Shortcuts.quote(e.command), icon, iconSource: icon !== "" ? Quickshell.iconPath(icon, true) : "" };
    }
    Repeater {
        id: list
        model: add.open ? add.found : []
        Item {
            id: line
            required property var modelData
            required property int index
            Layout.fillWidth: true
            implicitHeight: Tacit.height.row
            activeFocusOnTab: true
            Keys.onReturnPressed: add.picked(add.appOf(line.modelData))
            Keys.onEnterPressed: add.picked(add.appOf(line.modelData))
            Keys.onSpacePressed: add.picked(add.appOf(line.modelData))
            Keys.onEscapePressed: add.closed()
            Keys.onUpPressed: line.index === 0 ? search.forceActiveFocus() : line.nextItemInFocusChain(false).forceActiveFocus()
            Keys.onDownPressed: line.nextItemInFocusChain(true).forceActiveFocus()
            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                radius: Tacit.radius.row
                color: ColorUtils.transparentize(Tacit.inkMain, 1 - (lineArea.containsMouse ? Tacit.wash.hover : 0))
                border.width: line.activeFocus ? Tacit.state.focusRing : 0
                border.color: Tacit.accent
            }
            MaterialSymbol {
                visible: !line.modelData.icon || Quickshell.iconPath(line.modelData.icon, true) === ""
                x: Tacit.space.l
                anchors.verticalCenter: parent.verticalCenter
                text: "apps"
                iconSize: Tacit.icon.row
                color: Tacit.inkMeta
            }
            Image {
                x: Tacit.space.l
                anchors.verticalCenter: parent.verticalCenter
                width: Tacit.icon.row
                height: Tacit.icon.row
                sourceSize: Qt.size(Tacit.icon.row * 2, Tacit.icon.row * 2)
                source: line.modelData.icon ? Quickshell.iconPath(line.modelData.icon, true) : ""
            }
            StyledText {
                x: 2 * Tacit.space.l + Tacit.icon.row
                anchors.verticalCenter: parent.verticalCenter
                text: line.modelData.name
                font.pixelSize: Tacit.size.row
                color: Tacit.inkMain
            }
            MouseArea { id: lineArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: add.picked(add.appOf(line.modelData)) }
        }
    }
}
