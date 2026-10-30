import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Effects

// The menu's picture row, drawn as the wallpaper strip draws its cards (WallpaperStrip.qml): radius
// normal, the pointed one lifted with a primary ring, the wallpaper in use with the check dot.
// The first entry of `model` is the wallpaper in use. The card under the pointer opens wide (the
// old carousel's pop); the wheel and a drag scroll the row. A click emits `picked`.
Item {
    id: root
    property var model: []
    property real cardW: 60
    property real wideW: 108
    property real cardH: 62
    property int hovered: -1
    readonly property int pointed: root.hovered >= 0 ? root.hovered : 0
    signal picked(string path)

    implicitHeight: root.cardH + 8

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        orientation: ListView.Horizontal
        spacing: 8
        leftMargin: 3
        rightMargin: 3
        topMargin: 4
        model: root.model
        boundsBehavior: Flickable.StopAtBounds

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                const lo = list.originX - list.leftMargin;
                const hi = Math.max(lo, list.originX + list.contentWidth + list.rightMargin - list.width);
                list.contentX = Math.max(lo, Math.min(hi, list.contentX - (event.angleDelta.y + event.angleDelta.x)));
            }
        }

        delegate: Item {
            id: cell
            required property var modelData
            required property int index
            readonly property bool isPointed: cell.index === root.pointed
            width: cell.isPointed ? root.wideW : root.cardW
            height: root.cardH
            Behavior on width {
                Anim { type: Anim.Emphasized }
            }

            Rectangle {
                anchors.fill: parent
                anchors.margins: -3
                radius: Appearance.rounding.normal + 3
                color: "transparent"
                border.width: cell.isPointed && root.hovered >= 0 ? 2 : 0
                border.color: Appearance.colors.colPrimary
            }
            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.normal
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
            }
            Image {
                id: picture
                anchors.fill: parent
                visible: false
                source: cell.modelData ? FileUtils.fileUrl(FileUtils.trimFileProtocol(cell.modelData)) : ""
                asynchronous: true
                sourceSize: Qt.size(368, 208)
                fillMode: Image.PreserveAspectCrop
            }
            Rectangle {
                id: pictureMask
                anchors.fill: parent
                radius: Appearance.rounding.normal
                visible: false
                layer.enabled: true
            }
            MultiEffect {
                anchors.fill: parent
                source: picture
                maskEnabled: true
                maskSource: pictureMask
            }
            Rectangle {
                visible: cell.index === 0
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: 6
                width: 20
                height: 20
                radius: 10
                color: Appearance.colors.colPrimary
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "check"
                    iconSize: 14
                    color: Appearance.colors.colOnPrimary
                }
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.hovered = cell.index
                onExited: if (root.hovered === cell.index) root.hovered = -1
                onClicked: root.picked(cell.modelData)
            }
        }
    }
}
