pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Simple polled resource usage service with RAM, Swap, CPU and Disk usage.
 */
Singleton {
    id: root
    property real memoryTotal: 1
    property real memoryFree: 0
    property real memoryUsed: memoryTotal - memoryFree
    property real memoryUsedPercentage: memoryUsed / memoryTotal
    property real swapTotal: 1
    property real swapFree: 0
    property real swapUsed: swapTotal - swapFree
    property real swapUsedPercentage: swapTotal > 0 ? (swapUsed / swapTotal) : 0
    property real cpuUsage: 0
    property var previousCpuStats

    property string maxAvailableMemoryString: kbToGbString(ResourceUsage.memoryTotal)
    property string maxAvailableSwapString: kbToGbString(ResourceUsage.swapTotal)
    property string maxAvailableCpuString: "--"

    readonly property int historyLength: Config?.options.resources.historyLength ?? 60
    property list<real> cpuUsageHistory: []
    property list<real> memoryUsageHistory: []
    property list<real> swapUsageHistory: []

    property real cpuTemp: 0
    // The x86-only labels `sensors` was grepped for (Package id 0/Tctl/Tdie) print nothing on
    // this hardware, so parseFloat("") landed in cpuTemp as NaN. The thermal zones carry the
    // same reading and cost no process per tick.
    property string cpuTempPath: ""

    property real diskTotal: 1
    property real diskUsed: 0
    property real diskFree: 0
    property real diskUsedPercentage: diskTotal > 0 ? diskUsed / diskTotal : 0
    property list<real> diskUsageHistory: []
    property string maxAvailableDiskString: kbToGbString(diskTotal)

    Process {
        id: findCpuThermalZone
        running: true
        command: ["bash", "-c", 'best=""; for z in /sys/class/thermal/thermal_zone*; do t=$(cat "$z/type" 2>/dev/null) || continue; case "$t" in x86_pkg_temp|*cpu*top*) echo "$z/temp"; exit 0 ;; *cpu*) [ -n "$best" ] || best="$z/temp" ;; esac; done; echo "$best"']
        stdout: StdioCollector {
            id: thermalZoneCollector
            onStreamFinished: {
                root.cpuTempPath = thermalZoneCollector.text.trim()
            }
        }
    }

    FileView { id: fileCpuTemp; path: root.cpuTempPath }

    function refreshCpuTemp() {
        if (root.cpuTempPath.length === 0) return
        fileCpuTemp.reload()
        const milliC = parseFloat(fileCpuTemp.text())
        if (!isNaN(milliC)) root.cpuTemp = milliC / 1000
    }

    Process {
        id: diskProc
        command: ["bash", "-c", "df -k / | awk 'NR==2{print $2,$3,$4}'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split(" ").map(Number)
                if (parts.length >= 3) {
                    root.diskTotal = parts[0]
                    root.diskUsed  = parts[1]
                    root.diskFree  = parts[2]
                }
            }
        }
    }

    Timer {
        // Disk usage does not move on a three-second scale, and this was forking bash+df on
        // every tick for the whole session.
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            diskProc.running = false
            diskProc.running = true
        }
    }

    function kbToGbString(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB"
    }

    function updateMemoryUsageHistory() {
        const next = [...memoryUsageHistory, memoryUsedPercentage]
        if (next.length > historyLength) next.shift()
        memoryUsageHistory = next
    }
    function updateSwapUsageHistory() {
        const next = [...swapUsageHistory, swapUsedPercentage]
        if (next.length > historyLength) next.shift()
        swapUsageHistory = next
    }
    function updateCpuUsageHistory() {
        const next = [...cpuUsageHistory, cpuUsage]
        if (next.length > historyLength) next.shift()
        cpuUsageHistory = next
    }
    function updateDiskUsageHistory() {
        const next = [...diskUsageHistory, diskUsedPercentage]
        if (next.length > historyLength) next.shift()
        diskUsageHistory = next
    }
    function updateHistories() {
        updateMemoryUsageHistory()
        updateSwapUsageHistory()
        updateCpuUsageHistory()
        updateDiskUsageHistory()
    }

    Timer {
        // ms. At 1 this reloaded and regex-parsed /proc/meminfo and /proc/stat a thousand
        // times a second: 12% CPU at idle and the shell's memory climbing ~40 MB a minute.
        interval: Config.options?.resources?.updateInterval ?? 3000
        running: true
        repeat: true
        onTriggered: {
            fileMeminfo.reload()
            fileStat.reload()

            const textMeminfo = fileMeminfo.text()
            memoryTotal = Number(textMeminfo.match(/MemTotal: *(\d+)/)?.[1] ?? 1)
            memoryFree  = Number(textMeminfo.match(/MemAvailable: *(\d+)/)?.[1] ?? 0)
            swapTotal   = Number(textMeminfo.match(/SwapTotal: *(\d+)/)?.[1] ?? 1)
            swapFree    = Number(textMeminfo.match(/SwapFree: *(\d+)/)?.[1] ?? 0)

            const textStat = fileStat.text()
            const cpuLine  = textStat.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
            if (cpuLine) {
                const stats = cpuLine.slice(1).map(Number)
                const total = stats.reduce((a, b) => a + b, 0)
                const idle  = stats[3]
                if (previousCpuStats) {
                    const totalDiff = total - previousCpuStats.total
                    const idleDiff  = idle  - previousCpuStats.idle
                    cpuUsage = totalDiff > 0 ? (1 - idleDiff / totalDiff) : 0
                }
                previousCpuStats = { total, idle }
            }

            root.refreshCpuTemp()
            root.updateHistories()
            interval = Config.options?.resources?.updateInterval ?? 3000
        }
    }

    FileView { id: fileMeminfo; path: "/proc/meminfo" }
    FileView { id: fileStat;    path: "/proc/stat" }

    Process {
        id: findCpuMaxFreqProc
        environment: ({ LANG: "C", LC_ALL: "C" })
        command: ["bash", "-c", "lscpu | grep 'CPU max MHz' | awk '{print $4}'"]
        running: true
        stdout: StdioCollector {
            id: outputCollector
            onStreamFinished: {
                const mhz = parseFloat(outputCollector.text);
                if (isFinite(mhz) && mhz > 0)
                    root.maxAvailableCpuString = (mhz / 1000).toFixed(0) + " GHz"
            }
        }
    }
}
