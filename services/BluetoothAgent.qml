pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common

/**
 * The shell's half of the Bluetooth pairing agent. ~/.local/bin/quiet-btagent holds
 * org.bluez.Agent1 (Quickshell can call D-Bus but cannot export an object on it) and asks here;
 * this hands the question to the sheet and sends the answer back.
 *
 * Without this, BlueZ has no agent and every device that wants a confirmation, a passkey or a PIN
 * fails to pair with nothing said. The agent rejects a request when no shell is connected, so a
 * pairing started while the shell is down fails at the device instead of hanging.
 */
Singleton {
    id: root

    // The question BlueZ is waiting on, or null. One at a time: BlueZ pairs one device at a time,
    // and a second sheet over the first would hide the code the user is meant to compare.
    property var ask: null
    readonly property bool asking: root.ask !== null && !GlobalStates.screenLocked
    readonly property bool connected: root.link?.connected ?? false

    // Quickshell's Socket does not try again after a failed connect (setting `connected` false and
    // back to true does nothing), so a socket that is not connected is rebuilt until the agent
    // answers. The agent starts with the session and restarts on failure.
    property int gen: 0
    property var link: null
    Instantiator {
        model: [root.gen]
        delegate: Socket {
            path: `${Quickshell.env("XDG_RUNTIME_DIR")}/bt-agent.sock`
            connected: true
            parser: SplitParser {
                onRead: line => root.receive(line)
            }
            onConnectedChanged: {
                // the agent went away: nothing will answer this question, so it stops being one
                if (!connected) root.ask = null;
            }
        }
        onObjectAdded: (index, object) => root.link = object
        onObjectRemoved: (index, object) => {
            if (root.link === object) root.link = null;
        }
    }
    // every 2 s for the first 30 s unanswered, then every 10 s: a computer without Bluetooth has no
    // agent, and each failed connect is a line in the shell's log, which is kept in memory
    Timer {
        id: knock
        property int tries: 0
        interval: knock.tries < 15 ? 2000 : 10000
        repeat: true
        running: !root.connected
        onRunningChanged: if (!knock.running) knock.tries = 0
        onTriggered: { knock.tries++; root.gen++; }
    }

    function receive(line: string): void {
        if (line.length === 0) return;
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            return;
        }
        if (msg.ev === "ask") {
            root.ask = msg;
        } else if (msg.ev === "hide") {
            // the device or BlueZ gave up while the sheet was up
            if (root.ask?.id === msg.id) root.ask = null;
        }
    }

    function send(line: string): void {
        if (!root.connected) return;
        root.link.write(`${line}\n`);
        root.link.flush();
    }

    // `value` carries the PIN or passkey the user typed; the other kinds ignore it.
    function accept(value: string): void {
        const a = root.ask;
        if (!a) return;
        root.ask = null;
        if (a.kind === "pin" || a.kind === "passkey") root.send(`value ${a.id} ${value}`);
        else root.send(`ok ${a.id}`);
    }

    function refuse(): void {
        const a = root.ask;
        if (!a) return;
        root.ask = null;
        root.send(`no ${a.id}`);
    }

    // A code we are only showing has nothing to answer: the remote does the typing, and BlueZ
    // says how it ended. Dismissing it locally must not refuse the pairing.
    function dismiss(): void {
        root.ask = null;
    }
}
