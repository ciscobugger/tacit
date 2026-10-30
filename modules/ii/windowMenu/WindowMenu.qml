pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions

// The menu a right click on a window's top edge opens (WindowBand.menu, asked for by tacit-frame): the screen in small,
// the places a window can go. The whole card is five places, so nothing has to be aimed at: toward its top the notch
// (close), its bottom the dock (hide), its sides the halves, its middle filling the screen (or back to its size). The
// menu opens with its middle under the hand, so the middle is nothing until the hand has moved and let go: a release or
// a click where it opened never fills. Pointing at a place shows it on the real screen and the notch says it; a click,
// the arrow keys and Enter, or the right press held, moved and let go picks it. It is the drag drawn small. Approved as mocks/window-band/menu.html
// (2026-10-29), after the list of words read as any Linux menu.
Scope {
    id: root

    Loader {
        active: WindowBand.menu !== null
        sourceComponent: PanelWindow {
            id: menuWindow
            readonly property var m: WindowBand.menu
            readonly property string address: m?.address ?? ""
            readonly property var top: WindowBand.toplevelAt(address)
            readonly property var win: top?.lastIpcObject ?? null
            readonly property string appId: top?.wayland?.appId ?? (win?.class ?? "")
            readonly property string dockAppId: WindowBand.dockId(appId)
            readonly property string name: WindowBand.nameFor(win?.class ?? appId)
            readonly property bool filled: (win?.fullscreen ?? 0) === 1
            readonly property color light: Qt.rgba(1, 226 / 255, 200 / 255, 1)
            // the place pointed at: close, hide, left, right, fill or none
            property string place: ""
            // opened by a right press the plugin keeps: its release comes as menuup, and picks if the hand moved
            property bool held: true
            property bool moved: false
            property bool done: false

            function placeAt(x, y) {
                const c = mini.mapToItem(menuWindow.contentItem, mini.width / 2, mini.height / 2);
                const dx = (x - c.x) / (mini.width / 2), dy = (y - c.y) / (mini.height / 2);
                if (Math.abs(dx) < 0.3 && Math.abs(dy) < 0.34)
                    return menuWindow.held || !menuWindow.moved ? "" : "fill";
                if (Math.abs(dy) * 1.25 >= Math.abs(dx))
                    return dy < 0 ? "close" : "hide";
                return dx < 0 ? "left" : "right";
            }
            function near(x, y) {
                const p = card.mapToItem(menuWindow.contentItem, 0, 0);
                return x >= p.x - 24 && x <= p.x + card.width + 24 && y >= p.y - 24 && y <= p.y + card.height + 24;
            }
            // the place on the real screen: the notch says it, and for a hide the dock rises with the button that takes it
            onPlaceChanged: {
                const words = {
                    "close": `Close ${menuWindow.name}`,
                    "hide": `Hide ${menuWindow.name}`,
                    "left": `${menuWindow.name} on the left`,
                    "right": `${menuWindow.name} on the right`,
                    "fill": menuWindow.filled ? `${menuWindow.name} back to its size` : `${menuWindow.name} fills the screen`
                }[menuWindow.place];
                const icon = { "close": "close", "hide": "minimize", "left": "splitscreen_left", "right": "splitscreen_right", "fill": "fullscreen" }[menuWindow.place];
                if (words)
                    IslandController.request("window", { "text": words, "icon": icon, "hold": 60000, "prompt": true }, 65);
                else if (IslandController.transientState === "window" && IslandController.payload?.prompt)
                    IslandController.dismiss();
                if (menuWindow.place === "hide") {
                    WindowBand.dragAddress = menuWindow.address;
                    WindowBand.dragApp = menuWindow.dockAppId;
                    WindowBand.dropInto = menuWindow.dockAppId;
                    WindowBand.holdDock = true;
                } else if (WindowBand.holdDock && WindowBand.dropInto === menuWindow.dockAppId) {
                    WindowBand.holdDock = false;
                    WindowBand.dropInto = "";
                    WindowBand.dragAddress = "";
                }
            }
            function close() {
                if (menuWindow.done)
                    return;
                menuWindow.done = true;
                menuWindow.place = "";
                WindowBand.menu = null;
            }
            function pick(p) {
                if (!p || menuWindow.done)
                    return;
                const a = menuWindow.address;
                menuWindow.done = true;
                // the notch's words go; a hide keeps the dock up for the window to land in
                if (IslandController.transientState === "window" && IslandController.payload?.prompt)
                    IslandController.dismiss();
                WindowBand.act(p, a);
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
            Component.onDestruction: {
                GlobalFocusGrab.removeDismissable(menuWindow);
                if (!menuWindow.done)
                    menuWindow.close();
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    menuWindow.close();
                }
            }
            Connections {
                target: WindowBand
                function onMenuReleased(address) {
                    if (!menuWindow.held)
                        return;
                    menuWindow.held = false;
                    if (menuWindow.moved && menuWindow.place)
                        menuWindow.pick(menuWindow.place);
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPositionChanged: mouse => {
                    if (Math.hypot(mouse.x - (menuWindow.m?.x ?? 0), mouse.y - (menuWindow.m?.y ?? 0)) > 10)
                        menuWindow.moved = true;
                    // held, the direction alone picks; opened by a click, only over the card
                    menuWindow.place = menuWindow.held || menuWindow.near(mouse.x, mouse.y) ? menuWindow.placeAt(mouse.x, mouse.y) : "";
                }
                onClicked: mouse => {
                    if (mouse.button === Qt.LeftButton && menuWindow.near(mouse.x, mouse.y))
                        menuWindow.pick(menuWindow.placeAt(mouse.x, mouse.y));
                    else
                        menuWindow.close();
                }
            }

            // where the window would go, on the real screen: a half filled in, or the whole screen drawn round
            Rectangle {
                readonly property bool side: menuWindow.place === "left" || menuWindow.place === "right"
                x: menuWindow.place === "right" ? parent.width / 2 + 4 : 8
                y: 44
                width: side ? parent.width / 2 - 12 : parent.width - 16
                height: parent.height - 52 - 8
                radius: 14
                color: side ? ColorUtils.transparentize(Appearance.colors.colPanelFrost, 0.35) : "transparent"
                border.width: 1.5
                border.color: ColorUtils.transparentize(menuWindow.light, 0.6)
                opacity: side || menuWindow.place === "fill" ? 1 : 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
            }

            Rectangle {
                id: card
                width: mini.width + 20
                height: mini.height + 20
                // its middle under the hand, so the hand moves the way the drag would; kept on the screen, under the notch
                x: Math.min(Math.max((menuWindow.m?.x ?? 0) - width / 2, 8), menuWindow.width - width - 8)
                y: Math.min(Math.max((menuWindow.m?.y ?? 0) - height / 2, 44), menuWindow.height - height - 8)
                radius: 16
                color: Appearance.colors.colPanelFrost
                scale: 0.94
                opacity: 0
                focus: true
                Keys.onPressed: event => {
                    const k = { [Qt.Key_Up]: "close", [Qt.Key_Down]: "hide", [Qt.Key_Left]: "left", [Qt.Key_Right]: "right" }[event.key];
                    if (k) {
                        menuWindow.held = false;
                        menuWindow.place = k;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        menuWindow.pick(menuWindow.place || "fill");
                    } else if (event.key === Qt.Key_Escape) {
                        menuWindow.close();
                    } else {
                        return;
                    }
                    event.accepted = true;
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

                // the screen in small: its wallpaper, dimmed; the notch, the dock and the sides
                Rectangle {
                    id: mini
                    anchors.centerIn: parent
                    width: 232
                    height: 145
                    radius: 10
                    clip: true
                    color: "#1a1412"

                    Image {
                        anchors.fill: parent
                        readonly property string wallpaper: Config.options.background.wallpaperPath ?? ""
                        readonly property string thumbnail: Config.options.background.thumbnailPath ?? ""
                        // Image cannot decode a live wallpaper (an .mp4, .webm, ...); the still made for the wallpaper
                        // strip can. Without it the map was a black card.
                        readonly property string path: /\.(mp4|webm|mkv|mov|m4v|gif)$/i.test(wallpaper) && thumbnail.length > 0
                            ? thumbnail : wallpaper
                        source: path.length === 0 ? "" : path.startsWith("/") ? `file://${path}` : path
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 464
                        asynchronous: true
                        opacity: status === Image.Ready ? 1 : 0
                    }
                    Rectangle {
                        anchors.fill: parent
                        color: Qt.rgba(11 / 255, 6 / 255, 5 / 255, 0.3)
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: 1
                        border.color: Qt.rgba(232 / 255, 225 / 255, 223 / 255, 0.16)
                    }

                    // the place pointed at glows from its side of the card
                    Rectangle {
                        anchors.fill: parent
                        opacity: menuWindow.place ? 1 : 0
                        gradient: Gradient {
                            orientation: menuWindow.place === "left" || menuWindow.place === "right" ? Gradient.Horizontal : Gradient.Vertical
                            GradientStop {
                                position: 0
                                color: menuWindow.place === "close" || menuWindow.place === "left" ? Qt.rgba(1, 226 / 255, 200 / 255, 0.16) : "transparent"
                            }
                            GradientStop {
                                position: 0.5
                                color: menuWindow.place === "fill" ? Qt.rgba(1, 226 / 255, 200 / 255, 0.1) : "transparent"
                            }
                            GradientStop {
                                position: 1
                                color: menuWindow.place === "hide" || menuWindow.place === "right" ? Qt.rgba(1, 226 / 255, 200 / 255, 0.16) : "transparent"
                            }
                        }
                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                    }

                    Rectangle {
                        readonly property bool on: menuWindow.place === "close"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        width: on ? 64 : 52
                        height: 11
                        bottomLeftRadius: 6
                        bottomRightRadius: 6
                        Behavior on width {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        color: on ? menuWindow.light : Qt.rgba(30 / 255, 27 / 255, 26 / 255, 0.85)
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                    Rectangle {
                        readonly property bool on: menuWindow.place === "hide"
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        width: 96
                        height: on ? 16 : 13
                        topLeftRadius: 6
                        topRightRadius: 6
                        Behavior on height {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        color: on ? menuWindow.light : Qt.rgba(30 / 255, 27 / 255, 26 / 255, 0.85)
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                    Rectangle {
                        readonly property bool on: menuWindow.place === "left"
                        x: 4
                        y: 26
                        width: on ? 6 : 4
                        height: parent.height - 52
                        radius: 2
                        color: on ? menuWindow.light : Qt.rgba(1, 226 / 255, 200 / 255, 0.35)
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                    Rectangle {
                        readonly property bool on: menuWindow.place === "right"
                        x: parent.width - width - 4
                        y: 26
                        width: on ? 6 : 4
                        height: parent.height - 52
                        radius: 2
                        color: on ? menuWindow.light : Qt.rgba(1, 226 / 255, 200 / 255, 0.35)
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                    // the middle, pointed at: a window growing out to fill the space between the notch, the dock and the sides
                    // (filled already, shrinking in to a window's size); nothing is drawn there otherwise
                    Rectangle {
                        readonly property bool on: menuWindow.place === "fill"
                        readonly property bool big: on !== menuWindow.filled
                        x: big ? 14 : mini.width * 0.27
                        y: big ? 15 : mini.height * 0.29
                        width: mini.width - 2 * x
                        height: big ? mini.height - 34 : mini.height * 0.42
                        radius: 5
                        color: Qt.rgba(29 / 255, 26 / 255, 25 / 255, 0.9)
                        border.width: 1.5
                        border.color: menuWindow.light
                        opacity: on ? 1 : 0
                        Behavior on x {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on y {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on height {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 3
                            width: 14
                            height: 2
                            radius: 1
                            color: Qt.rgba(223 / 255, 192 / 255, 178 / 255, 0.8)
                        }
                    }
                }
            }
        }
    }
}
