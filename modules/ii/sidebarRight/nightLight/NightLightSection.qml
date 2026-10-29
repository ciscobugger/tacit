import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * Night light, unfolded inside the quick panel: the switch in the header, then one line
 * each for automatic, warmth, gamma, and the two anti-flashbang helpers. Brightness is not
 * here: the panel's top slider already is it.
 */
Item {
    id: root
    property bool shown: false
    readonly property int rowHeight: 36
    // hyprsunset is driven by fire-and-forget hyprctl calls, so the switch cannot know the
    // screen changed until the state is read back. Until then it says what it asked for.
    property bool pending: false
    property bool pendingOn: false

    onShownChanged: if (root.shown) Hyprsunset.fetchState()
    Timer {
        id: settleTimer
        interval: 400
        onTriggered: {
            root.pending = false;
            Hyprsunset.fetchState();
        }
    }

    Layout.fillWidth: true
    implicitHeight: root.shown ? body.implicitHeight : 0
    clip: true
    opacity: root.shown ? 1 : 0
    visible: root.shown || root.implicitHeight > 0
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

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 36
            spacing: 6
            StyledText {
                text: Translation.tr("Night light")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            Item {
                Layout.fillWidth: true
            }
            StyledText {
                visible: root.pending
                text: root.pendingOn ? Translation.tr("Turning on") : Translation.tr("Turning off")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            StyledSwitch {
                checked: Hyprsunset.temperatureActive
                onClicked: {
                    root.pendingOn = !Hyprsunset.temperatureActive;
                    root.pending = true;
                    settleTimer.restart();
                    Hyprsunset.toggleTemperature(!Hyprsunset.temperatureActive);
                    checked = Qt.binding(() => Hyprsunset.temperatureActive);
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Appearance.colors.colLayer0Border
        }

        SwitchLine {
            glyph: "night_sight_auto"
            label: Translation.tr("Automatic, by the time of day")
            checked: Config.options.light.night.automatic
            onToggled: Config.options.light.night.automatic = !Config.options.light.night.automatic
        }
        SliderLine {
            glyph: "thermostat"
            label: Translation.tr("Warmth")
            from: 6500
            to: 1200
            value: Config.options.light.night.colorTemperature
            valueText: `${Math.round(Config.options.light.night.colorTemperature)} K`
            onMoved: v => Config.options.light.night.colorTemperature = v
        }
        SliderLine {
            glyph: "contrast"
            label: Translation.tr("Gamma")
            from: Hyprsunset.gammaLowerLimit / 100
            to: 1
            value: Hyprsunset.gamma / 100
            valueText: `${Math.round(Hyprsunset.gamma)}%`
            onMoved: v => Hyprsunset.setGamma(v * 100)
        }
        SwitchLine {
            glyph: "filter"
            label: Translation.tr("Dim bright content")
            detail: Translation.tr("a screen shader; costs GPU, bends colours")
            checked: HyprlandAntiFlashbangShader.enabled
            onToggled: {
                if (HyprlandAntiFlashbangShader.enabled)
                    HyprlandAntiFlashbangShader.disable();
                else
                    HyprlandAntiFlashbangShader.enable();
            }
        }
        SwitchLine {
            glyph: "light_mode"
            label: Translation.tr("Dim by backlight")
            detail: Translation.tr("keeps colours; a step behind")
            checked: Config.options.light.antiFlashbang.enable
            onToggled: Config.options.light.antiFlashbang.enable = !Config.options.light.antiFlashbang.enable
            last: true
        }
    }

    component SwitchLine: Item {
        id: sw
        property string glyph: ""
        property string label: ""
        property string detail: ""
        property bool checked: false
        property bool last: false
        signal toggled()
        Layout.fillWidth: true
        implicitHeight: root.rowHeight
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10
            MaterialSymbol {
                text: sw.glyph
                iconSize: 20
                color: sw.checked ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
            }
            StyledText {
                text: sw.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.fillWidth: true
                text: sw.detail
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            StyledSwitch {
                checked: sw.checked
                onClicked: {
                    sw.toggled();
                    checked = Qt.binding(() => sw.checked);
                }
            }
        }
        Rectangle {
            visible: !sw.last
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            height: 1
            color: Appearance.colors.colLayer0Border
        }
    }

    component SliderLine: Item {
        id: sl
        property string glyph: ""
        property string label: ""
        property real from: 0
        property real to: 1
        property real value: 0
        property string valueText: ""
        signal moved(real v)
        Layout.fillWidth: true
        implicitHeight: root.rowHeight
        // Every apply is a process (gamma shells out to hyprctl) or a config write, and one per
        // drag frame stuttered the shell: the first step lands at once, the rest at ~12 Hz, and
        // the released value always lands.
        Timer {
            id: applyThrottle
            interval: 80
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10
            MaterialSymbol {
                text: sl.glyph
                iconSize: 20
                color: Appearance.colors.colOnLayer0
            }
            StyledText {
                Layout.preferredWidth: 60
                text: sl.label
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
            }
            TacitSlider {
                Layout.fillWidth: true
                showNumber: false
                from: sl.from
                to: sl.to
                value: sl.value
                onMoved: {
                    if (applyThrottle.running)
                        return;
                    sl.moved(value);
                    applyThrottle.restart();
                }
                onPressedChanged: if (!pressed) {
                    applyThrottle.stop();
                    sl.moved(value);
                }
            }
            StyledText {
                Layout.preferredWidth: 44
                horizontalAlignment: Text.AlignRight
                text: sl.valueText
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            height: 1
            color: Appearance.colors.colLayer0Border
        }
    }
}
