pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Qt5Compat.GraphicalEffects
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.ii.island

/**
 * The Shelf view, after boring.notch ShelfView.swift: a dashed drop zone holding whatever was
 * dragged onto the notch, tiles you can drag back out, and Copy / Clear. Items live in the
 * shell's existing DropShelf singleton (modules/common/widgets/DropShelf.qml), so the desktop
 * drop shelf and the notch show the same list.
 */
Item {
    id: root

    property bool dragOver: false
    property bool draggingOut: false
    // The notch's drag source, handed in by the loader: a tile is destroyed the moment the
    // sheet folds, and Qt reads the source when the target asks for the file.
    property Item dragProxy: null
    readonly property bool empty: DropShelf.items.length === 0
    // Music keeps playing while files are parked: a slim transport row under the zone.
    readonly property bool showTransport: IslandController.mediaVisible
    signal openFile(string path)

    implicitWidth: 560
    implicitHeight: 150

    // Dashed panel (theirs: RoundedRectangle 16, dashed stroke; accent while a drag hovers).
    Shape {
        id: zone
        anchors.fill: parent
        anchors.leftMargin: 20
        anchors.rightMargin: 64
        anchors.topMargin: 4
        anchors.bottomMargin: root.showTransport ? 40 : 14
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            fillColor: "transparent"
            strokeColor: root.dragOver ? Appearance.colors.colPrimary : Appearance.colors.colLayer0Border
            strokeWidth: 1.5
            strokeStyle: ShapePath.DashLine
            dashPattern: [4, 4]
            capStyle: ShapePath.RoundCap
            startX: 16
            startY: 0
            PathLine { x: zone.width - 16; y: 0 }
            PathArc { x: zone.width; y: 16; radiusX: 16; radiusY: 16 }
            PathLine { x: zone.width; y: zone.height - 16 }
            PathArc { x: zone.width - 16; y: zone.height; radiusX: 16; radiusY: 16 }
            PathLine { x: 16; y: zone.height }
            PathArc { x: 0; y: zone.height - 16; radiusX: 16; radiusY: 16 }
            PathLine { x: 0; y: 16 }
            PathArc { x: 16; y: 0; radiusX: 16; radiusY: 16 }
        }

        // Empty state.
        Column {
            anchors.centerIn: parent
            spacing: 6
            visible: root.empty
            MaterialSymbol {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "move_to_inbox"
                iconSize: 28
                color: IslandController.subtextColor
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Drop files here"
                font.family: Appearance.font.family.main
                font.pixelSize: 14
                color: IslandController.subtextColor
            }
        }

        // Tiles: thumbnail or icon over a name, 96px wide, draggable back out.
        ListView {
            id: tiles
            anchors.fill: parent
            anchors.margins: 10
            orientation: ListView.Horizontal
            spacing: 8
            clip: true
            visible: !root.empty
            // The zone holds four tiles: a glance. More than four and the fourth tile is the
            // count, and it opens the shelf as a list in Files, where twenty is nothing.
            readonly property int shown: DropShelf.items.length > 4 ? 3 : DropShelf.items.length
            // the newest first: a drop joins the end of the list, and showing its start hid what was just dropped
            model: DropShelf.items.slice(DropShelf.items.length - shown).reverse().concat(DropShelf.items.length > 4 ? [`+${DropShelf.items.length - 3}`] : [])
            interactive: false

            delegate: Item {
                id: tile
                required property string modelData
                readonly property string path: modelData
                readonly property bool more: tile.path.startsWith("+")   // the "+N" tile
                readonly property bool isImage: !more && /\.(png|jpe?g|webp|bmp|gif)$/i.test(tile.path)
                readonly property bool isDir: tile.path.endsWith("/")
                readonly property string name: tile.path.replace(/\/$/, "").split("/").pop()
                width: 96
                height: tiles.height

                Rectangle {
                    id: card
                    anchors.fill: parent
                    radius: 12
                    color: cardArea.containsMouse ? Appearance.colors.colLayer1Hover : "transparent"

                    Column {
                        anchors.centerIn: parent
                        spacing: 6

                        Item {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 56
                            height: 56

                            Rectangle {
                                anchors.fill: parent
                                radius: 12
                                color: Appearance.colors.colLayer2
                                visible: !tile.isImage || thumb.status !== Image.Ready
                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    visible: !tile.more
                                    text: tile.isDir ? "folder" : "draft"
                                    iconSize: 28
                                    color: Appearance.colors.colOnLayer2
                                }
                                StyledText {
                                    anchors.centerIn: parent
                                    visible: tile.more
                                    text: tile.path
                                    font.pixelSize: 18
                                    font.weight: Font.DemiBold
                                    color: Appearance.colors.colPrimary
                                }
                            }
                            StyledImage {
                                id: thumb
                                anchors.fill: parent
                                visible: tile.isImage && status === Image.Ready
                                source: tile.isImage ? FileUtils.fileUrl(tile.path) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.width: 112
                                sourceSize.height: 112
                                layer.enabled: true
                                layer.effect: OpacityMask {
                                    maskSource: Rectangle {
                                        width: 56
                                        height: 56
                                        radius: 12
                                    }
                                }
                            }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 88
                            horizontalAlignment: Text.AlignHCenter
                            // the title it came from when the desktop knows one, else the file name
                            text: tile.more ? "all in Files" : Things.describe(tile.path).title
                            elide: Text.ElideMiddle
                            maximumLineCount: 1
                            font.family: Appearance.font.family.main
                            font.pixelSize: 12
                            color: IslandController.contentColor
                        }
                    }

                    MouseArea {
                        id: cardArea
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                        drag.target: tile.more || !root.dragProxy ? null : parent
                        cursorShape: tile.more ? Qt.PointingHandCursor : Qt.OpenHandCursor
                        onPressed: event => {
                            if (event.button === Qt.LeftButton && root.dragProxy)
                                parent.grabToImage(result => root.dragProxy.Drag.imageSource = result.url);
                        }
                        onReleased: {
                            if (root.dragProxy && root.dragProxy.Drag.active)
                                root.dragProxy.Drag.drop();
                            parent.x = 0;
                            parent.y = 0;
                        }
                        // A click opens the file (theirs: Quick Look / open); right or middle
                        // click takes it off the shelf.
                        onClicked: event => {
                            if (tile.more) {
                                Files.openShelf();
                                root.openFile("");   // folds the sheet
                            } else if (event.button === Qt.LeftButton)
                                root.openFile(tile.path);
                            else
                                DropShelf.remove(tile.path);
                        }
                        // The sheet must not fold while a tile is being dragged out.
                        drag.onActiveChanged: {
                            root.draggingOut = cardArea.drag.active;
                            if (!root.dragProxy || tile.more)
                                return;
                            if (cardArea.drag.active) {
                                root.dragProxy.Drag.mimeData = { "text/uri-list": FileUtils.fileUrl(tile.path) };
                                root.dragProxy.Drag.active = true;
                            } else {
                                root.dragProxy.Drag.active = false;
                            }
                        }
                    }
                }
            }
        }
    }

    // Transport row while something plays, so the player is never out of reach behind the shelf.
    Row {
        anchors.left: parent.left
        anchors.leftMargin: 20
        anchors.right: parent.right
        anchors.rightMargin: 64
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 6
        height: 30
        spacing: 8
        visible: root.showTransport

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 3 * 28 - 3 * 8
            text: MprisController.activePlayer?.trackTitle || "Unknown track"
            elide: Text.ElideRight
            font.family: Appearance.font.family.title
            font.pixelSize: 13
            color: IslandController.subtextColor
        }
        IslandControlButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 28
            implicitHeight: 28
            glyph: "skip_previous"
            iconSize: 16
            enabled: MprisController.canGoPrevious
            onActivated: MprisController.previous()
        }
        IslandControlButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 28
            implicitHeight: 28
            glyph: MprisController.isPlaying ? "pause" : "play_arrow"
            iconSize: 16
            onActivated: MprisController.togglePlaying()
        }
        IslandControlButton {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 28
            implicitHeight: 28
            glyph: "skip_next"
            iconSize: 16
            enabled: MprisController.canGoNext
            onActivated: MprisController.next()
        }
    }

    // Right column: copy all, clear.
    Column {
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.top: parent.top
        anchors.topMargin: 4
        spacing: 6

        IslandControlButton {
            glyph: "content_copy"
            enabled: !root.empty
            onActivated: DropShelf.copyAll()
        }
        IslandControlButton {
            glyph: "delete_sweep"
            enabled: !root.empty
            onActivated: DropShelf.clear()
        }
    }
}
