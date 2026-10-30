pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * What the palette shows before anything is typed: the files you opened last (the desktop's
 * recently-used list, which apps write when they open a file) and the apps you started last
 * (PaletteFrecency's table), newest first.
 */
Singleton {
    id: root

    readonly property string xbelPath: `${FileUtils.trimFileProtocol(Directories.home)}/.local/share/recently-used.xbel`

    // [{ path, name, at }], newest first
    property var files: []

    function reload() {
        xbel.reload();
    }

    FileView {
        id: xbel
        path: root.xbelPath
        blockLoading: false
        watchChanges: false
        onLoaded: root.files = root.parse(xbel.text())
        onLoadFailed: root.files = []
    }

    function parse(text) {
        const out = [];
        const tags = text.match(/<bookmark\s[^>]*>/g) ?? [];
        const attr = (tag, name) => (new RegExp(`\\s${name}="([^"]*)"`).exec(tag) ?? [])[1] ?? "";
        for (const tag of tags) {
            const href = attr(tag, "href");
            if (!href.startsWith("file://"))
                continue;
            let path = "";
            try {
                path = decodeURIComponent(href.slice("file://".length).replace(/&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&"));
            } catch (e) {
                continue;
            }
            const at = Date.parse(attr(tag, "visited")) || Date.parse(attr(tag, "modified")) || Date.parse(attr(tag, "added")) || 0;
            out.push({
                "path": path,
                "name": path.split("/").pop(),
                "at": at
            });
        }
        return out.sort((a, b) => b.at - a.at);
    }

    // The last apps started from the palette or the dock: [{ id, at }], newest first
    function apps(limit) {
        const stats = PaletteFrecency.stats ?? {};
        return Object.keys(stats).filter(key => key.startsWith("app:")).map(key => ({
                    "id": key.slice(4),
                    "at": stats[key]?.last ?? 0
                })).filter(item => item.at > 0).sort((a, b) => b.at - a.at).slice(0, limit);
    }
}
