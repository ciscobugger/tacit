import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls

// The control panel's slider (TacitSlider stays as it was, for Settings and the rest). The design kit's slider
// (https://design.tacitos.co/slider.html): a slim 6 px
// track, the reached part in the secondary ink over the track (main ink at 12 %),
// the 14 px knob shown only while the pointer is on it or a drag holds it, and
// the value as a word at its end in the secondary ink with tabular figures. The
// knob takes the shell's 14 px rest and 18 px held sizes so the drag range never
// changes. Plain component, no services: the login lock's tree may load it.
// `label` replaces the percentage; `showNumber: false` for rows that print the value themselves.
Slider {
    id: root
    property bool showNumber: true
    property string label: ""

    readonly property bool knobShown: root.hovered || root.pressed
    readonly property real dotRest: 14
    readonly property real dotHeld: 18
    readonly property real numberArea: showNumber ? 34 + 8 : 0

    implicitHeight: 28
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
        implicitHeight: 28
        Rectangle {
            id: track
            // The track lives in the padding box, not the whole control: with the
            // number's room taken from the right, the left padding must come off the
            // track too, or a full slider stops short of its own track's end.
            anchors.left: parent.left
            anchors.leftMargin: root.leftPadding
            anchors.verticalCenter: parent.verticalCenter
            width: root.availableWidth
            height: 6
            radius: 3
            // The quiet track: the main ink washed to 12 % over the ground — never a
            // colour of its own, the amount is the reached part's job.
            color: ColorUtils.transparentize(Tacit.inkMain, 0.88)
            // The reached part in the secondary ink (the kit moves the accent out of
            // the slider: accent is a mark, not an amount).
            // The reached part: to the value while the knob is away (a 100 % fill
            // closes flush with the track's end, 0 leaves nothing), and to the knob's
            // centre while it shows, so the fill meets the knob that follows it.
            Rectangle {
                height: parent.height
                width: root.knobShown
                    ? root.dotHeld / 2 + root.visualPosition * (root.availableWidth - root.dotHeld)
                    : root.visualPosition * root.availableWidth
                radius: parent.radius
                color: Tacit.inkSec
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
            color: Tacit.inkSec
        }
    }

    // The handle item is as wide as the held dot, so the drag range does not change when the dot
    // grows; the dot is drawn in its middle, and only exists while the pointer is on the
    // slider or a drag holds it: at rest a row of sliders stays quiet.
    handle: Item {
        x: root.leftPadding + root.visualPosition * (root.availableWidth - width)
        anchors.verticalCenter: parent.verticalCenter
        width: root.dotHeld
        height: width
        opacity: root.knobShown ? 1 : 0
        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
        Rectangle {
            anchors.centerIn: parent
            width: root.pressed ? root.dotHeld : root.dotRest
            height: width
            radius: width / 2
            color: Tacit.inkMain
            Behavior on width {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }
    }
}
