import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root

    property bool reallyOpen: false

    Connections {
        target: GlobalStates
        function onWallpaperSelectorOpenChanged() {
            if (GlobalStates.wallpaperSelectorOpen) {
                closeAnimTimer.stop();
                root.reallyOpen = true;
            } else {
                // a cancelled lock-screen pick must not aim the next pick at the lock
                GlobalStates.wallpaperSelectorTarget = "wallpaper";
                closeAnimTimer.restart();
            }
        }
    }

    Timer {
        id: closeAnimTimer
        // the strip's Anim and the picture's fade (WallpaperStrip.qml)
        interval: Appearance.animation.elementMove.duration
        onTriggered: root.reallyOpen = false
    }

    Loader {
        id: wallpaperSelectorLoader
        active: root.reallyOpen

        // The whole screen: behind the strip it shows the picture pointed at (WallpaperStrip.qml).
        sourceComponent: PanelWindow {
            id: panelWindow
            screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell:wallpaperSelector"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: GlobalStates.wallpaperSelectorOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
            color: "transparent"
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // one frame shown as closed, so the strip rises and the picture fades in
            property bool entered: false
            Timer {
                interval: 60
                running: true
                onTriggered: panelWindow.entered = true
            }

            WallpaperStrip {
                anchors.fill: parent
                shown: panelWindow.entered && GlobalStates.wallpaperSelectorOpen
                onCloseRequested: GlobalStates.wallpaperSelectorOpen = false
            }
        }
    }

    function toggleWallpaperSelector() {
        if (Config.options.wallpaperSelector.useSystemFileDialog) {
            Wallpapers.openFallbackPicker(Appearance.m3colors.darkmode);
            return;
        }
        GlobalStates.wallpaperSelectorOpen = !GlobalStates.wallpaperSelectorOpen
    }

    IpcHandler {
        target: "wallpaperSelector"

        function toggle(): void {
            root.toggleWallpaperSelector();
        }

        function random(): void {
            Wallpapers.randomFromCurrentFolder();
        }
    }

    CompositorGlobalShortcut {
        name: "wallpaperSelectorToggle"
        description: "Toggle wallpaper selector"
        onPressed: {
            root.toggleWallpaperSelector();
        }
    }

    CompositorGlobalShortcut {
        name: "wallpaperSelectorRandom"
        description: "Select random wallpaper in current folder"
        onPressed: {
            Wallpapers.randomFromCurrentFolder();
        }
    }
}