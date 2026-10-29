import QtQuick
import Qt5Compat.GraphicalEffects
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.tacit

/**
 * The Gallery: the file the keyboard is on, large, and the folder as a strip under it. Left and Right walk the
 * strip, Enter opens; a click picks, a double click opens, a right click gives the file's menu. A picture shows
 * itself; anything else is said by its glyph and what it is. Where you are in the strip: a wash and the sand
 * tick under it, Praxis's mark turned on its side.
 */
Item {
    id: gallery

    property var model                    // the window's folder model
    property int cursor: -1
    property var selectedMap: ({})
    property var shown: name => true      // the window's filter
    signal picked(int index, var mouse)
    signal opened(int index)
    signal contextRequested(int index, real x, real y)

    readonly property bool has: !!gallery.model && gallery.cursor >= 0 && gallery.cursor < gallery.model.count
    readonly property string path: gallery.has ? gallery.model.get(gallery.cursor, "filePath") : ""
    readonly property bool isDir: gallery.has && gallery.model.get(gallery.cursor, "fileIsDir")
    readonly property var thing: gallery.path.length > 0 ? Things.describe(gallery.path + (gallery.isDir ? "/" : "")) : null
    readonly property bool picture: !!gallery.thing && gallery.thing.kind === "image"
    function kindWord(k) {
        return ({ folder: "Folder", image: "Picture", video: "Video", audio: "Audio", pdf: "PDF", doc: "Document",
                  archive: "Archive", code: "Code", text: "Text" })[k] ?? "File";
    }
    readonly property string facts: {
        if (!gallery.has)
            return "";
        const parts = [gallery.kindWord(gallery.thing?.kind ?? "")];
        if (!gallery.isDir)
            parts.push(Voice.size(gallery.model.get(gallery.cursor, "fileSize")));
        parts.push(Voice.age(gallery.model.get(gallery.cursor, "fileModified").getTime()));
        return Voice.facts(parts);
    }
    onCursorChanged: if (gallery.cursor >= 0) Qt.callLater(() => strip.positionViewAtIndex(gallery.cursor, ListView.Contain))
    onVisibleChanged: if (visible && gallery.cursor >= 0) Qt.callLater(() => strip.positionViewAtIndex(gallery.cursor, ListView.Center))

    // the look
    Item {
        id: stage
        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: caption.top; topMargin: 12; bottomMargin: 12; leftMargin: 16; rightMargin: 16 }
        Image {
            id: big
            anchors.fill: parent
            visible: gallery.picture && status === Image.Ready
            source: gallery.picture ? "file://" + gallery.path : ""
            asynchronous: true
            cache: false
            autoTransform: true
            sourceSize.width: 1600
            sourceSize.height: 1600
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            // a new picture settles in rather than snapping
            onSourceChanged: { big.opacity = 0; }
            onStatusChanged: if (status === Image.Ready) bigIn.restart()
            Anim { id: bigIn; target: big; property: "opacity"; from: 0; to: 1; type: Anim.FastEffects }
        }
        Rectangle {
            anchors.centerIn: parent
            visible: gallery.has && !big.visible
            width: 120
            height: 120
            radius: 22
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
            MaterialSymbol {
                anchors.centerIn: parent
                text: gallery.thing?.glyph ?? ""
                fill: gallery.isDir ? 1 : 0
                iconSize: 56
                color: Tacit.inkSec
            }
        }
        StyledText {
            anchors.centerIn: parent
            visible: !gallery.has
            text: "Nothing here"
            font.pixelSize: 15
            color: Tacit.inkMeta
        }
    }

    // what it is: its name, then kind, size and age
    Column {
        id: caption
        anchors { left: parent.left; right: parent.right; bottom: strip.top; bottomMargin: 12; leftMargin: 16; rightMargin: 16 }
        spacing: 2
        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: gallery.thing?.name ?? ""
            elide: Text.ElideMiddle
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: Tacit.inkMain
        }
        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: gallery.facts
            font.pixelSize: 13
            color: Tacit.inkMeta
        }
    }

    // the folder, as a strip
    ListView {
        id: strip
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 6 }
        height: 96
        orientation: ListView.Horizontal
        spacing: 4
        clip: true
        model: gallery.model
        boundsBehavior: Flickable.StopAtBounds
        GlideWheel { view: strip }
        delegate: Item {
            id: tile
            required property int index
            required property string fileName
            required property string filePath
            required property bool fileIsDir
            readonly property bool shownHere: gallery.shown(tile.fileName)
            readonly property bool here: tile.index === gallery.cursor
            readonly property var thing: Things.describe(tile.filePath + (tile.fileIsDir ? "/" : ""))
            width: tile.shownHere ? 88 : 0
            height: 96
            visible: tile.shownHere
            Rectangle {
                anchors { fill: parent; bottomMargin: 8 }
                radius: 12
                color: tile.here ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
                    : gallery.selectedMap[tile.filePath] ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                    : tileArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
                Behavior on color { ColorAnimation { duration: 80 } }
            }
            Item {
                id: art
                x: 8
                y: 8
                width: 72
                height: 72
                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                    visible: tile.thing.kind !== "image" || thumb.status !== Image.Ready
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: tile.thing.glyph
                        fill: tile.fileIsDir ? 1 : 0
                        iconSize: 28
                        color: Tacit.inkSec
                    }
                }
                Loader {
                    id: thumb
                    anchors.fill: parent
                    active: tile.thing.kind === "image"
                    readonly property int status: item ? item.status : Image.Null
                    sourceComponent: ThumbnailImage {
                        sourcePath: tile.filePath
                        sourceSize.width: 144
                        sourceSize.height: 144
                        fillMode: Image.PreserveAspectCrop
                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle { width: 72; height: 72; radius: 8 }
                        }
                    }
                }
            }
            // where you are: the sand tick, under the tile
            Rectangle {
                visible: tile.here
                anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 1 }
                width: 16
                height: 3
                radius: 1.5
                color: Tacit.accent
            }
            MouseArea {
                id: tileArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        const p = tileArea.mapToItem(null, mouse.x, mouse.y);
                        gallery.contextRequested(tile.index, p.x, p.y);
                    } else gallery.picked(tile.index, mouse);
                }
                onDoubleClicked: gallery.opened(tile.index)
            }
            StyledToolTip { text: tile.fileName; extraVisibleCondition: tileArea.containsMouse }
        }
    }
}
