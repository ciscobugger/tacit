import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The switch Settings uses, only for a real on/off: on is a sand track with the dark knob (sand's
 * own ink), off an outline with a quiet knob, so the two read apart at a glance. The track is sized
 * to the design's toggle (28x16 to 33x20) and the on state is the ink, not the accent.
 */
Switch {
    id: sw
    implicitWidth: 33
    implicitHeight: 20
    padding: 0
    background: null
    contentItem: null

    indicator: Rectangle {
        implicitWidth: 33
        implicitHeight: 20
        radius: 10
        color: sw.checked ? Tacit.inkMain : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 1)
        border.width: sw.checked ? 0 : 1.5
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.7)
        Behavior on color { ColorAnimation { duration: 140 } }

        Rectangle {
            width: 14
            height: 14
            radius: 7
            y: 3
            x: sw.checked ? parent.width - width - 3 : 3
            color: sw.checked ? Appearance.m3colors.m3onPrimary : Tacit.inkMeta
            Behavior on x { Anim { type: Anim.FastSpatial } }
            Behavior on color { ColorAnimation { duration: 140 } }
        }
    }
}
