import QtQuick
import Qt5Compat.GraphicalEffects
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * One item in the grid: a thumbnail for pictures, a glyph for the rest, the name, the age.
 */
Item {
    id: cell

    required property string fileName
    required property string filePath
    required property bool fileIsDir
    required property double fileSize
    required property date fileModified
    required property int index

    property bool selected: false
    property bool current: false
    property bool flash: false
    property bool cut: false
    readonly property var thing: Things.describe(cell.filePath + (cell.fileIsDir ? "/" : ""))
    readonly property bool picture: cell.thing.kind === "image"

    signal pressedAt(var mouse, int index)
    signal clicked(var mouse, int index)
    signal doubleClicked(int index)
    signal contextRequested(int index, real x, real y)

    width: GridView.view ? GridView.view.cellWidth : 156
    height: GridView.view ? GridView.view.cellHeight : 176

    Rectangle {
        anchors.fill: parent
        anchors.margins: 4
        radius: 12
        color: cell.selected ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
            : (area.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent")
        Behavior on color { ColorAnimation { duration: 80 } }
    }
    Rectangle {
        anchors.fill: parent
        anchors.margins: 4
        radius: 12
        color: Appearance.colors.colPrimary
        opacity: cell.flash ? 0.18 : 0
        Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    }

    Item {
        id: art
        anchors.top: parent.top
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        // the picture grows with the grid's size; the name under it keeps its size
        readonly property real k: cell.GridView.view ? (cell.GridView.view.size ?? 1) : 1
        width: Math.round(120 * art.k)
        height: Math.round(100 * art.k)
        Rectangle {
            anchors.fill: parent
            radius: 10
            color: Appearance.colors.colLayer1
            visible: !cell.picture || thumb.status !== Image.Ready
            MaterialSymbol {
                anchors.centerIn: parent
                text: cell.thing.glyph
                fill: cell.fileIsDir ? 1 : 0
                iconSize: Math.round(40 * art.k)
                color: Tacit.inkSec
            }
        }
        Loader {   // pictures and videos ask for a thumbnail (a video's is a frame); the widget wants a real path
            id: thumb
            anchors.fill: parent
            active: cell.picture || cell.thing.kind === "video"
            readonly property int status: item ? item.status : Image.Null
            sourceComponent: ThumbnailImage {
                sourcePath: cell.filePath
                sourceSize.width: art.k > 1.3 ? 512 : 256
                sourceSize.height: art.k > 1.3 ? 512 : 256
                fillMode: Image.PreserveAspectCrop
                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle { width: art.width; height: art.height; radius: 10 }
                }
            }
        }
    }
    StyledText {
        id: nameLabel
        anchors.top: art.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 10
        horizontalAlignment: Text.AlignHCenter
        text: cell.fileName
        elide: Text.ElideMiddle
        font.pixelSize: 14
        font.weight: cell.selected ? Font.Medium : Font.Normal
        color: Tacit.inkMain
        opacity: cell.cut ? 0.5 : 1
    }
    StyledText {
        anchors.top: nameLabel.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        text: Voice.age(cell.fileModified.getTime())
        font.pixelSize: 13
        font.family: Appearance.font.family.numbers
        color: Tacit.inkMeta
    }

    // The window's drag source, not this delegate's: see FilesRow.
    readonly property Item dragProxy: cell.GridView.view?.dragProxy ?? null
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        property bool rightHeld: false
        drag.target: rightHeld || !cell.dragProxy ? null : cell.dragProxy
        drag.threshold: 10
        property real pressX: 0
        property real pressY: 0
        property bool grabbed: false
        onPressed: mouse => {
            rightHeld = mouse.button !== Qt.LeftButton;
            pressX = mouse.x; pressY = mouse.y; grabbed = false;
            cell.pressedAt(mouse, cell.index);
        }
        onPositionChanged: mouse => {
            if (!pressed || rightHeld || grabbed)
                return;
            if (Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < 4)
                return;
            grabbed = true;
            art.grabToImage(result => { if (cell.dragProxy) cell.dragProxy.Drag.imageSource = result.url; });
        }
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                const p = cell.mapToItem(null, mouse.x, mouse.y);
                cell.contextRequested(cell.index, p.x, p.y);
            }
            else
                cell.clicked(mouse, cell.index);
        }
        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) cell.doubleClicked(cell.index); }
        drag.onActiveChanged: {
            if (!cell.dragProxy)
                return;
            if (drag.active) {
                cell.dragProxy.Drag.mimeData = { "text/uri-list": cell.GridView.view.uriList(cell.index) };
                cell.dragProxy.Drag.active = true;
            } else {
                cell.dragProxy.Drag.active = false;
            }
        }
        onReleased: {
            if (cell.dragProxy && cell.dragProxy.Drag.active)
                cell.dragProxy.Drag.drop();
        }
    }
}
