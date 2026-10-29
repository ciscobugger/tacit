pragma ComponentBehavior: Bound
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell.Io

// A 10-band live equalizer, ported from ilyaMiro's Serpantinum MusicPopup
// equalizer. Originally embedded in Player.qml's controls/lyrics view-swap,
// now a standalone bar widget + popup (see modules/ii/bar/Equalizer.qml and
// EqualizerPopup.qml) so its width isn't tied to the media popup at all.
// Talks to EasyEffects through scripts/eq/equalizer.sh.
Item {
    id: root

    // Passed in by EqualizerPopup.qml - a scheme tinted off the currently
    // playing track's art (or plain Appearance.colors as a standalone fallback)
    // so this matches the media popup's look-and-feel.
    property QtObject blendedColors: Appearance.colors
    signal closeRequested()

    // b1..b10 gains in dB, mirrors eq_state.json written by equalizer.sh
    property var bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    property string presetName: "Flat"
    property bool pending: false
    // equalizer.sh prints one line on stderr for a missing jq, a missing EasyEffects and a band
    // it will not take. Detached, all three were thrown away, so a slider moved with nothing
    // behind it. EasyEffects itself is asked for separately: with none installed every apply
    // writes a preset that nothing ever loads.
    property string lastError: ""
    readonly property string statusMessage: root.lastError !== "" ? root.lastError
        : !EasyEffects.available ? Translation.tr("EasyEffects is not installed, so nothing is applied")
        : ""
    readonly property var bandLabels: ["32", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    readonly property real bandRange: 12 // -12dB .. +12dB, matches equalizer.sh clamp expectations

    // Mirrors equalizer.sh's save_preset() calls exactly, so tapping a
    // preset chip moves the sliders immediately instead of waiting on a
    // shell round-trip to read the state file back.
    readonly property var presetValues: ({
        "Flat":    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "Bass":    [5, 7, 5, 2, 1, 0, 0, 0, 1, 2],
        "Treble":  [-2, -1, 0, 1, 2, 3, 4, 5, 6, 6],
        "Vocal":   [-2, -1, 1, 3, 5, 5, 4, 2, 1, 0],
        "Pop":     [2, 4, 2, 0, 1, 2, 4, 2, 1, 2],
        "Rock":    [5, 4, 2, -1, -2, -1, 2, 4, 5, 6],
        "Jazz":    [3, 3, 1, 1, 1, 1, 2, 1, 2, 3],
        "Classic": [0, 1, 2, 2, 2, 2, 1, 2, 3, 4]
    })
    readonly property var presetIcons: ({
        "Flat": "horizontal_rule", "Bass": "graphic_eq", "Treble": "trending_up",
        "Vocal": "mic", "Pop": "star", "Rock": "bolt", "Jazz": "piano", "Classic": "music_note"
    })

    function refresh() {
        eqGetProc.running = false
        eqGetProc.running = true
    }

    function setBand(index, value) {
        root.bands[index] = value
        root.bandsChanged()
        root.presetName = "Custom"
        root.pending = true
        root.runEq(["set_band", String(index + 1), String(Math.round(value))])
    }

    function applyPending() {
        root.runEq(["apply"])
        root.pending = false
    }

    function applyPreset(name) {
        // Update sliders instantly from the known preset values...
        const vals = root.presetValues[name]
        if (vals) root.bands = vals.slice()
        root.presetName = name
        root.pending = false
        // ...while the backend writes + loads the matching EasyEffects preset.
        root.runEq(["preset", name])
    }

    // One Process per request: a slider drag writes a band per step, and reusing a single
    // Process would kill the previous write halfway through.
    function runEq(args) {
        const proc = eqProcComponent.createObject(root, {
            "command": ["bash", Directories.eqScriptPath, Directories.eqStateDir].concat(args)
        })
        proc.running = true
    }

    Component {
        id: eqProcComponent
        Process {
            id: proc
            stderr: StdioCollector { id: eqErrCollector }
            onExited: (exitCode, exitStatus) => {
                if (exitCode === 0) {
                    root.lastError = ""
                } else {
                    const said = eqErrCollector.text.trim().split("\n").pop().replace(/^equalizer\.sh: /, "")
                    root.lastError = said.length > 0 ? said : Translation.tr("The equalizer backend failed")
                }
                proc.destroy()
            }
        }
    }

    Component.onCompleted: root.refresh()

    Process {
        id: eqGetProc
        command: ["bash", Directories.eqScriptPath, Directories.eqStateDir, "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text)
                    root.bands = [
                        Number(data.b1), Number(data.b2), Number(data.b3), Number(data.b4), Number(data.b5),
                        Number(data.b6), Number(data.b7), Number(data.b8), Number(data.b9), Number(data.b10)
                    ]
                    root.presetName = data.preset ?? "Custom"
                    root.pending = !!data.pending
                } catch (e) {
                    // Leave previous values if the state file isn't ready yet
                }
            }
        }
    }

    component SectionCard: Rectangle {
        radius: Appearance.rounding.large
        color: ColorUtils.transparentize(root.blendedColors.colLayer1, 0.35)
    }

    component SectionHeader: StyledText {
        font.pixelSize: Appearance.font.pixelSize.small
        font.bold: true
        color: root.blendedColors.colSubtext
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 16

        // Header: icon, title/preset, close
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Rectangle {
                implicitWidth: 46
                implicitHeight: 46
                radius: Appearance.rounding.normal
                color: ColorUtils.transparentize(root.blendedColors.colPrimary, 0.85)

                MaterialSymbol {
                    anchors.centerIn: parent
                    iconSize: Appearance.font.pixelSize.huge
                    fill: 1
                    text: "equalizer"
                    color: root.blendedColors.colPrimary
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.title
                    font.bold: true
                    color: root.blendedColors.colOnLayer0
                    elide: Text.ElideRight
                    text: Translation.tr("Equalizer")
                }
                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: root.blendedColors.colSubtext
                    elide: Text.ElideRight
                    text: `${Translation.tr("Preset")}: ${root.presetName}`
                }
            }

            RippleButton {
                implicitWidth: 36
                implicitHeight: 36
                buttonRadius: Appearance.rounding.full
                colBackground: ColorUtils.transparentize(root.blendedColors.colSecondaryContainer, 1)
                colBackgroundHover: root.blendedColors.colSecondaryContainerHover
                colRipple: root.blendedColors.colSecondaryContainerActive
                downAction: () => root.closeRequested()
                contentItem: MaterialSymbol {
                    iconSize: Appearance.font.pixelSize.huge
                    fill: 1
                    horizontalAlignment: Text.AlignHCenter
                    color: root.blendedColors.colOnSecondaryContainer
                    text: "close"
                }
            }
        }

        // blendedColors carries no error tone, so this one line reads from the palette.
        StyledText {
            Layout.fillWidth: true
            visible: root.statusMessage !== ""
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colError
            wrapMode: Text.WordWrap
            text: root.statusMessage
        }

        // Bands card
        SectionCard {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 320

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                SectionHeader {
                    text: Translation.tr("Bands")
                }

                RowLayout {
                    id: bandRow
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    Repeater {
                        model: root.bandLabels.length

                        delegate: ColumnLayout {
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredWidth: 0
                            Layout.fillHeight: true
                            spacing: 6

                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                font.features: { "tnum": 1 }
                                color: root.blendedColors.colSubtext
                                text: `${Math.round(root.bands[index] ?? 0) > 0 ? "+" : ""}${Math.round(root.bands[index] ?? 0)}`
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                // 0dB reference line
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width * 0.5
                                    height: 1
                                    color: ColorUtils.transparentize(root.blendedColors.colSubtext, 0.7)
                                }

                                StyledSlider {
                                    id: bandSlider
                                    anchors.centerIn: parent
                                    width: parent.height - 4
                                    height: parent.width
                                    rotation: -90
                                    configuration: StyledSlider.Configuration.M
                                    from: -root.bandRange
                                    to: root.bandRange
                                    value: root.bands[index] ?? 0
                                    highlightColor: root.blendedColors.colPrimary
                                    trackColor: root.blendedColors.colSecondaryContainer
                                    handleColor: root.blendedColors.colPrimary
                                    usePercentTooltip: false
                                    tooltipContent: `${Math.round(value) > 0 ? "+" : ""}${Math.round(value)} dB`
                                    onMoved: root.setBand(index, value)

                                    Behavior on value {
                                        enabled: !bandSlider.pressed
                                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                                    }
                                }
                            }

                            StyledText {
                                Layout.alignment: Qt.AlignHCenter
                                font.pixelSize: Appearance.font.pixelSize.smallest
                                color: root.blendedColors.colSubtext
                                text: root.bandLabels[index]
                            }
                        }
                    }
                }
            }
        }

        // Presets card
        SectionCard {
            Layout.fillWidth: true
            implicitHeight: presetsColumn.implicitHeight + 32

            ColumnLayout {
                id: presetsColumn
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                SectionHeader {
                    text: Translation.tr("Presets")
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 4
                    columnSpacing: 10
                    rowSpacing: 10

                    Repeater {
                        model: Object.keys(root.presetValues)

                        delegate: GroupButton {
                            id: presetBtn
                            required property string modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            buttonText: Translation.tr(modelData)
                            toggled: root.presetName === modelData
                            downAction: () => root.applyPreset(modelData)
                            // contentItem is stretched to the button's full (grid-cell)
                            // width by QQC2, so the icon+label pair is centered inside
                            // an Item rather than left-packed by a bare RowLayout.
                            contentItem: Item {
                                implicitWidth: presetBtnContent.implicitWidth
                                implicitHeight: presetBtnContent.implicitHeight
                                RowLayout {
                                    id: presetBtnContent
                                    anchors.centerIn: parent
                                    spacing: 6
                                    MaterialSymbol {
                                        iconSize: Appearance.font.pixelSize.large
                                        fill: 0
                                        text: root.presetIcons[presetBtn.modelData] ?? "tune"
                                        color: presetBtn.toggled ? root.blendedColors.colOnPrimary : root.blendedColors.colOnLayer1
                                    }
                                    StyledText {
                                        text: presetBtn.buttonText
                                        color: presetBtn.toggled ? root.blendedColors.colOnPrimary : root.blendedColors.colOnLayer1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Bottom actions
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            DialogButton {
                buttonText: Translation.tr("Reset")
                downAction: () => root.applyPreset("Flat")
            }

            Item { Layout.fillWidth: true }

            DialogButton {
                buttonText: root.pending ? Translation.tr("Apply") : Translation.tr("Applied")
                enabled: root.pending
                colEnabled: root.blendedColors.colPrimary
                downAction: () => root.applyPending()
            }
        }
    }
}
