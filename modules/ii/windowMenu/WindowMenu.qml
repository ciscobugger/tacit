pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.ii.desktopMenu

// The menu a right click on a window's top edge opens (WindowBand.menu, asked for by tacit-frame): what the hand does
// on the band, for anyone who would rather click. Made only while it is open, in the desktop menu's card and rows.
Scope {
    id: root

    Loader {
        active: WindowBand.menu !== null
        sourceComponent: PanelWindow {
            id: menuWindow
            readonly property var m: WindowBand.menu
            function pick(verb) {
                WindowBand.act(verb, menuWindow.m?.address ?? "");
            }

            screen: Quickshell.screens.find(s => s.name === menuWindow.m?.monitor) ?? Quickshell.screens[0]
            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            WlrLayershell.namespace: "quickshell:windowMenu"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            Component.onCompleted: GlobalFocusGrab.addDismissable(menuWindow)
            Component.onDestruction: GlobalFocusGrab.removeDismissable(menuWindow)
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    WindowBand.menu = null;
                }
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: WindowBand.menu = null
            }

            Rectangle {
                id: card
                width: 240
                implicitHeight: col.implicitHeight + 20
                // under the hand, as a right click's menu is, kept on the screen
                x: Math.min(Math.max((menuWindow.m?.x ?? 0) - 20, 8), menuWindow.width - width - 8)
                y: Math.min(Math.max((menuWindow.m?.y ?? 0) + 6, 8), menuWindow.height - implicitHeight - 8)
                radius: Appearance.rounding.verylarge
                color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.04)
                scale: 0.85
                opacity: 0
                transformOrigin: Item.Top
                focus: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        WindowBand.menu = null;
                        event.accepted = true;
                    }
                }
                Component.onCompleted: {
                    scale = 1.0;
                    opacity = 1.0;
                }
                Behavior on scale {
                    animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                ColumnLayout {
                    id: col
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 10
                    }
                    spacing: 2
                    MenuRow {
                        glyph: "close"
                        label: "Close"
                        onClicked: menuWindow.pick("close")
                    }
                    MenuRow {
                        glyph: "minimize"
                        label: "Hide"
                        onClicked: menuWindow.pick("hide")
                    }
                    MenuHairline {}
                    MenuRow {
                        glyph: "fullscreen"
                        label: "Fill the screen"
                        onClicked: menuWindow.pick("fill")
                    }
                    MenuRow {
                        glyph: "splitscreen_left"
                        label: "Left half"
                        onClicked: menuWindow.pick("left")
                    }
                    MenuRow {
                        glyph: "splitscreen_right"
                        label: "Right half"
                        onClicked: menuWindow.pick("right")
                    }
                }
            }
        }
    }
}
