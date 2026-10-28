import QtQuick
import QtQuick.Effects
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit
import Tacit.Kit as K

/**
 * The Gallery: the file the keyboard is on, large, and the folder as a strip under it. Left and Right walk the
 * strip, Enter opens; a click picks, a double click opens, a right click gives the file's menu. A picture shows
 * itself; anything else is said by its symbol and what it is. In the strip, as in the grid: the selection is the
 * accent ring 4 px around a tile, the pointer's hover a 5 % wash, the keyboard's place the kit's focus ring.
 */
Item {
    id: gallery

    property var model                    // the window's folder model
    property int cursor: -1
    property var selectedMap: ({})
    property bool keysShown: false        // the keyboard's focus ring is showing
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
        K.Symbol {
            anchors.centerIn: parent
            visible: gallery.has && !big.visible
            text: gallery.thing?.glyph ?? ""
            filled: gallery.isDir
            size: 56
        }
    }

    // what it is: its name, then kind, size and age
    Column {
        id: caption
        anchors { left: parent.left; right: parent.right; bottom: strip.top; bottomMargin: 12; leftMargin: 16; rightMargin: 16 }
        spacing: 2
        K.TacitText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: gallery.thing?.name ?? ""
            elide: Text.ElideMiddle
            size: "body"
            weight: "medium"
        }
        K.TacitText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: gallery.facts
            ink: "sec"
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
        model: ScriptModel { values: gallery.model?.rows ?? []; objectProp: "filePath" }
        boundsBehavior: Flickable.StopAtBounds
        GlideWheel { view: strip }
        delegate: Item {
            id: tile
            required property int index
            required property var modelData
            readonly property string fileName: tile.modelData.fileName
            readonly property string filePath: tile.modelData.filePath
            readonly property bool fileIsDir: tile.modelData.fileIsDir
            readonly property bool shownHere: gallery.shown(tile.fileName)
            readonly property bool here: tile.index === gallery.cursor
            readonly property bool chosen: gallery.selectedMap[tile.filePath] === true
            readonly property var thing: Things.describe(tile.filePath + (tile.fileIsDir ? "/" : ""))
            width: tile.shownHere ? 88 : 0
            height: 96
            visible: tile.shownHere
            Item {
                id: art
                x: 8
                y: 8
                width: 72
                height: 72
                // no picture of itself: its symbol on the field's wash
                Rectangle {
                    anchors.fill: parent
                    radius: Tacit.radius.row
                    color: Qt.alpha(Tacit.inkMain, Tacit.wash.action)
                    visible: tile.thing.kind !== "image" || thumb.status !== Image.Ready
                    K.Symbol {
                        anchors.centerIn: parent
                        text: tile.thing.glyph
                        filled: tile.fileIsDir
                        size: 28
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
                        layer.effect: MultiEffect { maskEnabled: true; maskSource: artMask }
                    }
                }
                Rectangle { id: artMask; visible: false; width: 72; height: 72; radius: Tacit.radius.row; layer.enabled: true }
                // hover and press: the main ink over the tile
                Rectangle {
                    anchors.fill: parent
                    radius: Tacit.radius.row
                    color: Tacit.inkMain
                    opacity: tileArea.pressed ? Tacit.wash.pressed : tileArea.containsMouse ? Tacit.wash.hover : 0
                    Behavior on opacity { NumberAnimation { duration: Tacit.motion.hover.ms } }
                }
                Rectangle {
                    id: ring
                    anchors.fill: parent
                    anchors.margins: -4
                    radius: Tacit.radius.row + 4
                    color: "transparent"
                    border.width: 2
                    border.color: Tacit.accent
                    visible: tile.chosen
                }
                Item {
                    anchors.fill: tile.chosen ? ring : parent
                    K.FocusRing {
                        shown: gallery.keysShown && tile.here
                        corner: tile.chosen ? ring.radius : Tacit.radius.row
                    }
                }
            }
            MouseArea {
                id: tileArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onPressed: K.Kit.focusVisible = false
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        const p = tileArea.mapToItem(null, mouse.x, mouse.y);
                        gallery.contextRequested(tile.index, p.x, p.y);
                    } else gallery.picked(tile.index, mouse);
                }
                onDoubleClicked: gallery.opened(tile.index)
            }
            K.Tooltip { text: tile.fileName; shown: tileArea.containsMouse }
        }
    }
}
