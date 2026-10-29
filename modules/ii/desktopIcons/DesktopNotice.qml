import QtQuick
import qs.modules.common
import Tacit.Kit as K

/**
 * The line above the dock that says what just happened ("Moved Budget 2027.xlsx to the trash") and offers Undo:
 * the kit's Notice (tacit-kit Notice.qml) drawn from the shell's own tokens, because the shell's Tacit does not
 * carry the kit's `motion.notice` yet. Same look, same time (K.Kit.motion("notice")), the pointer on it keeps it.
 * `show(text, words)`; words "" shows no Undo. `activated()` is Undo.
 */
Item {
    id: notice
    property string text: ""
    property string actionWords: ""
    property bool isShown: false
    readonly property bool shown: isShown
    readonly property bool held: bubbleHover.hovered || pill.activeFocus
    signal activated()

    function show(line, words) {
        notice.text = line;
        notice.actionWords = words ?? "";
        notice.isShown = true;
        stay.restart();
    }
    function hide() {
        if (!notice.isShown)
            return;
        notice.isShown = false;
        stay.stop();
    }
    onHeldChanged: if (notice.isShown) { if (notice.held) stay.stop(); else stay.restart(); }
    Timer { id: stay; interval: K.Kit.ms(K.Kit.motion("notice").ms); onTriggered: if (!notice.held) notice.hide() }

    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    readonly property real maxWidth: parent.width - 2 * Tacit.space.l
    width: Math.min(bubble.implicitWidth, notice.maxWidth)
    height: bubble.implicitHeight
    visible: progress.value > 0.001 || notice.isShown
    Accessible.role: Accessible.AlertMessage
    Accessible.name: notice.text
    Keys.onEscapePressed: notice.hide()

    QtObject {
        id: progress
        property real value: notice.isShown ? 1 : 0
        Behavior on value {
            NumberAnimation {
                duration: K.Kit.ms(notice.isShown ? Tacit.motion.arriveSmall.ms : Tacit.motion.leave.ms)
                easing.type: Easing.BezierSpline
                easing.bezierCurve: notice.isShown ? Tacit.motion.arriveSmall.curve : Tacit.motion.leave.curve
            }
        }
    }
    Rectangle {
        id: bubble
        width: notice.width
        implicitWidth: row.implicitWidth + 2 * Tacit.space.l
        implicitHeight: Tacit.height.row
        radius: Tacit.radius.slab
        color: Tacit.overlay
        border.width: 1
        border.color: Qt.alpha(Tacit.inkMain, 0.10)
        opacity: progress.value
        transform: Translate { y: (1 - progress.value) * Tacit.space.l }
        HoverHandler { id: bubbleHover }
        Row {
            id: row
            anchors.verticalCenter: parent.verticalCenter
            x: Tacit.space.l
            spacing: Tacit.space.m
            K.TacitText {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, notice.maxWidth - 2 * Tacit.space.l - (pill.visible ? pill.width + row.spacing : 0))
                text: notice.text
                elide: Text.ElideRight
            }
            Item {
                id: pill
                visible: notice.actionWords !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: pillWords.implicitWidth + 2 * Tacit.space.l
                height: Tacit.height.field - Tacit.space.xs
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: notice.actionWords
                Accessible.onPressAction: pill.press()
                function press() { notice.activated(); notice.hide(); }
                scale: pillTap.pressed ? Tacit.state.pressScale : 1
                Behavior on scale { NumberAnimation { duration: K.Kit.ms(Tacit.motion.hover.ms) } }
                Rectangle {
                    id: pillFace
                    anchors.fill: parent
                    radius: height / 2
                    color: Tacit.accent
                    Rectangle {
                        anchors.fill: parent; radius: parent.radius; color: Tacit.inkOnAccent
                        opacity: pillHover.hovered ? Tacit.wash.hover : 0
                        Behavior on opacity { NumberAnimation { duration: K.Kit.ms(Tacit.motion.hover.ms) } }
                    }
                }
                K.FocusRing { shown: pill.activeFocus && K.Kit.focusVisible; corner: pillFace.radius }
                K.TacitText { id: pillWords; anchors.centerIn: parent; text: notice.actionWords; weight: "medium"; ink: "onAccent" }
                HoverHandler { id: pillHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { id: pillTap; onTapped: { K.Kit.focusVisible = false; pill.press(); } }
                Keys.onPressed: event => {
                    K.Kit.focusVisible = true;
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        pill.press();
                        event.accepted = true;
                    }
                }
            }
        }
    }
}
