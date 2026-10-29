import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell.Io
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    readonly property bool centerOnly: Config.options.bar.layouts.leftLayout.length === 0 && Config.options.bar.layouts.rightLayout.length === 0 && !Config.options.bar.vertical

    PanelWindow {
        id: panelWindow

        readonly property bool animatedEntrance: WM.compositor !== "hyprland"
        property bool reallyVisible: false
        visible: reallyVisible

        Component.onCompleted: reallyVisible = GlobalStates.sidebarRightOpen

        Connections {
            target: GlobalStates
            function onSidebarRightOpenChanged() {
                if (GlobalStates.sidebarRightOpen) {
                    closeAnimTimer.stop();
                    panelWindow.reallyVisible = true;
                } else {
                    // The shell owns the exit slide on every compositor now (Hyprland's
                    // layer animation is off for this namespace), so always let it finish.
                    closeAnimTimer.restart();
                }
            }
        }

        Timer {
            id: closeAnimTimer
            interval: Appearance.animationCurves.expressiveDefaultSpatialDuration // matches Anim {}
            onTriggered: panelWindow.reallyVisible = false
        }

        function hide() {
            GlobalStates.sidebarRightOpen = false;
        }

        onVisibleChanged: {
            if (visible) {
                GlobalFocusGrab.addDismissable(panelWindow);
            } else {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
        }

        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                panelWindow.hide();
            }
        }

        exclusiveZone: 0
        // Bottom-right corner, sized to its content (see SidebarRightContent.qml). The window
        // is the body plus one cove on the left and one above (DockedRect corner mode).
        readonly property int cove: 12
        implicitWidth: sidebarWidth + cove
        // What the panel may never exceed: the screen minus the notch's reserved height. Past it the panel scrolls
        // its own content (SidebarRightContent.qml), because anything above the window's top
        // edge is outside the layer surface, where nothing is drawn and nothing is clickable.
        readonly property real panelMaxHeight: (screen?.height ?? 1080)
            - Config.options.island.reservedHeight - cove
        // Constant, like the notch's window: a layer surface cannot animate a resize, so the
        // window is as tall as the panel can ever get and the panel animates inside it. The
        // mask keeps the empty part click-through.
        implicitHeight: panelMaxHeight + cove
        // The click area is the part of the panel still inside the window. It is its own item
        // because a slide is a transform on entranceWrapper, and the mask must never leave the
        // surface.
        mask: Region {
            item: maskBox
        }
        WlrLayershell.namespace: "quickshell:sidebarRight"
        WlrLayershell.keyboardFocus: GlobalStates.sidebarRightOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        color: "transparent"

        anchors {
            right: true
            bottom: true
        }

        Item {
            anchors.fill: parent

            MouseArea {
                id: outsideClickArea
                anchors.fill: parent
                enabled: panelWindow.animatedEntrance
                visible: panelWindow.animatedEntrance
                onClicked: panelWindow.hide()
            }

            Item {
                id: maskBox
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(0, Math.min(entranceWrapper.contentHeight * (1 - entranceWrapper.offsetScale), parent.height))
            }

            Item {
                id: entranceWrapper
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                clip: true

                readonly property bool open: GlobalStates.sidebarRightOpen
                readonly property real contentHeight: (sidebarContentLoader.item?.implicitHeight ?? 0) + panelWindow.cove
                // The palette's motion, turned to this edge: the whole panel rises out of the
                // bottom edge as one piece and settles with the slight overshoot of the spatial
                // curve (caelestia launcher Wrapper.qml). No fade: Hyprland blurs only pixels
                // above ignore_alpha, so a fading panel would pop its blur in mid-way.
                property real offsetScale: open ? 0 : 1
                height: contentHeight
                transform: Translate { y: entranceWrapper.contentHeight * entranceWrapper.offsetScale }

                Behavior on offsetScale {
                    Anim {}
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => { mouse.accepted = true }
                    z: -1
                }

                Loader {
                    id: sidebarContentLoader
                    // The body sits flush in the corner; the cove to its left and the cove
                    // above it are drawn by the DockedRect inside SidebarRightContent.qml.
                    active: panelWindow.reallyVisible || Config?.options.sidebar.keepRightSidebarLoaded
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        leftMargin: panelWindow.cove
                    }
                    // No Behavior here: the content animates its own height (the date/calendar
                    // group on the standard curve), and the panel follows it frame by frame. A
                    // second animation on top made the panel overshoot and come back.
                    height: item?.implicitHeight ?? 0

                    focus: GlobalStates.sidebarRightOpen
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) {
                            panelWindow.hide();
                        }
                    }

                    sourceComponent: SidebarRightContent {
                        maxHeight: panelWindow.panelMaxHeight
                    }
                }
            }
        }

        IpcHandler {
            target: "sidebarRight"

            function toggle(): void {
                GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
            }

            function close(): void {
                GlobalStates.sidebarRightOpen = false;
            }

            function open(): void {
                GlobalStates.sidebarRightOpen = true;
            }

            // the panel on its sound section
            function openSound(): void {
                GlobalStates.sidebarRightSection = "showAudioOutputDialog";
                GlobalStates.sidebarRightOpen = true;
            }
        }

        CompositorGlobalShortcut {
            name: "sidebarRightToggle"
            description: "Toggles right sidebar on press"

            onPressed: {
                GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
            }
        }
        CompositorGlobalShortcut {
            name: "sidebarRightOpen"
            description: "Opens right sidebar on press"

            onPressed: {
                GlobalStates.sidebarRightOpen = true;
            }
        }
        CompositorGlobalShortcut {
            name: "sidebarRightClose"
            description: "Closes right sidebar on press"

            onPressed: {
                GlobalStates.sidebarRightOpen = false;
            }
        }
    }
}