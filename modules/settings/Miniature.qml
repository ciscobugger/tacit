import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.modules.common
import qs.modules.common.functions

/**
 * This screen at a quarter of its size, for Appearance: the wallpaper, the notch docked into the
 * top edge, and one window floating over it the way Settings opens, frosted as much as the window
 * really is. The dock hides at rest, so it is not drawn. Geometry is the desktop's, scaled by k.
 */
Item {
    id: mini
    property string wallpaper: ""
    property color ground: Appearance.m3colors.m3surfaceContainerLow
    property real seeThrough: 0.15             // the window's transparency, 0 = solid
    readonly property real k: width / 1920
    implicitWidth: 480
    implicitHeight: width * 9 / 16

    Item {
        id: desk
        anchors.fill: parent
        visible: false

        Image {
            id: wall
            anchors.fill: parent
            // each part of the path escaped: a '#', '?' or '%' in a picture's name cut the address short and the
            // preview stayed empty
            source: mini.wallpaper.length > 0 ? "file://" + mini.wallpaper.split("/").map(encodeURIComponent).join("/") : ""
            sourceSize.width: 960
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
        }

        // one window, as Settings opens: blurred wallpaper under the ground, 18 px corners
        Item {
            id: win
            x: 360 * mini.k
            y: 170 * mini.k
            width: 1200 * mini.k
            height: 800 * mini.k
            Item {
                anchors.fill: parent
                anchors.margins: 1
                clip: true
                MultiEffect {
                    x: -win.x - 1
                    y: -win.y - 1
                    width: desk.width
                    height: desk.height
                    source: wall
                    blurEnabled: true
                    blur: 1
                    blurMax: 24
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: 18 * mini.k
                color: ColorUtils.transparentize(mini.ground, mini.seeThrough)
                border.width: 1
                border.color: ColorUtils.transparentize(Appearance.m3colors.m3outlineVariant, 0.5)
            }
            // its places on a slab, its page as lines
            Rectangle {
                x: 16 * mini.k
                y: 56 * mini.k
                width: 232 * mini.k
                height: parent.height - y - 16 * mini.k
                radius: 14 * mini.k
                color: Appearance.m3colors.m3surfaceContainerLow
                border.width: 1
                border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
            }
            Column {
                x: 272 * mini.k
                y: 64 * mini.k
                spacing: 7
                Rectangle { width: 70; height: 6; radius: 3; color: ColorUtils.transparentize(Appearance.colors.colInkMain, 0.5) }
                Repeater {
                    model: [190, 150, 200, 120, 170]
                    Rectangle {
                        required property int modelData
                        width: modelData * mini.k * 2.2
                        height: 3
                        radius: 1.5
                        color: ColorUtils.transparentize(Appearance.colors.colInkMain, 0.8)
                    }
                }
            }
        }

        // the notch: concave coves into the top edge, round below
        Shape {
            id: notch
            readonly property real w: 400 * mini.k
            readonly property real h: 36 * mini.k
            readonly property real c: 9 * mini.k
            readonly property real r: 14 * mini.k
            x: (mini.width - w) / 2 - c
            width: w + 2 * c
            height: h
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: "#0c0a0a"
                strokeColor: "transparent"
                startX: 0
                startY: 0
                PathArc { x: notch.c; y: notch.c; radiusX: notch.c; radiusY: notch.c; direction: PathArc.Clockwise }
                PathLine { x: notch.c; y: notch.h - notch.r }
                PathArc { x: notch.c + notch.r; y: notch.h; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Counterclockwise }
                PathLine { x: notch.c + notch.w - notch.r; y: notch.h }
                PathArc { x: notch.c + notch.w; y: notch.h - notch.r; radiusX: notch.r; radiusY: notch.r; direction: PathArc.Counterclockwise }
                PathLine { x: notch.c + notch.w; y: notch.c }
                PathArc { x: notch.w + 2 * notch.c; y: 0; radiusX: notch.c; radiusY: notch.c; direction: PathArc.Clockwise }
                PathLine { x: 0; y: 0 }
            }
        }
    }

    Rectangle {
        id: mask
        anchors.fill: parent
        radius: 10
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        anchors.fill: parent
        source: desk
        maskEnabled: true
        maskSource: mask
    }
    Rectangle {
        anchors.fill: parent
        radius: 10
        color: "transparent"
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
    }
}
