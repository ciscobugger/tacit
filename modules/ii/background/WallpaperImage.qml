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
 */
StyledImage {
    id: root
    property string target: ""
    // device pixels the picture has to cover
    property size view: Qt.size(width, height)
    property real aspect: 0
    // the picture in `source` is the one asked for in `target` (until the probe is back, `status` still speaks of the last one)
    property string shown: ""
    readonly property bool loaded: root.status === Image.Ready && root.shown === root.target
    readonly property string targetUrl: FileUtils.fileUrl(root.target)
    readonly property point focusAt: Wallpapers.focusFor(root.target)

    fillMode: Image.Stretch
    readonly property real coverW: root.aspect > root.view.width / root.view.height ? root.view.height * root.aspect : root.view.width
    readonly property real coverH: root.aspect > root.view.width / root.view.height ? root.view.height : root.view.width / root.aspect
    sourceSize: root.aspect > 0 ? Qt.size(Math.ceil(root.coverW), Math.ceil(root.coverH)) : Qt.size(0, 0)
    sourceClipRect: root.aspect > 0 ? Qt.rect(
        Math.floor(root.focusAt.x * (Math.ceil(root.coverW) - root.view.width)),
        Math.floor(root.focusAt.y * (Math.ceil(root.coverH) - root.view.height)),
        root.view.width, root.view.height) : Qt.rect(0, 0, 0, 0)

    onTargetChanged: {
        if (root.target === "") {
            root.source = "";
            root.shown = "";
            root.aspect = 0;
        }
    }

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
                root.shown = root.target;
                root.source = root.targetUrl;
            } else if (status === Image.Error) {
                // let the real load fail too, so the caller's own error path (Status Error) runs
                root.aspect = 0;
                root.shown = root.target;
                root.source = root.targetUrl;
            }
        }
    }
}
