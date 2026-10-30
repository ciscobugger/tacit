pragma Singleton
import qs
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Crew's threads, read-only: ~/.local/state/crew/index.json (sessions -> thread id, places)
 * and threads/<id>/thread.json (name, kind, place, next). The notch uses it to name a
 * session's row after its thread and to open Claude in the thread's place; the palette
 * finds threads through it. `crew` writes; this only reads, and reloads when the index moves.
 */
Singleton {
    id: root

    readonly property string dir: FileUtils.trimFileProtocol(`${Directories.home}/.local/state/crew`)
    property var sessions: ({})   // session id -> thread id
    property var threads: ({})    // id -> {id, name, kind, place, next, status}
    readonly property var open: Object.values(root.threads).filter(t => t.status === "open")

    property int retries: 0
    property string lastRead: ""

    FileView {
        id: index
        path: Qt.resolvedUrl("file://" + root.dir + "/index.json")
        watchChanges: true
        onFileChanged: index.reload()
        onLoaded: {
            root.retries = 0;
            try {
                root.sessions = JSON.parse(index.text()).sessions ?? ({});
            } catch (e) {
                root.sessions = ({});
            }
            // the threads are read whatever the index says, so an unreadable index costs the
            // session bindings and not every thread's name
            readProc.running = false;
            readProc.running = true;
        }
        // `crew` renames the index into place on every bind, so the file can be gone for an
        // instant and the watch dies with the inode: retry, and keep the last good maps.
        onLoadFailed: {
            if (root.retries < 10) {
                root.retries += 1;
                retry.restart();
            }
        }
    }
    Timer {
        id: retry
        interval: 500
        onTriggered: index.reload()
    }
    Timer {   // the floor under the watch: the last good maps stand until a load succeeds
        interval: 30000
        running: true
        repeat: true
        onTriggered: index.reload()
    }
    Component.onCompleted: index.reload()

    Process {
        id: readProc
        // no forks: bash reads each file itself, the files are split on a record separator
        command: ["bash", "-c", 'for f in "$0"/threads/*/thread.json; do [ -f "$f" ] && printf \'%s\\n\\x1e\\n\' "$(<"$f")"; done', root.dir]
        stdout: StdioCollector {
            onStreamFinished: {
                // the 30 s floor reloads the same files most of the time: leave the maps alone then
                if (text === root.lastRead)
                    return;
                root.lastRead = text;
                const map = {};
                for (const chunk of text.split("\x1e")) {
                    if (!chunk.trim().startsWith("{"))
                        continue;
                    try {
                        const t = JSON.parse(chunk);
                        map[t.id] = t;
                    } catch (e) {}
                }
                root.threads = map;
            }
        }
    }

    function forSession(sid) {
        const id = root.sessions[sid];
        return id ? (root.threads[id] ?? null) : null;
    }
}
