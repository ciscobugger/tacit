import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

// The agent's thinking as one quiet line (OpenChamber's reasoning row): "Thinking" and the
// first words; a click opens the whole text under a thin rail. `live` while it is still coming in.
Item {
    id: think
    property string text: ""
    property bool live: false
    // as for a tool line, the conversation keeps whether this is open; thinking carries no id of
    // its own, so its text stands for it
    property var openIds: null
    property bool selfOpen: false
    // the text alone, already open: in a line that is only thinking, a second "Thought" to open was one click too many
    property bool bare: false
    readonly property string key: think.openIds && think.text.length ? `think:${think.text.length}:${think.text.substring(0, 48)}` : ""
    readonly property bool open: think.bare || (think.key.length ? think.openIds[think.key] === true : think.selfOpen)
    signal toggled(string key)
    // opens and closes on one value, as a tool line does: height, clip and fade together
    property real progress: think.open ? 1 : 0
    Behavior on progress { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    readonly property bool shown: think.progress > 0
    implicitHeight: row.height + (body.height + 4) * think.progress

    Item {
        id: row
        visible: !think.bare
        width: parent.width
        height: think.bare ? 0 : 34
        HoverHandler { id: hover }
        Rectangle {
            anchors { fill: parent; leftMargin: -6; rightMargin: -6 }
            radius: Appearance.rounding.small
            color: hover.hovered ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
        }
        MaterialSymbol {
            id: icon
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            visible: !think.live || hover.hovered
            text: hover.hovered || think.open ? (think.open ? "expand_more" : "chevron_right") : "neurology"
            iconSize: 17
            color: Appearance.colors.colInkSecondary
        }
        LiveDot {
            visible: think.live && !hover.hovered
            anchors { horizontalCenter: icon.horizontalCenter; verticalCenter: parent.verticalCenter }
        }
        ShineText {
            id: name
            anchors { left: icon.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
            width: implicitWidth
            // a finished thought is past: "Thinking" only while it comes in
            text: think.live ? "Thinking" : "Thought"
            pixelSize: 15
            weight: Font.Medium
            active: think.live
            rests: true
            opacity: think.live ? 1 : 0.85
        }
        StyledText {
            anchors { left: name.right; leftMargin: 8; right: parent.right; verticalCenter: parent.verticalCenter }
            visible: !think.open
            text: think.text.replace(/\s+/g, " ").trim()
            elide: think.live ? Text.ElideLeft : Text.ElideRight
            font.pixelSize: 15
            color: Appearance.colors.colInkMeta
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (think.key.length) think.toggled(think.key);
                else think.selfOpen = !think.selfOpen;
            }
        }
    }

    Item {
        id: reveal
        visible: think.shown
        clip: think.progress < 1
        anchors { top: row.bottom; topMargin: think.bare ? 4 : 2; left: parent.left; right: parent.right }
        height: body.height * think.progress
        Item {
            id: body
            opacity: think.progress
            anchors { top: parent.top; left: parent.left; leftMargin: think.bare ? 0 : 7; right: parent.right }
            // whole: in a 320 px box with its own scroll a long thought read as cut off (owner 2026-10-10)
            height: bodyText.implicitHeight + 8
            Rectangle {
                visible: !think.bare   // the opened line's own rail is beside it
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 1
                color: Appearance.m3colors.m3outlineVariant
            }
            Flickable {
                anchors { fill: parent; leftMargin: think.bare ? 0 : 12; bottomMargin: 8 }
                clip: true
                contentHeight: bodyText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                StyledText {
                    id: bodyText
                    width: parent.width
                    text: think.shown ? think.text : ""
                    wrapMode: Text.Wrap
                    font.pixelSize: 16
                    lineHeight: 1.5
                    color: Appearance.colors.colInkSecondary
                }
            }
        }
    }
}
