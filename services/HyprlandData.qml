pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.services

/**
 * Provides access to some Hyprland data not available in Quickshell.Hyprland.
 */
Singleton {
    id: root
    property var windowList: []
    property var addresses: []
    property var windowByAddress: ({})
    property var workspaces: []
    property var workspaceIds: []
    property var workspaceById: ({})
    property var activeWorkspace: null
    property var monitors: []
    property var layers: ({})
    property string lastClientsText: ""

    // Convenient stuff

    function toplevelsForWorkspace(workspace) {
        return ToplevelManager.toplevels.values.filter(toplevel => {
            const address = `0x${toplevel.HyprlandToplevel?.address}`;
            var win = HyprlandData.windowByAddress[address];
            return win?.workspace?.id === workspace;
        })
    }

    function hyprlandClientsForWorkspace(workspace) {
        return root.windowList.filter(win => win.workspace.id === workspace);
    }

    // True fullscreen only: a workspace's hasfullscreen is also set by a maximized window
    // (Super+D), and a maximized window must keep the notch. fullscreen is a bit mask, 2 = fullscreen.
    function workspaceHasTrueFullscreen(workspace) {
        return root.trueFullscreenWindow(workspace) !== null;
    }

    // The window filling a workspace in true fullscreen, or null.
    function trueFullscreenWindow(workspace) {
        return root.windowList.find(win => win.workspace.id === workspace && win.mapped !== false && (win.fullscreen & 2) !== 0) ?? null;
    }

    function clientForToplevel(toplevel) {
        if (!toplevel || !toplevel.HyprlandToplevel) {
            return null;
        }
        const address = `0x${toplevel?.HyprlandToplevel?.address}`;
        return root.windowByAddress[address];
    }

    // Internals

    function updateWindowList() {
        if (WM.compositor !== "hyprland") return;
        getClients.running = true;
    }

    function updateLayers() {
        if (WM.compositor !== "hyprland") return;
        getLayers.running = true;
    }

    function updateMonitors() {
        if (WM.compositor !== "hyprland") return;
        getMonitors.running = true;
    }

    function updateWorkspaces() {
        if (WM.compositor !== "hyprland") return;
        getWorkspaces.running = true;
        getActiveWorkspace.running = true;
    }

    function updateAll() {
        if (WM.compositor !== "hyprland") return;
        updateWindowList();
        updateMonitors();
        updateWorkspaces();
    }

    function biggestWindowForWorkspace(workspaceId) {
        const windowsInThisWorkspace = HyprlandData.windowList.filter(w => w.workspace.id == workspaceId);
        return windowsInThisWorkspace.reduce((maxWin, win) => {
            const maxArea = (maxWin?.size?.[0] ?? 0) * (maxWin?.size?.[1] ?? 0);
            const winArea = (win?.size?.[0] ?? 0) * (win?.size?.[1] ?? 0);
            return winArea > maxArea ? win : maxWin;
        }, null);
    }

    Component.onCompleted: {
        updateAll();
    }

    // Every event used to refresh everything at once, and each refresh starts five hyprctl
    // processes. Hyprland emits most events twice (the v2 form carries the same news), and a window
    // switch emits several, so idle use came to roughly 364,000 forks in 27 h - the shell's largest
    // single cost. The debounce is the Niri backend's (services/NiriBackend.qml).
    Timer {
        id: refreshDebounce
        interval: 80
        onTriggered: {
            // Layers are read only by the region selector, which asks for them when it opens.
            const w = root.pending;
            root.pending = ({});
            if (w.clients) root.updateWindowList();
            if (w.monitors) root.updateMonitors();
            if (w.workspaces) root.updateWorkspaces();
        }
    }

    // Which lists the events since the last refresh can have changed.
    property var pending: ({})
    readonly property var clientOnlyEvents: ["activewindow", "windowtitle", "urgent", "pin"]
    readonly property var workspaceEvents: ["workspace", "createworkspace", "destroyworkspace", "moveworkspace", "renameworkspace", "activespecial"]
    readonly property var monitorEvents: ["monitoradded", "monitorremoved", "focusedmon", "configreloaded"]

    Connections {
        target: Hyprland
        enabled: WM.compositor === "hyprland"

        function onRawEvent(event) {
            if (event.name.endsWith("v2")) return;
            if (["openlayer", "closelayer", "screencast"].includes(event.name)) return;
            const n = event.name;
            const p = root.pending;
            if (root.clientOnlyEvents.includes(n)) p.clients = true;
            else if (root.workspaceEvents.includes(n)) p.workspaces = true;
            else if (root.monitorEvents.includes(n)) { p.monitors = true; p.workspaces = true; }
            else { p.clients = true; p.workspaces = true; p.monitors = true; }
            refreshDebounce.restart()
        }
    }

    Process {
        id: getClients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            id: clientsCollector
            onStreamFinished: {
                // Empty or truncated output - hyprctl under load, or Hyprland shutting down - used
                // to throw here and leave the lists stale with no way back until the next event.
                if (clientsCollector.text === root.lastClientsText) return;
                let clients;
                try {
                    clients = JSON.parse(clientsCollector.text);
                } catch (e) {
                    return;
                }
                root.lastClientsText = clientsCollector.text;
                root.windowList = clients;
                let tempWinByAddress = {};
                for (var i = 0; i < root.windowList.length; ++i) {
                    var win = root.windowList[i];
                    tempWinByAddress[win.address] = win;
                }
                root.windowByAddress = tempWinByAddress;
                root.addresses = root.windowList.map(win => win.address);
            }
        }
    }

    Process {
        id: getMonitors
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            id: monitorsCollector
            onStreamFinished: {
                try {
                    root.monitors = JSON.parse(monitorsCollector.text);
                } catch (e) {
                }
            }
        }
    }

    Process {
        id: getLayers
        command: ["hyprctl", "layers", "-j"]
        stdout: StdioCollector {
            id: layersCollector
            onStreamFinished: {
                try {
                    root.layers = JSON.parse(layersCollector.text);
                } catch (e) {
                }
            }
        }
    }

    Process {
        id: getWorkspaces
        command: ["hyprctl", "workspaces", "-j"]
        stdout: StdioCollector {
            id: workspacesCollector
            onStreamFinished: {
                var rawWorkspaces;
                try {
                    rawWorkspaces = JSON.parse(workspacesCollector.text);
                } catch (e) {
                    return;
                }
                root.workspaces = rawWorkspaces.filter(ws => ws.id >= 1 && ws.id <= 100);
                let tempWorkspaceById = {};
                for (var i = 0; i < root.workspaces.length; ++i) {
                    var ws = root.workspaces[i];
                    tempWorkspaceById[ws.id] = ws;
                }
                root.workspaceById = tempWorkspaceById;
                root.workspaceIds = root.workspaces.map(ws => ws.id);
            }
        }
    }

    Process {
        id: getActiveWorkspace
        command: ["hyprctl", "activeworkspace", "-j"]
        stdout: StdioCollector {
            id: activeWorkspaceCollector
            onStreamFinished: {
                try {
                    root.activeWorkspace = JSON.parse(activeWorkspaceCollector.text);
                } catch (e) {
                }
            }
        }
    }
}