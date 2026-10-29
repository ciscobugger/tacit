pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common

/**
 * Flow: dictation for the whole desktop, the shell's half. (Named Dictation: QtQuick already has
 * a Flow type, and a singleton called Flow shadows it in every file that uses the layout.) ~/.local/bin/flowd does the hearing
 * (Gemini 3.5 Transcribe Live, streaming while you speak) and the typing; this holds the key
 * and shows it in the notch.
 *
 * Tap the key to start and tap again to write it where your cursor is; or hold it while you
 * speak and let go. (The Copilot key is a macro that reports its release at once, so it can
 * only be tapped; a real key does both.) Esc or a click on the notch's pill cancels. The pill:
 * "Listening" with the voice level, then "Writing…".
 */
Singleton {
    id: root

    property string state: "idle"     // idle | listening | writing | error
    property real level: 0
    // the voice's three bands while listening (flowd, 20 per second): low (its body), mid (vowels), high (hiss), 0..1.3
    property var bands: [0, 0, 0]
    onActiveChanged: if (!root.active) root.bands = [0, 0, 0]
    property bool handsFree: false
    property bool starting: false     // asked to start; "listening" comes with the first audio
    property string lastText: ""
    readonly property bool connected: root.link?.connected ?? false
    // flowd's socket protocol as this file was written. flowd sends its own in the reply to
    // `watch`: after an upgrade the shell talks to whichever flowd is still running from before it,
    // and until this was compared neither side could tell.
    readonly property int proto: 1
    property string flowBuild: ""
    property bool protoWarned: false
    readonly property bool active: root.state === "listening" || root.state === "writing"

    // Quickshell's Socket does not try again after a failed connect (setting `connected` false and
    // back to true does nothing), so a socket that is not connected is rebuilt on each knock.
    property int gen: 0
    property var link: null
    Instantiator {
        model: [root.gen]
        delegate: Socket {
            id: sock
            // "watch" makes flowd send its state here; once per socket
            property bool watching: false
            function watchOnce() {
                if (sock.watching) return;
                sock.watching = true;
                sock.write(JSON.stringify({ op: "watch" }) + "\n");
                sock.flush();
            }
            path: `${Quickshell.env("XDG_RUNTIME_DIR")}/flow.sock`
            connected: true
            parser: SplitParser { onRead: line => root.receive(line) }
            // connected the moment it is made (flowd already up, as after a shell restart), the socket never
            // reports a change, so the watch went unsent: the key started flowd but nothing came back
            Component.onCompleted: if (sock.connected) sock.watchOnce()
            onConnectedChanged: {
                if (connected) { retry.tries = 0; sock.watchOnce(); }
                else {
                    stuck.stop();
                    // flowd went away mid-dictation: nothing more will come, so end it here
                    if (root.active || root.starting) { root.starting = false; root.state = "idle"; root.show(""); }
                }
            }
        }
        onObjectAdded: (index, object) => root.link = object
        onObjectRemoved: (index, object) => {
            if (root.link === object) root.link = null;
        }
    }
    // flowd not there yet (starting with the session, or restarting): start the service, then keep
    // knocking until it answers. Knocking alone left the key dead for the session once flowd had
    // failed; the start is what Host.qml does for agent-host. The knock stays at 2 s so a flowd
    // restarted by hand is picked up at once, and only the start is thinned out - it is a
    // subprocess, and `systemctl --user start` on a running unit does nothing anyway.
    // After 30 s unanswered the knock is every 30 s: a computer without flowd (every install but the
    // owner's) logged a failed connect every 2 s for good, into the shell's log in memory. A press
    // of the key knocks fast again.
    Timer {
        id: retry
        property int tries: 0
        interval: retry.tries < 15 ? 2000 : 30000
        repeat: true
        running: !root.connected
        onTriggered: {
            if (retry.tries % 15 === 0)
                Quickshell.execDetached(["systemctl", "--user", "start", "flowd.service"]);
            retry.tries++;
            root.gen++;
        }
    }
    // flowd answers every op, so silence is a fault: a `start` it dropped because an old session
    // was still there, or a session that died while writing, used to leave "starting"/"writing"
    // set for good - no pill, the flow submap still entered and the key refusing to start again.
    Timer {
        id: stuck
        repeat: false
        onTriggered: {
            root.starting = false;
            root.state = "idle";
            root.show("");
            IslandController.request("flowNote", { icon: "hearing_disabled", text: Voice.cant("Flow didn't answer"), tone: "error" }, 90);
        }
    }
    function send(o) {
        if (!root.connected) return;
        root.link.write(JSON.stringify(o) + "\n");
        root.link.flush();
    }

    function receive(line) {
        let e;
        try { e = JSON.parse(line); } catch (x) { return; }
        switch (e.ev) {
        case "level":
            root.level = e.v;
            return;
        case "bands":
            root.bands = e.v;
            return;
        case "state":
            if (e.build !== undefined) root.flowBuild = e.build;
            if (e.proto !== undefined && e.proto !== root.proto && !root.protoWarned) {
                root.protoWarned = true;
                console.warn("Flow: flowd speaks protocol", e.proto, "and the shell", root.proto, "- build", e.build);
                IslandController.request("flowNote", { icon: "hearing_disabled", text: "Flow is from another build; restart it", tone: "error" }, 90);
            }
            root.state = e.state;
            root.starting = false;
            if (e.state === "idle") root.handsFree = false;
            // longer than flowd's own worst case (the stream's 8 s, then the hearing model on
            // the whole recording): this is a last resort, not a patience limit
            if (e.state === "writing") { stuck.interval = 150000; stuck.restart(); }
            else stuck.stop();
            root.show(e.text ?? "");
            return;
        case "note":
            IslandController.request("flowNote", { icon: "hearing_disabled", text: e.text }, 60);
            return;
        case "done":
            root.lastText = e.text ?? "";
            return;
        }
    }

    // the notch: one pill while it listens and writes; errors and notes as a short message
    function show(text) {
        // 150 is Flow's priority in IslandController.priorityFor: at 85 a battery or charger peek
        // hid a live microphone, and the pill it displaced came back two minutes later
        if (root.state === "listening")
            IslandController.request("flow", { icon: "mic", text: root.handsFree ? "Listening · press again to send" : "Listening" }, 150);
        else if (root.state === "writing")
            IslandController.request("flow", { icon: "edit_note", text: "Writing…", writing: true }, 150);
        else if (root.state === "error") {
            // flowd's text is a Python exception cut off mid-word: it belongs in the log, and the
            // notch gets a line in the house voice like every other surface
            console.warn("Flow:", text);
            IslandController.request("flowNote", { icon: "error", text: Voice.cant("Flow couldn't hear that"), tone: "error" }, 90);
        } else if (IslandController.transientState === "flow")
            IslandController.dismiss();
    }

    // ── the key ─────────────────────────────────────────────────────────────
    property double pressAt: 0
    CompositorGlobalShortcut {
        name: "flowHold"
        description: "Flow: hold to dictate; tap twice for hands-free"
        onPressed: root.press()
        onReleased: root.release()
    }
    // Pressed while it listens: that is "send". Let go after a real hold: also "send". Let go
    // quickly (a tap, or a key that reports its release at once): it keeps listening until the
    // next press, and the pill says so.
    property bool sending: false      // that press was the send tap, so its release must not re-arm
    function press() {
        // the pill is suppressed while the screen is locked, so a dictation there would open the
        // mic with no indicator and type its text into the password field
        if (GlobalStates.screenLocked) return;
        if (!root.connected) {
            IslandController.request("flowNote", { icon: "hearing_disabled", text: Voice.cant("Flow isn't running"), tone: "error" }, 90);
            retry.tries = 0;
            return;
        }
        root.pressAt = Date.now();
        if (root.state === "listening") { root.handsFree = false; root.sending = true; root.send({ op: "stop" }); return; }
        root.sending = false;
        if (!root.active && !root.starting) {
            root.starting = true;
            root.send({ op: "start" });
            stuck.interval = 3000;
            stuck.restart();
        }
    }
    function release() {
        // the release of the send tap: the state is still "listening" through flowd's quiet tail,
        // so without this the pill re-armed hands-free half a second after the text was sent
        if (root.sending) { root.sending = false; return; }
        if (!(root.state === "listening" || root.starting) || root.handsFree) return;
        if (Date.now() - root.pressAt >= 350) root.send({ op: "stop" });
        else { root.handsFree = true; root.show(""); }
    }
    function cancel() {
        root.handsFree = false;
        root.send({ op: "cancel" });
    }

    // ── the past dictations (the palette's Flow section, prefix ') ─────────────
    // flowd keeps the last 300 in ~/.local/state/flow/history.jsonl, oldest first
    FileView {
        id: historyFile
        path: `${Quickshell.env("HOME")}/.local/state/flow/history.jsonl`
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    function history() {
        const out = [];
        for (const l of (historyFile.text() || "").split("\n")) {
            if (!l.trim()) continue;
            try { out.push(JSON.parse(l)); } catch (e) {}
        }
        return out.reverse();
    }
    // type a past one where the cursor is, once the palette has closed
    function insert(text) { root.send({ op: "insert", text: text }); }

    // Esc while it listens or writes: the "flow" submap (hypr/custom/keybinds.lua) binds it to
    // this and keeps it from the app. Entered and left here; Esc also leaves it on its own.
    CompositorGlobalShortcut {
        name: "flowCancel"
        description: "Flow: cancel the dictation"
        onPressed: root.cancel()
    }
    property bool inSubmap: false
    // The submap is the compositor's state and outlives the shell; inSubmap does not. A reload or
    // a crash mid-sentence left Hyprland in "flow", where only Escape and the Flow key are bound,
    // so every other key in every app did nothing. Every shell start leaves it.
    Component.onCompleted: Hyprland.dispatch(`hl.dsp.submap("reset")`)
    // "starting" counts too: "listening" waits for the first audio chunk, and an Esc in that
    // window reached the app instead - in Claude Code it stops the running turn, which is the
    // thing the submap exists to prevent.
    readonly property bool holding: root.active || root.starting
    onHoldingChanged: {
        if (root.holding && !root.inSubmap) { root.inSubmap = true; Hyprland.dispatch(`hl.dsp.submap("flow")`); }
        else if (!root.holding && root.inSubmap) { root.inSubmap = false; Hyprland.dispatch(`hl.dsp.submap("reset")`); }
    }

    // locked while it was listening: end the dictation rather than record on with no pill and
    // type the transcript into whatever has the keyboard afterwards
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked && root.holding) root.cancel();
        }
    }
}
