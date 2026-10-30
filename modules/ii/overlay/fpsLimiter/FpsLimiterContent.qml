import qs.services
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.tacit.overlay
import qs.modules.ii.overlay

OverlayBackground {
    id: root

    enum State { Normal, Success, Error }

    property var currentState: FpsLimiterContent.State.Normal
    // Null until the check has run.
    property var hasMangoHud: null
    readonly property bool missing: root.hasMangoHud === false
    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight

    Timer {
        id: iconResetTimer
        interval: 1000
        onTriggered: {
            root.currentState = FpsLimiterContent.State.Normal;
        }
    }

    function applyLimit() {
        if (root.missing)
            return;
        var fpsValue = parseInt(fpsField.text);
        if (isNaN(fpsValue) || fpsValue < 0) {
            root.currentState = FpsLimiterContent.State.Error;
            iconResetTimer.restart();
            fpsField.text = "";
            return;
        }

        var cfgPaths = [
            "~/.config/MangoHud/MangoHud.conf",
        ]; // MangoHud config files

        var updateCommands = cfgPaths.map(path => {
            return "if grep -q '^fps_limit=' " + path + "; " +
            "then sed -i 's/^fps_limit=.*/fps_limit=" + fpsValue + "/' " + path + "; " +
            "else echo 'fps_limit=" + fpsValue + "' >> " + path + "; fi";
        }).join("; ");

        var cmd = "mkdir -p ~/.config/MangoHud; " + updateCommands + "; pkill -SIGUSR2 mangohud";

        fpsSetter.command = ["bash", "-c", cmd];
        fpsSetter.startDetached();

        root.currentState = FpsLimiterContent.State.Success;
        iconResetTimer.restart();

        // Clear the field after applying
        fpsField.text = "";
    }

    Process {
        id: fpsSetter
    }

    Process {
        id: mangoCheck
        running: true
        command: ["bash", "-c", "command -v mangohud"]
        onExited: (exitCode, exitStatus) => {
            root.hasMangoHud = exitCode === 0;
        }
    }

    ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredWidth: 200
                implicitHeight: 34
                radius: 17
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 14
                    visible: fpsField.text.length === 0
                    text: root.currentState === FpsLimiterContent.State.Error ? Translation.tr("Enter a valid number") : Translation.tr("Set FPS limit")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                }
                TextInput {
                    id: fpsField
                    anchors.fill: parent
                    anchors.leftMargin: 14
                    anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    inputMethodHints: Qt.ImhDigitsOnly
                    font.family: Appearance.font.family.main
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer0
                    selectionColor: Appearance.colors.colSecondaryContainer
                    selectedTextColor: Appearance.colors.colOnSecondaryContainer
                    clip: true
                    focus: true
                    onAccepted: root.applyLimit()
                }
            }
            OverlayRoundButton {
                size: 34
                iconSize: 20
                glyph: switch (root.currentState) {
                    case FpsLimiterContent.State.Error: return "close";
                    case FpsLimiterContent.State.Success: return "check";
                    case FpsLimiterContent.State.Normal:
                    default: return "save";
                }
                opacity: (root.currentState === FpsLimiterContent.State.Normal && fpsField.text.length > 0 && !root.missing) ? 1 : 0.4
                enabled: root.currentState === FpsLimiterContent.State.Normal && fpsField.text.length > 0 && !root.missing
                onClicked: root.applyLimit()
            }
        }
        Row {
            visible: root.missing
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: "info"
                iconSize: 16
                color: Appearance.colors.colSubtext
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Translation.tr("MangoHud is not installed")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }
    }
}
