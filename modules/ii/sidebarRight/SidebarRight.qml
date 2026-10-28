import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import Quickshell.Io
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
// PROTOTYPE: exists for the swapped content below; remove with the swap to revert.
import "proto"
import Tacit.Kit

Scope {
    id: root
    // PROTOTYPE: the window hugs the prototype content's measure (seven 40 px cells —
    // the secondary row — plus the body's two 16 px paddings); revert to
    // Appearance.sizes.sidebarWidth with the swap when the layout idea is settled.
    // !!! Update together with the content's own paddings (SidebarRightContentProto's
    // sidebarPadding) and togglesWidth — this stale once already and cut the content.
    property int sidebarWidth: Kit.tokens.height.action * 7 + Kit.tokens.space.s * 6 + Kit.tokens.space.l * 2
    readonly property bool centerOnly: Config.options.bar.layouts.leftLayout.length === 0 && Config.options.bar.layouts.rightLayout.length === 0 && !Config.options.bar.vertical

    // PROTOTYPE: quickshell target for opening the panel without the notch, for the
    // reshuffle and screenshots; revert with the swap.
    IpcHandler {
        target: "sidebar-right"
        function toggle(): void {
            GlobalStates.sidebarRightOpen = !GlobalStates.sidebarRightOpen;
        }
        function open(): void {
            GlobalStates.sidebarRightOpen = true;
        }
        function close(): void {
            GlobalStates.sidebarRightOpen = false;
        }
    }

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
            // Matches Anim.Standard's own duration (the normal one); a little extra
            // would only keep the window a moment later, never empty the mask.
            interval: Appearance.animationCurves.normalDuration
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
                // bottom edge as one piece (caelestia launcher Wrapper.qml). A standard
                // curve, not the overshooting spatial one: a docked silhouette that
                // overshoots lifts off the edge it docks into, and the small panel made
                // that gap unmistakable (2026-10-25, prototype feedback). No fade: Hyprland
                // blurs only pixels above ignore_alpha, so a fading panel would pop its
                // blur in mid-way.
                property real offsetScale: open ? 0 : 1
                height: contentHeight
                transform: Translate { y: entranceWrapper.contentHeight * entranceWrapper.offsetScale }

                Behavior on offsetScale {
                    Anim {
                        type: Anim.Standard
                    }
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

                    // PROTOTYPE: the content shown is the rearranged panel
                    // (proto/SidebarRightContentProto.qml); swap back to
                    // SidebarRightContent and drop the "proto" import below to revert.
                    sourceComponent: SidebarRightContentProto {
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