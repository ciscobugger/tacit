import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The session menu as the control panel's question: it rises in the same bottom-right
 * corner, in the same silhouette, over a light frosted scrim. Four big choices, four small
 * ones as text, warnings only when true. Arrows and Enter, Esc or a click outside cancels.
 * The old full-screen black scrim with eight 120px squares was the stock look, not ours.
 */
Scope {
    id: root

    property string focusedScreenName: WM.compositor === "niri"
        ? (NiriBackend.focusedMonitor?.name ?? "")
        : (Hyprland.focusedMonitor?.name ?? "")

    property var focusedScreen: Quickshell.screens.find(s => s.name === root.focusedScreenName)
        ?? Quickshell.screens[0]

    Loader {
        id: sessionLoader
        active: GlobalStates.sessionOpen
        onActiveChanged: {
            if (sessionLoader.active) {
                SessionWarnings.refresh();
                // Opened from the control panel's footer: the panel hands over its corner.
                GlobalStates.sidebarRightOpen = false;
            }
        }

        Connections {
            target: GlobalStates
            function onScreenLockedChanged() {
                if (GlobalStates.screenLocked) {
                    GlobalStates.sessionOpen = false;
                }
            }
        }

        sourceComponent: PanelWindow {
            id: sessionRoot
            screen: root.focusedScreen
            visible: sessionLoader.active

            function hide() {
                GlobalStates.sessionOpen = false;
            }

            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell:session"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            // A light scrim, blurred by the layer rule: the desktop stays readable behind
            // a question about it. Not the 95% black of before.
            color: ColorUtils.transparentize(Appearance.m3colors.m3background, 0.7)

            anchors {
                top: true
                left: true
                right: true
            }

            implicitWidth: root.focusedScreen?.width ?? 0
            implicitHeight: root.focusedScreen?.height ?? 0

            // The eight actions, in reading order. The first four are the big row. `busy` is the
            // word the screen waits under, and only the twoPress four carry one: they are the
            // ones that stay on screen after the press.
            readonly property var actions: [
                { "icon": "power_settings_new", "label": Translation.tr("Shut down"), "busy": Translation.tr("Shutting down"), "run": () => Session.poweroff() },
                { "icon": "restart_alt", "label": Translation.tr("Restart"), "busy": Translation.tr("Restarting"), "run": () => Session.reboot() },
                { "icon": "dark_mode", "label": Translation.tr("Sleep"), "run": () => Session.suspend() },
                { "icon": "lock", "label": Translation.tr("Lock"), "run": () => Session.lock() },
                { "icon": "logout", "label": Translation.tr("Log out"), "busy": Translation.tr("Logging out"), "run": () => Session.logout() },
                { "icon": "downloading", "label": Translation.tr("Hibernate"), "busy": Translation.tr("Hibernating"), "run": () => Session.hibernate() },
                { "icon": "settings_applications", "label": Translation.tr("Firmware"), "run": () => Session.rebootToFirmware() },
                { "icon": "browse_activity", "label": Translation.tr("Tasks"), "run": () => Session.launchTaskManager() }
            ]
            property int focusIndex: 3 // Lock: the one that cannot hurt
            // Shut down, Restart, Log out and Hibernate take every open window with them and
            // there is no undo: they ask a second time. The other four run on the first press.
            readonly property var twoPress: [0, 1, 4, 5]
            property int armedIndex: -1
            function shown(i) {
                return i !== 5 || Session.canHibernate;
            }
            // systemctl queues the job and returns at once, so there is no exit code to wait for:
            // the session going away is the only success a power action has. The screen therefore
            // stays up under the word for it and gets out of the way only when the session dies or
            // the command comes back refused - it never delays the action itself.
            property string waitingFor: ""
            property string failedText: ""

            function activate(i) {
                const action = sessionRoot.actions[i];
                if (!action || sessionRoot.waitingFor.length > 0)
                    return;
                if (sessionRoot.twoPress.includes(i) && sessionRoot.armedIndex !== i) {
                    sessionRoot.armedIndex = i;
                    sessionRoot.focusIndex = i;
                    disarmTimer.restart();
                    return;
                }
                sessionRoot.armedIndex = -1;
                sessionRoot.failedText = "";
                if (sessionRoot.twoPress.includes(i)) {
                    sessionRoot.waitingFor = action.busy;
                    action.run();
                    return;
                }
                sessionRoot.hide();
                action.run();
            }

            Connections {
                target: Session
                function onActionFailed(label, code) {
                    sessionRoot.waitingFor = "";
                    sessionRoot.failedText = Translation.tr("%1 was refused (exit %2). Nothing happened.").arg(label).arg(code);
                }
            }

            // An armed action left alone goes back to asking.
            Timer {
                id: disarmTimer
                interval: 5000
                onTriggered: sessionRoot.armedIndex = -1
            }

            MouseArea {
                anchors.fill: parent
                onClicked: sessionRoot.hide()
            }

            Item {
                id: keys
                focus: true
                Keys.onPressed: event => {
                    const n = sessionRoot.actions.length;
                    const back = event.key === Qt.Key_Left || event.key === Qt.Key_Backtab;
                    if (event.key === Qt.Key_Escape) {
                        sessionRoot.hide();
                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
                        sessionRoot.focusIndex = (sessionRoot.focusIndex + 1) % n;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
                        sessionRoot.focusIndex = (sessionRoot.focusIndex + n - 1) % n;
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                        // Two rows of four: up and down are the same jump between them.
                        sessionRoot.focusIndex = (sessionRoot.focusIndex + 4) % n;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                        sessionRoot.activate(sessionRoot.focusIndex);
                    } else {
                        return;
                    }
                    // Hibernate is left out where it cannot work: the focus steps over it
                    if (!sessionRoot.shown(sessionRoot.focusIndex))
                        sessionRoot.focusIndex = (sessionRoot.focusIndex + (back ? n - 1 : 1)) % n;
                    event.accepted = true;
                }
            }

            // The panel: the control panel's corner, silhouette and rise.
            Item {
                id: entranceWrapper
                readonly property int cove: 12
                readonly property real contentHeight: column.implicitHeight + 2 * 20 + cove
                anchors.right: parent.right
                width: Appearance.sizes.sidebarWidth + cove
                height: contentHeight
                property real offsetScale: 1
                y: parent.height - contentHeight + contentHeight * offsetScale
                Behavior on offsetScale {
                    Anim {}
                }
                Component.onCompleted: offsetScale = 0

                // Clicks on the panel itself must not reach the scrim's MouseArea.
                MouseArea {
                    anchors.fill: parent
                }

                DockedRect {
                    anchors.fill: parent
                    edge: "bottom-right"
                    cornerRadius: Appearance.rounding.verylarge
                    fillet: entranceWrapper.cove
                    color: Appearance.colors.colPanelFrost
                }

                ColumnLayout {
                    id: column
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.leftMargin: entranceWrapper.cove + 20
                    anchors.rightMargin: 20
                    anchors.topMargin: entranceWrapper.cove + 20
                    spacing: 18

                    RowLayout {
                        Layout.fillWidth: true
                        StyledText {
                            text: Translation.tr("Session")
                            font.pixelSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colOnSurface
                        }
                        Item { Layout.fillWidth: true }
                        StyledText {
                            text: sessionRoot.waitingFor.length > 0
                                ? `${sessionRoot.waitingFor}…`
                                : Translation.tr("Esc to cancel")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                    }

                    // Four big: glyph disc, label under.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Repeater {
                            model: 4
                            delegate: Item {
                                required property int index
                                Layout.fillWidth: true
                                implicitHeight: bigColumn.implicitHeight
                                ColumnLayout {
                                    id: bigColumn
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 6
                                    BigAction {
                                        id: bigAction
                                        Layout.alignment: Qt.AlignHCenter
                                        actionIndex: index
                                    }
                                    StyledText {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: sessionRoot.armedIndex === index
                                            ? Translation.tr("Press again")
                                            : sessionRoot.actions[index].label
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: (sessionRoot.focusIndex === index || bigAction.hovered) ? Appearance.colors.colOnSurface : Appearance.colors.colSubtext
                                    }
                                }
                            }
                        }
                    }

                    // Four small: text pills in one row.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6
                        Repeater {
                            model: 4
                            delegate: SmallAction {
                                required property int index
                                Layout.fillWidth: true
                                visible: sessionRoot.shown(actionIndex)
                                actionIndex: index + 4
                            }
                        }
                    }

                    // Warnings, text only, only when true.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        visible: SessionWarnings.downloadRunning || SessionWarnings.packageManagerRunning || IslandController.workUnsaved || sessionRoot.failedText.length > 0
                        Warning {
                            visible: sessionRoot.failedText.length > 0
                            text: sessionRoot.failedText
                        }
                        Warning {
                            visible: IslandController.workUnsaved
                            text: "Uncommitted work: " + IslandController.unsavedLine
                        }
                        Warning {
                            visible: SessionWarnings.downloadRunning
                            text: Translation.tr("A download may be in progress")
                        }
                        Warning {
                            visible: SessionWarnings.packageManagerRunning
                            text: Translation.tr("The package manager is running")
                        }
                    }
                }
            }

            component BigAction: RippleButton {
                id: big
                property int actionIndex: 0
                readonly property bool current: sessionRoot.focusIndex === actionIndex
                implicitWidth: 56
                implicitHeight: 56
                padding: 0
                // One action at a time: while the session is on its way out the rest go quiet.
                enabled: sessionRoot.waitingFor.length === 0
                buttonRadius: Appearance.rounding.full
                colBackground: current ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
                colBackgroundHover: Appearance.colors.colPrimary
                colRipple: Appearance.colors.colPrimaryActive
                releaseAction: () => sessionRoot.activate(actionIndex)
                contentItem: MaterialSymbol {
                    text: sessionRoot.actions[big.actionIndex].icon
                    iconSize: 26
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    color: (big.current || big.hovered) ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSurface
                }
            }

            component SmallAction: RippleButton {
                id: small
                property int actionIndex: 0
                readonly property bool current: sessionRoot.focusIndex === actionIndex
                implicitHeight: 32
                padding: 0
                enabled: sessionRoot.waitingFor.length === 0
                buttonRadius: Appearance.rounding.full
                colBackground: current ? Appearance.colors.colLayer2 : ColorUtils.transparentize(Appearance.colors.colLayer2, 1)
                colBackgroundHover: Appearance.colors.colLayer2
                colRipple: Appearance.colors.colLayer1Active
                releaseAction: () => sessionRoot.activate(actionIndex)
                contentItem: StyledText {
                    text: sessionRoot.armedIndex === small.actionIndex
                        ? Translation.tr("Press again")
                        : sessionRoot.actions[small.actionIndex].label
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    color: (small.current || small.hovered) ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                }
            }

            component Warning: RowLayout {
                property alias text: warningText.text
                spacing: 6
                MaterialSymbol {
                    text: "warning"
                    iconSize: 16
                    color: Appearance.colors.colError
                }
                StyledText {
                    id: warningText
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colError
                }
            }
        }
    }

    IpcHandler {
        target: "session"

        function toggle(): void {
            GlobalStates.sessionOpen = !GlobalStates.sessionOpen;
        }

        function close(): void {
            GlobalStates.sessionOpen = false;
        }

        function open(): void {
            GlobalStates.sessionOpen = true;
        }
    }

    CompositorGlobalShortcut {
        name: "sessionToggle"
        description: "Toggles session screen on press"

        onPressed: {
            GlobalStates.sessionOpen = !GlobalStates.sessionOpen;
        }
    }

    CompositorGlobalShortcut {
        name: "sessionOpen"
        description: "Opens session screen on press"

        onPressed: {
            GlobalStates.sessionOpen = true;
        }
    }

    CompositorGlobalShortcut {
        name: "sessionClose"
        description: "Closes session screen on press"

        onPressed: {
            GlobalStates.sessionOpen = false;
        }
    }
}
