pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.models.quickToggles
import qs.modules.tacit
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import qs.modules.ii.sidebarRight.bluetoothDevices
import qs.modules.ii.sidebarRight.vpn
import qs.modules.ii.sidebarRight.nightLight
import qs.modules.ii.sidebarRight.volumeMixer
import qs.modules.ii.sidebarRight.wifiNetworks

/**
 * The control panel, minimal. One frosted docked panel, no cards inside it:
 *
 *   toggles     one row of icon pills (wifi, bluetooth, notifications, night light, mic,
 *               caffeine) + "..." for the rest; right-click a pill with a list opens it
 *   sliders     brightness, volume - one line
 *   ─────────
 *   date · tasks   one line; opens calendar / to-do / timer in place
 *   ─────────
 *   settings                                                    session
 *
 * Cut: banner, avatar, hostname, uptime, edit mode, reload. Every function that was in the
 * old panel is still reachable; the boxes and labels around them are gone. Notifications are
 * not here: they live in the top-right corner (arrivals and centre). This panel sits in the
 * bottom-right corner and is exactly as tall as its content.
 */
Item {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    property int sidebarPadding: 14
    property bool showAudioOutputDialog: false
    property bool showAudioInputDialog: false
    property bool showBluetoothDialog: false
    property bool showNightLightDialog: false
    property bool showWifiDialog: false
    property bool showVpn: false
    // The sections are one place with three faces: opening one folds the others, so the
    // panel never stacks lists on top of each other.
    readonly property var sectionFlags: ["showWifiDialog", "showVpn", "showBluetoothDialog", "showAudioOutputDialog", "showAudioInputDialog", "showNightLightDialog"]
    function only(flag) {
        for (const f of root.sectionFlags)
            if (f !== flag && root[f])
                root[f] = false;
    }
    onShowWifiDialogChanged: if (showWifiDialog) only("showWifiDialog")
    onShowVpnChanged: if (showVpn) only("showVpn")
    onShowBluetoothDialogChanged: if (showBluetoothDialog) only("showBluetoothDialog")
    onShowAudioOutputDialogChanged: if (showAudioOutputDialog) only("showAudioOutputDialog")
    onShowAudioInputDialogChanged: if (showAudioInputDialog) only("showAudioInputDialog")
    onShowNightLightDialogChanged: if (showNightLightDialog) only("showNightLightDialog")
    property bool moreToggles: false
    // An "on" pill is raised like Settings' current row (the text colour at 12 %), not sunk: colLayer2 is
    // darker than the panel, so on used to read as a hole.
    readonly property color colPillOn: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
    readonly property color colPillOnHover: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.84)
    readonly property bool sidebarOpen: GlobalStates.sidebarRightOpen
    property var brightnessMonitor: Brightness.getMonitorForScreen(root.QsWindow.window?.screen)

    // GlobalStates.sidebarRightSection: open on that section. The content may be created by the
    // same open, so it is read on creation too.
    function takeSection() {
        const f = GlobalStates.sidebarRightSection;
        if (f === "")
            return;
        if (root.sectionFlags.includes(f))
            root[f] = true;
        GlobalStates.sidebarRightSection = "";
    }
    Component.onCompleted: root.takeSection()

    Connections {
        target: GlobalStates
        function onSidebarRightSectionChanged() {
            root.takeSection();
        }
        function onRequestBluetoothDialog() {
            if (!BluetoothStatus.available) return;
            root.showBluetoothDialog = true;
            GlobalStates.sidebarRightOpen = true;
        }
        function onSidebarRightOpenChanged() {
            if (!GlobalStates.sidebarRightOpen) {
                for (const f of root.sectionFlags)
                    root[f] = false;
                root.moreToggles = false;
            }
        }
    }

    // How tall the panel may get, from the window that holds it (SidebarRight.qml): the panel
    // is as tall as its content up to that, and scrolls what does not fit.
    property real maxHeight: 700
    implicitHeight: Math.min(column.implicitHeight + root.sidebarPadding * 2, root.maxHeight)
    implicitWidth: sidebarWidth


    // No shadow, no outline: a docked, frosted panel is one silhouette flaring into the
    // screen edge (DockedRect), separated from what is behind it by the frost alone.
    Rectangle {
        id: sidebarRightBackground

        anchors.fill: parent
        color: "transparent"
        radius: Appearance.rounding.verylarge

        DockedRect {
            id: dockedBg
            anchors.fill: parent
            edge: "bottom-right"
            cornerRadius: sidebarRightBackground.radius
            fillet: 12
            // The edge-panel frost (colPanelFrost) at 0.92 instead of 0.76. Frost sees only the wallpaper
            // (blur xray), and this panel docks on its brightest part: at 0.76 the sunset came through as rust
            // beside the notch, which sits on the dark top. Still above the blur threshold (ignore_alpha 0.64).
            color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerHigh, 0.08)
        }

        // A section open on top of the expanded date group is taller than the screen: at the
        // panel's limit the body scrolls instead of growing off the top edge, where a layer
        // surface can neither draw nor be clicked. Dragging is off while everything fits, so a
        // slider drag can never be stolen by a flick.
        StyledFlickable {
            id: body
            anchors.fill: parent
            anchors.margins: root.sidebarPadding
            contentHeight: column.implicitHeight
            interactive: contentHeight > height
            clip: true

            ColumnLayout {
                id: column
                width: body.width
                spacing: 10

                // ---------------------------------------------------------- toggles
                Flow {
                    Layout.fillWidth: true
                    spacing: 6

                    TogglePill {
                        model: NetworkToggle {}
                        dialog: "showWifiDialog"
                    }
                    TogglePill {
                        model: VpnToggle {}
                        dialog: "showVpn"
                    }
                    TogglePill {
                        model: BluetoothToggle {}
                        dialog: "showBluetoothDialog"
                    }
                    TogglePill {
                        model: NotificationToggle {}
                    }
                    TogglePill {
                        model: NightLightToggle {}
                        dialog: "showNightLightDialog"
                    }
                    TogglePill {
                        model: MicToggle {}
                        dialog: "showAudioInputDialog"
                    }
                    TogglePill {
                        model: IdleInhibitorToggle {}
                    }

                    RippleButton {
                        implicitWidth: 40
                        implicitHeight: 40
                        buttonRadius: 20
                        toggled: root.moreToggles
                        colBackgroundToggled: root.colPillOn
                        colBackgroundToggledHover: root.colPillOnHover
                        onClicked: root.moreToggles = !root.moreToggles
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: root.moreToggles ? "expand_less" : "more_horiz"
                            iconSize: 22
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: Appearance.colors.colOnLayer0
                        }
                        StyledToolTip {
                            text: Translation.tr("More")
                        }
                    }
                }

                // The rest, revealed by the dots: grows in place, no second panel.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: root.moreToggles ? moreRow.implicitHeight : 0
                    // Folded = not a layout item: at height 0 a visible item still takes the
                    // column's spacing on both sides, which doubled the gap under the pills.
                    visible: root.moreToggles || implicitHeight > 0
                    clip: true
                    opacity: root.moreToggles ? 1 : 0
                    // In-place growth: no overshoot (the panel is sized to its content).
                    Behavior on implicitHeight {
                        Anim {
                            type: Anim.Emphasized
                        }
                    }
                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }

                    Flow {
                        id: moreRow
                        width: parent.width
                        spacing: 6

                        TogglePill {
                            model: AudioToggle {}
                            dialog: "showAudioOutputDialog"
                        }
                        TogglePill {
                            model: ScreenRecordToggle {}
                        }
                        TogglePill {
                            model: ScreenSnipToggle {}
                        }
                        TogglePill {
                            model: ColorPickerToggle {}
                        }
                        TogglePill {
                            model: DarkModeToggle {}
                        }
                        TogglePill {
                            model: PowerProfilesToggle {}
                        }
                        TogglePill {
                            model: OnScreenKeyboardToggle {}
                        }
                        TogglePill {
                            model: WallpaperToggle {}
                        }
                    }
                }

                // ---------------------------------------------------------- sliders
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 14

                    LineSlider {
                        Layout.fillWidth: true
                        glyph: "brightness_6"
                        // Plain backlight, 0..100%, the same scale the notch's brightness peek shows.
                        // (Upstream folded a gamma dim into the bottom 30%, which put the backlight
                        // at 0 at the 30% mark: pitch black, and "50%" meant two different things.)
                        // Floor at 2% so the screen can never be turned off by a slider.
                        value: root.brightnessMonitor?.brightness ?? 0
                        onMoved: {
                            // A gamma dim is undone only with the backlight at zero, the one state
                            // the brightness keybinds' gamma extension can leave behind (this
                            // slider floors at 2%). Any other gamma below 100 is the Night light
                            // Gamma slider's, and resetting it here threw that setting away.
                            if (Hyprsunset.gamma !== 100 && (root.brightnessMonitor?.brightness ?? 1) < 0.01)
                                Hyprsunset.setGamma(100);
                            root.brightnessMonitor?.setBrightness(Math.max(0.02, value));
                        }
                    }
                    LineSlider {
                        Layout.fillWidth: true
                        // Muted, quiet, loud: the symbol says which (and settles in when it changes).
                        glyph: (Audio.sink?.audio?.muted ?? false) ? "volume_off"
                            : ((Audio.sink?.audio?.volume ?? 0) < 0.34 ? "volume_down" : "volume_up")
                        value: Audio.sink?.audio?.volume ?? 0
                        onMoved: {
                            if (Audio.sink?.audio)
                                Audio.sink.audio.volume = value;
                        }
                    }
                }

                // ---------------------------------------------------------- wi-fi, in place
                WifiSection {
                    shown: root.showWifiDialog
                }
                VpnSection {
                    shown: root.showVpn
                }
                BluetoothSection {
                    shown: root.showBluetoothDialog
                }
                AudioSection {
                    input: false
                    shown: root.showAudioOutputDialog
                }
                AudioSection {
                    input: true
                    shown: root.showAudioInputDialog
                }
                NightLightSection {
                    shown: root.showNightLightDialog
                }

                Hairline {}

                // ---------------------------------------------------------- date · tasks · timer
                // The line is the tab row; the open tab shows under it, in place.
                BottomWidgetGroup {
                    Layout.fillWidth: true
                }

                Hairline {}

                // ---------------------------------------------------------- footer
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    TextAction {
                        glyph: "settings"
                        label: Translation.tr("Settings")
                        onClicked: {
                            GlobalStates.sidebarRightOpen = false;
                            SettingsApp.open("");
                        }
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                    TextAction {
                        glyph: "mode_off_on"
                        label: Translation.tr("Session")
                        onClicked: GlobalStates.sessionOpen = true
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- pieces
    component Hairline: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Appearance.colors.colLayer0Border
    }

    // A round icon pill for one QuickToggleModel. Click = the toggle; right-click = its list
    // (wifi networks, devices, mixer...) when it has one. Name and state on hover.
    component TogglePill: RippleButton {
        id: pill
        required property QuickToggleModel model
        property string dialog: ""
        implicitWidth: 40
        implicitHeight: 40
        buttonRadius: 20
        toggled: pill.model.toggled
        // A pill that cannot act is dimmed, but one with a list stays clickable: that list is
        // where the reason is written (no adapter, no VPN set up), and it is the only way in.
        enabled: pill.model.available || pill.dialog.length > 0
        // Busy sits between on and unavailable: dimmer than settled, brighter than absent,
        // and still clickable (see QuickToggleModel.busy).
        opacity: !pill.model.available ? 0.4 : (pill.model.busy ? 0.6 : 1)
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        // Restraint: an "on" pill is a primary-tinted glyph on a quiet disc, not a filled
        // primary button - six of these in a row would be a wall of colour.
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        colBackgroundToggled: root.colPillOn
        colBackgroundToggledHover: root.colPillOnHover
        // A pill with a list (wifi, bluetooth, audio, mic, night light): click opens the list,
        // where the on/off switch also lives; right-click toggles directly. A plain pill toggles
        // on click. releaseAction is left-button only; `clicked` also fires for the right button.
        releaseAction: () => {
            if (pill.dialog.length > 0)
                root[pill.dialog] = !root[pill.dialog];
            else
                pill.model.mainAction();
        }
        altAction: pill.dialog.length > 0
            ? (() => { if (pill.model.available) pill.model.mainAction(); })
            : pill.model.altAction
        // Motion with a meaning: the symbol settles in as the pill is switched, the bell swings when
        // notifications come on, and Wi-Fi's arcs light up in turn while it is connecting.
        property bool ready: false
        Component.onCompleted: pill.ready = true
        onToggledChanged: {
            if (!pill.ready)
                return;
            pillMotion.settle();
            if (pill.toggled && (pill.model.icon ?? "").indexOf("notifications") === 0)
                pillMotion.swing();
        }
        readonly property bool connecting: pill.model.busy && (pill.model.icon ?? "").indexOf("wifi") >= 0
        property int connectingStep: 0
        onConnectingChanged: pill.connectingStep = 0
        Timer {
            running: pill.connecting && pill.visible
            repeat: true
            interval: 280
            onTriggered: pill.connectingStep = (pill.connectingStep + 1) % 4
        }
        SymbolMotion {
            id: pillMotion
            target: pillSymbol
        }
        contentItem: MaterialSymbol {
            id: pillSymbol
            anchors.centerIn: parent
            text: pill.connecting
                ? ["signal_wifi_0_bar", "network_wifi_1_bar", "network_wifi_2_bar", "signal_wifi_4_bar"][pill.connectingStep]
                : pill.model.icon
            fill: pill.toggled ? 1 : 0
            iconSize: 22
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: pill.toggled ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
        }
        StyledToolTip {
            text: (pill.model.hasStatusText && (pill.model.statusText ?? "").length > 0
                ? `${pill.model.name} · ${pill.model.statusText}`
                : pill.model.name) + (pill.dialog.length > 0 ? Translation.tr("\nRight-click to turn on/off") : "")
        }
    }

    // One-line slider with its glyph on the left; the number is the slider's own (no tooltip
    // popup: it would close the panel).
    component LineSlider: RowLayout {
        id: line
        property string glyph: "tune"
        property alias value: slider.value
        signal moved()
        spacing: 8

        property bool ready: false
        Component.onCompleted: line.ready = true
        onGlyphChanged: if (line.ready) lineMotion.settle()
        SymbolMotion {
            id: lineMotion
            target: lineSymbol
        }
        MaterialSymbol {
            id: lineSymbol
            text: line.glyph
            iconSize: 20
            color: Appearance.colors.colOnLayer0
        }
        TacitSlider {
            id: slider
            Layout.fillWidth: true
            onMoved: line.moved()
        }
    }

    component TextAction: RippleButton {
        id: taction
        property string glyph: ""
        property string label: ""
        implicitWidth: tactionRow.implicitWidth + 20
        implicitHeight: 32
        buttonRadius: 16
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        contentItem: Row {
            id: tactionRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: taction.glyph
                iconSize: 18
                color: Appearance.colors.colSubtext
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: taction.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
        }
    }
}
