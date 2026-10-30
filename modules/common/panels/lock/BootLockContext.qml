import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam

Scope {
    id: root

    enum ActionEnum { Unlock, Poweroff, Reboot }

    signal shouldReFocus()
    signal unlocked(targetAction: var)
    signal failed()
    // Local state instead of GlobalStates: the boot lock must not instantiate the shell's
    // GlobalStates singleton, which registers compositor global shortcuts and an IPC target
    // that the real shell registers again fifteen seconds later.
    property bool unlockFailed: false
    property bool hasCharacters: false

    // These properties are in the context and not individual lock surfaces
    // so all surfaces can share the same state.
    property string currentText: ""
    property bool unlockInProgress: false
    property bool showFailure: false
    // PAM could not even be asked (no /etc/pam.d entry, a module that will not load, a
    // context still busy). "Incorrect password" would be a lie, and a disc spinning with no
    // message is a machine nobody can get back into: the surface names this one.
    property bool authUnavailable: false
    property bool fingerprintsConfigured: false
    // fingerPam erroring completes at once (reader busy, fprintd down), so retrying from its
    // completion handler is a tight loop. Back off, and stop asking after a few.
    property int fingerErrors: 0
    readonly property int fingerErrorLimit: 3
    property var targetAction: BootLockContext.ActionEnum.Unlock
    property bool alsoInhibitIdle: false

    function resetTargetAction() {
        root.targetAction = BootLockContext.ActionEnum.Unlock;
    }

    function clearText() {
        root.currentText = "";
    }

    // The typed text and the failure it caused go stale together. An armed power action and a
    // live fingerprint reader do not: a pause must not turn Shut down back into Unlock.
    function forgetAttempt() {
        root.clearText();
        root.showFailure = false;
        root.authUnavailable = false;
        root.unlockFailed = false;
    }

    function resetClearTimer() {
        passwordClearTimer.restart();
    }

    function reset() {
        root.resetTargetAction();
        root.unlockInProgress = false;
        // An attempt still in flight would make the next start() fail and hang the field.
        if (pam.active) {
            pam.abort();
        }
        root.fingerErrors = 0;
        stopFingerPam();
        // Last: whatever aborting reported is stale the moment it arrives.
        root.forgetAttempt();
    }

    Timer {
        id: passwordClearTimer
        interval: 10000
        onTriggered: {
            root.forgetAttempt();
        }
    }

    onCurrentTextChanged: {
        if (currentText.length > 0) {
            showFailure = false;
            root.unlockFailed = false;
        }
        root.hasCharacters = currentText.length > 0;
        if (currentText.length > 0) {
            passwordClearTimer.restart();
        } else {
            passwordClearTimer.stop();
        }
    }

    function tryUnlock(alsoInhibitIdle = false) {
        root.alsoInhibitIdle = alsoInhibitIdle;
        root.authUnavailable = false;
        root.unlockInProgress = true;
        if (!pam.start()) {
            root.unlockInProgress = false;
            root.authUnavailable = true;
        }
    }

    function tryFingerUnlock() {
        if (!root.fingerprintsConfigured)
            return;
        if (!fingerPam.start()) {
            root.noteFingerError();
        }
    }

    function noteFingerError() {
        if (root.fingerErrors >= root.fingerErrorLimit)
            return;
        root.fingerErrors++;
        fingerRetryTimer.restart();
    }

    function stopFingerPam() {
        fingerRetryTimer.stop();
        if (fingerPam.active) {
            fingerPam.abort();
        }
    }

    Timer {
        id: fingerRetryTimer
        interval: 2000
        onTriggered: root.tryFingerUnlock()
    }

    Process {
        id: fingerprintCheckProc
        running: true
        command: ["bash", "-c", "fprintd-list $(whoami)"]
        stdout: StdioCollector {
            id: fingerprintOutputCollector
            onStreamFinished: {
                root.fingerprintsConfigured = fingerprintOutputCollector.text.includes("Fingerprints for user");
            }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                // console.warn("[LockContext] fprintd-list command exited with error:", exitCode, exitStatus);
                root.fingerprintsConfigured = false;
            }
        }
    }
    
    // fprintd-list answers long after startup, so the boot lock's own start-up call sees
    // false and never arms the reader: start from the value instead.
    onFingerprintsConfiguredChanged: {
        if (root.fingerprintsConfigured) {
            root.tryFingerUnlock();
        }
    }

    PamContext {
        id: pam

        // pam_unix will ask for a response for the password prompt
        onPamMessage: {
            if (this.responseRequired) {
                this.respond(root.currentText);
            }
        }

        // A PAM error never reaches completed: without this the field stays disabled for good.
        onError: err => {
            root.unlockInProgress = false;
            root.authUnavailable = true;
        }

        // pam_unix won't send any important messages so all we need is the completion status.
        onCompleted: result => {
            if (result == PamResult.Success) {
                root.unlocked(root.targetAction);
                stopFingerPam();
            } else {
                root.clearText();
                root.unlockInProgress = false;
                root.unlockFailed = true;
                root.showFailure = true;
            }
        }
    }

    PamContext {
        id: fingerPam

        configDirectory: "pam"
        config: "fprintd.conf"

        onCompleted: result => {
            if (result == PamResult.Success) {
                root.unlocked(root.targetAction);
                stopFingerPam();
            } else { // error, failed or out of tries: arm the reader again
                root.noteFingerError();
            }
        }

        onError: err => {
            root.noteFingerError();
        }
    }
}
