pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common

/**
 * The Dynamic Island: one top-centre layer window per screen, holding the morphing container.
 * The window itself never moves or resizes - only IslandContent does - so the reserved zone stays
 * constant and windows never jitter.
 */
Scope {
    id: island

    Variants {
        // For each monitor
        model: {
            const screens = Quickshell.screens;
            const list = Config.options.island.screenList;
            if (!list || list.length === 0)
                return screens;
            return screens.filter(screen => list.includes(screen.name));
        }

        LazyLoader {
            id: islandLoader
            active: !GlobalStates.screenLocked
            required property ShellScreen modelData

            component: PanelWindow {
                id: islandRoot
                screen: islandLoader.modelData

                WlrLayershell.namespace: "quickshell:island"
                // Keys only when opened from a key (IslandController.keyboard); None otherwise so
                // a hover never steals typing from the window under the pointer. Also only while
                // THIS screen's sheet is really open - a stale flag must not hold the seat on a
                // window showing the resting pill - and only on the screen the key was pressed
                // on, so two monitors' notches never ask for the seat at once.
                // Exclusive, and OnDemand is not an option here: this window is mapped for the
                // session (the resting pill), and Hyprland gives focus on an interactivity change
                // only to an exclusive surface (LayerSurface.cpp onCommit) - the sidebars get away
                // with OnDemand because their window maps as it opens. While it is exclusive the
                // compositor refuses keyboard focus to windows (FocusState.cpp), so a click
                // elsewhere cannot take the keyboard back: Escape at the sheet level
                // (IslandContent) and the shortcut are the ways out.
                WlrLayershell.keyboardFocus: (IslandController.keyboard && islandContent.open && islandContent.keyScreen) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
                // Hyprland buries the Top layer under a fullscreen window. boring.notch's
                // nowPlayingOnly: ride the Overlay layer while something plays in ANOTHER app, so a
                // game or a film keeps the music's transport; the fullscreen window's own player (a
                // video in the browser) is not another app, and the notch stays under it (Discord
                // 2026-10-27: the notch over YouTube in fullscreen). A maximized window is not fullscreen.
                readonly property var thisMonitorData: HyprlandData.monitors.find(m => m.name === islandRoot.screen?.name)
                readonly property var fullscreenWindow: HyprlandData.trueFullscreenWindow(thisMonitorData?.activeWorkspace?.id)
                readonly property bool overFullscreen: fullscreenWindow !== null && Config.options.island.showInFullscreenWhilePlaying
                    && IslandController.mediaPresent && MprisController.isPlaying
                    && !playsIn(fullscreenWindow, MprisController.activePlayer)
                WlrLayershell.layer: overFullscreen ? WlrLayer.Overlay : WlrLayer.Top
                // The player belongs to the window: its desktop entry or name is the window's app, or its
                // bus name carries the window's process (Chromium's and Firefox's instance names do).
                function playsIn(win, player) {
                    if (!win || !player)
                        return false;
                    const app = String(win.class || win.initialClass || "").toLowerCase();
                    const entry = String(player.desktopEntry || "").toLowerCase();
                    const name = String(player.identity || "").toLowerCase();
                    if (app && (entry === app || entry.endsWith("." + app) || (name && name.includes(app))))
                        return true;
                    return win.pid > 0 && new RegExp(`\\D${win.pid}$`).test(String(player.dbusName || ""));
                }
                color: "transparent"

                // Window-aware means honest: the reserve is exactly the resting header (34px)
                // plus a 4px breath, always. Peeks and the hover strip change width only, and
                // the clicked sheet OVERLAYS windows like a menu does - so nothing on the
                // desktop ever reflows because of the notch, and nothing moves under the pointer.
                exclusionMode: ExclusionMode.Normal
                exclusiveZone: Config.options.island.reservedHeight

                // Top-anchored only (the compositor centres it), at a FIXED size that never
                // changes: 860 x 540 since the browser's address sheet (820 wide with its shadow,
                // 2026-10-02); the other sheets keep to 440 (34 header + 150 player + 36 timer
                // row + 212 rows). Not the screen's width: the compositor blends every mapped
                // layer over every damaged pixel it overlaps. A window that resized on open/close
                // was tried and reverted: Hyprland animates a layer's size change, scaling what it
                // shows, so the notch shrank and swung aside (seen again growing it for the
                // address sheet). The mask keeps everything outside the notch click-through.
                anchors {
                    top: true
                }
                implicitWidth: 860
                implicitHeight: 540 + Config.options.island.topMargin
                mask: Region {
                    item: islandContent
                    // the sign-in's hole: the page window under it takes the pointer there
                    Region {
                        item: islandContent.holeItem
                        intersection: Intersection.Subtract
                    }
                }

                // Include in focus grab, like the bar
                Component.onCompleted: {
                    GlobalFocusGrab.addPersistent(islandRoot);
                }
                Component.onDestruction: {
                    GlobalFocusGrab.removePersistent(islandRoot);
                }

                IslandContent {
                    id: islandContent
                    screenData: islandRoot.screen
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: Config.options.island.topMargin
                }
            }
        }
    }
}
