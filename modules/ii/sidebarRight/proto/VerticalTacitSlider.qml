import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls

// The panel's slider turned to the vertical: the same track, fill and dot language as
// TacitSlider (modules/tacit/TacitSlider.qml, the notch meter: 5 px track colLayer2, fill
// colPrimary, radius 2.5, 14 px dot at rest, 18 px held) sharing the vertical axis
// instead of retelling it sideways. `value` means amount: 0 at the bottom, 1 at the top,
// so up is always more, the way every vertical control reads — Qt's own vertical slider
// maps the other way, so this widget owns the mapping instead of inheriting it.
Item {
    id: root
    property real value: 0
    signal moved()

    readonly property real dotRest: 14
    readonly property real dotHeld: 18

    // Fixed size: the background sizes from the widget itself, so a chase between
    // implicitHeight and the track's height cannot happen.
    implicitWidth: 36
    implicitHeight: 140

    Slider {
        id: internal

        // The internal slider runs Qt's own way (min at the top); `amount` mirrors it,
        // so every visual number below is written once, in amount terms.
        readonly property real amount: 1 - internal.value

        anchors.fill: parent
        hoverEnabled: true
        // No Behavior on the internal value: here the dot is the thing being dragged,
        // and a smoothed chase under the finger feels detached.

        onMoved: {
            root.value = internal.amount;
            root.moved();
        }
        // Wheel and key change the amount; dragging writes it too, through onMoved.

        MouseArea {
            anchors.fill: parent
            onPressed: mouse => mouse.accepted = false
            cursorShape: internal.pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        }

        background: Item {
            Rectangle {
                id: track
                width: 5
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                radius: 2.5
                color: Appearance.colors.colLayer2
                // The held part, from the bottom up: the fill mirrors the amount, not
                // the track.
                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    radius: parent.radius
                    height: root.dotHeld / 2 + internal.amount * (internal.availableHeight - root.dotHeld)
                    color: Appearance.colors.colPrimary
                }
            }
        }

        // Same reason as TacitSlider's: the handle spans the held dot so the drag range
        // never changes when the dot grows; the dot is drawn in its middle.
        handle: Item {
            y: internal.topPadding + (1 - internal.amount) * (internal.availableHeight - height)
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.dotHeld
            height: width
            Rectangle {
                anchors.centerIn: parent
                width: internal.pressed ? root.dotHeld : root.dotRest
                height: width
                radius: width / 2
                color: Appearance.colors.colPrimary
                Behavior on width {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }

    onValueChanged: {
        // External writes (services, wheel helpers) move the dot without firing moved.
        if (Math.abs(internal.amount - root.value) > 0.001 && !internal.pressed)
            internal.value = 1 - root.value;
    }
}
