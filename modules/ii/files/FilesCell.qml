import QtQuick
import QtQuick.Effects
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import Tacit.Kit as K

/**
 * One item in the grid: a picture or a video shows itself (at its own shape, fitted to the cell's frame), anything
 * else its symbol; the name and the age under it. Bare (a folder of pictures, FilesPictures): the picture fills the
 * cell at its own shape and says nothing more; a folder or another file there is its symbol and name on a 6 % wash.
 * The selection is the accent ring 4 px around the cell (around the picture when bare), as K.PictureGrid draws it;
 * the pointer's hover is the 5 % wash over it; the keyboard's place is the kit's focus ring, outside the selection's.
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
    property bool focused: false        // the keyboard is on this one and the ring is showing
    property bool flash: false
    property bool cut: false
    property bool bare: false
    // a GridView's delegate finds these on its view; FilesPictures hands them in
    property Item dragProxy: cell.GridView.view?.dragProxy ?? null
    property var uriList: i => cell.GridView.view.uriList(i)
    property real zoom: cell.GridView.view?.size ?? 1
    readonly property var thing: Things.describe(cell.filePath + (cell.fileIsDir ? "/" : ""))
    readonly property bool shows: cell.thing.kind === "image" || cell.thing.kind === "video"
    readonly property bool symbolOnly: !cell.shows || thumb.failed

    signal pressedAt(var mouse, int index)
    signal clicked(var mouse, int index)
    signal doubleClicked(int index)
    signal contextRequested(int index, real x, real y)

    width: GridView.view ? GridView.view.cellWidth : 156
    height: GridView.view ? GridView.view.cellHeight : 176

    // what the wash and the rings go around: the cell, set in so two selected neighbours keep their rings apart
    Item {
        id: box
        anchors.fill: parent
        anchors.margins: cell.bare ? 0 : Tacit.space.s
    }

    // The tile as 1.1.7 drew it, outside a folder of pictures (owner 2026-11-01: the old Pinax back): a wash behind it when
    // chosen (12 % of the ink) or under the pointer (5 %), a rounded frame the picture fills, the name and the age under it.
    Rectangle {
        anchors.fill: parent
        anchors.margins: 4
        radius: 12
        visible: !cell.bare
        color: cell.selected ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
            : (area.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent")
        Behavior on color { ColorAnimation { duration: 80 } }
    }
    // a folder or a file without a picture, among pictures: its symbol and name on the field's wash
    Rectangle {
        anchors.fill: box
        visible: cell.bare && cell.symbolOnly
        radius: Tacit.radius.row
        color: Qt.alpha(Tacit.inkMain, Tacit.wash.action)
    }

    Item {
        id: art
        // bare: the whole cell; else a frame at the top that grows with the grid's size (the name keeps its size)
        x: cell.bare ? 0 : Math.round((cell.width - width) / 2)
        y: cell.bare ? 0 : box.y + Tacit.space.s
        width: cell.bare ? cell.width : Math.round(120 * cell.zoom)
        height: cell.bare ? cell.height : Math.round(100 * cell.zoom)
        opacity: cell.cut ? 0.5 : 1

        Rectangle {
            anchors.fill: parent
            radius: 10
            visible: !cell.bare && cell.symbolOnly
            color: Appearance.colors.colLayer1
        }
        K.Symbol {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: cell.bare ? -Tacit.space.m : 0
            visible: cell.symbolOnly
            text: cell.thing.glyph
            filled: cell.fileIsDir
            size: Math.round(40 * cell.zoom)
        }
        // A picture at its own shape: bare, the cell already has it; in the frame, fitted and set on the frame's
        // foot, so the names under a row of them stay on one line.
        Loader {   // pictures and videos ask for a thumbnail (a video's is a frame); the widget wants a real path
            id: thumb
            readonly property bool ready: item !== null && item.status === Image.Ready
            readonly property bool failed: item !== null && item.status === Image.Error
            readonly property real ratio: thumb.ready ? thumb.item.implicitWidth / Math.max(1, thumb.item.implicitHeight) : 1
            readonly property bool wider: thumb.ratio >= art.width / Math.max(1, art.height)
            active: cell.shows
            width: art.width
            height: art.height
            x: Math.round((art.width - width) / 2)
            y: art.height - height
            sourceComponent: ThumbnailImage {
                sourcePath: cell.filePath
                sourceSize.width: cell.bare || cell.zoom > 1.3 ? 512 : 256
                sourceSize.height: cell.bare || cell.zoom > 1.3 ? 512 : 256
                fillMode: Image.PreserveAspectCrop
                layer.enabled: true
                layer.effect: MultiEffect { maskEnabled: true; maskSource: shapeMask }
                // a thumbnail that was not there at the first look stays an error until the source is set afresh
                property int looks: 0
                onStatusChanged: if (status === Image.Error && looks < 4) again.restart()
                Timer {
                    id: again
                    interval: 1500
                    onTriggered: {
                        parent.looks++;
                        parent.source = "";
                        // Not Qt.callLater: the deferred closure outlives the cell (the grid
                        // scrolled, the Loader deactivated) and evaluating it against a
                        // destroyed context is "a function in an invalid context". A timer
                        // inside the cell dies with the cell, so it can never fire late.
                        restore.start();
                    }
                }
                Timer {
                    id: restore
                    interval: 16
                    onTriggered: parent.source = parent.thumbnailPath
                }
            }
        }
        Rectangle { id: shapeMask; visible: false; width: thumb.width; height: thumb.height; radius: cell.bare ? Tacit.radius.row : 10; layer.enabled: true }
    }
    Column {
        visible: !cell.bare || cell.symbolOnly
        anchors.left: box.left
        anchors.right: box.right
        anchors.margins: Tacit.space.s
        y: cell.bare ? Math.round(art.height / 2 + 20 * cell.zoom) : art.y + art.height + Tacit.space.s
        spacing: 2
        K.TacitText {
            width: parent.width
            visible: cell.bare
            horizontalAlignment: Text.AlignHCenter
            text: cell.fileName
            elide: Text.ElideMiddle
            weight: cell.selected ? "medium" : "regular"
            ink: cell.cut ? "quiet" : "main"
        }
        StyledText {
            width: parent.width
            visible: !cell.bare
            horizontalAlignment: Text.AlignHCenter
            text: cell.fileName
            elide: Text.ElideMiddle
            font.pixelSize: 14
            font.weight: cell.selected ? Font.Medium : Font.Normal
            color: Tacit.inkMain
            opacity: cell.cut ? 0.5 : 1
        }
        StyledText {
            width: parent.width
            visible: !cell.bare
            horizontalAlignment: Text.AlignHCenter
            text: Voice.age(cell.fileModified.getTime())
            font.pixelSize: 13
            font.family: Appearance.font.family.numbers
            color: Tacit.inkMeta
        }
    }

    // hover and press: the main ink over the cell, as over a picture in K.PictureGrid
    Rectangle {
        anchors.fill: box
        radius: Tacit.radius.row
        color: Tacit.inkMain
        opacity: !cell.bare ? 0 : area.pressed && !area.rightHeld ? Tacit.wash.pressed : area.containsMouse ? Tacit.wash.hover : 0
        Behavior on opacity { NumberAnimation { duration: Tacit.motion.hover.ms } }
    }
    // a file just revealed ("show in folder") lights once
    Rectangle {
        anchors.fill: box
        radius: Tacit.radius.row
        color: Tacit.accent
        opacity: cell.flash ? 0.18 : 0
        Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    }
    Rectangle {
        id: ring
        anchors.fill: box
        anchors.margins: -4
        radius: Tacit.radius.row + 4
        color: "transparent"
        border.width: 2
        border.color: Tacit.accent
        visible: cell.selected && cell.bare
    }
    // the keyboard's place: around the selection's ring when it has one, else around the cell
    Item {
        anchors.fill: cell.selected ? ring : box
        K.FocusRing {
            shown: cell.focused
            corner: cell.selected ? ring.radius : Tacit.radius.row
        }
    }

    // The window's drag source, not this delegate's: see FilesRow.
    MouseArea {
        id: area
        anchors.fill: box
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
                cell.dragProxy.Drag.mimeData = { "text/uri-list": cell.uriList(cell.index) };
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
