pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common

import Quickshell
import Quickshell.Io
import QtQuick

/**
 * Simple Pomodoro time manager.
 */
Singleton {
    id: root

    property int focusTime: Config.options.time.pomodoro.focus
    property int breakTime: Config.options.time.pomodoro.breakTime
    property int longBreakTime: Config.options.time.pomodoro.longBreak
    property int cyclesBeforeLongBreak: Config.options.time.pomodoro.cyclesBeforeLongBreak

    property bool pomodoroRunning: Persistent.states.timer.pomodoro.running
    property bool pomodoroBreak: Persistent.states.timer.pomodoro.isBreak
    property bool pomodoroLongBreak: Persistent.states.timer.pomodoro.isBreak && (pomodoroCycle + 1 == cyclesBeforeLongBreak);
    property int pomodoroLapDuration: pomodoroLongBreak ? longBreakTime : pomodoroBreak ? breakTime : focusTime // This is a binding that's to be kept
    property int pomodoroSecondsLeft: pomodoroLapDuration // Reasonable init value, to be changed
    property int pomodoroCycle: Persistent.states.timer.pomodoro.cycle

    property bool stopwatchRunning: Persistent.states.timer.stopwatch.running
    property int stopwatchTime: 0
    property int stopwatchStart: Persistent.states.timer.stopwatch.start
    property var stopwatchLaps: Persistent.states.timer.stopwatch.laps

    // Countdown
    property bool countdownRunning: Persistent.states.timer.countdown.running
    property int countdownDuration: Persistent.states.timer.countdown.duration // seconds, total
    property int countdownStart: Persistent.states.timer.countdown.start
    property int countdownSecondsLeft: countdownDuration

    // General
    // A paused reading survives a restart; a running one is rebuilt from its start time.
    function restorePaused() {
        const t = Persistent.states.timer;
        if (!stopwatchRunning)
            stopwatchTime = t.stopwatch.elapsed;
        if (!countdownRunning)
            countdownSecondsLeft = t.countdown.left > 0 ? Math.min(t.countdown.left, countdownDuration) : countdownDuration;
        if (!pomodoroRunning && t.pomodoro.left > 0)
            pomodoroSecondsLeft = Math.min(t.pomodoro.left, pomodoroLapDuration);
    }

    // This singleton can be built before or after the states file is read.
    Component.onCompleted: {
        if (Persistent.ready)
            root.restorePaused();
    }
    Connections {
        target: Persistent
        function onReadyChanged() {
            root.restorePaused();
        }
    }

    function getCurrentTimeInSeconds() {  // Pomodoro uses Seconds
        return Math.floor(Date.now() / 1000);
    }

    function getCurrentTimeIn10ms() {  // Stopwatch uses 10ms
        return Math.floor(Date.now() / 10);
    }

    function formatSeconds(totalSeconds) {
        const s = Math.max(0, Math.round(totalSeconds));
        const m = Math.floor(s / 60);
        const sec = s % 60;
        return `${m}:${sec.toString().padStart(2, "0")}`;
    }

    // Pomodoro
    function refreshPomodoro() {
        // Work <-> break ?
        if (getCurrentTimeInSeconds() >= Persistent.states.timer.pomodoro.start + pomodoroLapDuration) {
            // Reset counts
            Persistent.states.timer.pomodoro.isBreak = !Persistent.states.timer.pomodoro.isBreak;
            Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds();
            // The notice and the chime are the shell's (IslandController.qml, "notices").

            if (!pomodoroBreak) {
                Persistent.states.timer.pomodoro.cycle = (Persistent.states.timer.pomodoro.cycle + 1) % root.cyclesBeforeLongBreak;
            }
        }

        pomodoroSecondsLeft = pomodoroLapDuration - (getCurrentTimeInSeconds() - Persistent.states.timer.pomodoro.start);
    }

    Timer {
        id: pomodoroTimer
        interval: 200
        running: root.pomodoroRunning
        repeat: true
        onTriggered: refreshPomodoro()
    }

    function togglePomodoro() {
        Persistent.states.timer.pomodoro.running = !pomodoroRunning;
        if (Persistent.states.timer.pomodoro.running) {
            // Start/Resume
            Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds() + pomodoroSecondsLeft - pomodoroLapDuration;
        } else {
            Persistent.states.timer.pomodoro.left = pomodoroSecondsLeft;
        }
    }

    function resetPomodoro() {
        Persistent.states.timer.pomodoro.running = false;
        Persistent.states.timer.pomodoro.isBreak = false;
        Persistent.states.timer.pomodoro.start = getCurrentTimeInSeconds();
        Persistent.states.timer.pomodoro.cycle = 0;
        Persistent.states.timer.pomodoro.left = 0;
        refreshPomodoro();
    }

    // Stopwatch
    function refreshStopwatch() {  // Stopwatch stores time in 10ms
        stopwatchTime = getCurrentTimeIn10ms() - stopwatchStart;
    }

    Timer {
        id: stopwatchTimer
        // The hundredths are only ever read in the right sidebar; the desktop card shows whole
        // seconds. A running stopwatch used to fire every 10 ms for the rest of the session -
        // and across a logout, since the flag is restored from states.json - with nothing on
        // screen. The elapsed time is derived from `start`, so a slow tick loses nothing.
        interval: GlobalStates.sidebarRightOpen ? 33 : 500
        running: root.stopwatchRunning
        repeat: true
        onTriggered: refreshStopwatch()
    }

    function toggleStopwatch() {
        if (root.stopwatchRunning)
            stopwatchPause();
        else
            stopwatchResume();
    }

    function stopwatchPause() {
        Persistent.states.timer.stopwatch.running = false;
        Persistent.states.timer.stopwatch.elapsed = stopwatchTime;
    }

    function stopwatchResume() {
        if (stopwatchTime === 0) Persistent.states.timer.stopwatch.laps = [];
        Persistent.states.timer.stopwatch.running = true;
        Persistent.states.timer.stopwatch.start = getCurrentTimeIn10ms() - stopwatchTime;
    }

    function stopwatchReset() {
        stopwatchTime = 0;
        Persistent.states.timer.stopwatch.laps = [];
        Persistent.states.timer.stopwatch.running = false;
        Persistent.states.timer.stopwatch.elapsed = 0;
    }

    function stopwatchRecordLap() {
        // push() mutates the JsonObject list in place, so nothing was notified: the lap list
        // never refreshed and the file was never rewritten. A new array is the only way.
        Persistent.states.timer.stopwatch.laps = [...Persistent.states.timer.stopwatch.laps, stopwatchTime];
    }

    // Countdown
    function refreshCountdown() {
        if (!Persistent.states.timer.countdown.running) return;

        const elapsed = getCurrentTimeInSeconds() - Persistent.states.timer.countdown.start;
        let left = Persistent.states.timer.countdown.duration - elapsed;

        if (left <= 0) {
            left = 0;
            Persistent.states.timer.countdown.running = false;
            Persistent.states.timer.countdown.duration = 0;
        }

        countdownSecondsLeft = left;
    }

    Timer {
        id: countdownTimer
        interval: 200
        running: root.countdownRunning
        repeat: true
        onTriggered: refreshCountdown()
    }

    // Adds minutes to the countdown. Works whether paused or running.
    function addCountdownMinutes(minutes) {
        const addSeconds = minutes * 60;
        if (root.countdownRunning) {
            Persistent.states.timer.countdown.duration += addSeconds;
        } else {
            Persistent.states.timer.countdown.duration = (Persistent.states.timer.countdown.duration ?? 0) + addSeconds;
            countdownSecondsLeft = Persistent.states.timer.countdown.duration;
            Persistent.states.timer.countdown.left = countdownSecondsLeft;
        }
    }

    function toggleCountdown() {
        if (countdownDuration <= 0) return;
        Persistent.states.timer.countdown.running = !countdownRunning;
        if (Persistent.states.timer.countdown.running) {
            Persistent.states.timer.countdown.start = getCurrentTimeInSeconds() - (countdownDuration - countdownSecondsLeft);
        } else {
            Persistent.states.timer.countdown.left = countdownSecondsLeft;
        }
    }

    function resetCountdown() {
        Persistent.states.timer.countdown.running = false;
        Persistent.states.timer.countdown.duration = 0;
        Persistent.states.timer.countdown.left = 0;
        countdownSecondsLeft = 0;
    }

    // False when there is nothing to start: toggleCountdown() returns at once on a duration of
    // zero or less, so the caller has to be told instead of being left to assume it ran.
    function startCountdown(seconds) {
        if (!(seconds > 0)) return false;
        Persistent.states.timer.countdown.running = false;
        Persistent.states.timer.countdown.duration = seconds;
        root.countdownSecondsLeft = seconds;
        root.toggleCountdown();
        return true;
    }

    // qs -c tacit ipc call timer countdown 300 | pomodoro | stop
    IpcHandler {
        target: "timer"

        function countdown(seconds: int): string {
            if (!root.startCountdown(seconds))
                return `countdown needs a positive number of seconds, got ${seconds}`;
            return `countdown started: ${seconds}s`;
        }

        function pomodoro(): void {
            root.togglePomodoro();
        }

        function stop(): void {
            if (root.pomodoroRunning) root.resetPomodoro();
            if (root.countdownRunning) root.resetCountdown();
        }
    }
}