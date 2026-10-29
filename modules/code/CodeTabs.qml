import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The open files as tabs: glyph and name, a dot while there are unsaved changes
 * (a close button under the pointer), the current one underlined in primary.
 */
ListView {
    id: tabs

    property var docs: []            // [{ rel, doc }]
    property int current: -1
    property var glyphFor: name => "draft"
    signal picked(int index)
    signal closeRequested(int index)

    orientation: ListView.Horizontal
    spacing: 2
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: tabs.docs

    // Past a dozen files the strip overflows, so it has to follow the file being edited.
    // A tab opened by the Claude app is appended and picked in one frame, before the view
    // has seen the new row, hence the callLater.
    onCurrentChanged: if (tabs.current >= 0) Qt.callLater(tabs.follow)
    onCountChanged: if (tabs.current >= 0) Qt.callLater(tabs.follow)
    // a strip that opened narrow, or narrowed later, still shows the file being edited
    onWidthChanged: if (tabs.current >= 0) Qt.callLater(tabs.follow)
    function follow() {
        if (tabs.current >= 0 && tabs.current < tabs.count) tabs.positionViewAtIndex(tabs.current, ListView.Contain);
    }

    delegate: Item {
        id: tab
        required property var modelData
        required property int index
        readonly property bool isCurrent: tabs.current === tab.index
        readonly property bool dirty: tab.modelData.doc ? tab.modelData.doc.dirty : false
        readonly property bool missing: tab.modelData.doc ? tab.modelData.doc.missing : false
        width: label.implicitWidth + 76
        height: ListView.view.height
        HoverHandler { id: tabHover }

        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 5
            anchors.bottomMargin: 5
            radius: Appearance.rounding.verysmall
            color: tab.isCurrent ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.86)
                : (tabHover.hovered ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent")
            Behavior on color { ColorAnimation { duration: 80 } }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 3
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 20
            height: 2
            radius: 1
            color: Tacit.inkMain
            opacity: tab.isCurrent ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
        }

        MaterialSymbol {
            id: glyph
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: tabs.glyphFor(tab.modelData.rel.split("/").pop())
            iconSize: Appearance.icon.small
            color: tab.isCurrent ? Tacit.inkMain : Tacit.inkMeta
        }
        StyledText {
            id: label
            anchors.left: glyph.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: tab.modelData.rel.split("/").pop()
            font.pixelSize: Appearance.font.pixelSize.smallie
            font.family: Appearance.font.family.condensed
            font.strikeout: tab.missing      // the tree's mark for a file that is not there
            color: tab.isCurrent ? Tacit.inkMain : Tacit.inkMeta
        }
        Rectangle {   // unsaved changes: beside the name, so pointing at the tab cannot hide it
            anchors.left: label.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 7; height: 7; radius: 4
            color: Tacit.accent
            visible: tab.dirty
        }
        Item {   // the close button reaches the tab's edge: no strip that answers to nothing
            id: closer
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 26; height: 18
            MaterialSymbol {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "close"
                iconSize: 14
                color: closeArea.containsMouse ? Tacit.inkMain : Tacit.inkMeta
                visible: tabHover.hovered
            }
            MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: tabs.closeRequested(tab.index)
            }
            StyledToolTip { text: "Close (Ctrl+W)"; extraVisibleCondition: closeArea.containsMouse }
        }
        MouseArea {
            id: hover
            anchors.fill: parent
            anchors.rightMargin: closer.width
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: mouse => mouse.button === Qt.MiddleButton ? tabs.closeRequested(tab.index) : tabs.picked(tab.index)
        }
    }
}
