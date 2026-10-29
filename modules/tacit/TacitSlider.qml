import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls

// The notch meter's track, fill and number (modules/ii/island/IslandHeader.qml, meterBarWing:
// 5 px track colLayer2, fill colPrimary, radius 2.5, number 12 px in the numbers font, 34 px wide,
// 8 px gap) as a slider. A 14 px dot sits at the fill's end, 18 px while held (no Tacit source:
// the notch meter has no handle). Plain component, no services: the login lock's tree may load it.
// `label` replaces the percentage; `showNumber: false` for rows that print the value themselves.
Slider {
    id: root
    property bool showNumber: true
    property string label: ""

    readonly property real dotRest: 14
    readonly property real dotHeld: 18
    readonly property real numberArea: showNumber ? 34 + 8 : 0

    implicitHeight: 24
    rightPadding: numberArea
    hoverEnabled: true

    Behavior on value {
        SmoothedAnimation {
            velocity: Appearance.animation.elementMoveFast.velocity
        }
    }

    MouseArea {
        anchors.fill: parent
        onPressed: mouse => mouse.accepted = false
        cursorShape: root.pressed ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    }

    background: Item {
        implicitHeight: 24
        Rectangle {
            id: track
            width: root.width - root.numberArea
            anchors.verticalCenter: parent.verticalCenter
            height: 5
            radius: 2.5
            color: Appearance.colors.colLayer2
            Rectangle {
                height: parent.height
                width: root.dotHeld / 2 + root.visualPosition * (root.availableWidth - root.dotHeld)
                radius: parent.radius
                color: Appearance.colors.colPrimary
            }
        }
        StyledText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 34
            visible: root.showNumber
            horizontalAlignment: Text.AlignRight
            text: root.label.length > 0 ? root.label : `${Math.round(root.visualPosition * 100)}%`
            font.family: Appearance.font.family.numbers
            font.pixelSize: 13
            color: root.pressed ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
        }
    }

    // The handle item is as wide as the held dot, so the drag range does not change when the dot
    // grows; the dot is drawn in its middle.
    handle: Item {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        anchors.verticalCenter: parent.verticalCenter
        width: root.dotHeld
        height: width
        Rectangle {
            anchors.centerIn: parent
            width: root.pressed ? root.dotHeld : root.dotRest
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
