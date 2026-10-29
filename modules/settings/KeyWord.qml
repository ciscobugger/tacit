import QtQuick
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * An action as words, in a list of them under a row ("Change the keys"): 40 high, the secondary ink, a wash on hover,
 * the accent ring when the keyboard is on it. Enter or Space does it.
 */
Item {
    id: word
    property string text: ""
    signal activated()
    readonly property real wordsWidth: label.implicitWidth
    width: label.implicitWidth + 2 * Tacit.space.l
    height: Tacit.height.action
    activeFocusOnTab: visible
    Keys.onReturnPressed: word.activated()
    Keys.onEnterPressed: word.activated()
    Keys.onSpacePressed: word.activated()
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: Tacit.space.xs
        anchors.bottomMargin: Tacit.space.xs
        radius: Tacit.radius.row
        color: ColorUtils.transparentize(Tacit.inkMain, 1 - (tap.containsMouse ? Tacit.wash.hover : 0))
        border.width: word.activeFocus && (word.focusReason === Qt.TabFocusReason || word.focusReason === Qt.BacktabFocusReason) ? Tacit.state.focusRing : 0
        border.color: Tacit.accent
    }
    StyledText {
        id: label
        anchors.centerIn: parent
        text: word.text
        font.pixelSize: Tacit.size.row
        color: tap.containsMouse ? Tacit.inkMain : Tacit.inkSec
    }
    MouseArea { id: tap; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: word.activated() }
}
