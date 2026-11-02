pragma ComponentBehavior: Bound
import QtQuick
import Qt5Compat.GraphicalEffects
import qs
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.utils
import qs.modules.common.widgets
import qs.modules.tacit.overlay
import qs.services
import qs.modules.ii.overlay

StyledOverlayWidget {
    id: root
    showClickabilityButton: false
    resizable: false
    // A picture brings its own ground; the empty card keeps the card's, so its words can be read.
    pinnedGround: !root.hasImage
    // A picture is for looking through; the empty card's button is not.
    clickthrough: root.hasImage || root.persistentStateEntry.clickthrough

    property string imageSource: Config.options.overlay.floatingImage.imageSource
    property real scaleFactor: Config.options.overlay.floatingImage.scale
    // The picture's own size, 0 until there is one.
    property int imageWidth: 0
    property int imageHeight: 0
    readonly property bool hasImage: root.imageWidth > 0 && root.imageHeight > 0
    // The empty card: room for the mark, the words and the button, and no more.
    readonly property int emptyWidth: 260
    readonly property int emptyHeight: 120
    // The first load is the completed component's; after that a new source loads itself.
    property bool created: false

    // Override to always save 0 size
    function savePosition(xPos = root.x, yPos = root.y, width = 0, height = 0) {
        root.persistentStateEntry.x = Math.round(xPos);
        root.persistentStateEntry.y = Math.round(yPos);
        root.persistentStateEntry.width = 0
        root.persistentStateEntry.height = 0
    }

    // "" is no picture; a path is read where it is and an address is fetched (ImageDownloaderProcess).
    function load() {
        root.imageWidth = 0;
        root.imageHeight = 0;
        animatedImage.source = "";
        imageDownloader.stop();
        if (root.imageSource.length > 0)
            imageDownloader.start(root.imageSource,
                Qt.resolvedUrl(Directories.tempImages + "/" + Qt.md5(root.imageSource)));
    }
    onImageSourceChanged: {
        if (root.created)
            root.load();
    }
    Component.onCompleted: {
        root.created = true;
        root.load();
    }

    // Pinax asks in a window of its own; OverlayContext closes the overlay for it and takes the
    // answer, because the answer comes after this widget is gone.
    function chooseImage() {
        OverlayContext.pickImage();
    }

    contentItem: OverlayBackground {
        id: bg
        radius: root.contentRadius
        implicitWidth: root.hasImage ? Math.round(root.imageWidth * root.scaleFactor) : root.emptyWidth
        implicitHeight: root.hasImage ? Math.round(root.imageHeight * root.scaleFactor) : root.emptyHeight

        WheelHandler {
            onWheel: (event) => {
                if (event.angleDelta.y < 0) {
                    Config.options.overlay.floatingImage.scale = Math.max(0.1, Config.options.overlay.floatingImage.scale - 0.1);
                }
                else if (event.angleDelta.y > 0) {
                    Config.options.overlay.floatingImage.scale = Math.min(5.0, Config.options.overlay.floatingImage.scale + 0.1);
                }
            }
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        }

        layer.enabled: true
        layer.effect: OpacityMask {
            maskSource: Rectangle {
                width: bg.width
                height: bg.height
                radius: bg.radius
            }
        }

        AnimatedImage {
            id: animatedImage
            anchors.centerIn: parent
            visible: root.hasImage
            width: Math.round(root.imageWidth * root.scaleFactor)
            height: Math.round(root.imageHeight * root.scaleFactor)
            sourceSize.width: width
            sourceSize.height: height

            playing: visible
            asynchronous: true
            source: ""
        }

        // A picture in place: while the overlay is open, the same chooser again for another one.
        // On the card's own ground: a pill's wash alone disappears on a bright picture.
        Rectangle {
            visible: root.hasImage && GlobalStates.overlayOpen
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            implicitWidth: changePill.implicitWidth + 8
            implicitHeight: changePill.implicitHeight + 6
            radius: Appearance.rounding.full
            color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.04)

            OverlayPill {
                id: changePill
                anchors.centerIn: parent
                glyph: "imagesmode"
                label: Translation.tr("Change picture")
                onClicked: root.chooseImage()
            }
        }

        // Nothing to show yet (or the source could not be read): what the card is for, and the one
        // way to give it a picture.
        Column {
            visible: !root.hasImage
            anchors.centerIn: parent
            spacing: 10

            MaterialSymbol {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "add_photo_alternate"
                iconSize: 28
                color: Appearance.colors.colSubtext
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Translation.tr("No picture yet")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            OverlayPill {
                anchors.horizontalCenter: parent.horizontalCenter
                glyph: "imagesmode"
                label: Translation.tr("Choose a picture")
                onClicked: root.chooseImage()
            }
        }

        ImageDownloaderProcess {
            id: imageDownloader

            onDone: (path, width, height) => {
                root.imageWidth = width;
                root.imageHeight = height;
                animatedImage.source = path;
            }
        }
    }
}
