pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    // property string cliphistBinary: FileUtils.trimFileProtocol(`${Directories.home}/.cargo/bin/stash`)
    property string cliphistBinary: "cliphist"
    property real pasteDelay: 0.15
    property string pressPasteCommand: "ydotool key -d 1 29:1 47:1 47:0 29:0"
    // The only surface that asks for a synthetic paste is the launcher; it keeps the keyboard for a
    // moment after it closes, and a paste that lands there is lost.
    readonly property string launcherLayerNamespace: "quickshell:overview"
    property bool sloppySearch: Config.options?.search.sloppy ?? false
    property real scoreThreshold: 0.2
    property list<string> entries: []

    // Preparing every entry is the expensive half of a refresh, so it waits for a query instead
    // of running on each clipboard change.
    property var preparedEntriesCache: null
    onEntriesChanged: root.preparedEntriesCache = null
    function preparedEntries(): var {
        if (root.preparedEntriesCache === null) {
            root.preparedEntriesCache = root.entries.map(a => ({
                name: Fuzzy.prepare(`${a.replace(/^\s*\S+\s+/, "")}`),
                entry: a
            }));
        }
        return root.preparedEntriesCache;
    }

    function fuzzyQuery(search: string): var {
        if (search.trim() === "") {
            return entries;
        }
        if (root.sloppySearch) {
            const results = entries.slice(0, 100).map(str => ({
                entry: str,
                score: Levendist.computeTextMatchScore(str.toLowerCase(), search.toLowerCase())
            })).filter(item => item.score > root.scoreThreshold)
                .sort((a, b) => b.score - a.score)
            return results.map(item => item.entry)
        }

        return Fuzzy.go(search, root.preparedEntries(), {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
    }

    function entryIsImage(entry) {
        return !!(/^\d+\t\[\[.*binary data.*\d+x\d+.*\]\]$/.test(entry))
    }

    property bool refreshPending: false
    function refresh() {
        if (readProc.running) {
            // Re-starting a running Process spawns a second `cliphist list` whose lines land in the
            // same buffer, and the buffer clear throws away what the first one had read.
            root.refreshPending = true;
            return;
        }
        readProc.buffer = []
        readProc.running = true
    }

    function copy(entry) {
        if (root.cliphistBinary.includes("cliphist")) // Classic cliphist
            Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`]);
        else { // Stash
            const entryNumber = entry.split("\t")[0];
            Quickshell.execDetached(["bash", "-c", `${root.cliphistBinary} decode ${entryNumber} | wl-copy`]);
        }
    }

    // ydotool types into whatever holds the keyboard. Every synthetic paste waits for the launcher
    // surface to unmap, then refuses to type unless the window that asked for it is still the
    // focused one - keystrokes in the wrong window are worse than no paste at all.
    function pasteFocusGuard(): string {
        const stopped = StringUtils.shellSingleQuoteEscape(Translation.tr("The window that asked for it is not focused any more"));
        const stoppedTitle = StringUtils.shellSingleQuoteEscape(Translation.tr("Paste stopped"));
        const failedTitle = StringUtils.shellSingleQuoteEscape(Translation.tr("Paste failed"));
        const noYdotool = StringUtils.shellSingleQuoteEscape(Translation.tr("ydotool is not installed"));
        return `target=$(hyprctl activewindow -j | jq -r '.address // empty'); `
            + `for i in $(seq 1 40); do hyprctl layers | grep -q '${root.launcherLayerNamespace}' || break; sleep 0.05; done; `
            + `sleep ${root.pasteDelay}; `
            + `focused=$(hyprctl activewindow -j | jq -r '.address // empty'); `
            // A focused layer surface can leave hyprctl with no active window, so an empty reading
            // before the wait is not treated as the target - an empty one after it still aborts.
            + `if [ -z "$focused" ] || { [ -n "$target" ] && [ "$focused" != "$target" ]; }; then `
            + `notify-send '${stoppedTitle}' '${stopped}' -a "Tacit"; exit 1; fi; `
            + `command -v ydotool >/dev/null || { notify-send '${failedTitle}' '${noYdotool}' -a "Tacit"; exit 1; }; `
    }

    function pasteFailureReport(): string {
        return ` || notify-send '${StringUtils.shellSingleQuoteEscape(Translation.tr("Paste failed"))}' `
            + `'${StringUtils.shellSingleQuoteEscape(Translation.tr("Could not type into the focused window"))}' -a "Tacit"`
    }

    function paste(entry) {
        const decodeAndCopy = root.cliphistBinary.includes("cliphist") // Classic cliphist
            ? `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy`
            : `${root.cliphistBinary} decode ${entry.split("\t")[0]} | wl-copy`;
        Quickshell.execDetached(["bash", "-c", root.pasteFocusGuard()
            + `${decodeAndCopy} && sleep ${root.pasteDelay} && ${root.pressPasteCommand}` + root.pasteFailureReport()]);
    }

    function superpaste(count, isImage = false) {
        // Find entries
        const targetEntries = entries.filter(entry => {
            if (!isImage) return true;
            return entryIsImage(entry);
        }).slice(0, count)
        if (targetEntries.length === 0) {
            Quickshell.execDetached(["notify-send", Translation.tr("Superpaste"), Translation.tr("No matching clipboard entries"), "-a", "Tacit"]);
            return;
        }
        const pasteCommands = [...targetEntries].reverse().map(entry => `printf '%s' '${StringUtils.shellSingleQuoteEscape(entry)}' | ${root.cliphistBinary} decode | wl-copy && sleep ${root.pasteDelay} && ${root.pressPasteCommand}`)
        // Act
        Quickshell.execDetached(["bash", "-c", root.pasteFocusGuard()
            + pasteCommands.join(` && sleep ${root.pasteDelay} && `) + root.pasteFailureReport()]);
    }

    Process {
        id: deleteProc
        property var queue: []
        property string entry: ""
        command: ["bash", "-c", `echo '${StringUtils.shellSingleQuoteEscape(deleteProc.entry)}' | ${root.cliphistBinary} delete`]
        function deleteNext() {
            if (deleteProc.queue.length === 0) return;
            deleteProc.entry = deleteProc.queue.shift();
            deleteProc.running = true;
        }
        onExited: (exitCode, exitStatus) => {
            root.refresh();
            deleteProc.deleteNext();
        }
    }

    function deleteEntry(entry) {
        // One delete at a time: a start while the Process is running is deferred, and the deferred
        // start picks up whatever `entry` holds by then - which used to be "".
        deleteProc.queue.push(entry);
        if (!deleteProc.running) deleteProc.deleteNext();
    }

    Process {
        id: wipeProc
        command: ["bash", "-c", `${root.cliphistBinary} wipe; rm -rf ~/.cache/cliphist/db`]
        onExited: (exitCode, exitStatus) => {
            root.entries = [];
            root.refresh();
        }
    }

    function wipe() {
        root.entries = [];
        wipeProc.running = true;
    }

    Connections {
        target: Quickshell
        function onClipboardTextChanged() {
            delayedUpdateTimer.restart()
        }
    }

    Timer {
        id: delayedUpdateTimer
        interval: Config.options.hacks.arbitraryRaceConditionDelay
        repeat: false
        onTriggered: {
            root.refresh()
        }
    }

    Process {
        id: readProc
        property list<string> buffer: []

        command: [root.cliphistBinary, "list"]

        stdout: SplitParser {
            onRead: (line) => {
                readProc.buffer.push(line)
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.entries = readProc.buffer
            } else {
                root.entries = []
                console.error("[Cliphist] Failed to refresh with code", exitCode, "and status", exitStatus)
            }
            if (root.refreshPending) {
                root.refreshPending = false;
                root.refresh();
            }
        }
    }

    IpcHandler {
        target: "cliphistService"

        function update(): void {
            // The wl-paste watcher and Quickshell's own clipboard signal both fire per copy; the
            // debounce collapses them into one refresh, after `cliphist store` has committed.
            delayedUpdateTimer.restart()
        }
    }
}