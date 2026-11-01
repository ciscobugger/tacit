import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Fills its box the way PreserveAspectCrop does, but with the part of the picture the person chose
 * (Wallpapers.focusFor) in view instead of always the middle. Set `target`, not `source`: a tiny copy
 * tells the picture's shape first, then the real one is decoded at the size that covers the box and
 * cut to it. The item stays exactly the box, so the transition shaders and blurs that sample it
 * need no change.
 *
 * `fit` is the person's choice (background.wallpaperFit): "fill" as above, "fit" the whole picture
 * inside the box (the box's ground shows beside it; a sampler then needs the item's layer, which
 * Background turns on), "stretch" the whole picture pulled to the box.
 */
StyledImage {
    id: root
    property string target: ""
    // device pixels the picture has to cover
    property size view: Qt.size(width, height)
    property string fit: "fill"
    // Look the picture's own size up first (Wallpapers.sizeFor, one header read per picture). Qt never
    // scales a decode up: a picture smaller than the box came back at its own size inside a box-sized
    // cut, padded with black - small in a corner of the screen (Discord #bugs, 2026-11-01). With its
    // size known, such a picture is decoded at that size and the cut is taken from it and scaled up.
    // Thumbnails leave it off: their boxes are smaller than any picture.
    property bool exact: false
    property real aspect: 0
    // the picture in `source` is the one asked for in `target` (until the probe is back, `status` still speaks of the last one)
    property string shown: ""
    // the probe has told this target's shape
    property string probed: ""
    readonly property bool loaded: root.status === Image.Ready && root.shown === root.target
    readonly property string targetUrl: FileUtils.fileUrl(root.target)
    readonly property point focusAt: Wallpapers.focusFor(root.target)
    // -1 while unknown, 0 when it cannot be read (then it is treated as large, as before)
    readonly property size natural: root.exact ? Wallpapers.sizeFor(root.target) : Qt.size(0, 0)
    readonly property bool sizeKnown: root.natural.width >= 0

    readonly property real viewAspect: root.view.width / root.view.height
    readonly property real coverW: root.aspect > root.viewAspect ? root.view.height * root.aspect : root.view.width
    readonly property real coverH: root.aspect > root.viewAspect ? root.view.height : root.view.width / root.aspect
    readonly property bool small: root.natural.width > 0 && root.natural.width < Math.ceil(root.coverW)
    // the part of a small picture with the box's shape, in the picture's own pixels
    readonly property real cutW: Math.min(root.natural.width, root.natural.height * root.viewAspect)
    readonly property real cutH: root.cutW / root.viewAspect

    fillMode: root.fit === "fit" ? Image.PreserveAspectFit : Image.Stretch
    sourceSize: root.aspect <= 0 || (root.fit === "fill" && root.small) ? Qt.size(0, 0)
        : root.fit === "fill" ? Qt.size(Math.ceil(root.coverW), Math.ceil(root.coverH))
        // fit and stretch: the whole picture, decoded no larger than the box
        : Qt.size(root.view.width, root.view.height)
    sourceClipRect: root.aspect <= 0 || root.fit !== "fill" ? Qt.rect(0, 0, 0, 0)
        : root.small ? Qt.rect(
            Math.floor(root.focusAt.x * (root.natural.width - root.cutW)),
            Math.floor(root.focusAt.y * (root.natural.height - root.cutH)),
            Math.floor(root.cutW), Math.floor(root.cutH))
        : Qt.rect(
            Math.floor(root.focusAt.x * (Math.ceil(root.coverW) - root.view.width)),
            Math.floor(root.focusAt.y * (Math.ceil(root.coverH) - root.view.height)),
            root.view.width, root.view.height)

    onTargetChanged: {
        if (root.target === "") {
            root.source = "";
            root.shown = "";
            root.probed = "";
            root.aspect = 0;
        }
    }
    // the decode waits for both the shape and (when exact) the size, so its first cut is the right one
    function show() {
        if (root.probed !== root.target || !root.sizeKnown || root.shown === root.target) return;
        root.shown = root.target;
        root.source = root.targetUrl;
    }
    onSizeKnownChanged: root.show()

    Image {
        id: probe
        visible: false
        asynchronous: true
        cache: true
        source: root.targetUrl
        sourceSize: Qt.size(64, 64)
        onStatusChanged: {
            if (status === Image.Ready && implicitHeight > 0) {
                root.aspect = implicitWidth / implicitHeight;
                root.probed = root.target;
                root.show();
            } else if (status === Image.Error) {
                // let the real load fail too, so the caller's own error path (Status Error) runs
                root.aspect = 0;
                root.probed = root.target;
                root.shown = root.target;
                root.source = root.targetUrl;
            }
        }
    }
}
