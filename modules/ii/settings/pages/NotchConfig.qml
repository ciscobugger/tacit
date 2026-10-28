import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets

/**
 * The notch's options: what it shows at rest and on the sheet, which arrivals may peek, the
 * media rules, and the agent side (watched repos, pull requests). The twelve peek hold
 * durations under island.hold stay in config.json. Same controls as the other pages.
 */
ContentPage {
    id: page
    forceWidth: true

    // ConfigTextArea commits on Return instead of inserting a newline, so the list fields
    // below are one line and separate their entries with commas.
    function textOf(list) {
        return (list ?? []).join(", ");
    }
    function listOf(text) {
        return (text + "").split(/[,\n]/).map(l => l.trim()).filter(l => l.length > 0);
    }

    function goTo(term) {
        const t = term.toLowerCase().trim()

        function findTarget(rootItem) {
            for (let i = 0; i < rootItem.children.length; i++) {
                let child = rootItem.children[i]
                if (child.title && child.title.toLowerCase().includes(t)) {
                    return child
                }
            }

            for (let i = 0; i < rootItem.children.length; i++) {
                let found = findTarget(rootItem.children[i])
                if (found) return found
            }
            return null
        }

        let target = findTarget(page.contentItem)
        if (target) {
            let pos = target.mapToItem(page.contentItem, 0, 0)
            page.contentY = Math.max(0, pos.y)
        }
    }

    ContentSection {
        icon: "call_to_action"
        title: Translation.tr("Notch")
        shape: MaterialShape.Shape.Cookie4Sided

        GroupedList {
            ConfigSwitch {
                buttonIcon: "toggle_on"
                text: Translation.tr("Enable the notch")
                checked: Config.options.island.enable
                onSwitched: (value) => { Config.options.island.enable = value }
            }
            ConfigSwitch {
                buttonIcon: "toast"
                enabled: Config.options.island.enable
                text: Translation.tr("Hide the bar (the notch replaces it)")
                checked: Config.options.island.hideBar
                onSwitched: (value) => { Config.options.island.hideBar = value }
            }
            ConfigSwitch {
                buttonIcon: "mouse"
                text: Translation.tr("Open the sheet on hover")
                checked: Config.options.island.hoverExpand
                onSwitched: (value) => { Config.options.island.hoverExpand = value }
            }
            ConfigSwitch {
                buttonIcon: "fullscreen"
                text: Translation.tr("Stay over fullscreen windows while music plays")
                checked: Config.options.island.showInFullscreenWhilePlaying
                onSwitched: (value) => { Config.options.island.showInFullscreenWhilePlaying = value }
            }
            ConfigSpinBox {
                icon: "vertical_align_top"
                text: Translation.tr("Distance from the top edge")
                value: Config.options.island.topMargin
                from: 0
                to: 40
                stepSize: 1
                onValueChanged: { Config.options.island.topMargin = value }
            }
            ConfigSpinBox {
                icon: "height"
                text: Translation.tr("Screen height it reserves from windows")
                value: Config.options.island.reservedHeight
                from: 0
                to: 80
                stepSize: 1
                onValueChanged: { Config.options.island.reservedHeight = value }
            }
        }

        ContentSubsection {
            title: Translation.tr("Show the notch on")
            visible: Hyprland.monitors.values.length > 1

            WidgetsMonitorSelector {
                configEntry: Config.options.island
            }
        }

        ContentSubsection {
            title: Translation.tr("Greeting")
            GroupedList {
                ConfigSwitch {
                    buttonIcon: "waving_hand"
                    text: Translation.tr("Greet at startup")
                    checked: Config.options.island.greeting.enable
                    onSwitched: (value) => { Config.options.island.greeting.enable = value }
                }
                ConfigTextArea {
                    Layout.fillWidth: true
                    buttonIcon: "person"
                    text: Translation.tr("Name in the greeting")
                    placeholderText: Translation.tr("Leave empty to use your profile name")
                    value: Config.options.island.greeting.name
                    onValueChanged: { Config.options.island.greeting.name = value }
                }
            }
        }
    }

    ContentSection {
        icon: "notifications_active"
        title: Translation.tr("What may peek")
        shape: MaterialShape.Shape.Clover4Leaf

        GroupedList {
            ConfigSwitch {
                buttonIcon: "notifications"
                text: Translation.tr("Notifications")
                checked: Config.options.island.states.notification
                onSwitched: (value) => { Config.options.island.states.notification = value }
            }
            ConfigSwitch {
                buttonIcon: "volume_up"
                text: Translation.tr("Volume")
                checked: Config.options.island.states.volume
                onSwitched: (value) => { Config.options.island.states.volume = value }
            }
            ConfigSwitch {
                buttonIcon: "brightness_6"
                text: Translation.tr("Brightness")
                checked: Config.options.island.states.brightness
                onSwitched: (value) => { Config.options.island.states.brightness = value }
            }
            ConfigSwitch {
                buttonIcon: "battery_charging_full"
                text: Translation.tr("Battery and charger")
                checked: Config.options.island.states.power
                onSwitched: (value) => { Config.options.island.states.power = value }
            }
            ConfigSwitch {
                buttonIcon: "wifi"
                text: Translation.tr("Network changes")
                checked: Config.options.island.states.network
                onSwitched: (value) => { Config.options.island.states.network = value }
            }
            ConfigSwitch {
                buttonIcon: "grid_view"
                text: Translation.tr("Workspace switches")
                checked: Config.options.island.states.workspace
                onSwitched: (value) => { Config.options.island.states.workspace = value }
            }
            ConfigSwitch {
                buttonIcon: "timer"
                text: Translation.tr("Timers")
                checked: Config.options.island.states.focus
                onSwitched: (value) => { Config.options.island.states.focus = value }
            }
            ConfigSwitch {
                buttonIcon: "progress_activity"
                text: Translation.tr("Long jobs reporting over IPC")
                checked: Config.options.island.states.activity
                onSwitched: (value) => { Config.options.island.states.activity = value }
            }
            ConfigSwitch {
                buttonIcon: "download_done"
                text: Translation.tr("New downloads and screenshots")
                checked: Config.options.island.states.download
                onSwitched: (value) => { Config.options.island.states.download = value }
            }
            ConfigSpinBox {
                icon: "stacks"
                text: Translation.tr("Peeks kept waiting behind another")
                value: Config.options.island.notificationQueueDepth
                from: 0
                to: 10
                stepSize: 1
                onValueChanged: { Config.options.island.notificationQueueDepth = value }
            }
        }
    }

    ContentSection {
        icon: "music_note"
        title: Translation.tr("Music")
        shape: MaterialShape.Shape.Pill

        GroupedList {
            ConfigSwitch {
                buttonIcon: "play_circle"
                text: Translation.tr("Show the player")
                checked: Config.options.island.media.enable
                onSwitched: (value) => { Config.options.island.media.enable = value }
            }
            ConfigSwitch {
                buttonIcon: "pause_circle"
                enabled: Config.options.island.media.enable
                text: Translation.tr("Keep a paused player on the sheet")
                checked: Config.options.island.media.keepWhenPaused
                onSwitched: (value) => { Config.options.island.media.keepWhenPaused = value }
            }
            ConfigSpinBox {
                icon: "schedule"
                enabled: Config.options.island.media.keepWhenPaused
                text: Translation.tr("Minutes a paused player stays")
                value: Config.options.island.media.keepPausedMinutes
                from: 1
                to: 60
                stepSize: 1
                onValueChanged: { Config.options.island.media.keepPausedMinutes = value }
            }
            ConfigSwitch {
                buttonIcon: "graphic_eq"
                enabled: Config.options.island.media.enable
                text: Translation.tr("Waveform in the wing while playing")
                checked: Config.options.island.media.waveform
                onSwitched: (value) => { Config.options.island.media.waveform = value }
            }
        }
    }

    ContentSection {
        icon: "smart_toy"
        title: Translation.tr("Agents and work")
        shape: MaterialShape.Shape.Sunny

        GroupedList {
            ConfigTextArea {
                id: unsavedReposField
                Layout.fillWidth: true
                buttonIcon: "commit"
                text: Translation.tr("Repos watched for uncommitted work, comma separated")
                placeholderText: "~/dev/project, ~/dev/other"
                value: page.textOf(Config.options.island.unsavedRepos)
                confirmButtonVisible: true
                onConfirmClicked: {
                    const next = page.listOf(value)
                    if (page.textOf(next) !== page.textOf(Config.options.island.unsavedRepos))
                        Config.options.island.unsavedRepos = next
                }

                Connections {
                    target: unsavedReposField.textArea
                    function onActiveFocusChanged() {
                        if (!unsavedReposField.textArea.activeFocus)
                            unsavedReposField.confirmClicked()
                    }
                }
            }
            ConfigSpinBox {
                icon: "schedule"
                text: Translation.tr("Minutes before uncommitted work shows a glyph")
                value: Config.options.island.unsavedAfterMinutes
                from: 5
                to: 720
                stepSize: 5
                onValueChanged: { Config.options.island.unsavedAfterMinutes = value }
            }
            ConfigTextArea {
                id: prReposField
                Layout.fillWidth: true
                buttonIcon: "merge"
                text: Translation.tr("GitHub repos watched for pull requests (owner/name), comma separated")
                placeholderText: "owner/name, owner/other"
                value: page.textOf(Config.options.island.prRepos)
                confirmButtonVisible: true
                onConfirmClicked: {
                    const next = page.listOf(value)
                    if (page.textOf(next) !== page.textOf(Config.options.island.prRepos))
                        Config.options.island.prRepos = next
                }

                Connections {
                    target: prReposField.textArea
                    function onActiveFocusChanged() {
                        if (!prReposField.textArea.activeFocus)
                            prReposField.confirmClicked()
                    }
                }
            }
        }
    }
}
