pragma Singleton
import QtQuick
import Quickshell
import qs.modules.common
import qs.modules.common.functions

// Activity's inks, measured on the frosted ground in the v7 mock: emphasis by brightness, sand for
// the cause's amount and the recommended action only.
Singleton {
    readonly property color main: Appearance.colors.colInkMain
    readonly property color sec: ColorUtils.mix(Appearance.colors.colInkMain, Appearance.colors.colInkSecondary, 0.25)
    readonly property color meta: ColorUtils.mix(Appearance.colors.colInkSecondary, Appearance.colors.colInkMeta, 0.4)
    readonly property color faint: Appearance.colors.colInkFaint
    readonly property color sand: Appearance.colors.colPrimary
    readonly property color onSand: Appearance.m3colors.m3onPrimary
    // the render harness draws this row as if the pointer were on it
    property string previewHover: ""
    // the row the pointer is on; while there is one, the list does not re-order under it
    property string pointerRow: ""
}
