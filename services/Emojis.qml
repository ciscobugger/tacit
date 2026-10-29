pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Emojis.
 */
Singleton {
    id: root
    // The list lives in the session's own script. An installed system keeps it under TACIT_HYPR
    // (/usr/share/tacit/hypr): a fresh account has no ~/.config/hypr, so the picker found no file and answered
    // "No emoji for ..." to every query (2026-10-19). The person's own copy wins when there is one.
    readonly property string ownScriptPath: `${Directories.config}/hypr/hyprland/scripts/fuzzel-emoji.sh`
    readonly property string shippedScriptPath: `${Quickshell.env("TACIT_HYPR") || "/usr/share/tacit/hypr"}/hyprland/scripts/fuzzel-emoji.sh`
    property string emojiScriptPath: root.ownScriptPath
	property string lineBeforeData: "### DATA ###"
    property list<var> list
    readonly property var preparedEntries: list.map(a => ({
        name: Fuzzy.prepare(`${a}`),
        entry: a
    }))
    function fuzzyQuery(search: string): var {
        return Fuzzy.go(search, preparedEntries, {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
    }

    // Copy it, then type it into the window the person was in once the palette has closed. If typing is not
    // possible (no wtype, or no window holds the keyboard) the notice says it was copied, so the pick is never lost.
    function insert(glyph: string) {
        Quickshell.clipboardText = glyph;
        const copied = StringUtils.shellSingleQuoteEscape(Translation.tr("Copied - paste it where you want it"));
        const title = StringUtils.shellSingleQuoteEscape(Translation.tr("Emoji"));
        Quickshell.execDetached(["bash", "-c",
            `for i in $(seq 1 40); do hyprctl layers | grep -q 'quickshell:overview' || break; sleep 0.05; done; sleep 0.15; `
            + `[ -n "$(hyprctl activewindow -j | jq -r '.address // empty')" ] && wtype -- "$1" `
            + `|| notify-send '${title}' '${copied}' -a "Tacit"`, "emoji", glyph]);
    }

    function load() {
        emojiFileView.reload()
    }

    function updateEmojis(fileContent) {
        const lines = fileContent.split("\n")
        const dataIndex = lines.indexOf(root.lineBeforeData)
        if (dataIndex === -1) {
            console.warn("No data section found in emoji script file.")
            return
        }
        const emojis = lines.slice(dataIndex + 1).filter(line => line.trim() !== "")
        root.list = emojis.map(line => line.trim())
    }

    FileView {
        id: emojiFileView
        path: Qt.resolvedUrl(root.emojiScriptPath)
        onLoaded: root.updateEmojis(emojiFileView.text())
        onLoadFailed: error => {
            // an install has no ~/.config/hypr: the session's own copy under TACIT_HYPR is the emoji list there
            if (root.emojiScriptPath !== root.shippedScriptPath) {
                root.emojiScriptPath = root.shippedScriptPath
                // read once this failure has returned: a path changed inside it is dropped with the failed read, and
                // the list stayed empty on every install ("No emoji for", Discord 2026-10-23, Yugank and Hadi)
                Qt.callLater(() => emojiFileView.reload())
                return
            }
            console.warn("[Emojis] no emoji list at " + root.emojiScriptPath)
        }
    }
}
