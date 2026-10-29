pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root
    property bool visible: false
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property var realPlayers: MprisController.players
    readonly property var meaningfulPlayers: {
        const preferred = Config.options.bar.media.preferredPlayer.trim().toLowerCase()
        if (preferred.length === 0) return filterDuplicatePlayers(realPlayers)
        const filtered = realPlayers.filter(p =>
            (p.identity ?? "").toLowerCase().includes(preferred) ||
            (p.desktopEntry ?? "").toLowerCase().includes(preferred)
        )
        if (filtered.length === 0) return filterDuplicatePlayers(realPlayers)
        return filterDuplicatePlayers(filtered)
    }
    readonly property real osdWidth: Appearance.sizes.osdWidth
    readonly property real widgetWidth: Appearance.sizes.mediaControlsWidth
    readonly property real widgetHeight: Appearance.sizes.mediaControlsHeight
    property real popupRounding: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

    readonly property string mediaPosition: {
        if (Config.options.bar.layouts.leftLayout.includes("media")) return "left"
        if (Config.options.bar.layouts.middleLayout.includes("media")) return "center"
        if (Config.options.bar.layouts.rightLayout.includes("media")) return "right"
        return "center"
    }

    // The notch sits at the top edge and reserves this much height.
    readonly property real topReserved: Config.options.island.reservedHeight

    function filterDuplicatePlayers(players) {
        if (!Config.options.media.filterDuplicatePlayers)
            return players;
        let filtered = [];
        let used = new Set();

        for (let i = 0; i < players.length; ++i) {
            if (used.has(i))
                continue;
            let p1 = players[i];
            let group = [i];

            // Find duplicates by trackTitle prefix
            for (let j = i + 1; j < players.length; ++j) {
                let p2 = players[j];
                if ((p1.trackTitle && p2.trackTitle && (p1.trackTitle.includes(p2.trackTitle) || p2.trackTitle.includes(p1.trackTitle))) || (Math.abs(p1.position - p2.position) <= 2 && Math.abs(p1.length - p2.length) <= 2)) {
                    group.push(j);
                }
            }

            // Pick the one with non-empty trackArtUrl, or fallback to the first
            let chosenIdx = group.find(idx => players[idx].trackArtUrl && players[idx].trackArtUrl.length > 0);
            if (chosenIdx === undefined)
                chosenIdx = group[0];

            filtered.push(players[chosenIdx]);
            group.forEach(idx => used.add(idx));
        }
        return filtered;
    }

    Process {
        id: cavaProc
        // Exactly one cava may be alive: these terms are the complement of
        // IslandController.othersRunCava, which owns the waveform in every other case - the
        // equalizer included. (mediaLyricsVisible never existed, so its term only read true.)
        running: (GlobalStates.mediaControlsOpen ||
            Config.options.bar.layouts.leftLayout.includes("visualizer") ||
            Config.options.bar.layouts.middleLayout.includes("visualizer") ||
            Config.options.bar.layouts.rightLayout.includes("visualizer") ||
            Config.options.background.widgets.visualizer.enable)
            && MprisController.activePlayer !== null
        onRunningChanged: {
            if (!cavaProc.running) {
                GlobalStates.visualizerPoints = [];
            }
        }
        command: ["cava", "-p", `${FileUtils.trimFileProtocol(Directories.scriptPath)}/cava/raw_output_config.txt`]
        stdout: SplitParser {
            onRead: data => {
                let points = data.split(";").map(p => parseFloat(p.trim())).filter(p => !isNaN(p));
                GlobalStates.visualizerPoints = points;
            }
        }
    }

    Loader {
        id: mediaControlsLoader
        active: GlobalStates.mediaControlsOpen
        onActiveChanged: {
            if (!mediaControlsLoader.active && root.realPlayers.length === 0) {
                GlobalStates.mediaControlsOpen = false;
            }
        }

        sourceComponent: PanelWindow {
            id: panelWindow
            visible: true

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: root.widgetWidth
            implicitHeight: playerColumnLayout.implicitHeight
            color: "transparent"
            WlrLayershell.namespace: "quickshell:mediaControls"

            anchors {
                top: true
                left: true
            }
            margins {
                top: root.topReserved
                left: {
                    if (root.mediaPosition === "left") return 0
                    if (root.mediaPosition === "right") return panelWindow.screen.width - root.widgetWidth
                    return (panelWindow.screen.width - root.widgetWidth) / 2
                }
            }

            mask: Region {
                item: playerColumnLayout
            }

            Component.onCompleted: {
                if (!Config.options.bar.media.alwaysVisible)
                    GlobalFocusGrab.addDismissable(panelWindow);
            }
            Component.onDestruction: {
                if (!Config.options.bar.media.alwaysVisible)
                    GlobalFocusGrab.removeDismissable(panelWindow);
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    if (!Config.options.bar.media.alwaysVisible)
                        GlobalStates.mediaControlsOpen = false;
                }
            }

            ColumnLayout {
                id: playerColumnLayout
                anchors.fill: parent
                spacing: -Appearance.sizes.elevationMargin // Shadow overlap okay

                Repeater {
                    model: ScriptModel {
                        values: root.meaningfulPlayers
                    }
                    delegate: Player {
                        required property MprisPlayer modelData
                        player: modelData
                        visualizerPoints: GlobalStates.visualizerPoints  
                        implicitWidth: root.widgetWidth
                        implicitHeight: showLyrics ? 290 : Appearance.sizes.mediaControlsHeight
                        radius: root.popupRounding
                    }
                }

                Item {
                    // No player placeholder
                    Layout.alignment: {
                        if (panelWindow.anchors.left)
                            return Qt.AlignLeft;
                        if (panelWindow.anchors.right)
                            return Qt.AlignRight;
                        return Qt.AlignHCenter;
                    }
                    Layout.leftMargin: Appearance.sizes.hyprlandGapsOut
                    Layout.rightMargin: Appearance.sizes.hyprlandGapsOut
                    visible: root.meaningfulPlayers.length === 0
                    implicitWidth: placeholderBackground.implicitWidth + Appearance.sizes.elevationMargin
                    implicitHeight: placeholderBackground.implicitHeight + Appearance.sizes.elevationMargin

                    StyledRectangularShadow {
                        target: placeholderBackground
                    }

                    Rectangle {
                        id: placeholderBackground
                        anchors.centerIn: parent
                        color: Appearance.colors.colLayer0
                        radius: root.popupRounding
                        property real padding: 20
                        implicitWidth: placeholderLayout.implicitWidth + padding * 2
                        implicitHeight: placeholderLayout.implicitHeight + padding * 2

                        ColumnLayout {
                            id: placeholderLayout
                            anchors.centerIn: parent

                            StyledText {
                                text: Translation.tr("No active player")
                                font.pixelSize: Appearance.font.pixelSize.large
                            }
                            StyledText {
                                color: Appearance.colors.colSubtext
                                text: Translation.tr("Make sure your player has MPRIS support\nor try turning off duplicate player filtering")
                                font.pixelSize: Appearance.font.pixelSize.small
                            }
                        }
                    }
                }
            }
        }
    }

    // The island owns media day to day: the header's wings and the sheet's player are where what
    // is playing shows (modules/ii/island/states/IslandSheet.qml). So SUPER+M and `mediaControls
    // toggle/open` open the NOTCH, not this popup - one event, one surface, the way the
    // notification popup stands down for the island's notification peek. openRequested() is the
    // signal the island's own `open` IPC raises, so the notch opens exactly as SUPER+Space does.
    // The window below stays loadable: a kept bar still opens it from its media widget
    // (modules/ii/bar/Media.qml), and it is the whole surface when the notch is off.
    readonly property bool islandOwnsMedia: IslandController.ownsMedia
    // true when the request went to the notch instead of this popup
    function toNotch(): bool {
        if (!root.islandOwnsMedia)
            return false;
        IslandController.openRequested();
        return true;
    }

    IpcHandler {
        target: "mediaControls"

        // Write the same state the shortcuts do: assigning the Loader's active
        // property directly would break its binding and strand every shortcut.
        function toggle(): void {
            if (root.toNotch())
                return;
            GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
        }

        function close(): void {
            GlobalStates.mediaControlsOpen = false;
        }

        function open(): void {
            if (root.toNotch())
                return;
            GlobalStates.mediaControlsOpen = true;
        }
    }

    CompositorGlobalShortcut {
        name: "mediaControlsToggle"
        description: "Toggles media controls on press"

        onPressed: {
            if (root.toNotch())
                return;
            GlobalStates.mediaControlsOpen = !GlobalStates.mediaControlsOpen;
        }
    }
    CompositorGlobalShortcut {
        name: "mediaControlsOpen"
        description: "Opens media controls on press"

        onPressed: {
            if (root.toNotch())
                return;
            GlobalStates.mediaControlsOpen = true;
        }
    }
    CompositorGlobalShortcut {
        name: "mediaControlsClose"
        description: "Closes media controls on press"

        onPressed: {
            GlobalStates.mediaControlsOpen = false;
        }
    }
}
