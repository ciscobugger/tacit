pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * The window the keyring sheet lives in, the shape of the pairing window (../bluetooth/BluetoothPairing.qml):
 * overlay layer, keyboard held while asking, kept up for 450 ms after the answer so the sheet can fold back
 * (1.5 s after a password, which may be wrong).
 * tacit-keyring-prompter (the gcr SystemPrompter/PrivatePrompter owner) asks the DialogBridge for kinds
 * "keyring.password" and "keyring.confirm" (params in KeyringContent.qml, DIALOGS.md); a dialog waits while the
 * screen is locked (DialogBridge.asking).
 *
 * A wrong password makes the prompter ask again on the same prompt, after gnome-keyring has checked it. The sheet
 * stays up in a busy state for that (up to 1.5 s after a password answer) and shows the error instead of folding
 * and opening again.
 */
Scope {
    id: root

    Component.onCompleted: {
        DialogBridge.claim("keyring.password");
        DialogBridge.claim("keyring.confirm");
    }
    Component.onDestruction: {
        DialogBridge.unclaim("keyring.password");
        DialogBridge.unclaim("keyring.confirm");
    }

    readonly property bool wanted: DialogBridge.asking && (DialogBridge.current.kind ?? "").startsWith("keyring.")
    // the ask on the sheet; kept while it folds back
    property var ask: null
    property bool up: false
    readonly property bool asking: root.wanted && root.ask !== null
    // a password was just answered and the next ask (the retry) may still come
    property bool busy: false

    onWantedChanged: {
        if (wanted) {
            linger.stop();
            busy = false;
            ask = DialogBridge.current;
            up = true;
        } else {
            linger.restart();
        }
    }
    Connections {
        target: DialogBridge
        function onCurrentChanged() {
            if (root.wanted) root.ask = DialogBridge.current;
        }
    }
    Timer {
        id: linger
        interval: root.busy ? 1500 : 450
        onTriggered: { root.busy = false; root.up = false; }
    }

    function answer(result): void {
        const id = root.ask?.id;
        if (!id) return;
        root.busy = result?.password !== undefined;
        DialogBridge.answer(id, result);
    }
    function refuse(reason: string): void {
        const id = root.ask?.id;
        if (!id) return;
        DialogBridge.refuse(id, reason);
    }

    // An unlock ask with nothing left to unlock is moot: one an app set off behind the boot lock, whose keyring the
    // lock's own PAM check (pam_gnome_keyring in /etc/pam.d/login) has opened since; shown, it would ask for a password
    // the keyring already has (2026-10-14: it flashed in the notch at every boot). While such an ask waits, whether or
    // not it shows yet, the collections are looked at each second; once none is locked it is refused, as Cancel would.
    // Not a new password (choosing one) nor a confirm. The old password of a change (Seahorse's) would count as moot
    // too: nothing in Tacit asks for one.
    // Only gnome-keyring's own unlock ask, which names its keyring ('... the keyring "Login" ...'): gpg's pinentry and
    // an ssh key's passphrase come through the same prompter for passwords the keyring never holds, and were refused
    // as moot within a second (2026-10-22: signing a package always failed with "Operation cancelled").
    // An ask worded for a login keyring that PAM did not open at login ('The login keyring did not get unlocked when
    // you logged into your computer.') is that same ask, without the quoted name: autologin has no password to give
    // PAM until the boot lock's own check does, so an app asking in between got it, and it stayed in the notch after
    // the keyring was already open (2026-11-05, at every boot).
    readonly property var unlockAsk: {
        const c = DialogBridge.current;
        const description = c?.params?.description ?? "";
        return c && c.kind === "keyring.password" && !c.params?.passwordNew
            && (/keyring\s+["“'‘]/i.test(description) || /login keyring did not get unlocked/i.test(description))
            ? c : null;
    }
    Timer {
        interval: 1000
        repeat: true
        triggeredOnStart: true
        running: root.unlockAsk !== null
        onTriggered: {
            if (mootCheck.running) return;
            mootCheck.askId = root.unlockAsk.id;
            mootCheck.running = true;
        }
    }
    Process {
        id: mootCheck
        property string askId: ""
        command: ["bash", "-c", Quickshell.shellPath("scripts/keyring/all_unlocked.sh")]
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0 && root.unlockAsk?.id === mootCheck.askId)
                DialogBridge.refuse(mootCheck.askId, "cancelled");
        }
    }

    Loader {
        active: root.up
        sourceComponent: Variants {
            model: Quickshell.screens
            delegate: PanelWindow {
                id: panelWindow
                required property var modelData
                screen: modelData

                anchors {
                    top: true
                    left: true
                    right: true
                    bottom: true
                }

                color: "transparent"
                WlrLayershell.namespace: "quickshell:keyring"
                WlrLayershell.keyboardFocus: root.asking ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
                WlrLayershell.layer: WlrLayer.Overlay
                exclusionMode: ExclusionMode.Ignore

                KeyringContent {
                    anchors.fill: parent
                    ask: root.ask
                    active: root.asking || root.busy
                    busy: root.busy && !root.asking
                    onAnswered: result => root.answer(result)
                    onRefused: reason => root.refuse(reason)
                }
            }
        }
    }
}
