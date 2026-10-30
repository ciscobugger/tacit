pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Simple notes manager.
 * Each item is an object with "id", "content", "attachments" (array of file paths), "createdAt".
 */
Singleton {
    id: root
    property var filePath: Directories.desktopNotesPath ?? (Directories.config + "/notes.json")
    property var list: []
    // A file that did not parse may still hold notes: it is never written over.
    property bool broken: false

    function save() {
        if (root.broken) {
            console.log("[Notes] Not saving: " + root.filePath + " did not parse")
            return
        }
        notesFileView.setText(JSON.stringify(root.list))
    }

    function addNote(content, attachments) {
        const item = {
            "id": Date.now().toString() + "-" + Math.floor(Math.random() * 10000),
            "content": content ?? "",
            "attachments": attachments ?? [],
            "createdAt": Date.now()
        }
        list.push(item)
        root.list = list.slice(0)
        root.save()
        return item.id
    }

    function updateNote(id, content, attachments) {
        const idx = list.findIndex(n => n.id === id)
        if (idx >= 0) {
            list[idx].content = content
            if (attachments !== undefined)
                list[idx].attachments = attachments
            root.list = list.slice(0)
            root.save()
        }
    }

    function deleteNote(id) {
        const idx = list.findIndex(n => n.id === id)
        if (idx >= 0) {
            list.splice(idx, 1)
            root.list = list.slice(0)
            root.save()
        }
    }

    function refresh() {
        notesFileView.reload()
    }

    Component.onCompleted: {
        refresh()
    }

    FileView {
        id: notesFileView
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            const fileContents = notesFileView.text()
            try {
                const parsed = JSON.parse(fileContents)
                if (Array.isArray(parsed)) {
                    root.list = parsed
                    root.broken = false
                } else {
                    root.broken = true
                    console.log("[Notes] The file is not a list; keeping the notes in memory")
                }
            } catch (e) {
                root.broken = true
                console.log("[Notes] Cannot read the file, keeping the notes in memory: " + e)
            }
            console.log("[Notes] File loaded")
        }
        onLoadFailed: (error) => {
            if (error == FileViewError.FileNotFound) {
                console.log("[Notes] File not found, creating new file.")
                root.list = []
                notesFileView.setText(JSON.stringify(root.list))
            } else {
                console.log("[Notes] Error loading file: " + error)
            }
        }
    }
}