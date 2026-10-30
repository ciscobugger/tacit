pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs

Singleton {
    id: root
    property var items: []
    property int maxItems: 30

    // Persisted like the to-do list (services/Todo.qml): parked files survive a shell restart
    // (boring.notch ShelfPersistenceService). Missing files are pruned on load.
    readonly property string filePath: FileUtils.trimFileProtocol(`${Directories.state}/user/shelf.json`)
    property bool loaded: false
    onItemsChanged: {
        if (root.loaded)
            shelfFile.setText(JSON.stringify(root.items))
    }
    Component.onCompleted: shelfFile.reload()

    FileView {
        id: shelfFile
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try {
                const parsed = JSON.parse(shelfFile.text())
                root.items = Array.isArray(parsed) ? parsed.filter(p => typeof p === "string") : []
            } catch (e) {
                root.items = []
            }
            root.loaded = true
            root.prune()
        }
        onLoadFailed: (error) => {
            root.loaded = true
            if (error == FileViewError.FileNotFound)
                shelfFile.setText("[]")
        }
    }

    function addItems(urls) {
        let arr = [...items]
        for (const url of urls) {
            const path = FileUtils.trimFileProtocol(decodeURIComponent(url.toString()))
            if (arr.includes(path)) continue
            // A full shelf makes room instead of swallowing the drop and opening with nothing new
            if (arr.length >= root.maxItems)
                arr.shift()
            arr.push(path)
        }
        // Only a real change: reassigning the same list rebuilds every tile, and a tile that is
        // the source of the drag being dropped dies under Qt's feet (the shell crashed on a
        // shelf tile dropped back onto the notch).
        if (arr.length !== items.length || arr.some((p, i) => p !== items[i]))
            root.items = arr
    }

    function show(urls, x, y, screen) {
        root.addItems(urls)
        GlobalStates.dropShelfX = x
        GlobalStates.dropShelfY = y
        GlobalStates.dropShelfScreen = screen ?? null
        GlobalStates.dropShelfOpen = true
    }

    function copyAll() {
        if (root.items.length === 0) return
        const uriList = root.items.map(p => FileUtils.fileUrl(p)).join("\n")
        copyProc.payload = uriList
        copyProc.running = true
    }

    function remove(path) {
        root.items = root.items.filter(p => p !== path)
    }

    // Drop entries whose file is gone (boring.notch ShelfStateViewModel.cleanupInvalidItems).
    function prune() {
        if (root.items.length === 0) return
        pruneProc.running = false
        pruneProc.running = true
    }

    Process {
        id: pruneProc
        command: ["bash", "-c", `for f in ${root.items.map(p => `'${StringUtils.shellSingleQuoteEscape(p)}'`).join(" ")}; do [ -e "$f" ] || printf '%s\n' "$f"; done`]
        stdout: SplitParser {
            onRead: line => { const p = line.trim(); if (p.length > 0) root.remove(p) }
        }
    }

    function clear() {
        root.items = []
        GlobalStates.dropShelfOpen = false
    }

    function hide() {
        GlobalStates.dropShelfOpen = false
    }

    // qs -c tacit ipc call shelf add /path/to/file   (scripts can park files on the notch)
    IpcHandler {
        target: "shelf"

        function add(path: string): void {
            root.addItems([path.startsWith("file://") ? path : "file://" + encodeURI(path)]);
        }

        function clear(): void {
            root.clear();
        }

        function remove(path: string): void {
            root.remove(path);
        }
    }

    Process {
        id: copyProc
        property string payload: ""
        command: ["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(copyProc.payload)}' | wl-copy --type text/uri-list`]
    }
}