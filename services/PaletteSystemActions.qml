pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.models.quickToggles
import qs.modules.common.functions
import QtQuick
import Quickshell

/**
 * The "System" section of the command palette.
 *
 * Every row runs the exact command the rest of the shell already uses for that
 * toggle, so behaviour stays in sync with the bar util buttons, the quick toggles
 * and the session screen.
 */
Singleton {
    id: root

    readonly property string sectionTitle: Translation.tr("System")

    // The same four toggle objects the control panel's pills are built from
    // (modules/common/models/quickToggles): the state they show and the call they make are
    // written once, so a row here and a pill there cannot drift apart. The names and the search
    // words below stay the palette's own.
    readonly property QuickToggleModel wifi: NetworkToggle {}
    readonly property QuickToggleModel bluetooth: BluetoothToggle {}
    readonly property QuickToggleModel powerProfile: PowerProfilesToggle {}

    // name / subtitle / verb / icon / keywords / run, in the order of section 5 of the brief
    readonly property var actions: [
        {
            name: Translation.tr("Wi-Fi"),
            // With no link at all the toggle's status text is empty (it has a glyph to lean on
            // and this row has not), so the radio's own state answers for it.
            subtitle: root.wifi.statusText.length > 0 ? root.wifi.statusText
                : (root.wifi.toggled ? Translation.tr("On") : Translation.tr("Off")),
            verb: Translation.tr("Toggle"),
            icon: root.wifi.icon,
            keywords: "wifi wireless network internet",
            run: () => root.wifi.mainAction()
        },
        {
            name: Translation.tr("Bluetooth"),
            subtitle: root.bluetooth.statusText,
            verb: Translation.tr("Toggle"),
            icon: root.bluetooth.icon,
            keywords: "bluetooth bt headphones",
            available: root.bluetooth.available,
            run: () => root.bluetooth.mainAction()
        },
        {
            name: Translation.tr("Power profile"),
            subtitle: root.powerProfile.statusText,
            verb: Translation.tr("Cycle"),
            icon: root.powerProfile.icon,
            keywords: "power profile battery performance saver balanced",
            run: () => root.powerProfile.mainAction()
        },
        {
            name: Translation.tr("Wallpaper"),
            subtitle: Translation.tr("Pick a new one"),
            verb: Translation.tr("Open"),
            icon: "wallpaper",
            keywords: "wallpaper background picture",
            run: () => {
                GlobalStates.wallpaperSelectorOpen = true;
            }
        },
        {
            name: Translation.tr("Screen recording"),
            subtitle: IslandController.recording ? Translation.tr("Recording now") : Translation.tr("Whole screen, an area or a window"),
            verb: IslandController.recording ? Translation.tr("Stop") : Translation.tr("Record"),
            icon: IslandController.recording ? "stop_circle" : "screen_record",
            keywords: "record recording screen video capture screencast",
            run: () => IslandController.recording ? IslandController.stopRecording() : IslandController.openRecordSoon()
        },
        {
            // The id of the desktop entry that opens the same window (session/applications/settings.desktop),
            // so the palette can show this row and that app once, not twice.
            id: "settings",
            name: Translation.tr("Settings"),
            subtitle: Translation.tr("Tacit's settings"),
            verb: Translation.tr("Go"),
            icon: "settings",
            keywords: "settings preferences config shell",
            run: () => {
                SettingsApp.open("");
            }
        },
        {
            name: Translation.tr("Lock"),
            subtitle: Translation.tr("Lock the session"),
            verb: Translation.tr("Run"),
            icon: "lock",
            keywords: "lock screen session",
            run: () => Session.lock()
        },
        {
            name: Translation.tr("Sleep"),
            subtitle: Translation.tr("Suspend now"),
            verb: Translation.tr("Run"),
            icon: "bedtime",
            keywords: "sleep suspend standby",
            run: () => Session.suspend()
        },
        {
            name: Translation.tr("Restart"),
            subtitle: Translation.tr("Reboot now"),
            verb: Translation.tr("Run"),
            icon: "restart_alt",
            keywords: "restart reboot",
            run: () => Session.reboot()
        },
        {
            name: Translation.tr("Shut down"),
            subtitle: Translation.tr("Power off now"),
            verb: Translation.tr("Run"),
            icon: "power_settings_new",
            keywords: "shutdown power off halt",
            run: () => Session.poweroff()
        },
        {
            name: Translation.tr("Restart shell"),
            subtitle: Translation.tr("Reload Quickshell"),
            verb: Translation.tr("Run"),
            icon: "refresh",
            keywords: "restart shell reload quickshell qs",
            run: () => Quickshell.reload(true)
        }
    ]

    /**
     * Name match, not fuzzy sort: these rows are a fixed short list. With an empty query the
     * whole list is returned, so an opened, untyped palette reads as a small control centre
     * with live state in the subtitles instead of an empty box.
     */
    function fuzzyQuery(search: string): var {
        const needle = (search ?? "").trim().toLowerCase();
        return root.actions.filter(action => {
            if (action.available === false)
                return false;
            if (needle.length === 0)
                return true;
            return action.name.toLowerCase().includes(needle) || action.keywords.includes(needle);
        }).map(action => resultComp.createObject(null, {
            id: action.id ?? "",
            name: action.name,
            comment: action.subtitle,
            type: root.sectionTitle,
            verb: action.verb,
            iconName: action.icon,
            iconType: LauncherSearchResult.IconType.Material,
            execute: action.run
        }));
    }

    Component {
        id: resultComp
        LauncherSearchResult {}
    }
}
