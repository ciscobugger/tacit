pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions

/**
 * The phone as a place to send files to. The phone daemon (kdeconnectd) does the work; scripts/phone/phone-link.py
 * is the one way to it. This keeps what the person needs to see: whether the part is here, the phone that asked to
 * connect (with its code), the phone that is connected, and every file sent this session with its state.
 *
 * A send is: waiting (no phone connected yet), queued, sending, sent, failed. Files go one at a time. "Sent" means
 * the daemon took the file and is passing it on: it reports no progress, so the bar has no percent.
 *
 * Words on screen never name the daemon or the phone's app. Files shows all of this (modules/ii/files/FilesPhone.qml);
 * the notch says each send through IslandController's activity line.
 */
Singleton {
    id: root

    // Where the phone's app comes from: the page the code on the connect page opens.
    readonly property string appPage: "https://tacitos.co/phone"

    // ------------------------------------------------------------------ what is true now
    property bool loaded: false          // the first reading has come back
    property bool installed: true
    property bool running: false
    property string computerName: ""     // what the phone's list calls this computer
    property var devices: []             // [{ id, name, paired, reachable, asked, key }]

    readonly property var phone: root.devices.find(d => d.paired) ?? null
    readonly property var asking: root.devices.find(d => d.asked && !d.paired) ?? null
    readonly property bool paired: root.phone !== null
    readonly property string phoneId: root.phone?.id ?? ""
    readonly property string phoneName: root.phone?.name ?? ""
    readonly property bool phoneReachable: root.phone?.reachable ?? false
    // the part that talks to phones is there and running
    readonly property bool usable: root.loaded && root.installed && root.running
    // What a file's menu says: "Send to your phone…" opens the way in; once connected it sends.
    readonly property string menuWords: root.paired ? `Send to ${root.phoneName}` : "Send to your phone…"
    // the code both screens show, as "4F2A 91" (groups of four)
    function codeOf(key) {
        return (key ?? "").toUpperCase().replace(/[^0-9A-Z]/g, "").replace(/(.{4})(?=.)/g, "$1 ");
    }

    // the page asked for from elsewhere (a file's menu in the notch or the palette): Files shows it
    signal pageRequested()

    // ------------------------------------------------------------------ reading
    // A page that shows the phone holds `watching` up: it looks every two seconds and asks the daemon to search once.
    // Otherwise once a minute, so the menu knows the phone's name.
    property int watching: 0
    onWatchingChanged: {
        if (root.watching === 1) {
            root.run(["refresh"]);
            root.read();
        }
    }
    readonly property string script: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/phone/phone-link.py`
    function read() {
        if (!stateProc.running)
            stateProc.running = true;
    }
    Process {
        id: stateProc
        command: ["python3", "-I", root.script, "state"]
        stdout: StdioCollector {
            onStreamFinished: {
                let s = null;
                try { s = JSON.parse(text); } catch (e) { s = null; }
                if (s === null)
                    return;
                root.installed = s.installed;
                root.running = s.running;
                root.computerName = s.name;
                root.devices = s.devices;
                root.loaded = true;
                root.pump();
            }
        }
    }
    Timer {
        interval: root.watching > 0 ? 2000 : 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.read()
    }

    // one-shot commands (answer, forget, refresh); the reading follows each
    property var pending: []
    function run(args) {
        root.pending = root.pending.concat([args]);
        root.next();
    }
    function next() {
        if (actProc.running || root.pending.length === 0)
            return;
        actProc.command = ["python3", "-I", root.script].concat(root.pending[0]);
        root.pending = root.pending.slice(1);
        actProc.running = true;
    }
    Process {
        id: actProc
        onExited: {
            root.read();
            root.next();
        }
    }

    // ------------------------------------------------------------------ getting the part
    // The part that talks to phones is not on every computer. The first time someone sets up a phone it is got the way
    // the Apps window gets a part of the system (stored.py: Tacit's own password ask, the whole system brought up to
    // date in the same step). setup: "" | "working" | "cancelled" | "denied" | "offline" | "space" | "busy" | "failed"
    property string setup: ""
    property real setupProgress: 0
    property string setupPhase: ""
    property string setupResult: ""
    readonly property string installer: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/store/stored.py`
    readonly property string setupWords: ({
        "cancelled": "The password was not given, so nothing changed.",
        "denied": "The password was not accepted, so nothing changed.",
        "offline": "There is no internet connection. Connect, then try again.",
        "space": "There is not enough space on this computer. Free up some, then try again.",
        "busy": "Another update is running. Try again when it has finished.",
        "failed": "It did not work, and nothing was changed. Try again."
    })[root.setup] ?? ""
    function setupPhone() {
        if (root.setup === "working" || installProc.running || startProc.running)
            return;
        root.setup = "working";
        root.setupProgress = 0;
        root.setupPhase = "Starting";
        root.setupResult = "";
        installProc.running = true;
    }
    Process {
        id: installProc
        command: ["python3", "-I", root.installer, "install", "kdeconnect", "--everything"]
        stdout: SplitParser {
            onRead: line => {
                let j = null;
                try { j = JSON.parse(line); } catch (e) { return; }
                if (j.progress !== undefined) {
                    root.setupProgress = j.progress;
                    root.setupPhase = j.phase;
                }
                if (j.result !== undefined)
                    root.setupResult = j.result;
            }
        }
        onExited: code => {
            if (root.setupResult === "ok") {
                // continue straight into pairing: the daemon starts now, as it does at every sign-in
                root.setupPhase = "Starting";
                startProc.running = true;
            } else {
                // "update" cannot be answered here (the system is brought up to date in the same step): a plain failure
                const r = root.setupResult;
                root.setup = ["cancelled", "denied", "offline", "space", "busy"].includes(r) ? r : "failed";
            }
        }
    }
    Process {
        id: startProc
        command: ["python3", "-I", root.script, "start"]
        onExited: code => {
            // a daemon that did not answer leaves the page's own sentence (it starts at sign-in)
            root.setup = "";
            root.read();
        }
    }

    // ------------------------------------------------------------------ answering the phone
    // Connect (and send what was waiting: the waiting files go as soon as the phone is connected and reachable)
    function connect() {
        if (root.asking)
            root.run(["accept", root.asking.id]);
    }
    function notNow() {
        if (root.asking)
            root.run(["decline", root.asking.id]);
    }
    function forget() {
        if (root.phone)
            root.run(["forget", root.phone.id]);
    }

    // ------------------------------------------------------------------ the code on the connect page
    property var qrRows: []
    Process {
        id: qrProc
        command: ["python3", "-I", root.script, "qr", root.appPage]
        stdout: StdioCollector {
            onStreamFinished: root.qrRows = text.split("\n").filter(l => l.length > 0)
        }
    }
    function ensureCode() {
        if (root.qrRows.length === 0 && !qrProc.running)
            qrProc.running = true;
    }

    // ------------------------------------------------------------------ sending
    // { n, path, name, state: "waiting" | "queued" | "sending" | "sent" | "failed" }, newest first
    property var sends: []
    property int counter: 0
    readonly property var waiting: root.sends.filter(s => s.state === "waiting")

    function patch(n, fields) {
        root.sends = root.sends.map(s => s.n === n ? Object.assign({}, s, fields) : s);
    }

    // Files to the phone. Connected: they go. Not yet: they wait, and the phone's page opens to connect it.
    function send(paths) {
        // without the part that talks to phones nothing can wait for one: the page says why
        if (!root.usable) {
            root.pageRequested();
            return;
        }
        root.batches = root.batches.concat([paths]);
        root.checkNext();
    }
    // only files can go: a folder or a missing path is left out before it becomes a row
    property var batches: []
    function checkNext() {
        if (checkProc.running || root.batches.length === 0)
            return;
        checkProc.command = ["python3", "-I", root.script, "files"].concat(root.batches[0]);
        root.batches = root.batches.slice(1);
        checkProc.running = true;
    }
    function add(paths) {
        const rows = [];
        for (const p of paths) {
            root.counter++;
            rows.push({ "n": root.counter, "path": p, "name": p.split("/").pop(), "state": root.paired ? "queued" : "waiting" });
        }
        if (rows.length === 0)
            return;
        root.sends = rows.reverse().concat(root.sends).slice(0, 30);
        if (!root.paired)
            root.pageRequested();
        root.pump();
    }
    Process {
        id: checkProc
        stdout: StdioCollector {
            onStreamFinished: root.add(text.split("\n").filter(l => l.length > 0))
        }
        onExited: root.checkNext()
    }
    function retry(n) {
        root.patch(n, { "state": root.paired ? "queued" : "waiting" });
        if (!root.paired)
            root.pageRequested();
        root.pump();
    }
    function clearDone() {
        root.sends = root.sends.filter(s => s.state === "waiting" || s.state === "queued" || s.state === "sending");
    }

    // Waiting files become queued when the phone is there; the next queued one is handed over.
    property int current: 0
    property string sentTo: ""   // the phone this send went to, even if it is forgotten meanwhile
    function pump() {
        if (root.paired && root.sends.some(s => s.state === "waiting"))
            root.sends = root.sends.map(s => s.state === "waiting" ? Object.assign({}, s, { "state": "queued" }) : s);
        if (sendProc.running)
            return;
        const queued = root.sends.filter(s => s.state === "queued");
        if (queued.length === 0 || !root.paired)
            return;
        const s = queued[queued.length - 1];   // oldest first
        root.current = s.n;
        root.sentTo = root.phoneName;
        root.patch(s.n, { "state": "sending" });
        IslandController.startActivity(`Sending to ${root.phoneName}`, s.name, true);
        sendProc.command = ["python3", "-I", root.script, "send", root.phoneId, s.path];
        sendProc.running = true;
    }
    Process {
        id: sendProc
        onExited: code => {
            const s = root.sends.find(x => x.n === root.current);
            const ok = code === 0;
            root.patch(root.current, { "state": ok ? "sent" : "failed" });
            if (ok)
                IslandController.endActivity("ok", `Sent to ${root.sentTo} · ${s?.name ?? ""}`);
            else
                IslandController.endActivity("fail", `Not sent to ${root.sentTo}`);
            root.pump();
        }
    }
}
