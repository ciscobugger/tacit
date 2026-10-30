pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: root

    required property Component lockSurface
    property alias context: lockContext
    property Component sessionLockSurface: WlSessionLockSurface {
        id: sessionLockSurface
        color: "transparent"
        Loader {
            active: GlobalStates.screenLocked
            anchors.fill: parent
            opacity: active ? 1 : 0
            // Fade OUT only. Fading in from 0 shows the compositor's blank lock backdrop
            // (black) for the whole ramp: the "small fast gap" between the boot ground and
            // the lock. The surface's first frame must already be the ground.
            Behavior on opacity {
                enabled: !GlobalStates.screenLocked
                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
            }
            sourceComponent: root.lockSurface
        }
    }

    Process {
        id: unlockKeyringProc
        property string password: ""
        stdinEnabled: true
        // The script takes the password on stdin when UNLOCK_PASSWORD is unset. Handing it
        // over that way instead leaves it out of /proc/<pid>/environ, which anything else
        // running as this user can read for as long as the script lives.
        onStarted: {
            unlockKeyringProc.write(unlockKeyringProc.password + "\n");
            unlockKeyringProc.password = "";
            unlockKeyringProc.stdinEnabled = false;
        }
        onExited: (exitCode, exitStatus) => {
            KeyringStorage.fetchKeyringData();
        }
    }
    function unlockKeyring() {
        unlockKeyringProc.password = lockContext.currentText;
        unlockKeyringProc.stdinEnabled = true;
        unlockKeyringProc.exec({
            command: ["bash", "-c", Quickshell.shellPath("scripts/keyring/unlock.sh")]
        })
    }

    // This stores all the information shared between the lock surfaces on each screen.
    // https://github.com/quickshell-mirror/quickshell-examples/tree/master/lockscreen
    LockContext {
        id: lockContext

        Connections {
            target: GlobalStates
            function onScreenLockedChanged() {
                if (GlobalStates.screenLocked) {
                    lockContext.reset();
                    lockContext.tryFingerUnlock();
                }
            }
        }

        onUnlocked: (targetAction) => {
            // Perform the target action if it's not just unlocking
            if (targetAction == LockContext.ActionEnum.Poweroff) {
                Session.poweroff();
                return;
            } else if (targetAction == LockContext.ActionEnum.Reboot) {
                Session.reboot();
                return;
            }

            // Unlock the keyring if configured to do so
            if (Config.options.lock.security.unlockKeyring) root.unlockKeyring(); // Async

            // Unlock the screen before exiting, or the compositor will display a
            // fallback lock you can't interact with.
            GlobalStates.screenLocked = false;

            // Reset
            lockContext.reset();

            // Post-unlock actions
            if (lockContext.alsoInhibitIdle) {
                lockContext.alsoInhibitIdle = false;
                Idle.inhibitForSession();
            }
        }
    }

    WlSessionLock {
        id: lock
        locked: GlobalStates.screenLocked
        surface: root.sessionLockSurface
        // The compositor refuses a second lock while another client (bootlock) holds one.
        // Follow it, or screenLocked stays true with no lock surface and cannot be set again.
        onLockedChanged: if (!locked && GlobalStates.screenLocked) GlobalStates.screenLocked = false
    }

    function lock() {
        if (Config.options.lock.useHyprlock) {
            Quickshell.execDetached(["bash", "-c", "pidof hyprlock || hyprlock"]);
            return;
        }
        GlobalStates.screenLocked = true;
    }

    IpcHandler {
        target: "lock"

        function activate(): void {
            root.lock();
        }
        function focus(): void {
            lockContext.shouldReFocus();
        }
    }

    CompositorGlobalShortcut {
        name: "lock"
        description: "Locks the screen"

        onPressed: {
            root.lock()
        }
    }

    CompositorGlobalShortcut {
        name: "lockFocus"
        description: "Re-focuses the lock screen. This is because Hyprland after waking up for whatever reason"
            + "decides to keyboard-unfocus the lock screen"

        onPressed: {
            lockContext.shouldReFocus();
        }
    }

    // The compositor, not the shell, knows whether this session is locked. A shell
    // reload rebuilds every singleton, so GlobalStates.screenLocked comes back false
    // and WlSessionLock would tell the compositor to unlock a locked screen; a shell
    // crash leaves the lock with no client at all. LockedHint survives both.
    Process {
        id: lockedHintProc
        command: ["bash", "-c", "loginctl show-session \"$XDG_SESSION_ID\" -p LockedHint --value 2>/dev/null || true"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "yes" && !GlobalStates.screenLocked) {
                    root.lock();
                }
            }
        }
    }

    function initIfReady() {
        if (!Config.ready || !Persistent.ready) return;
        // Re-attach to a lock that outlived the shell. Asked on every start, before
        // launchOnStartup is considered, because a reload is not a new Hyprland instance
        // and so the startup lock below can never cover it.
        lockedHintProc.running = true;
        if (Config.options.lock.launchOnStartup && Persistent.isNewHyprlandInstance) {
            startupLockProc.running = true;
        } else {
            KeyringStorage.fetchKeyringData();
        }
    }
    // A fresh boot is exactly when bootlock.qml is still holding an ext-session-lock of its
    // own, and it leaves the ready marker only once someone has typed the password. Locking
    // again before that hands the compositor's lock to this client and tears the boot lock's
    // surface down mid-authentication.
    Process {
        id: startupLockProc
        command: ["bash", "-c", "[ -e \"$XDG_RUNTIME_DIR/martida-lock-ready\" ]"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.lock();
            } else {
                KeyringStorage.fetchKeyringData();
            }
        }
    }
    Connections {
        target: Config
        function onReadyChanged() {
            root.initIfReady();
        }
    }
    Connections {
        target: Persistent
        function onReadyChanged() {
            root.initIfReady();
        }
    }
    // onReadyChanged cannot fire for a Config that was already ready when this Scope
    // was built, which is the usual case on a reload: ask once directly as well.
    Component.onCompleted: root.initIfReady()
}
