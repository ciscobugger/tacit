pragma Singleton

import qs.services
import qs.modules.common
import Quickshell
import Quickshell.Services.UPower
import QtQuick
import Quickshell.Io

Singleton {
    id: root
    // Read the EC battery directly, not UPower's DisplayDevice: that one averages every
    // battery it sees, and the dead qcom-battmgr device (0%, "nan") halved the real number
    // (62% showed as 31%). Falls back to the display device on machines without the EC.
    readonly property var device: UPower.devices.values.find(d => d.isLaptopBattery && (d.nativePath ?? "").includes("book4-ec"))
        ?? UPower.displayDevice
    property bool available: device.isLaptopBattery
    property var chargeState: device.state
    property bool isCharging: chargeState == UPowerDeviceState.Charging
    // Plugged in is the adapter's word, not the pack's. book4-pd-charge follows the pack's
    // own charge request, and when the pack asks for 0 mA (balancing, a taper step) it reports
    // "not charging" with the cable in - which read as unplugged and fired the low-battery
    // warning at 14% and again at 19% while charging.
    readonly property bool onAc: !UPower.onBattery
    property bool isPluggedIn: onAc || isCharging || chargeState == UPowerDeviceState.PendingCharge
    property real percentage: device?.percentage ?? 1
    readonly property bool allowAutomaticSuspend: Config.options.battery.automaticSuspend

    property bool isLow: available && (percentage <= Config.options.battery.low / 100)
    property bool isCritical: available && (percentage <= Config.options.battery.critical / 100)
    property bool isSuspending: available && (percentage <= Config.options.battery.suspend / 100)
    property bool isFull: available && (percentage >= Config.options.battery.full / 100)

    property bool isLowAndNotCharging: isLow && !isPluggedIn
    property bool isCriticalAndNotCharging: isCritical && !isPluggedIn
    property bool isSuspendingAndNotCharging: allowAutomaticSuspend && isSuspending && !isPluggedIn
    property bool isFullAndCharging: isFull && isCharging

    // The times are the pack's own, not UPower's: UPower divides by the current at this instant, which the EC gives
    // without its direction and in steps, and the island swung between 3, 4 and 9 h to full, and showed a time to full
    // while a capped charger let the pack drain (2026-10-13). Here the rate is the pack's energy over the last minutes
    // (a line through samples every 20 s, 12 min kept, 4 min needed), its sign the direction. A time shows once there
    // is such a rate, rounded (5 min under an hour, 10 above), and changes only when it moves by more than a tenth.
    property var samples: []
    property real measuredRate: NaN                 // W, positive while the pack fills
    readonly property bool drainingOnAc: isPluggedIn && measuredRate < -0.3
    property real energyRate: isNaN(measuredRate) ? 0 : Math.abs(measuredRate)
    property real timeToEmpty: 0
    property real timeToFull: 0
    onIsPluggedInChanged: { samples = []; measuredRate = NaN; timeToEmpty = 0; timeToFull = 0; }
    function shown(old, secs) {
        if (!(secs > 60))
            return 0;
        const step = secs < 3600 ? 300 : 600;
        const rounded = Math.max(step, Math.round(secs / step) * step);
        return old > 0 && Math.abs(rounded - old) <= old * 0.1 ? old : rounded;
    }
    function sample() {
        if (!root.available || !(device.energy > 0))
            return;
        const now = Date.now();
        const kept = root.samples.filter(p => now - p.t <= 12 * 60000);
        kept.push({ t: now, e: device.energy });
        root.samples = kept;
        if (now - kept[0].t < 4 * 60000) {
            root.measuredRate = NaN;
            return;
        }
        // least squares, energy (Wh) against time (h)
        const n = kept.length, t0 = kept[0].t;
        let st = 0, se = 0, stt = 0, ste = 0;
        for (const p of kept) {
            const t = (p.t - t0) / 3600000;
            st += t; se += p.e; stt += t * t; ste += t * p.e;
        }
        const den = n * stt - st * st;
        root.measuredRate = den > 0 ? (n * ste - st * se) / den : NaN;
        const rate = root.measuredRate, left = device.energyCapacity - device.energy;
        root.timeToFull = root.shown(root.timeToFull, isCharging && rate > 0.3 && left > 0 ? left / rate * 3600 : 0);
        root.timeToEmpty = root.shown(root.timeToEmpty, !isPluggedIn && rate < -0.3 ? device.energy / -rate * 3600 : 0);
    }
    Timer {
        interval: 20000
        repeat: true
        running: root.available
        triggeredOnStart: true
        onTriggered: {
            root.sample();
            // Timers stand still while suspended, the wall clock does not: a long gap since the last tick is a resume
            const now = Date.now();
            if (root.lastTickAt > 0 && now - root.lastTickAt > 60000) root.resumedAt = now;
            root.lastTickAt = now;
            root.maybeSuspend();
        }
    }

    property real health: (function() {
        const devList = UPower.devices.values;
        for (let i = 0; i < devList.length; ++i) {
            const dev = devList[i];
            if (dev.isLaptopBattery && dev.healthSupported) {
                const health = dev.healthPercentage;
                if (health === 0) {
                    return 0.01;
                } else if (health < 1) {
                    return health * 100;
                } else {
                    return health;
                }
            }
        }
        return 0;
    })()

    property int chargeCycles: (function() {
        const devList = UPower.devices.values;
        for (let i = 0; i < devList.length; ++i) {
            const dev = devList[i];
            if (dev.isLaptopBattery) {
                return dev.chargeCycles ?? -1
            }
        }
        return -1
    })()

    // The low, critical, full and charger notices and their chimes are sent by the shell
    // (IslandController.qml, "notices"): the login lock loads this file too, and sent each twice.
    // Also asked every 20 s: after a resume that is still below the threshold the condition does not change, so only
    // the change handler would never suspend again. Two minutes after a resume it holds off, enough to save a file.
    // Only the shell suspends (shell.qml sets suspends): the lock, settings and activity load this file too.
    property bool suspends: false
    property double lastTickAt: 0
    property double resumedAt: 0
    function maybeSuspend() {
        if (!root.suspends || !root.available || !isSuspendingAndNotCharging) return;
        if (Date.now() - resumedAt < 120000) return;
        Quickshell.execDetached(["bash", "-c", `systemctl suspend || loginctl suspend`]);
    }
    onIsSuspendingAndNotChargingChanged: root.maybeSuspend()
}
