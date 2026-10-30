pragma Singleton

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Wayland

Singleton {
    id: root

    // Entry ids are lower-cased below, while the config keeps whatever the user wrote
    // ("org.kde.Dolphin"), so every comparison against the pinned list folds case.
    function isPinned(appId) {
        const target = (appId ?? "").toLowerCase();
        return (Config.options.dock.pinnedApps ?? []).some(id => id.toLowerCase() === target);
    }

    function togglePin(appId) {
        const pins = Config.options.dock.pinnedApps ?? [];
        const target = (appId ?? "").toLowerCase();
        if (root.isPinned(appId)) {
            Config.options.dock.pinnedApps = pins.filter(id => id.toLowerCase() !== target)
        } else {
            Config.options.dock.pinnedApps = pins.concat([appId])
        }
    }

    property var _entriesById: ({})
    // One program under two ids: Thyris is pinned as "thyris" (its package's entry; "browser" on a development
    // machine) while its window says "browser-cef" (the engine's id); its windows go on the pinned one rather than a
    // second Thyris
    readonly property var aliases: ({ "browser-cef": root.isPinned("thyris") ? "thyris" : "browser" })

    property list<var> apps: {
        var map = new Map();

        // Pinned apps
        const pinnedApps = Config.options?.dock.pinnedApps ?? [];
        for (const appId of pinnedApps) {
            if (!map.has(appId.toLowerCase())) map.set(appId.toLowerCase(), ({
                pinned: true,
                toplevels: []
            }));
        }

        // Separator
        if (pinnedApps.length > 0) {
            map.set("SEPARATOR", { pinned: false, toplevels: [] });
        }

        // Ignored apps
        const ignoredRegexStrings = Config.options?.dock.ignoredAppRegexes ?? [];
        const ignoredRegexes = ignoredRegexStrings.flatMap(pattern => {
            try {
                return [new RegExp(pattern, "i")];
            } catch (e) {
                return [];
            }
        });
        // Open windows
        for (const toplevel of ToplevelManager.toplevels.values) {
            if (ignoredRegexes.some(re => re.test(toplevel.appId))) continue;
            const key = root.aliases[toplevel.appId.toLowerCase()] ?? toplevel.appId.toLowerCase();
            if (!map.has(key)) map.set(key, ({
                pinned: false,
                toplevels: []
            }));
            map.get(key).toplevels.push(toplevel);
        }

        var values = [];

        // Reuse the entry object for an id instead of building a new one: the dock's delegates
        // keep their hover state and click-to-cycle position only while identity survives, and
        // this binding re-runs on every window open and close.
        for (const [key, value] of map) {
            let entry = root._entriesById[key];
            if (entry) {
                entry.toplevels = value.toplevels;
                entry.pinned = value.pinned;
            } else {
                entry = appEntryComp.createObject(root, { appId: key, toplevels: value.toplevels, pinned: value.pinned });
                root._entriesById[key] = entry;
            }
            values.push(entry);
        }
        for (const key of Object.keys(root._entriesById)) {
            if (!map.has(key)) {
                root._entriesById[key].destroy();
                delete root._entriesById[key];
            }
        }

        return values;
    }

    component TaskbarAppEntry: QtObject {
        id: wrapper
        required property string appId
        required property list<var> toplevels
        required property bool pinned
    }
    Component {
        id: appEntryComp
        TaskbarAppEntry {}
    }
}