pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.modules.common.functions
import Qt5Compat.GraphicalEffects
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris

// Standalone popup, opened only via the "equalizer" button inside the media
// popup's controls (PlayerControls.qml / PlayerControlsLyrics.qml) - there is
// no separate bar icon for it. Sized on its own terms - nothing here
// references Appearance.sizes.mediaControlsWidth.
//
// Visually styled like Player.qml's media card (blurred now-playing art, cava
// wave visualizer, border) since that's the "look" being matched, even though
// this popup isn't tied to any one player/track - it just reflects whatever
// MprisController.activePlayer currently is, same as the bar's media widget.
//
// Uses the same Loader-active pattern as modules/ii/mediaControls/MediaControls.qml:
// the PanelWindow is created/destroyed by the Loader in step with
// GlobalStates.equalizerOpen, so the popup's entrance/exit is whatever native
// map/unmap animation the compositor (Hyprland) already plays for every other
// quickshell layer-shell surface - the same "pop" you see opening media -
// rather than a hand-rolled QML slide.
Scope {
    id: root

    readonly property real popupWidth: 760
    readonly property real popupHeight: 640
    readonly property real popupRounding: Appearance.rounding.screenRounding - Appearance.sizes.hyprlandGapsOut + 1

    // No standalone "equalizer" bar entry anymore - it only opens via the
    // button inside the media popup, so position it the same way the media
    // popup itself is positioned (wherever "media" sits in the bar layout).
    readonly property string equalizerPosition: {
        if (Config.options.bar.layouts.leftLayout.includes("media")) return "left"
        if (Config.options.bar.layouts.middleLayout.includes("media")) return "center"
        if (Config.options.bar.layouts.rightLayout.includes("media")) return "right"
        return "center"
    }

    // The notch sits at the top edge and reserves this much height.
    readonly property real topReserved: Config.options.island.reservedHeight

    // Now-playing art, purely decorative here (same download-cache approach
    // Player.qml uses) - if nothing is playing this just stays blank and the
    // card falls back to a plain tinted background.
    readonly property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property var artUrl: activePlayer?.trackArtUrl ?? ""
    readonly property string artFilePath: `${Directories.coverArt}/${Qt.md5(root.artUrl)}`
    property bool artDownloaded: false
    readonly property string displayedArtFilePath: {
        if (!GlobalStates.equalizerOpen) return ""
        if (!root.artUrl || root.artUrl.length === 0) return ""
        if (!root.artDownloaded) return ""
        if (root.artUrl.startsWith("file://")) return root.artUrl
        return Qt.resolvedUrl(root.artFilePath)
    }
    readonly property color artDominantColor: ColorUtils.mix(
        (colorQuantizer?.colors[0] ?? Appearance.colors.colPrimary),
        Appearance.colors.colPrimaryContainer,
        0.8) || Appearance.m3colors.m3secondaryContainer
    readonly property QtObject blendedColors: AdaptedMaterialScheme {
        color: root.artDominantColor
    }

    onArtUrlChanged: {
        root.artDownloaded = (root.artUrl ?? "").startsWith("file://")
    }

    Process {
        id: coverArtDownloader
        property string targetFile: root.artUrl
        property string targetPath: root.artFilePath
        // This art is decoration inside the popup, so it is fetched only while the popup is up -
        // the media widget does the same download for the bar's own card.
        running: GlobalStates.equalizerOpen && !root.artDownloaded && (root.artUrl ?? "").length > 0
        command: ["bash", "-c", `[ -f ${targetPath} ] || curl -4 -sSL '${StringUtils.shellSingleQuoteEscape(targetFile)}' -o '${targetPath}'`]
        onExited: root.artDownloaded = true
    }

    ColorQuantizer {
        id: colorQuantizer
        source: root.displayedArtFilePath
        depth: 0
        rescaleSize: 1
    }

    Loader {
        id: equalizerLoader
        active: GlobalStates.equalizerOpen

        sourceComponent: PanelWindow {
            id: panelWindow
            visible: true

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            implicitWidth: root.popupWidth
            implicitHeight: root.popupHeight
            color: "transparent"
            WlrLayershell.namespace: "quickshell:equalizer"

            anchors {
                top: true
                left: true
            }
            margins {
                top: root.topReserved
                left: {
                    if (root.equalizerPosition === "left") return 0
                    if (root.equalizerPosition === "right") return panelWindow.screen.width - root.popupWidth
                    return (panelWindow.screen.width - root.popupWidth) / 2
                }
            }

            mask: Region {
                item: cardBackground
            }

            Component.onCompleted: GlobalFocusGrab.addDismissable(panelWindow)
            Component.onDestruction: GlobalFocusGrab.removeDismissable(panelWindow)
            Connections {
                target: GlobalFocusGrab
                function onDismissed() { GlobalStates.equalizerOpen = false }
            }

            StyledRectangularShadow {
                target: cardBackground
            }

            Rectangle {
                id: cardBackground
                anchors.fill: parent
                anchors.margins: Appearance.sizes.elevationMargin
                radius: root.popupRounding
                color: ColorUtils.applyAlpha(root.blendedColors.colLayer0, 1)
                border.width: 1
                border.color: ColorUtils.transparentize(root.blendedColors.colOnLayer0, 0.85)

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: cardBackground.width
                        height: cardBackground.height
                        radius: cardBackground.radius
                    }
                }

                Image {
                    id: blurredArt
                    anchors.fill: parent
                    source: root.displayedArtFilePath
                    sourceSize.width: cardBackground.width
                    sourceSize.height: cardBackground.height
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    antialiasing: true
                    asynchronous: true
                    visible: root.displayedArtFilePath.length > 0

                    layer.enabled: true
                    layer.effect: StyledBlurEffect {
                        source: blurredArt
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: ColorUtils.transparentize(root.blendedColors.colLayer0, 0.25)
                    }
                }

                WaveVisualizer {
                    anchors.fill: parent
                    live: root.activePlayer?.isPlaying ?? false
                    points: GlobalStates.visualizerPoints
                    maxVisualizerValue: 1000
                    smoothing: 2
                    color: root.blendedColors.colPrimary
                }

                EqualizerView {
                    anchors.fill: parent
                    blendedColors: root.blendedColors
                    onCloseRequested: GlobalStates.equalizerOpen = false
                }
            }
        }
    }
}
