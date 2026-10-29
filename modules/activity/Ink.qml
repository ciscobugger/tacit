pragma Singleton
import QtQuick
import Quickshell
import qs.modules.common
import qs.modules.common.functions

// Activity's inks, measured on the frosted ground in the v7 mock: emphasis by brightness, sand for
// the cause's amount and the recommended action only.
Singleton {
    readonly property color main: Tacit.inkMain
    readonly property color sec: Tacit.inkSec
    readonly property color meta: Tacit.inkMeta
    readonly property color faint: Tacit.inkFaint
    readonly property color sand: Tacit.accent
    readonly property color onSand: Tacit.inkOnAccent
    // the render harness draws this row as if the pointer were on it
    property string previewHover: ""
    // the row the pointer is on; while there is one, the list does not re-order under it
    property string pointerRow: ""
}
