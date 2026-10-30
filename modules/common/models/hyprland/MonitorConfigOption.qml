pragma ComponentBehavior: Bound
import QtQml
import QtQuick
import Quickshell.Io
import qs.services
import "../"

NestableObject {
    id: root

    property var monitors: []

    Component.onCompleted: fetchProc.running = true

    function updateMonitor(index, changes) {
        let m = root.monitors.slice()
        m[index] = Object.assign({}, m[index], changes)
        root.monitors = m
    }

    function _buildLuaLine(m) {
        if (m.disabled)
            return `hl.monitor({ output = "${m.name}", disabled = true })`

        const pos = `${m.x}x${m.y}`
        let line = `hl.monitor({ output = "${m.name}", mode = "${m.currentMode}", position = "${pos}", scale = ${m.scale}`

        if (m.transform && m.transform !== 0)
            line += `, transform = ${m.transform}`

        line += ` })`
        return line
    }

    function save() {
        if (root.monitors.length === 0) return
        if (root.monitors.some(m => !m.name)) return

        const lines = root.monitors.map(m => {
            const line = root._buildLuaLine(m)
            console.log(`[MonitorConfig] saving line: "${line}"`)
            return line
        }).join("\n")

        console.log(`[MonitorConfig] full file:\n${lines}`)

        const escaped = lines.replace(/'/g, "'\\''")
        saveProc.command = ["bash", "-c",
            `printf '%s\n' '${escaped}' > ~/.config/hypr/monitors.lua`]
        saveProc.running = true
    }

    function applyMonitor(m) {
        if (!m.name) return

        const base = `${m.name},${m.currentMode},${m.x}x${m.y},${m.scale}`
        applyProc.command = ["hyprctl", "keyword", "monitor",
            m.disabled
                ? `${m.name},disable`
                : (m.transform && m.transform !== 0)
                    ? `${base},transform,${m.transform}`
                    : base]
        applyProc.running = true
    }

    // A Process ignores running = true while it runs, so rapid changes are
    // collected and applied once, after the previous run has finished.
    property var _pendingApply: ({})

    function applyAndSave(index) {
        root._pendingApply[index] = true
        applyTimer.restart()
    }

    Timer {
        id: applyTimer
        interval: 150
        onTriggered: {
            if (applyProc.running || saveProc.running) {
                restart()
                return
            }
            const pending = Object.keys(root._pendingApply)
            root._pendingApply = ({})
            // One apply Process: only the last changed monitor is applied live;
            // the saved file and the reload that follows cover the rest.
            if (pending.length > 0) {
                root.applyMonitor(root.monitors[pending[pending.length - 1]])
                root.save()
            }
        }
    }

    function logicalWidth(m) {
        return (m.transform === 1 || m.transform === 3) ? m.height : m.width
    }

    function logicalHeight(m) {
        return (m.transform === 1 || m.transform === 3) ? m.width : m.height
    }

    Process {
        id: fetchProc
        command: ["hyprctl", "monitors", "all", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.monitors = JSON.parse(text).map(m => ({
                        name:          m.name,
                        description:   m.description,
                        width:         m.width,
                        height:        m.height,
                        refreshRate:   m.refreshRate,
                        x:             m.x,
                        y:             m.y,
                        scale:         m.scale,
                        transform:     m.transform ?? 0,
                        disabled:      m.disabled,
                        availableModes: m.availableModes,
                        currentMode:   `${m.width}x${m.height}@${m.refreshRate.toFixed(2)}Hz`
                    }))
                } catch(e) {
                    console.log("[MonitorConfig] Error parseando JSON:", e)
                }
            }
        }
    }

    Process { id: applyProc }

    Process {
        id: saveProc
        onRunningChanged: if (!running) reloadProc.running = true
    }

    Process {
        id: reloadProc
        command: ["hyprctl", "reload"]
    }
}