pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Pipewire

/**
 * Audio output or input, unfolded inside the quick panel like Wi-Fi: flat rows, hairlines,
 * one motion. Devices first (a click makes one the default; the default carries a check),
 * then the apps on it, each with its own level and a mute on its icon. The panel's top
 * slider is the master; this is where you pick what plays and what each app gets.
 */
Item {
    id: root
    property bool shown: false
    required property bool input
    readonly property int rowHeight: 40
    readonly property int maxRows: 6
    readonly property list<var> devices: root.input ? Audio.inputDevices : Audio.outputDevices
    // Apps only: PipeWire's own filter streams (the tuned-speakers chain, the echo canceller)
    // are streams too but carry no application name, and they are not something to mix.
    readonly property list<var> apps: (root.input ? Audio.inputAppNodes : Audio.outputAppNodes).filter(n => ((n?.properties?.["application.name"] ?? "") + "").length > 0)
    readonly property var current: root.input ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink

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

    // An app's name and icon are readable only on a bound node, and the list below needs the name to
    // show the app at all, so every node is bound while the section is shown.
    PwObjectTracker {
        objects: root.shown ? Pipewire.nodes.values : []
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
                text: root.input ? Translation.tr("Input") : Translation.tr("Output")
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colSubtext
            }
            Item {
                Layout.fillWidth: true
            }
            StyledText {
                text: (root.current?.audio?.muted ?? false) ? Translation.tr("Muted") : ""
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            StyledSwitch {
                readonly property bool live: !(root.current?.audio?.muted ?? true)
                // With no device there is nothing to mute, and the toggle would throw.
                enabled: (root.current?.audio ?? null) !== null
                checked: live
                onClicked: {
                    if (root.input)
                        Audio.toggleMicMute();
                    else
                        Audio.toggleMute();
                    checked = Qt.binding(() => live);
                }
            }
        }
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Appearance.colors.colLayer0Border
        }

        // Capped and scrolling, like the Wi-Fi and Bluetooth lists: devices plus every app
        // playing is unbounded, and the panel cannot grow past the screen.
        StyledFlickable {
            id: list
            Layout.fillWidth: true
            implicitHeight: Math.min(rows.implicitHeight, root.maxRows * root.rowHeight + 8)
            contentHeight: rows.implicitHeight
            clip: true

            Column {
                id: rows
                width: list.width
                // ------------------------------------------------------ devices
                Repeater {
                    model: ScriptModel {
                        values: root.devices
                    }
                    delegate: RippleButton {
                        id: dev
                        required property var modelData
                        readonly property bool isDefault: dev.modelData?.id === root.current?.id
                        width: rows.width
                        implicitHeight: root.rowHeight
                        buttonRadius: Appearance.rounding.small
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        colRipple: Appearance.colors.colLayer1Active
                        onClicked: root.input ? Audio.setDefaultSource(dev.modelData) : Audio.setDefaultSink(dev.modelData)
                        contentItem: RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10
                            MaterialSymbol {
                                text: root.input ? "mic" : "speaker"
                                iconSize: 20
                                color: dev.isDefault ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: Audio.friendlyDeviceName(dev.modelData)
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.font.pixelSize.small
                                color: Appearance.colors.colOnLayer0
                            }
                            MaterialSymbol {
                                visible: dev.isDefault
                                text: "check"
                                iconSize: 18
                                color: Appearance.colors.colPrimary
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
                StyledText {
                    width: rows.width
                    height: root.rowHeight
                    visible: root.devices.length === 0
                    verticalAlignment: Text.AlignVCenter
                    leftPadding: 10
                    text: root.input ? Translation.tr("No input device") : Translation.tr("No output device")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                }

                // ------------------------------------------------------ apps
                Item {
                    width: rows.width
                    height: 30
                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.apps.length === 0
                            ? (root.input ? Translation.tr("Nothing is listening") : Translation.tr("Nothing is playing"))
                            : (root.input ? Translation.tr("Listening") : Translation.tr("Playing"))
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                }
                Repeater {
                    model: ScriptModel {
                        values: root.apps
                    }
                    delegate: AppRow {
                        required property var modelData
                        node: modelData
                        width: rows.width
                        rowHeight: root.rowHeight
                    }
                }
            }
        }
    }

    // One app: its icon (click mutes it), its name, its own level.
    component AppRow: Item {
        id: app
        required property PwNode node
        property int rowHeight: 40
        implicitHeight: app.rowHeight
        PwObjectTracker {
            objects: [app.node]
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 10
            RippleButton {
                implicitWidth: 28
                implicitHeight: 28
                buttonRadius: 14
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer1Hover
                onClicked: app.node.audio.muted = !app.node.audio.muted
                StyledToolTip {
                    text: (app.node?.audio?.muted ?? false) ? Translation.tr("Unmute") : Translation.tr("Mute")
                }
                contentItem: Item {
                    anchors.fill: parent
                    IconImage {
                        anchors.centerIn: parent
                        implicitSize: 20
                        opacity: (app.node?.audio?.muted ?? false) ? 0.35 : 1
                        source: {
                            let icon = AppSearch.guessIcon(app.node?.properties["application.icon-name"] ?? "");
                            if (!AppSearch.iconExists(icon))
                                icon = AppSearch.guessIcon(app.node?.properties["node.name"] ?? "");
                            return Quickshell.iconPath(icon, "image-missing");
                        }
                    }
                    MaterialSymbol {
                        anchors.centerIn: parent
                        visible: app.node?.audio?.muted ?? false
                        text: root.input ? "mic_off" : "volume_off"
                        iconSize: 16
                        color: Appearance.colors.colOnLayer0
                    }
                }
            }
            StyledText {
                Layout.fillWidth: true
                text: Audio.appNodeDisplayName(app.node)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.small
                color: Appearance.colors.colOnLayer0
                opacity: (app.node?.audio?.muted ?? false) ? 0.5 : 1
            }
            TacitSlider {
                id: level
                Layout.preferredWidth: 140
                showNumber: false
                from: 0
                to: 1
                value: app.node?.audio?.volume ?? 0
                onMoved: app.node.audio.volume = value
            }
            StyledText {
                Layout.preferredWidth: 34
                horizontalAlignment: Text.AlignRight
                text: `${Math.round((app.node?.audio?.volume ?? 0) * 100)}%`
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
