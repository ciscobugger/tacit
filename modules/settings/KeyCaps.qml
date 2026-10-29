import QtQuick
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services

/**
 * One key combination as caps, a cap for each key ("Super", "Shift", "S"). Small caps sit in a row of a list, big ones
 * hold what is being pressed. 28 high small (a row's height less 2 x its small space), 36 big (a field).
 */
Row {
    id: caps
    property string combo: ""          // "Super+Shift+S"
    property bool big: false
    property color ink: Tacit.inkSec
    spacing: Tacit.space.xs
    Repeater {
        model: caps.combo === "" ? [] : caps.combo.split("+")
        Rectangle {
            required property string modelData
            height: caps.big ? Tacit.height.field : Tacit.height.row - 2 * Tacit.space.s
            width: Math.max(height, label.implicitWidth + 2 * Tacit.space.s)
            radius: Tacit.radius.art
            color: ColorUtils.transparentize(Tacit.inkMain, 1 - Tacit.wash.current)
            StyledText {
                id: label
                anchors.centerIn: parent
                text: Shortcuts.capName(parent.modelData)
                font.pixelSize: caps.big ? Tacit.size.row : Tacit.size.meta
                font.weight: Tacit.weight.medium
                color: caps.ink
            }
        }
    }
}
