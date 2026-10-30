pragma Singleton
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common

Singleton {
    id: root

    // A power action that was refused, for a surface that is still on screen to say so. The
    // notification below covers the case where nothing is.
    signal actionFailed(string label, int code)

    // Every one of these ends in a `||` fallback that swallows the failure, and execDetached
    // threw the exit status away on top of that: a shut down that logind refuses used to look
    // exactly like one that worked. Hibernate on a machine with no resume device is the case
    // that happens here.
    Process {
        id: actionProc
        property string label: ""
        onExited: (exitCode, exitStatus) => {
            // exitStatus 1 is QProcess::CrashExit, which is also what a process this singleton
            // replaced with the next action reports: that is not a command refusing.
            if (exitCode === 0 || exitStatus !== 0)
                return;
            root.actionFailed(actionProc.label, exitCode);
            Quickshell.execDetached(["notify-send",
                Translation.tr("%1 failed").arg(actionProc.label),
                Translation.tr("The command exited %1. Nothing happened.").arg(exitCode),
                "-a", "Shell"]);
        }
    }

    function runAction(label, script) {
        actionProc.running = false;
        actionProc.label = label;
        actionProc.command = ["bash", "-c", script];
        actionProc.running = true;
    }

    function changePassword() {
        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.changePassword}`]);
    }

    function lock() {
        if (WM.compositor === "niri") {
            Quickshell.execDetached(["qs", "-p", Directories.shellFile, "ipc", "call", "lock", "activate"]);
        } else {
            // Same chain as hypridle's lock_cmd, so a lock does not depend on hypridle running.
            Quickshell.execDetached(["bash", "-c", "qs -p \"$1\" ipc call lock activate || pidof hyprlock || hyprlock", "lock", Directories.shellFile]);
        }
    }

    function suspend() {
        root.runAction(Translation.tr("Sleep"), "systemctl suspend || loginctl suspend");
    }

    // No closeAllWindows() here or below: killing every window raced the poweroff that
    // followed it by milliseconds and bought nothing but the unsaved work. The compositor and
    // logind take the session down on their own.
    function logout() {
        if (WM.compositor === "niri") {
            root.runAction(Translation.tr("Log out"), "niri msg action quit");
        } else {
            root.runAction(Translation.tr("Log out"), "pkill -i Hyprland");
        }
    }

    function launchTaskManager() {
        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.taskManager}`]);
    }

    // whether this computer can hibernate (a swap file to wake from: tacit-install makes one where the disk has room);
    // the session screen leaves Hibernate out where logind says it cannot
    property bool canHibernate: false
    Process {
        running: true
        command: ["busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "CanHibernate"]
        stdout: StdioCollector {
            onStreamFinished: root.canHibernate = /"(yes|challenge)"/.test(text)
        }
    }

    function hibernate() {
        root.runAction(Translation.tr("Hibernate"), "systemctl hibernate || loginctl hibernate");
    }

    function poweroff() {
        root.runAction(Translation.tr("Shut down"), "systemctl poweroff || loginctl poweroff");
    }

    function reboot() {
        root.runAction(Translation.tr("Restart"), "reboot || loginctl reboot");
    }

    function rebootToFirmware() {
        root.runAction(Translation.tr("Firmware"), "systemctl reboot --firmware-setup || loginctl reboot --firmware-setup");
    }
}
