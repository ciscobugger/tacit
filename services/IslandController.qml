pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Services.Mpris

/**
 * State machine behind the quiet notch.
 * The notch rests as one 34px header (art if playing, time, one status glyph). Long-lived things
 * (media, a running timer) never take a row of their own: they live in the header's slots.
 * Peeks (volume, battery, a new track...) hold for a while in the header, width only, then
 * resolve back. Only a click grows the notch down (IslandContent owns that). Everything here is
 * driven by other services' change signals - the timers are the hold timer, the pause decay and
 * the one-shot startup timer.
 */
Singleton {
    id: root

    readonly property bool enabled: Config.options.island.enable
    readonly property bool suppressed: GlobalStates.screenLocked || GlobalStates.sessionOpen

    // ------------------------------------------------------------------ header slots
    readonly property bool focusRunning: Config.options.island.states.focus
        && (TimerService.pomodoroRunning || TimerService.countdownRunning)
    // Media wings (art left, spectrum right) while playing. Paused: the wings stay 3s, dimmed,
    // then fold - boring.notch's waitInterval (Constants.swift:129, MusicManager.swift:546).
    // Playing again brings them straight back.
    // "Present" is not "an MPRIS player exists": browsers keep a dead player around after the
    // tab is closed (Zen: Paused, position 0, no length - indistinguishable from a paused
    // video, so position cannot be the signal). A player counts while it plays, and for
    // media.keepPausedMinutes after a pause - the video you will resume. Stopped, or paused
    // longer than that, and the sheet says "Nothing playing" until something plays again.
    readonly property bool playerAlive: {
        const p = MprisController.activePlayer;
        if (!p)
            return false;
        if (p.isPlaying)
            return true;
        if (p.playbackState === MprisPlaybackState.Stopped)
            return false;
        return Config.options.island.media.keepWhenPaused && !root.pauseStale;
    }
    readonly property bool mediaPresent: Config.options.island.media.enable && root.playerAlive
    // Starts from the real state: a player merely paused when the shell comes up is not
    // "present"; one already playing is (no change signal ever fires for the initial state).
    // Assigned once, not bound: a binding would re-evaluate on every pause and skip the grace.
    property bool pauseStale: true
    Component.onCompleted: {
        root.pauseStale = !MprisController.isPlaying;
        // the updates the notch offers (Updates.qml): a singleton starts when something names it
        Updates.load();
        // the layout at start is not a switch: without this the first dictation after a reload peeked "English (UK)"
        const layout = HyprlandXkb.currentLayoutName ?? "";
        if (layout.toLowerCase() !== "error")
            root.lastLayout = layout;
    }
    Timer {
        id: pauseStaleTimer
        interval: Math.max(1, Config.options.island.media.keepPausedMinutes) * 60000
        repeat: false
        running: MprisController.activePlayer !== null && !MprisController.isPlaying
        onTriggered: root.pauseStale = true
    }
    Connections {
        target: MprisController
        function onIsPlayingChanged() {
            if (MprisController.isPlaying)
                root.pauseStale = false;
        }
        function onActivePlayerChanged() {
            root.pauseStale = !MprisController.isPlaying;
        }
    }
    // Starts expired: a player that is merely paused when the shell comes up gets no wings.
    property bool pausedExpired: true
    readonly property bool mediaVisible: mediaPresent && (MprisController.isPlaying || !pausedExpired)
    Timer {
        id: pauseDecay
        interval: 3000
        repeat: false
        running: root.mediaPresent && !MprisController.isPlaying
        onTriggered: root.pausedExpired = true
    }
    Connections {
        target: MprisController
        function onIsPlayingChanged() {
            if (MprisController.isPlaying)
                root.pausedExpired = false;
        }
        // A player appearing mid-song: announce it like a track change.
        function onActivePlayerChanged() {
            if (MprisController.isPlaying)
                root.requestTrack();
        }
    }

    // ------------------------------------------------------------------ transient state
    property string transientState: ""
    property int transientPriority: -1
    property var payload: ({})
    property var queue: []
    property bool warmedUp: false // services settle noisily on startup; ignore that first burst

    readonly property string currentState: transientState !== "" ? transientState : "idle"
    readonly property bool transientShowing: transientState !== ""

    function holdFor(name) {
        const hold = Config.options.island.hold;
        switch (name) {
        case "greeting":
        case "reload":
            return hold.greeting;
        case "battery":
            return hold.battery;
        case "timerDone":
            return hold.timerDone;
        case "charger":
            return hold.power;
        case "volume":
        case "brightness":
            return hold.meter;
        case "notification":
            return hold.notification;
        case "network":
            return hold.network;
        case "workspace":
            return hold.workspace;
        case "activity":
            return hold.activity;
        case "activityDone":
            return hold.activityDone;
        case "activityFail":
            return hold.activityFail;
        case "track":
        case "session":
            return 3000;
        case "brief":
            return 4000;
        case "copied":
            return 1200;
        case "claudeAsk":   // it waits for its answer (0: no hold timer); answered anywhere, Claude.qml takes it down
            return 0;
        case "signedIn":    // the sign-in's breath out
            return 2600;
        case "flow":        // Flow listening or writing: it stays until flowd says it is done
            return 120000;
        case "flowNote":    // what Flow could not do: a line to read, not a flash
        case "note":        // another program's line (island note): read, not flashed
            return 4000;
        case "disk":
        case "pr":
            return 4000;
        case "memory":
            return 6000;
        case "notAnswering":    // it waits for an answer; the wrapper ends it when the app answers again
            return 3600000;
        case "wallpaper":
            return 7000;
        case "update":      // said once: it stays long enough to answer
            return 15000;
        case "updated":     // its What's new is there to be pressed
            return 10000;
        case "recordSaved":
            return 2600;
        case "window":      // the window band (WindowBand.qml): each line brings its own hold
            return root.payload?.hold ?? 4000;
        case "download":
            return hold.download;
        case "layout":
            return 1500;
        case "chargerFault":
            return 5000;
        }
        return 2000;
    }

    /**
     * Ask the island to show a transient state. Incoming priority >= current preempts. Incoming
     * lower QUEUES (FIFO, oldest dropped) unless it is noise that is stale by the time its turn
     * comes - a meter or a workspace numeral - which is dropped. A download or a battery warning
     * arriving during a volume peek used to be lost entirely.
     * Re-firing the state that is already showing restarts the hold without a morph.
     */
    function request(name, data, priority) {
        if (!root.enabled || root.suppressed)
            return;
        if (!root.warmedUp && name !== "greeting")
            return;
        // the sign-in holds the sheet: a notification and an agent's ask wait until it folds (signinHeldBack)
        if (root.signinHeldBack(name)) {
            root.enqueue(name, data, priority);
            return;
        }
        if (root.transientShowing && root.transientState === name) {
            // Three notifications arriving together are three things to read: each one waits
            // its turn instead of overwriting the text of the one on screen. Every other
            // state is a value that has moved on, so re-firing it just refreshes the pill.
            if (name === "notification") {
                root.enqueue(name, data, priority);
                return;
            }
            root.payload = data ?? ({});
            if (root.holdFor(name) > 0)
                holdTimer.restart();
            return;
        }
        // an agent's ask waits for its answer; a volume or brightness key still shows over it, and the ask comes back
        // first when that has gone
        if (root.transientShowing && root.transientState === "claudeAsk" && (name === "volume" || name === "brightness")) {
            root.queue = [{ "name": "claudeAsk", "data": root.payload, "priority": root.transientPriority }]
                .concat(root.queue.filter(q => q.name !== "claudeAsk"));
            root.activate(name, data, priority);
            return;
        }
        if (root.transientShowing && priority < root.transientPriority) {
            if (name === "volume" || name === "brightness" || name === "workspace")
                return;
            root.enqueue(name, data, priority);
            return;
        }
        root.activate(name, data, priority);
    }

    function enqueue(name, data, priority) {
        const depth = Config.options.island.notificationQueueDepth;
        let queued = root.queue.slice().filter(q => q.name !== name || name === "notification");
        queued.push({
            "name": name,
            "data": data ?? ({}),
            "priority": priority,
            "at": Date.now()
        });
        while (queued.length > depth)
            queued.shift();
        root.queue = queued;
    }

    function activate(name, data, priority) {
        root.transientState = name;
        root.transientPriority = priority;
        root.payload = data ?? ({});
        const hold = root.holdFor(name);
        holdTimer.interval = Math.max(1, hold);
        if (hold > 0)
            holdTimer.restart();
        else
            holdTimer.stop();
    }

    /** Hold expiry, or a click on the island. Queued peeks morph in directly: peeks are width
     *  changes now, and a visit to rest between two of them would be shrink-grow-shrink-grow. */
    function dismiss() {
        holdTimer.stop();
        root.transientState = "";
        root.transientPriority = -1;
        // a peek is news of a moment: one that waited more than 10 s (behind an ask, say) goes rather than arriving
        // late; an ask, a notification and an update's lines wait their turn (said once: "Updated to Tacit 1.0.1" waited
        // behind the greeting at a start and was dropped unseen, VM 2026-10-20)
        const now = Date.now();
        const waits = q => q.name === "claudeAsk" || q.name === "notification" || q.name === "update" || q.name === "updated";
        if (root.queue.some(q => !waits(q) && q.at > 0 && now - q.at > 10000))
            root.queue = root.queue.filter(q => waits(q) || !(q.at > 0) || now - q.at <= 10000);
        const at = root.queue.findIndex(q => !root.signinHeldBack(q.name));
        if (at >= 0) {
            let queued = root.queue.slice();
            const next = queued.splice(at, 1)[0];
            root.queue = queued;
            root.activate(next.name, next.data, next.priority);
        }
    }

    /** The source of a queued state has ended (a job finished, dictation stopped): drop it,
     *  or dismiss() replays it later with a full hold - a progress pill for a job that is over,
     *  "Listening" at an idle Flow. Also clears it from the pill when it is the one showing. */
    function cancelState(name) {
        const queued = root.queue.filter(q => q.name !== name);
        if (queued.length !== root.queue.length)
            root.queue = queued;
        if (root.transientShowing && root.transientState === name)
            root.dismiss();
    }

    Timer {
        id: holdTimer
        repeat: false
        onTriggered: root.dismiss()
    }

    // Flow's own show() only ever dismisses the pill it is looking at, so a "Listening" peek
    // parked behind a higher-priority one outlives the dictation it describes.
    Connections {
        target: Dictation
        function onActiveChanged() {
            if (!Dictation.active)
                root.cancelState("flow");
        }
    }

    onSuppressedChanged: {
        if (!root.suppressed) {
            if (root.signinPhase === "waiting" && root.signinAside === "lock")
                signinUnlocked.restart();
            return;
        }
        root.queue = [];
        root.textDragOver = false;
        // The island window is destroyed while suppressed (locked), so IslandContent's
        // onOpenChanged - the only place that clears this - can never run. Left true, the
        // layer asks the compositor for Exclusive keyboard focus on the next map while
        // showing the resting pill, and the whole session loses the keyboard.
        root.keyboard = false;
        root.addressOut = false;
        root.dismiss();
        // the island's window goes with the lock: the page goes now, the sign-in waits and comes back after it
        if (root.signinPhase === "open") {
            root.signinSend({ "op": "unmap" });
            root.signinWait("lock");
        }
    }

    // ------------------------------------------------------------------ geometry per state
    // boring.notch keeps the camera in the middle and puts everything in WINGS either side of
    // it (ContentView.swift computedChinWidth, InlineHUD.swift). Our camera is the time: it
    // never leaves the centre, and every state is a pair of equal wings around it. The
    // container morphs to these numbers the moment the state changes; content lands into the
    // shape afterwards, so nothing here may depend on the loaded content's size.
    // 116 fits the clock's "00:00"; a 12-hour format ("10:33 AM") widens the middle by what its time needs more, or
    // the wings land on it (Discord 2026-10-21: "AM" over the volume bar)
    readonly property real centreWidth: 116 + Math.max(0, root.clockWidth - Math.ceil(clock24.advanceWidth)) + (root.ambientGlyph !== "" ? 30 : 0)
    // The clock's box (StripClock): the widest time the format shows, digits as 0 (tabular), so nothing moves as the
    // minutes change. 10:58 gives two hour digits in every format, and AM, the wider of AM and PM.
    readonly property string clockSample: Qt.locale().toString(new Date(2000, 0, 1, 10, 58), Config.options?.time.format ?? "hh:mm").replace(/[0-9]/g, "0")
    readonly property real clockWidth: Math.ceil(clockWide.advanceWidth)
    TextMetrics {
        id: clockWide
        font.family: Appearance.font.family.numbers
        font.pixelSize: 16
        font.variableAxes: ({ "wght": 500 })
        font.features: ({ "tnum": 1 })
        text: root.clockSample
    }
    TextMetrics {
        id: clock24
        font: clockWide.font
        text: "00:00"
    }

    // Wings are always symmetric around the clock, which never moves (boring.notch HUD: icon
    // left, value right). A running timer at rest: glyph left, time left right (48); with
    // media showing too, art left and "⏱ 4:59" right (64). One-sided growth and a sliding
    // clock were both tried and rejected as "growing to the right".
    // The widths fit the wing text one step up (2026-10-01: 14 -> 15 px, about 7 % wider).
    function wingFor(name) {
        switch (name) {
        case "idle":
            if (root.focusRunning)
                return root.mediaVisible ? 68 : 52;
            if (root.mediaVisible)
                return 32;
            // a working session at rest: its name left, what it is doing right
            if (AgentSessions.active !== null)
                return 128;
            return 0;
        case "open":
            return 140;
        case "volume":
        case "brightness":
            return 108;
        case "track":
        case "session":
            return 140;
        case "activity":
            return 150;
        case "greeting":
        case "reload":
            return 118;
        case "brief":
            return 182;
        case "workspace":
            return 40;
        case "notification":
        case "pr":
        case "wallpaper":
            return 172;
        case "claudeAsk":
        case "update":      // Tonight and Restart
        case "updated":
            return 204;
        case "window":      // with its Reopen, Show or Undo; the hint is words alone
            return root.payload?.pill ? 204 : 182;
        case "flow":
            return 160;
        case "download":
        case "memory":
            return 150;
        case "signin":
        case "signinPeek":
            // the sign-in's sheet is as wide as its page; its header breathes in at that width first
            return (root.signinSheetWidth - root.centreWidth) / 2;
        case "signinWait":
        case "signedIn":
            return 160;
        }
        // battery, charger, timerDone, network, activityDone, activityFail ("Plugged in, not charging" whole)
        return 140;
    }

    // Set by IslandContent while text (a sentence, a link) is dragged over the notch.
    property bool textDragOver: false

    // the sand layer is up (IslandContent): Flow takes the film's notch, the sand behind the time, no words
    property bool sandReady: false

    function geometryFor(name) {
        // Flow with the sand: the approved film's notch, 150 x 40 with its 17 px corners (sandwind.py's tank)
        if (name === "flow" && root.sandReady)
            return { "w": 150, "h": 40, "r": 17, "f": 6 };
        if (name === "open")
            // boring.notch openNotchSize 640x190 with radii 19/24 (sizing/matters.swift:16-18);
            // ours is scaled to the sheet's contents. The cove stays 6 when open: against this
            // wallpaper's black top band a 19px cove read as a bite out of the corners.
            // Nothing playing: a one-line sheet, not 150px of "Nothing playing".
            // A running timer adds its own row. (A quick-start row was tried and rejected:
            // "feels useless, waste"; the sheet's floor stays for things that are happening.)
            // Rows and no player: the "nothing playing" line goes; the rows ARE the sheet.
            // Text being dragged over it keeps the 72px floor: the sheet's "drop to hand this
            // over" line is centred in that body, and in the 12px the rows leave it lands on
            // top of the header seam and the first row instead.
            return { "w": 560, "h": (root.mediaPresent ? 150 : ((root.openRowsHeight > 0 && !root.textDragOver) ? 12 : 72)) + (root.focusRunning ? 36 : 0) + root.openRowsHeight, "r": 24, "f": 6 };
        // an app not answering: the prompt drops out of the notch (Activity v7 mock, state 09)
        if (name === "notAnswering")
            return { "w": 520, "h": 34, "r": 24, "f": 6 };
        return { "w": root.centreWidth + 2 * root.wingFor(name), "h": 34, "r": 14, "f": 6 };
    }

    // ------------------------------------------------------------------ colour
    // "neutral" is the resting body; transients may still name a tone (success, error, notify).
    readonly property string tone: root.transientShowing ? (root.payload?.tone ?? "neutral") : "neutral"
    // Hard rule: no heavy colours. The body is ALWAYS the frost (translucent surfaceContainer over the compositor blur,
    // custom/rules.lua:17; the darker 88 % glass was tried 2026-10-15 and the frost kept, "felt more Praxis"), and since
    // 2026-10-15 no tone colours words: the point in the main ink, the rest in meta.
    readonly property color bodyColor: Appearance.colors.colPanelFrost
    readonly property color contentColor: Tacit.inkMain
    readonly property color subtextColor: Tacit.inkMeta

    // ------------------------------------------------------------------ ambient glyph (idle)
    // Quickshell's Privacy service reports mic activity as an always-truthy array, so read the
    // Pipewire link groups here instead.
    // Only APPS count. PipeWire's own echo-cancel module keeps a capture stream linked to the
    // mic permanently (echo-cancel-capture -> book4_mic_aec), which lit the mic glyph all day
    // with nobody listening.
    readonly property bool micLive: Pipewire.linkGroups.values.some(group =>
        group.source?.type === PwNodeType.AudioSource
        && group.target?.type === PwNodeType.AudioInStream
        && !/^(echo-cancel|filter-chain|book4_mic_aec)/.test(group.target?.name ?? ""))
    // ------------------------------------------------------------------ screen recording
    // Super+Shift+R opens the sheet's choice (states/IslandRecord.qml): the whole screen, an area or a window, and the
    // sound. While it records, the time stands where the clock was (IslandHeader) and a click or the key again stops
    // it; then the sheet shows it on a card and the file waits on the shelf. scripts/videos/record.sh records and
    // writes the state read here (Persistent.states.record). Approved mock: ~/dev/tacit-site/mocks/record/.
    readonly property bool recording: Persistent.states.record.enable
    property real recordNow: Date.now()
    Timer {
        running: root.recording
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.recordNow = Date.now()
    }
    function clockText(ms) {
        const s = Math.max(0, Math.floor(ms / 1000));
        const mm = Math.floor(s / 60) % 60, ss = String(s % 60).padStart(2, "0");
        return s >= 3600 ? `${Math.floor(s / 3600)}:${String(mm).padStart(2, "0")}:${ss}` : `${mm}:${ss}`;
    }
    readonly property string recordElapsed: root.clockText(root.recordNow - Persistent.states.record.started)
    // the last recording, for its card: how long it ran
    readonly property string recordLength: root.clockText(Persistent.states.record.stopped - Persistent.states.record.started)
    signal recordRequested()
    signal recordSaved()
    function openRecord() {
        if (root.recording) {
            root.stopRecording();
            return;
        }
        // no notch to ask in: the area picker, as before
        if (!root.enabled || root.suppressed) {
            GlobalStates.recordPick = "area";
            return;
        }
        root.keyboardScreen = Hyprland.focusedMonitor?.name ?? "";
        root.keyboard = true;
        root.recordRequested();
    }
    // from the palette's row or the control panel's pill: once their window has gone, so the sheet gets the keyboard
    function openRecordSoon() {
        recordOpenLater.restart();
    }
    Timer {
        id: recordOpenLater
        interval: 300
        onTriggered: root.openRecord()
    }
    // the sheet's choice, once the sheet has folded out of the picture (the area picker freezes the screen as it
    // opens); the whole screen is the notch's screen
    property string recordWhat: ""
    property string recordScreen: ""
    // from the choice until it records: the sheet does not open under the pointer left on the notch (IslandContent),
    // or the whole screen's recording starts with the shelf in it
    property bool recordArming: false
    function chooseRecord(what, screenName) {
        Persistent.states.record.last = what;
        root.recordWhat = what;
        root.recordScreen = screenName;
        root.recordArming = true;
        armingEnd.restart();
        recordLater.restart();
    }
    Timer {
        id: armingEnd
        interval: 5000
        onTriggered: root.recordArming = false
    }
    Timer {
        id: recordLater
        interval: 450
        onTriggered: {
            if (root.recordWhat === "screen")
                root.startRecording(["--fullscreen"].concat(root.recordScreen !== "" ? ["--output", root.recordScreen] : []));
            else
                GlobalStates.recordPick = root.recordWhat;
        }
    }
    // where: ["--region", "x,y wxh"] (logical, global) or ["--fullscreen", ...]
    function startRecording(where) {
        const s = Persistent.states.record.sound;
        Quickshell.execDetached([Directories.recordScriptPath].concat(where, s === "system" ? ["--sound"] : s === "mic" ? ["--mic"] : []));
    }
    function stopRecording() {
        Quickshell.execDetached([Directories.recordScriptPath, "--stop"]);
    }
    onRecordingChanged: {
        root.recordArming = false;
        const file = Persistent.states.record.file;
        if (root.recording || file === "")
            return;
        DropShelf.addItems(["file://" + file]);
        root.recordSaved();
    }
    // A running timer is a status glyph; the hover strip carries its remaining time and controls.
    readonly property bool timerAmbient: TimerService.pomodoroRunning || TimerService.countdownRunning
    readonly property string ambientGlyph: {
        // The charger is plugged in but the EC is not charging: this machine's known fault
        // (see memory book4-charging). Red, and first - it costs a battery.
        if (root.chargerFault)
            return "battery_alert";
        if (root.micLive)
            return "mic";
        // An agent session is waiting on you (permission or a question).
        if (AgentSessions.waiting || Claude.waiting)
            return "back_hand";
        // A pull request waits on your review.
        if (root.prReviews.length > 0)
            return "rate_review";
        // A session just finished: a tick for a few seconds.
        if (AgentSessions.justDone)
            return "check";
        if (Notifications.silent)
            return "notifications_off";
        if (Battery.available && Battery.isCharging)
            return "bolt";
        if (root.activityAmbient)
            return "progress_activity";
        // Disk nearly full: red, like the charger fault - it costs you something.
        if (root.diskPct >= 95)
            return "hard_drive";
        // Memory full: red too, until it clears; Activity says what holds it.
        if (root.memoryFull)
            return "memory";
        // Session pulse: an agent is working. Read "busy" from across the room.
        if (AgentSessions.sessions.some(s => s.state === "working"))
            return "progress_activity";
        // A running timer is not a glyph: the idle right wing carries its time left.
        // Things switched on and easy to forget: caffeine, a headset as output.
        if (Vpn.connected)
            return "vpn_key";
        if (Idle.inhibit)
            return "coffee";
        if (((Audio.sink?.name ?? "") + "").startsWith("bluez"))
            return "headphones";
        // Files parked on the shelf: the notch says so at rest, no tab needed.
        if (DropShelf.items.length > 0)
            return "stacks";
        if (Notifications.unread > 0)
            return "circle";
        // Uncommitted work sitting for over an hour: a reminder, so it ranks with night light.
        if (root.workUnsaved)
            return "commit";
        // Night light is on a schedule, so it ranks last: a reminder, not an alert.
        if (Hyprsunset.temperatureActive)
            return "bedtime";
        return "";
    }

    // ------------------------------------------------------------------ voice
    function greetingLine() {
        const name = (Config.options.island.greeting.name || Config.options.profile.displayName || "").trim();
        const hour = DateTime.hour24;
        let line;
        if (hour < 5)
            line = "Still up";
        else if (hour < 12)
            line = "Morning";
        else if (hour < 17)
            line = "Afternoon";
        else if (hour < 21)
            line = "Evening";
        else
            line = "Late one";
        return name.length > 0 ? `${line}, ${name}.` : `${line}.`;
    }

    function batteryPercent() {
        return Math.round(Battery.percentage * 100);
    }

    // ------------------------------------------------------------------ startup
    // Set by ReloadPopup when this shell came from a reload: the first word is then the reload's,
    // not a greeting (it used to greet on every reload).
    property bool afterReload: false
    function noteReload() {
        root.afterReload = true;
    }

    Timer {
        id: startupTimer
        interval: 900
        repeat: false
        running: root.enabled
        onTriggered: {
            root.warmedUp = true;
            root.lastWifiConnected = Network.wifiStatus === "connected";
            if (root.afterReload && !root.suppressed) {
                root.request("reload", {}, 100);
                root.requestBrief(root.briefParts(), 90);
            } else if (Config.options.island.greeting.enable && !root.suppressed) {
                root.request("greeting", {
                    "text": root.greetingLine()
                }, 100);
                // The restart brief queues behind the greeting: a second beat, not a longer line.
                root.requestBrief(root.briefParts(), 90);
            }
        }
    }

    // ------------------------------------------------------------------ charger fault
    // The EC reports the adapter (raw_flags bit 2) independently of whether it charges. On this
    // machine charging dies silently mid-session; the flags are the only honest signal. Three
    // consecutive 10s polls of "adapter present, not charging" = a fault: one peek, and a red
    // glyph at rest until charging resumes.
    // The two paths are this machine's EC. Anywhere else they do not exist, and the loop leaves
    // rather than poll two missing files for the whole session.
    property bool chargerFault: false
    property int chargerFaultPolls: 0
    Process {
        id: chargerWatch
        running: root.enabled && Config.options.island.states.power
        command: ["bash", "-c", `f=/sys/bus/i2c/devices/3-0062/raw_flags; s=/sys/class/power_supply/book4-ec-battery/status; [ -r "$f" ] && [ -r "$s" ] || exit 0; while :; do echo "$(cat "$f" 2>/dev/null) $(cat "$s" 2>/dev/null)"; sleep 10; done`]
        stdout: SplitParser {
            onRead: line => root.onChargerPoll(line.trim())
        }
    }

    function onChargerPoll(line) {
        const parts = line.split(" ");
        // Two fields, and the first must be the EC's hex word: a missing sysfs file yields
        // "Discharging" alone, and parseInt("Discharging", 16) is 13 (a phantom adapter bit).
        if (parts.length !== 2 || !/^0x[0-9a-f]+$/i.test(parts[0]))
            return;
        const flags = parseInt(parts[0], 16);
        const status = parts[1];
        const adapter = (flags & 0x04) !== 0;
        const faulty = adapter && status !== "Charging" && status !== "Full";
        if (!faulty) {
            root.chargerFaultPolls = 0;
            root.chargerFault = false;
            return;
        }
        root.chargerFaultPolls += 1;
        if (root.chargerFaultPolls < 3 || root.chargerFault)
            return;
        root.chargerFault = true;
        root.request("chargerFault", {
            "icon": "battery_alert",
            "text": "Plugged in, not charging",
            "value": `${root.batteryPercent()}%`,
            "tone": "error"
        }, 85);
    }

    // ------------------------------------------------------------------ notices
    // Battery and timer events are told once: by the notch when it can show them, otherwise by one
    // plain notification. Battery.qml and TimerService.qml are also loaded by the login lock, so
    // the notices and their chimes are sent here, by the shell only. Locked, the notice skips the
    // transient hint and waits in the notification centre.
    readonly property bool canShowPower: root.enabled && !root.suppressed && Config.options.island.states.power
        && !GlobalStates.screenLocked && !GlobalStates.sessionOpen
    readonly property bool canShowFocus: root.enabled && !root.suppressed && Config.options.island.states.focus
        && !GlobalStates.screenLocked && !GlobalStates.sessionOpen

    function notice(summary, body, urgent) {
        const args = ["notify-send", summary, body, "-a", "Tacit"];
        if (urgent)
            args.push("-u", "critical");
        if (!GlobalStates.screenLocked)
            args.push("--hint=int:transient:1");
        Quickshell.execDetached(args);
    }
    function chime(name, on) {
        if (on)
            Audio.playSystemSound(name);
    }

    // ------------------------------------------------------------------ battery and charger
    Connections {
        target: Battery

        function onIsLowAndNotChargingChanged() {
            if (Battery.available && Battery.isLowAndNotCharging) lowHeld.restart(); else lowHeld.stop();
        }

        function onIsCriticalAndNotChargingChanged() {
            if (Battery.available && Battery.isCriticalAndNotCharging) criticalHeld.restart(); else criticalHeld.stop();
        }

        function onIsPluggedInChanged() {
            if (!Battery.available)
                return;
            root.chime(Battery.isPluggedIn ? "power-plug" : "power-unplug", Config.options.sounds.battery);
            if (!root.canShowPower)
                return;
            root.request("charger", {
                "icon": Battery.isPluggedIn ? "bolt" : "power_off",
                // isPluggedIn means on AC, which is not the same as taking charge: the pack
                // balancing or tapering draws nothing and the percentage does not move.
                "text": Battery.isPluggedIn ? (Battery.isCharging ? "Charging." : "Plugged in.") : "On battery.",
                "value": `${root.batteryPercent()}%`,
                "tone": Battery.isPluggedIn ? "success" : "neutral",
                "spring": Battery.isPluggedIn
            }, 80);
        }

        function onIsFullAndChargingChanged() {
            if (!Battery.available || !Battery.isFullAndCharging)
                return;
            root.chime("complete", Config.options.sounds.battery);
            if (root.canShowPower)
                root.request("charger", {
                    "icon": "bolt",
                    "text": "Full. You can unplug.",
                    "tone": "success",
                    "spring": true
                }, 80);
            else
                root.notice("Battery full", "You can unplug the charger.", false);
        }
    }

    // A low reading is announced once it has held for 5 s: for about a second after a wake the EC driver has no
    // reading yet and UPower says 0%, and every wake sent "Low battery" and "Battery critically low" at 0% (2026-10-09).
    Timer {
        id: lowHeld
        interval: 5000
        onTriggered: {
            if (!Battery.available || !Battery.isLowAndNotCharging)
                return;
            root.chime("dialog-warning", Config.options.sounds.battery);
            if (root.canShowPower)
                root.requestBattery();
            else
                root.notice("Low battery", `${root.batteryPercent()}% left. Plug in soon.`, true);
        }
    }
    Timer {
        id: criticalHeld
        interval: 5000
        onTriggered: {
            if (!Battery.available || !Battery.isCriticalAndNotCharging)
                return;
            root.chime("suspend-error", Config.options.sounds.battery);
            if (root.canShowPower)
                root.requestBattery();
            else
                root.notice("Battery critically low", Config.options.battery.automaticSuspend
                    ? `${root.batteryPercent()}%. The laptop sleeps at ${Config.options.battery.suspend}%.`
                    : `${root.batteryPercent()}%. Plug in now.`, true);
        }
    }

    function requestBattery() {
        let line;
        if (Battery.isSuspendingAndNotCharging)
            line = `Suspending at ${Config.options.battery.suspend}%.`;
        else if (Battery.isCriticalAndNotCharging)
            line = `${root.batteryPercent()}%. Plug in.`;
        else
            line = `${root.batteryPercent()}%`;
        // the time left beside the percent when Battery has measured one
        const secs = Battery.timeToEmpty;
        const m = Math.round(secs / 60);
        const left = !(secs > 60) ? "left" : m >= 60 ? `about ${Math.floor(m / 60)} h ${m % 60} min` : `about ${m} min`;
        root.request("battery", {
            "icon": "battery_alert",
            "text": line,
            "value": line.endsWith("%") ? left : "",
            "tone": "error"
        }, 92);
    }

    // ------------------------------------------------------------------ timers
    property bool countdownWasRunning: false

    function timerEvent(peekText, summary, body) {
        root.chime("alarm-clock-elapsed", Config.options.sounds.pomodoro);
        if (root.canShowFocus)
            root.request("timerDone", {
                "icon": "check_circle",
                "text": peekText
            }, 88);
        else
            root.notice(summary, body, false);
    }

    Connections {
        target: TimerService

        function onPomodoroBreakChanged() {
            if (!TimerService.pomodoroRunning)
                return;
            // read before TimerService advances the cycle (TimerService.qml, refreshPomodoro)
            const longBreak = TimerService.pomodoroBreak && (TimerService.pomodoroCycle + 1 == TimerService.cyclesBeforeLongBreak);
            const minutes = Math.floor((longBreak ? TimerService.longBreakTime : TimerService.pomodoroBreak ? TimerService.breakTime : TimerService.focusTime) / 60);
            root.timerEvent(TimerService.pomodoroBreak ? "Focus done." : "Break's over.", "Pomodoro",
                TimerService.pomodoroBreak ? `${longBreak ? "Long break" : "Break"}: ${minutes} minutes.` : `Focus: ${minutes} minutes.`);
        }

        function onCountdownRunningChanged() {
            if (TimerService.countdownRunning) {
                root.countdownWasRunning = true;
                return;
            }
            if (root.countdownWasRunning && TimerService.countdownSecondsLeft <= 1)
                root.timerEvent("Timer done.", "Timer", "Your countdown finished.");
            root.countdownWasRunning = false;
        }
    }

    // ------------------------------------------------------------------ media
    // Click on the art: raise the player's window. MPRIS names the player, Hyprland names the
    // window class, and browsers disagree (Zen calls itself "firefox"), hence the table.
    function raisePlayer() {
        const p = MprisController.activePlayer;
        if (!p)
            return;
        // MPRIS Raise first: a browser switches to the TAB that is playing, which focusing the
        // window alone cannot do. Then the window, for players that ignore Raise.
        if (p.canRaise)
            p.raise();
        const key = ((p.desktopEntry || p.identity || "") + "").toLowerCase().split(/[ ._-]/)[0];
        const table = {
            "firefox": ["zen", "firefox", "librewolf", "floorp"],
            "chromium": ["chromium", "google-chrome", "brave-browser", "thorium-browser"],
            "chrome": ["google-chrome", "chromium"],
            "thyris": ["browser-cef", "browser"],   // Thyris's window is the engine's (Discord 2026-10-23)
            "opsis": ["browser-cef", "browser"]
        };
        const candidates = table[key] ?? [key];
        const win = (HyprlandData.windowList ?? []).find(w => candidates.includes((w.class ?? "").toLowerCase()));
        // This Hyprland is Lua-configured: dispatches are Lua calls on hl.dsp, the same form
        // services/HyprlandBackend.qml uses.
        if (win)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${win.address}" })`);
    }

    // A new track announces itself once: 3s of art, title and artist in the header, then back to
    // art only. Only while playing - scrubbing a paused queue is not news.
    Connections {
        target: MprisController.activePlayer
        enabled: root.enabled && Config.options.island.media.enable

        function onTrackTitleChanged() {
            root.requestTrack();
        }
    }

    function requestTrack() {
        const player = MprisController.activePlayer;
        if (!player || !MprisController.isPlaying)
            return;
        const title = (player.trackTitle ?? "").trim();
        if (title.length === 0)
            return;
        root.request("track", {
            "title": title,
            "artist": (player.trackArtist ?? "").trim(),
            "art": player.trackArtUrl ?? ""
        }, 45);
    }

    // ------------------------------------------------------------------ meters
    Connections {
        target: Audio.sink?.audio ?? null
        enabled: root.enabled && Config.options.island.states.volume

        function onVolumeChanged() {
            root.requestVolume();
        }

        function onMutedChanged() {
            root.requestVolume();
        }
    }

    function requestVolume() {
        if (!Audio.ready)
            return;
        // Body stays neutral even above 100%; the meter colours its numeral instead (section 3).
        root.request("volume", {
            "kind": "volume"
        }, 76);
    }

    Connections {
        target: Brightness
        enabled: root.enabled && Config.options.island.states.brightness

        function onBrightnessChanged() {
            root.request("brightness", {
                "kind": "brightness"
            }, 76);
        }
    }

    // Gamma (night light's dimming) is a brightness-family meter; the OSD used to show it.
    Connections {
        target: Hyprsunset
        enabled: root.enabled && Config.options.island.states.brightness
        function onGammaChangeAttempt() {
            root.request("brightness", {
                "kind": "gamma"
            }, 76);
        }
    }
    // The speaker protection tripping (an illegal or over-limit volume step) is a warning,
    // not a level: said in words, like a download or a session note.
    // Only while the notch shows volume; otherwise the OSD says it (OnScreenDisplay.qml).
    Connections {
        target: Audio
        enabled: root.enabled && Config.options.island.states.volume
        function onSinkProtectionTriggered(reason) {
            root.request("download", {
                "icon": "volume_off",
                "text": Translation.tr("Volume held back · %1").arg(reason)
            }, 80);
        }
    }

    // Brightness is per monitor; the island reads the focused one, like Brightness's own
    // increase/decreaseBrightness() do.
    readonly property real focusedBrightness: {
        const monitor = Brightness.monitors.find(m => m.screen?.name === Hyprland.focusedMonitor?.name);
        return monitor?.brightness ?? 0;
    }

    // ------------------------------------------------------------------ notifications
    Connections {
        target: Notifications
        enabled: root.enabled && Config.options.island.states.notification

        function onNotify(notification) {
            if (Notifications.popupInhibited)
                return;
            root.request("notification", {
                "summary": notification.summary ?? "",
                "body": notification.body ?? "",
                "appName": notification.appName ?? "",
                "appIcon": notification.appIcon ?? "",
                "image": notification.image ?? "",
                "urgency": notification.urgency ?? "1",
                // Notif.urgency is notification.urgency.toString(); "2" is Critical, the same
                // comparison NotificationGroup.qml makes.
                "tone": String(notification.urgency ?? "1") === "2" ? "notifyUrgent" : "notify"
            }, 60);
        }
    }

    // ------------------------------------------------------------------ radios
    property bool lastWifiConnected: false

    Connections {
        target: Network
        enabled: root.enabled && Config.options.island.states.network

        function onNetworkNameChanged() {
            root.requestNetwork();
        }

        function onWifiStatusChanged() {
            root.requestNetwork();
        }

        function onWifiEnabledChanged() {
            root.requestNetwork();
        }
    }

    function requestNetwork() {
        const connected = Network.wifiStatus === "connected";
        let line;
        let icon = Network.materialSymbol;
        if (Network.ethernet) {
            line = "Wired.";
            icon = "lan";
        } else if (!Network.wifiEnabled) {
            line = "Wi-Fi off.";
        } else if (connected) {
            line = Network.active?.ssid || Network.networkName;
            if (!line || line.length === 0)
                return;
        } else if (root.lastWifiConnected) {
            line = "Wi-Fi dropped.";
        } else {
            root.lastWifiConnected = connected;
            return;
        }
        root.lastWifiConnected = connected;
        root.request("network", {
            "icon": icon,
            "text": line
        }, 50);
    }

    // One device leaving while another stays does not move BluetoothStatus.connected, which is
    // devices.values.some(d => d.connected), so the set is watched instead: the addresses and
    // names of the last evaluation, diffed against this one. Seeded when this object is created,
    // because devices already connected then fire no change signal to seed from.
    property var connectedDeviceNames: ({})

    function syncBluetoothDevices() {
        const before = root.connectedDeviceNames;
        const live = BluetoothStatus.connectedDevices;
        let now = ({});
        for (let i = 0; i < live.length; i++)
            now[live[i].address] = ((live[i].name ?? "") + "").trim();
        root.connectedDeviceNames = now;
        if (!root.warmedUp)
            return;
        // A device BlueZ has not named yet cannot be announced; when the name arrives the set
        // is evaluated again, and this is where it gets its line.
        for (const addr in now) {
            if (now[addr].length === 0 || (addr in before && before[addr].length > 0))
                continue;
            root.request("network", {
                "icon": "bluetooth_connected",
                "text": `${now[addr]} connected.`
            }, 50);
        }
        // Switching the adapter off drops every link at once: that is the adapter's own line
        // below, not one per device over the top of it.
        if (!BluetoothStatus.enabled)
            return;
        for (const addr in before) {
            if (addr in now || before[addr].length === 0)
                continue;
            root.request("network", {
                "icon": "bluetooth_disabled",
                "text": `${before[addr]} disconnected.`
            }, 50);
        }
    }

    Connections {
        target: BluetoothStatus
        enabled: root.enabled && Config.options.island.states.network
        Component.onCompleted: root.syncBluetoothDevices()

        function onConnectedDevicesChanged() {
            root.syncBluetoothDevices();
        }

        // Both edges: switching Bluetooth on was the one toggle the notch never confirmed.
        function onEnabledChanged() {
            root.request("network", {
                "icon": BluetoothStatus.enabled ? "bluetooth" : "bluetooth_disabled",
                "text": BluetoothStatus.enabled ? "Bluetooth on." : "Bluetooth off."
            }, 50);
        }
    }

    // ------------------------------------------------------------------ collapse shortcut
    // CHANGES-island.md: Esc was never implemented because the island takes no keyboard focus.
    // A compositor global shortcut needs none. Hyprland binds Esc to `quickshell:islandCollapse`
    // (appid defaults to "quickshell", so the bare name below is the second half of it).
    // Registered here rather than in Island.qml so it registers exactly once and not once per
    // screen; IslandContent listens for the signal.
    signal collapseExpansion

    CompositorGlobalShortcut {
        name: "islandCollapse"
        description: "Folds the notch's hover strip and sheet back to the resting header"

        onPressed: root.collapseExpansion()
    }

    // ------------------------------------------------------------------ workspaces
    readonly property int focusedWorkspaceId: Hyprland.focusedWorkspace?.id ?? (HyprlandData.activeWorkspace?.id ?? 0)

    onFocusedWorkspaceIdChanged: {
        if (!Config.options.island.states.workspace || root.focusedWorkspaceId <= 0)
            return;
        root.request("workspace", {
            "number": root.focusedWorkspaceId
        }, 30);
    }

    // ------------------------------------------------------------------ downloads
    // boring.notch DownloadWatcher: a finished browser download is a live activity. Here a new
    // file in ~/Downloads is a 3s peek and is parked on the shelf, so it can be dragged straight
    // out of the notch. No inotify-tools on this machine: one bash loop, `find -newer` against a
    // stamp every two seconds. Partial files (.part, .crdownload, .tmp, dotfiles) are skipped;
    // browsers rename them into place, which is the moment the final name shows up.
    property var announcedDownloads: ({})

    // Screenshots land in the same watcher: screenSnip.savePath is the second folder.
    readonly property string screenshotDir: Config.options.screenSnip.savePath ?? ""

    Process {
        id: downloadWatch
        running: root.enabled && Config.options.island.states.download
        // the account's Downloads folder by its own name (xdg-user-dirs names it in the account's language: ~/Téléchargements)
        command: ["bash", "-c", `d='${StringUtils.shellSingleQuoteEscape(FileUtils.trimFileProtocol(Directories.downloads))}'; p='${StringUtils.shellSingleQuoteEscape(root.screenshotDir)}'; s=$(mktemp); n=$(mktemp); trap 'rm -f "$s" "$n"' EXIT; touch "$s"; while sleep 2; do touch "$n"; for dir in "$d" "$p"; do [ -n "$dir" ] && find "$dir" -maxdepth 1 -type f -newer "$s" ! -name '.*' ! -name '*.part' ! -name '*.crdownload' ! -name '*.tmp' -printf '%p\n' 2>/dev/null; done; find "$d" -maxdepth 1 -type f \\( -name '*.part' -o -name '*.crdownload' \\) -printf 'P\t%s\t%p\n' 2>/dev/null; mv -f "$n" "$s"; done`]
        stdout: SplitParser {
            onRead: line => {
                if (line.startsWith("P\t")) {   // a download still growing: name, size
                    const f = line.split("\t");
                    Jobs.sampleDownload(f[2].trim(), parseInt(f[1]));
                } else {
                    root.onDownloaded(line.trim());
                }
            }
        }
    }

    function onDownloaded(path) {
        if (path.length === 0)
            return;
        // A file still being written shows up every tick; announce each path once per minute.
        const now = Date.now();
        const seen = root.announcedDownloads[path] ?? 0;
        if (now - seen < 60000)
            return;
        let map = {};
        for (const k in root.announcedDownloads)	// keep only the last minute
            if (now - root.announcedDownloads[k] < 60000)
                map[k] = root.announcedDownloads[k];
        map[path] = now;
        root.announcedDownloads = map;
        const name = path.split("/").pop();
        const isShot = root.screenshotDir.length > 0 && path.startsWith(root.screenshotDir + "/");
        Origins.recordArrival(path, isShot);   // which page / window / phone it came from, now
        DropShelf.addItems(["file://" + path]);
        Recents.addFile(path, isShot);
        Journal.log(isShot ? "file.screenshot" : "file.download", { "path": path });
        root.request("download", {
            "icon": isShot ? "screenshot_monitor" : "download_done",
            "text": isShot ? "Screenshot" : name,
            "value": "on the shelf",
            "path": path   // a click on the peek opens it
        }, 55);
    }

    // ------------------------------------------------------------------ vpn
    Connections {
        target: Vpn
        function onImported(name) {
            root.request("download", { "icon": "vpn_key", "text": Translation.tr("Added VPN %1").arg(name) }, 55);
        }
        function onImportFailed(path, reason) {
            // not a VPN after all: it is a file, and files dropped here park on the shelf
            DropShelf.addItems(["file://" + path]);
            root.request("download", { "icon": "vpn_key_off", "text": Translation.tr("Not a VPN file · parked") }, 55);
        }
    }

    // ------------------------------------------------------------------ keyboard layout
    // The one OSD the notch did not cover: a layout switch peeks its name for 1.5s. Only a real switch: when Flow types
    // (wtype) a virtual keyboard comes in whose keymap has no layout name - Hyprland reports it as "error" - and then
    // the real layout comes back; the notch said "error | keyboard" after every dictation (2026-10-15).
    property string lastLayout: ""
    Connections {
        target: HyprlandXkb
        enabled: root.enabled

        function onCurrentLayoutNameChanged() {
            const name = HyprlandXkb.currentLayoutName;
            if (!name || name.toLowerCase() === "error" || name === root.lastLayout)
                return;
            root.lastLayout = name;
            root.request("layout", {
                "icon": "keyboard",
                "text": HyprlandXkb.currentLayoutName
            }, 40);
        }
    }

    // ------------------------------------------------------------------ live activities
    // A job that reports a start and never an end (a crashed script) must not spin forever:
    // thirty minutes without progress and it is dropped as failed.
    property real activityTouchedAt: 0
    Timer {
        running: root.activityAmbient || root.transientState === "activity"
        interval: 60000
        repeat: true
        onTriggered: {
            if (root.activityTouchedAt > 0 && Date.now() - root.activityTouchedAt > 1800000)
                root.endActivity("fail");
        }
    }
    // One entry point for any long job:
    //   qs -c tacit ipc call island start "Backup" "Copying home"
    //   qs -c tacit ipc call island progress 40
    //   qs -c tacit ipc call island end ok
    // The island shows one thing at a time, so it tracks one job at a time: a second start replaces
    // the first. The running state sits below every other transient and can never preempt one;
    // after island.hold.activity it demotes itself out of the pill into the ambient glyph slot and
    // keeps tracking there. Only a failure is allowed to interrupt.
    property string activityName: ""
    property string activityDescription: ""
    property int activityPercent: 0
    property bool activityRunning: false
    property bool activityDemoted: false

    // Set only by a click on the island, never by the demote timer: "not now" is a thing the
    // user said, so it outlives the job and swallows the completion pill too. A failure still
    // gets through - that is the one thing the design lets interrupt.
    property bool activityMuted: false

    // What the glyph slot reads: a job that has outlived its turn in the pill.
    readonly property bool activityAmbient: root.activityRunning && root.activityDemoted

    // indeterminate: no percent to show (Claude working): the shape turns instead of a bar
    function startActivity(name, description, indeterminate) {
        root.activityTouchedAt = Date.now();
        if (!root.enabled || !Config.options.island.states.activity)
            return;
        root.activityName = String(name ?? "").trim() || "Working";
        root.activityDescription = String(description ?? "").trim();
        root.activityPercent = indeterminate ? -1 : 0;
        root.activityRunning = true;
        root.activityDemoted = false;
        root.activityMuted = false;
        demoteTimer.restart();
        stallTimer.restart();
        root.showActivity();
    }

    function setActivityProgress(percent) {
        root.activityTouchedAt = Date.now();
        if (!root.activityRunning)
            return;
        // Any sign of life resets the stall watchdog below.
        stallTimer.restart();
        const value = Number(percent);
        root.activityPercent = Math.max(0, Math.min(100, isNaN(value) ? 0 : Math.round(value)));
        // Once demoted the job lives in the glyph slot; growing the pill back would undo that.
        if (root.activityDemoted)
            return;
        root.showActivity();
    }

    // What the job is doing now (Claude's current step): the pill follows it unless demoted.
    function setActivityText(text) {
        root.activityTouchedAt = Date.now();
        if (!root.activityRunning)
            return;
        stallTimer.restart();
        root.activityDescription = String(text ?? "").trim();
        if (!root.activityDemoted)
            root.showActivity();
    }

    // text: a line of its own for the done / failed pill; extra: merged into its payload
    // (claudeId routes a click; silent: end without a pill).
    function endActivity(status, text, extra) {
        root.activityTouchedAt = 0;
        if (!root.activityRunning)
            return;
        stallTimer.stop();
        // A progress update parked behind another peek would come back as a pill for a job
        // that is already over, stuck at its last percentage.
        root.cancelState("activity");
        const failed = String(status ?? "ok").trim().toLowerCase() !== "ok";
        const name = root.activityName;
        demoteTimer.stop();
        root.activityRunning = false;
        root.activityDemoted = false;
        const wasMuted = root.activityMuted;
        root.activityMuted = false;
        const line = String(text ?? "").trim();
        if (failed) {
            root.request("activityFail", Object.assign({
                "icon": "error",
                "text": line.length > 0 ? line : root.activityFailLine(),
                "tone": "error"
            }, extra ?? {}), 90);
            return;
        }
        // The user clicked this job away while it was running. Honour that through the end: a
        // silent finish, and the ambient glyph simply goes out.
        if (wasMuted || extra?.silent)
            return;
        // Minimal ceremony: the low priority the running state had, so a finished job never pushes
        // anything else off the island. It does replace the running pill, because equal priority
        // preempts.
        // 35 sits above workspace (30) but below every meaningful peek, so a finished job is
        // seen without shouting over a notification. At 10 it was DISCARDED whenever anything
        // else was on screen, because request() queues only notifications and drops the rest.
        root.request("activityDone", Object.assign({
            "icon": "check_circle",
            "text": line.length > 0 ? line : `${name} done.`
        }, extra ?? {}), 35);
    }

    // `end` carries a status and nothing else, so the failure line is the description the job
    // registered at start - the one thing it has said about itself. One line, and short enough to
    // stay inside the pill: IslandMessage centres its row and does not elide.
    function activityFailLine(): string {
        // Always name the failure. Previously a job started with a description returned
        // that description verbatim, so "Backup"/"Copying home" rendered as "Copying
        // home" and only the error tint said anything had gone wrong.
        const detail = (root.activityDescription ?? "").split("\n")[0].trim();
        const named = (root.activityName ?? "").trim();
        if (named.length === 0)
            return detail.length > 0 ? detail : "Failed.";
        if (detail.length === 0)
            return `${named} failed.`;
        const line = `${named} failed: ${detail}`;
        return line.length > 60 ? line.slice(0, 59) + "\u2026" : line;
    }

    // A click on the island dismisses whatever it is showing. For a job that is still running that
    // means "not now", not "cancelled": it carries on in the glyph slot and does not climb back
    // into the pill on its next progress update.
    function demoteActivity() {
        if (!root.activityRunning)
            return;
        demoteTimer.stop();
        root.activityDemoted = true;
        root.activityMuted = true;
    }

    function showActivity() {
        // Priority 10 is under every transient in the table, so this is always the thing that gets
        // dropped, never the thing that drops something else.
        root.request("activity", {
            "name": root.activityName,
            "text": root.activityDescription,
            "percent": root.activityPercent
        }, 10);
    }

    // Not restarted by progress updates: demotion is measured from the start of the job, while the
    // hold timer restarts on every update.
    Timer {
        id: demoteTimer
        interval: Config.options.island.hold.activity
        repeat: false
        onTriggered: {
            root.activityDemoted = true;
            root.cancelState("activity");
        }
    }

    // A job that dies without calling end() would otherwise hold the ambient glyph for the
    // rest of the session. Ten minutes without a progress call is taken as gone.
    Timer {
        id: stallTimer
        interval: 600000
        repeat: false
        onTriggered: {
            root.activityRunning = false;
            root.activityDemoted = false;
            root.activityMuted = false;
            demoteTimer.stop();
            root.cancelState("activity");
        }
    }

    // ------------------------------------------------------------------ wallpaper
    // A picture held over the desktop became the wallpaper: say so, and a tap on the peek
    // puts the old one back.
    property string wallpaperBefore: ""
    function wallpaperSet(path) {
        // Already the wallpaper: say that instead of claiming a change nothing would show.
        if (path === Config.options.background.wallpaperPath) {
            root.request("copied", { "icon": "wallpaper", "text": "Already your wallpaper" }, 65);
            return;
        }
        root.wallpaperBefore = Config.options.background.wallpaperPath;
        Wallpapers.apply(path);
        root.request("wallpaper", { "icon": "wallpaper", "text": "Wallpaper set", "tone": "notify" }, 65);
    }
    function wallpaperUndo() {
        if (root.wallpaperBefore.length === 0)
            return;
        Wallpapers.apply(root.wallpaperBefore);
        root.wallpaperBefore = "";
        root.request("copied", { "icon": "undo", "text": "Wallpaper back" }, 70);
    }

    // ------------------------------------------------------------------ pull requests
    // ~/.local/bin/notch-prs every five minutes over Config island.prRepos. Only TRANSITIONS
    // speak: open -> merged, checks -> failing, review newly requested. The first poll after
    // start is silent (it is not news). A pending review request is a glyph at rest.
    function pollNow() {
        prProc.command = [Directories.tacitBin + "/notch-prs"].concat(Config.options.island.prRepos);
        prProc.running = false;
        prProc.running = true;
        diskProc.running = false;
        diskProc.running = true;
    }
    property var prs: ({})   // "repo#number" -> the last row seen
    property bool prsPrimed: false
    readonly property var prReviews: Object.values(root.prs).filter(p => p.state === "OPEN" && p.review)
    Timer {
        running: root.enabled && Config.options.island.prRepos.length > 0
        interval: 300000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            prProc.command = [Directories.tacitBin + "/notch-prs"].concat(Config.options.island.prRepos);
            prProc.running = false;
            prProc.running = true;
        }
    }
    Process {
        id: prProc
        stdout: StdioCollector {
            onStreamFinished: {
                const rows = text.split("\n").filter(l => l.startsWith("{")).map(l => {
                    try {
                        return JSON.parse(l);
                    } catch (e) {
                        return null;
                    }
                }).filter(r => r !== null);
                if (rows.length === 0)
                    return;   // logged out or offline: keep what we know, say nothing
                const next = {};
                for (const r of rows) {
                    const key = `${r.repo}#${r.number}`;
                    const prev = root.prs[key];
                    next[key] = r;
                    if (!root.prsPrimed || !prev)
                        continue;
                    const short = `#${r.number} ${r.title}`;
                    // independent: one poll can bring a failure and a review request together
                    if (prev.state === "OPEN" && r.state === "MERGED") {
                        root.request("pr", { "icon": "merge", "text": `Merged · ${short}`, "tone": "success" }, 65);
                        Journal.log("pr.merged", { "number": r.number, "title": r.title, "repo": r.repo });
                    }
                    if (prev.checks !== "failure" && r.checks === "failure" && r.state === "OPEN") {
                        root.request("pr", { "icon": "error", "text": `Checks failed · ${short}`, "tone": "error" }, 65);
                        Journal.log("pr.failed", { "number": r.number, "title": r.title, "repo": r.repo });
                    }
                    if (!prev.review && r.review && r.state === "OPEN") {
                        root.request("pr", { "icon": "rate_review", "text": `Review requested · ${short}`, "tone": "notify" }, 65);
                        Journal.log("pr.review", { "number": r.number, "title": r.title, "repo": r.repo });
                    }
                }
                root.prs = next;
                root.prsPrimed = true;
            }
        }
    }

    // ------------------------------------------------------------------ disk
    // The fullest of / and /home, every ten minutes. Crossing 90% peeks once; 95% and up is
    // the red glyph at rest until it drops.
    property int diskPct: 0
    property bool diskWarned: false
    Timer {
        running: root.enabled
        interval: 600000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            diskProc.running = false;
            diskProc.running = true;
        }
    }
    Process {
        id: diskProc
        command: ["bash", "-c", "df --output=pcent,target / /home 2>/dev/null | tail -n +2 | sort -rn | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.trim().match(/^(\d+)%\s+(\S+)/);
                if (!m)
                    return;
                const pct = parseInt(m[1]);
                if (pct >= 90 && !root.diskWarned && root.warmedUp) {
                    root.request("disk", { "icon": "hard_drive", "text": `Disk ${pct}% full · ${m[2]}`, "tone": "error" }, 80);
                    Journal.log("fault.disk", { "pct": pct, "mount": m[2] });
                }
                root.diskWarned = pct >= 90;
                root.diskPct = pct;
            }
        }
    }

    // ------------------------------------------------------------------ memory
    // Memory full: one line in the notch when it starts ("Memory full · Zen"; a click opens Activity),
    // the red memory glyph at rest while it lasts. The thresholds are Activity's (modules/activity/Data.qml):
    // pressure at 10 % or under a tenth free; it clears under 2 % with more than 15 % free.
    property bool memoryFull: false
    Timer {
        running: root.enabled
        interval: 10000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            memProc.running = false;
            memProc.running = true;
        }
    }
    Process {
        id: memProc
        command: ["sh", "-c", "head -1 /proc/pressure/memory; grep -E '^Mem(Total|Available):' /proc/meminfo"]
        stdout: StdioCollector {
            onStreamFinished: root.onMemory(text)
        }
    }
    function onMemory(text) {
        const num = re => parseFloat((re.exec(text) ?? [])[1] ?? "0");
        const total = num(/MemTotal:\s+(\d+)/);
        if (total <= 0)
            return;
        const psi = num(/avg10=([\d.]+)/);
        const free = num(/MemAvailable:\s+(\d+)/) / total;
        const full = root.memoryFull ? !(psi < 2 && free > 0.15) : (psi >= 10 || free < 0.10);
        if (full && !root.memoryFull && root.warmedUp) {
            memTop.running = false;
            memTop.running = true;
            Journal.log("fault.memory", { "psi": psi, "free": Math.round(free * 100) });
        }
        root.memoryFull = full;
    }
    // who holds the most, named the way Activity names it
    Process {
        id: memTop
        command: ["python3", "-I", Quickshell.shellPath("scripts/activity/sample.py"), "--top"]
        stdout: StdioCollector {
            onStreamFinished: {
                const who = text.trim();
                root.request("memory", { "icon": "memory", "text": who.length > 0 ? `Memory full · ${who}` : "Memory full", "tone": "error" }, 80);
            }
        }
    }

    // ------------------------------------------------------------------ an app not answering
    // Hyprland notices (missed pings) and runs hyprland-dialog; ours (scripts/activity/hyprland-dialog,
    // in ~/.local/bin) brings that one dialog here. The answer goes back on the wrapper's fifo as the
    // button's own text and Hyprland acts on it: Terminate kills the app, Wait gives it more time.
    property var notAnswering: null     // {id, cls, title, pid, fifo, buttons, name, since}
    property int notAnsweringFor: 0     // seconds since Hyprland noticed
    function showNotAnswering(n) {
        if (!root.enabled || root.suppressed)
            return false;
        // without a launcher entry, the class's last part: "Org.kde.krita isn't answering" for Krita (2026-10-17)
        const name = DesktopEntries.heuristicLookup(n.cls)?.name ?? n.cls.split(".").pop();
        n.name = name.charAt(0).toUpperCase() + name.slice(1);
        n.since = Date.now();
        root.notAnswering = n;
        root.notAnsweringFor = 0;
        root.closeRequested();      // an open sheet would hide it
        root.activate("notAnswering", n, 95);
        return true;
    }
    function answerNotAnswering(which) {
        const n = root.notAnswering;
        if (!n)
            return;
        Quickshell.execDetached(["sh", "-c", 'printf "%s\\n" "$2" > "$1"', "sh", n.fifo, which === "close" ? n.buttons[0] : n.buttons[1]]);
        // Terminate is Hyprland's to carry out; an app that ignores it is killed 3 s later
        if (which === "close" && n.pid)
            Quickshell.execDetached(["sh", "-c", 'sleep 3; kill -0 "$1" 2>/dev/null && kill -KILL "$1"', "sh", String(n.pid)]);
        root.clearNotAnswering();
    }
    function notAnsweringDetails() {
        const n = root.notAnswering;
        if (n)
            Quickshell.execDetached(["activity-open", `stuck:${n.pid}:${root.notAnsweringFor}`]);
    }
    function clearNotAnswering() {
        root.notAnswering = null;
        root.cancelState("notAnswering");
    }
    // The wrapper ends when the app answers again; Hyprland may SIGKILL it, so it cannot always say so.
    // The app itself going away clears the card too.
    Timer {
        running: root.notAnswering !== null
        interval: 1000
        repeat: true
        onTriggered: {
            root.notAnsweringFor = Math.round((Date.now() - root.notAnswering.since) / 1000);
            anrAlive.running = false;
            anrAlive.running = true;
        }
    }
    Process {
        id: anrAlive
        command: ["sh", "-c", 'kill -0 "$1" 2>/dev/null && { [ "$2" -gt 0 ] 2>/dev/null || exit 0; kill -0 "$2" 2>/dev/null; }', "sh", String(root.notAnswering?.id ?? "-1"), String(root.notAnswering?.pid ?? 0)]
        onExited: code => {
            if (code !== 0 && root.notAnswering !== null)
                root.clearNotAnswering();
        }
    }

    // ------------------------------------------------------------------ uncommitted work
    // ~/.local/bin/notch-dirty over the configured repos and every session's folder, every
    // five minutes: {path, count, age}. Work sitting uncommitted past the threshold is a quiet
    // "commit" glyph at rest and a warning line on the session menu - never a peek.
    property var dirtyRepos: []
    readonly property var unsavedRepos: root.dirtyRepos.filter(r => r.age >= Config.options.island.unsavedAfterMinutes)
    readonly property bool workUnsaved: root.unsavedRepos.length > 0
    readonly property string unsavedLine: root.unsavedRepos.map(r => {
        const h = Math.floor(r.age / 60);
        return `${r.path.split("/").pop()} (${r.count} file${r.count === 1 ? "" : "s"}, ${h >= 1 ? h + "h" : r.age + "m"})`;
    }).join(", ")

    Timer {
        running: root.enabled
        interval: 300000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshDirty()
    }
    function refreshDirty() {
        const home = FileUtils.trimFileProtocol(Directories.home);
        const repos = Config.options.island.unsavedRepos.map(r => (r + "").replace(/^~/, home));
        for (const s of AgentSessions.sessions)
            if ((s.cwd + "").length > 0 && !repos.includes(s.cwd))
                repos.push(s.cwd);
        dirtyProc.command = [Directories.tacitBin + "/notch-dirty"].concat(repos);
        dirtyProc.running = false;
        dirtyProc.running = true;
    }
    Process {
        id: dirtyProc
        stdout: StdioCollector {
            onStreamFinished: {
                root.dirtyRepos = text.split("\n").filter(l => l.includes("\t")).map(l => {
                    const f = l.split("\t");
                    return { "path": f[0], "count": parseInt(f[1]), "age": parseInt(f[2]) };
                });
            }
        }
    }

    // ------------------------------------------------------------------ agent sessions
    // Claude Code sessions report through ~/.local/bin/notch-session (hooks in
    // ~/.claude/settings.json): which terminal window, and idle / working / waiting / done.
    // The sheet lists them; one that waits on you is the ambient glyph at rest, and a peek
    // when its window is not the one in front of you (there the terminal already says so).
    // The rows under the sheet are FROZEN at open (IslandContent.openSheet -> snapshotRows):
    // items arriving or expiring while you look must not reflow under the pointer. Six rows at
    // most; sessions first (they are "now"), recents fill the rest; two with a player showing.
    // Singletons are lazy: touch Recents here so it watches the clipboard from shell start,
    // not from the first time the sheet opens.
    readonly property int recentCount: Recents.fresh.length
    readonly property int originCount: Object.keys(Origins.index).length  // and the origin index (its IPC must exist before the first hook call)
    readonly property int jobCount: Jobs.running.length   // and the jobs (their IPC, and the sweep of what finished while the shell was down)
    readonly property int deviceCount: Devices.list.length   // and the disks (udisks monitor from the start)
    // a stick that just appeared: a peek; pulled: one too, only if it had been mounted
    Connections {
        target: Devices
        function onAdded(dev) {
            if (root.warmedUp)
                root.request("copied", { "icon": Devices.glyphFor(dev), "text": `${Devices.nameFor(dev)} · ${dev.size}` }, 65);
        }
        function onFailed(what) {
            root.request("copied", { "icon": "error", "text": Voice.cant(what) }, 70);
        }
    }
    readonly property int journalCount: Journal.events.length  // same: load the day record at start
    readonly property int sessionCount: AgentSessions.sessions.length  // and the sessions
    readonly property int threadCount: Threads.open.length              // and crew's threads
    property var openSessions: []
    property var openRecents: []
    // sessions' delegated agents add a 26px sub-row each
    // sub-rows: three per session at most, plus a 20px "and N more" line when there are more
    readonly property int openAgentRows: root.openSessions.reduce((n, s) => n + Math.min(3, (s.agents ?? []).length), 0)
    readonly property int openAgentMore: root.openSessions.reduce((n, s) => n + ((s.agents ?? []).length > 3 ? 20 : 0), 0)
    property int sessionsHidden: 0
    readonly property int openRowsHeight: (root.openSessions.length + root.openRecents.length) > 0
        ? (root.openSessions.length + root.openRecents.length) * 34 + root.openAgentRows * 26 + root.openAgentMore + (root.sessionsHidden > 0 ? 20 : 0) + 8 + (root.openSessions.length > 0 && root.openRecents.length > 0 ? 9 : 0) : 0
    // What openRowsHeight is allowed to reach. These sheets keep to 440 of the notch window
    // (Island.qml), so rows past this are simply not drawn and cannot be scrolled to: 406 is
    // that height less the 34px header, and the sheet's body sits above the
    // rows - 150 for the player or the shelf's tiles, 12 when the rows ARE the sheet.
    function rowsRoom(shelf) {
        return 406 - ((shelf || root.mediaPresent) ? 150 : 12) - (root.focusRunning ? 36 : 0);
    }
    // `seen`: a real open (hover, keybind) marks the stream seen; a drag-over that opens the
    // shelf does not - you were not looking at the rows.
    // `shelf`: the sheet is opening on the shelf, whose tiles take the body's 150.
    function snapshotRows(seen, shelf) {
        const cap = root.mediaPresent ? 3 : 6;
        const all = AgentSessions.rows;
        const room = root.rowsRoom(shelf);
        const costOf = s => {
            const n = (s.agents ?? []).length;
            return 34 + Math.min(3, n) * 26 + (n > 3 ? 20 : 0);
        };
        // A session with delegated agents is up to 112px tall, so six of them do not fit:
        // take rows while there is room and count the rest as hidden, keeping a line for the
        // "and N more sessions" note when there is one.
        let sessions = [];
        let used = 8;   // the row list's own bottom padding
        for (const s of all.slice(0, cap)) {
            const rest = all.length - sessions.length - 1;
            if (used + costOf(s) + (rest > 0 ? 20 : 0) > room)
                break;
            used += costOf(s);
            sessions.push(s);
        }
        root.sessionsHidden = Math.max(0, all.length - sessions.length);
        if (root.sessionsHidden > 0)
            used += 20;
        root.openSessions = sessions;
        let recents = [];
        for (const r of Recents.ranked().slice(0, Math.max(0, cap - sessions.length))) {
            const cost = 34 + (sessions.length > 0 && recents.length === 0 ? 9 : 0);   // the hairline between the two
            if (used + cost > room)
                break;
            used += cost;
            recents.push(r);
        }
        root.openRecents = recents;
        if (seen)
            Recents.markSeen();
    }

    // The restart brief: what the sessions are doing, and what sits uncommitted - one line
    // after the greeting, so a shell restart never loses your place.
    // Two wings: sessions on the left, uncommitted repos on the right. Empty when there is
    // nothing to say.
    // Two wings only when both sides have something; one side alone is a plain peek (text
    // left, its glyph right), so the notch never opens an empty wing.
    function requestBrief(parts, priority) {
        if (parts.left.length > 0 && parts.right.length > 0) {
            root.request("brief", parts, priority);
        } else if (parts.left.length > 0) {
            root.request("session", { "icon": "progress_activity", "text": parts.left }, priority);
        } else if (parts.right.length > 0) {
            root.request("session", { "icon": "commit", "text": parts.right }, priority);
        }
    }

    function briefParts() {
        const parts = [];
        const working = AgentSessions.sessions.filter(s => s.state === "working").length;
        const waiting = AgentSessions.sessions.filter(s => s.state === "waiting").length;
        if (working > 0)
            parts.push(`${working} working`);
        if (waiting > 0)
            parts.push(`${waiting} waiting`);
        const left = parts.join(" · ");
        const right = root.unsavedRepos.length > 0
            ? `${root.unsavedRepos.map(r => r.path.split("/").pop()).join(", ")} uncommitted` : "";
        return { "left": left, "right": right };
    }

    // Day record: faults and the lock, from here; sessions from the hooks; files above.
    onChargerFaultChanged: {
        if (root.chargerFault && IslandController.warmedUp)
            Journal.log("fault.charger", {});
    }
    // `qs -c tacit ipc call island open|close`: open the sheet from a keybind or a script,
    // pinned until the pointer comes and goes (or 6s), exactly like a desktop drop.
    signal openRequested()
    signal closeRequested()

    // ------------------------------------------------------------------ ask (quick chat)
    // Super+Shift+Space, `island ask`, the palette's Claude row, a capture: the sheet opens as
    // the notch's Claude chat (states/IslandAsk.qml). The conversation, its context and the
    // draft live in services/Claude.qml; this only opens the sheet. `fresh`: something new came
    // with it (a file, a question), so the shortcut's second press does not put it away.
    signal askRequested(bool fresh)
    readonly property bool claudeUp: Claude.connected   // Claude is a lazy singleton: made at startup
    readonly property bool flowUp: Dictation.connected       // so is Flow (dictation): its key needs it running 
    // `keys` false: open without taking the keyboard (the browser's address handing over in "look")
    function openAsk(origin, chips, text, keys) {
        // Never arm the keyboard for a window that will not exist to release it.
        if (!root.enabled || root.suppressed)
            return;
        const fresh = (chips?.length ?? 0) > 0 || (text ?? "").length > 0;
        Claude.invoke(origin, chips ?? [], text ?? "");
        root.keyboardScreen = Hyprland.focusedMonitor?.name ?? "";
        root.keyboard = keys ?? true;
        root.askRequested(fresh);
    }
    CompositorGlobalShortcut {
        name: "islandAsk"
        description: "Ask Claude in the notch"
        onPressed: root.openAsk("shortcut", [], "")
    }
    // True only while the sheet was opened from a key: the island takes keyboard focus for
    // arrows and Enter, and gives it back the moment it closes. Hover-opens never take it.
    property bool keyboard: false
    // There is a notch per screen but one keyboard: the screen it was on when the key was
    // pressed. Only that screen's notch opens, and only it may ask the compositor for
    // exclusive focus - otherwise the typing can land on a resting pill on the other monitor.
    // Empty (no focused monitor reported) means every screen, which is the single-screen case.
    property string keyboardScreen: ""

    // ------------------------------------------------------------------ address (the browser's Ctrl+L)
    // `island address <socket> <monitor> <mode>`: the sheet opens as the browser's address
    // (states/IslandAddress.qml), which connects to that socket and draws what the browser answers
    // (~/book4-edge/ctrll-notch-plan.md). Held like Ask, with the keyboard. "off" when no notch can
    // show it, so the browser opens its own card at once. The mode is "edit" (Ctrl+L) or "new"
    // (Ctrl+T); "look" and "look-new" open them without the keyboard, for tests while someone is
    // typing elsewhere.
    property string addressSocket: ""
    property string addressMode: "edit"
    property int addressSerial: 0
    property string addressTask: ""     // the notch row while it is open: the task left, "N pages" right
    property int addressPages: 0
    // the sheet is out, opaque: from the call until it has folded back into the notch
    property bool addressOut: false
    signal addressRequested()
    // test hooks (`island addressType`, `island addressKey`): typing without a keyboard
    signal addressTyped(string text)
    signal addressKeyed(string key)
    function openAddress(socket, monitor, mode) {
        if (!root.enabled || root.suppressed || socket.length === 0)
            return "off";
        const list = Config.options.island.screenList;
        if (monitor.length > 0 && !Quickshell.screens.some(s => s.name === monitor && (!list || list.length === 0 || list.includes(s.name))))
            return "off";
        root.addressSocket = socket;
        root.addressMode = mode.endsWith("new") ? "new" : "edit";
        root.addressTask = "";
        root.addressPages = 0;
        root.addressOut = true;
        root.keyboardScreen = monitor.length > 0 ? monitor : (Hyprland.focusedMonitor?.name ?? "");
        root.keyboard = !mode.startsWith("look");
        root.addressSerial++;
        root.addressRequested();
        return "open";
    }

    // ------------------------------------------------------------------ sign-in (the browser's popup in the notch)
    // `island signin <socket> <monitor> <mode>` (~/book4-edge/signin-notch-plan.md): the browser's sign-in popup opens
    // inside the notch. A held state, not a transient: it stays until the popup closes. The connection lives here, not
    // in the sheet, so the lock (which takes the island's window away) keeps it. One JSON object a line, as the address
    // (the browser's qml/NotchSignin.qml lists them): hello brings the popup's host, whether it is secure, the opener's
    // host and favicon and the size it asked for; page, ask, code, aside and count follow as they change; done when it
    // has closed (signed: by itself). This side says map (the sheet has settled: show the page at this size), unmap
    // (the page goes first), back and close (the way back, the flick), answer and fill. IslandContent draws the sheet
    // and leaves a hole where the page window (class browser-signin, ~/dev/browser/hypr/browser.lua) shows through.
    // Answers "open", or "off" when no notch here can show it (the browser then gives it a window of its own): the
    // notch off or locked, no such screen, a full-screen window on it, another sign-in already in the notch.
    property string signinSocket: ""
    property string signinScreen: ""
    property var signinSock: null
    // "": none; "calling": connected, no hello yet; "open": the sheet holds it; "waiting": folded to its wing
    property string signinPhase: ""
    // why it waits: "busy" (Ask, the shelf or the address had the sheet when it came), "ask" (one of those took the
    // sheet from it), "focus" (another window took the keys), "lock", "opener" (its opener is off screen in the
    // browser), "agent" (you opened the agent's ask that waited behind it)
    property string signinAside: ""
    property var signin: ({})          // host, secure, opener, icon, width, height, count
    property var signinAsk: null       // the shown ask in Asks.view's words, with id and kind; null when none
    property int signinAskCount: 0
    property bool signinCode: false    // the page's one-time code field has the keys
    property string signinAddress: ""  // the page window while mapped (Hyprland's address)
    // a sign-in from another app (mode "app": gcloud's in foot): that app's window, the one with the keys when the call
    // came, which gets them back when it ends; by its exact address, never closed
    property string signinAppAddress: ""
    property bool signinFocused: false // the page window has had the keys since it mapped
    property bool signinEnding: false  // done heard: the fold to rest is running
    readonly property bool signinHolding: root.signinPhase === "open"
    signal signinOpen()                // the sheet opens as the sign-in (IslandContent)
    signal signinDone(bool signed)     // the popup closed while its sheet is out: fold, the page first
    signal signinAsideRequested(string reason)   // fold to the waiting wing, the page first
    signal signinMapped()              // the page window is up under the hole
    signal signinUnmapped()            // the browser hid it

    // The sheet: the page as asked (540 x 440 when nothing was), at least 400 wide and at most 760, and as tall as the
    // island's window lets it be (Island.qml: 540) under the 34 px header and 2 px gap, over the asks and the grabber.
    readonly property real signinPageWidth: Math.round(Math.max(400, Math.min(760, (root.signin.width ?? 0) > 0 ? root.signin.width : 540)))
    readonly property real signinBand: root.signinBandFor(root.signinAsk, root.signinCodeShown)
    readonly property real signinRoom: 540 - 36 - root.signinBand - 18
    readonly property real signinPageHeight: Math.round(Math.max(200, Math.min(root.signinRoom, (root.signin.height ?? 0) > 0 ? root.signin.height : 440)))
    readonly property real signinSheetWidth: root.signinPageWidth + 20
    readonly property real signinSheetHeight: 36 + root.signinPageHeight + root.signinBand + 18
    // the asks under the page (states/IslandSignin.qml lays them out to these numbers): 8 px over a 40 px row for the
    // first line and its buttons, 18 per further line or note, 36 per field, 30 per option; the code row is 40
    function signinBandFor(ask, code) {
        let h = 0;
        if (ask) {
            const extra = Math.max(0, (ask.lines ?? []).length - 1) + (ask.notes ?? []).length;
            const fields = (ask.fields ?? []).length, options = (ask.options ?? []).length;
            h += 8 + 40 + 18 * extra + 36 * fields + 30 * options + (fields + options > 0 ? 6 : 0);
        }
        if (code)
            h += (ask ? 0 : 8) + 40;
        return h;
    }
    // the page's top left on the screen: the sheet is centred on its monitor, under the header
    function signinPagePos() {
        const s = Quickshell.screens.find(x => x.name === root.signinScreen) ?? Quickshell.screens[0];
        return s ? Qt.point(Math.round(s.x + (s.width - root.signinPageWidth) / 2), s.y + Config.options.island.topMargin + 36) : Qt.point(0, 0);
    }

    // What arrives while the sign-in holds the sheet: a notification, and an agent asking ("Claude needs you", "1
    // waiting" in the right wing), wait until it folds. Volume and the rest show in the right wing for their hold.
    function signinHeldBack(name) {
        return root.signinHolding && (name === "notification" || name === "claudeAsk");
    }
    readonly property int signinAgents: root.signinHolding ? root.queue.filter(q => q.name === "claudeAsk").length : 0
    onSigninHoldingChanged: {
        if (!root.signinHolding && !root.transientShowing && root.queue.length > 0)
            root.dismiss();
    }

    function openSignin(socket, monitor, mode) {
        if (!root.enabled || root.suppressed || socket.length === 0 || root.signinPhase !== "")
            return "off";
        const list = Config.options.island.screenList;
        const screen = monitor.length > 0 ? monitor : (Hyprland.focusedMonitor?.name ?? "");
        if (screen.length > 0 && !Quickshell.screens.some(s => s.name === screen && (!list || list.length === 0 || list.includes(s.name))))
            return "off";
        // the notch lies under a full-screen window there
        const m = HyprlandData.monitors.find(x => x.name === screen);
        if (m && (HyprlandData.workspaceById[m.activeWorkspace?.id]?.hasfullscreen ?? false))
            return "off";
        root.signinSocket = socket;
        root.signinScreen = screen;
        const active = ToplevelManager.activeToplevel?.HyprlandToplevel?.address ?? "";
        root.signinAppAddress = mode === "app" && active !== "" ? `0x${active}` : "";
        root.signinPhase = "calling";
        root.signinAside = "";
        root.signin = {};
        root.signinAsk = null;
        root.signinAskCount = 0;
        root.signinCode = false;
        root.signinAddress = "";
        root.signinFocused = false;
        root.signinEnding = false;
        const old = root.signinSock;
        root.signinSock = null;
        if (old)
            old.destroy();
        root.signinSock = signinSockComponent.createObject(root, { "path": socket, "connected": true });
        signinHello.restart();
        return "open";
    }
    Component {
        id: signinSockComponent
        Socket {
            id: sock
            parser: SplitParser { onRead: line => { if (sock === root.signinSock) root.signinReceive(line); } }
            onConnectedChanged: {
                if (sock.connected) {
                    sock.write(JSON.stringify({ "op": "hello" }) + "\n");
                    sock.flush();
                } else if (sock === root.signinSock) {
                    root.signinGone();
                }
            }
            onError: if (!sock.connected && sock === root.signinSock) root.signinGone()
        }
    }
    // no hello: nothing there (the browser gone); it has its own window by now
    Timer {
        id: signinHello
        interval: 2000
        onTriggered: if (root.signinPhase === "calling") root.signinEnd(false)
    }
    function signinSend(o) {
        const sock = root.signinSock;
        if (sock && sock.connected) {
            sock.write(JSON.stringify(o) + "\n");
            sock.flush();
        }
    }
    function signinReceive(line) {
        let m;
        try { m = JSON.parse(line); } catch (e) { return; }
        if (m.op === "hello") {
            if (root.signinPhase !== "calling")
                return;
            signinHello.stop();
            root.signin = m;
            root.signinPhase = "waiting";
            root.signinAside = "";
            root.signinOpen();
            // no notch here took it (another screen's, or none): it waits as a wing
            if (root.signinPhase === "waiting" && root.signinAside === "")
                root.signinAside = "busy";
        } else if (m.op === "page") {
            root.signin = Object.assign({}, root.signin, m);
        } else if (m.op === "count") {
            root.signin = Object.assign({}, root.signin, { "count": m.count });
        } else if (m.op === "ask") {
            root.signinAsk = m.ask ?? null;
            root.signinAskCount = m.count ?? 0;
        } else if (m.op === "code") {
            root.signinCode = m.on === true;
        } else if (m.op === "aside") {
            if (m.on && root.signinPhase === "open")
                root.signinAsideRequested("opener");
            else if (m.on && root.signinPhase === "waiting" && root.signinAside === "")
                root.signinAside = "opener";
            else if (!m.on && root.signinPhase === "waiting" && root.signinAside === "opener")
                root.signinResume();
        } else if (m.op === "unmapped") {
            root.signinUnmapped();
        } else if (m.op === "done") {
            root.signinFinish(m.signed === true);
        }
    }
    // the popup has closed: its sheet folds (the page first), or with none out it simply ends
    function signinFinish(signed) {
        if (root.signinEnding || root.signinPhase === "")
            return;
        root.signinEnding = true;
        if (root.signinPhase === "open") {
            signinFoldLimit.signed = signed;
            signinFoldLimit.restart();
            root.signinDone(signed);
        } else {
            root.signinEnd(signed);
        }
    }
    // the browser went away (it quit, or the popup closed without a word): as a close
    function signinGone() {
        if (root.signinPhase === "calling")
            root.signinEnd(false);
        else if (root.signinPhase !== "")
            root.signinFinish(false);
    }
    // a fold that never reports back (its screen's notch gone mid-fold) still ends
    Timer {
        id: signinFoldLimit
        property bool signed: false
        interval: 1500
        onTriggered: if (root.signinEnding) root.signinEnd(signinFoldLimit.signed)
    }
    // Over: the connection goes and, signed in, the notch breathes out once in the success tone.
    function signinEnd(signed) {
        signinFoldLimit.stop();
        signinHello.stop();
        const opener = root.signin.opener ?? "";
        const icon = root.signin.icon ?? "";
        const app = root.signin.app === true;
        // an app's sign-in: the keys go back to that app's window, if it is still there
        if (root.signinAppAddress !== "" && root.signinPhase !== "calling" && (HyprlandData.windowByAddress[root.signinAppAddress] ?? null) !== null)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${root.signinAppAddress}" })`);
        root.signinAppAddress = "";
        root.signinPhase = "";
        root.signinAside = "";
        root.signinEnding = false;
        root.signinAsk = null;
        root.signinAskCount = 0;
        root.signinCode = false;
        root.signinAddress = "";
        root.signinFocused = false;
        const sock = root.signinSock;
        root.signinSock = null;
        if (sock)
            sock.destroy();
        if (signed)
            root.request("signedIn", { "text": "Signed in", "opener": opener, "icon": icon, "app": app, "tone": "success", "spring": true }, 70);
    }
    function signinHold() {
        root.signinPhase = "open";
        root.signinAside = "";
    }
    function signinWait(reason) {
        if (root.signinPhase === "")
            return;
        root.signinPhase = "waiting";
        root.signinAside = reason;
        root.signinAddress = "";
        root.signinFocused = false;
    }
    // back from the waiting wing: a click on it, the lock or Ask gone, the opener on screen again
    function signinResume() {
        if (root.signinPhase === "waiting" && !root.suppressed)
            root.signinOpen();
    }
    // the way back, and the flick: the popup closes (its page may still ask "Leave?"); done folds the sheet
    function signinBack() {
        root.signinSend({ "op": "back" });
    }
    function signinClose() {
        root.signinSend({ "op": "close" });
    }
    function signinAnswer(id, choice, data) {
        root.signinSend({ "op": "answer", "id": id, "choice": choice, "data": data ?? {} });
    }
    Timer {
        id: signinUnlocked
        interval: 700
        onTriggered: if (root.signinPhase === "waiting" && root.signinAside === "lock") root.signinResume()
    }

    // The page window: Hyprland names it on map (openwindow, class browser-signin); it goes where the hole is (the
    // rule places it there on its own monitor; this covers another one), then the hole opens. Another window taking
    // the keys from it folds the sheet to its wing - but not one that took them by being pointed at: focus follows the
    // mouse here (input:follow_mouse 1), and the pointer drifting off the page must not fold the sign-in. So the keys
    // going to a window under the pointer (hovered, or clicked) leave it out; a switch by key (Alt+Tab, a workspace,
    // a new window) folds it.
    Connections {
        target: Hyprland
        enabled: root.signinPhase === "open"
        function onRawEvent(event) {
            if (event.name === "openwindow") {
                const f = event.data.split(",");
                if (f.length < 3 || f[2] !== "browser-signin")
                    return;
                root.signinAddress = `0x${f[0]}`;
                const at = root.signinPagePos();
                Hyprland.dispatch(`hl.dsp.window.move({ x = ${at.x}, y = ${at.y}, window = "address:${root.signinAddress}" })`);
                root.signinMapped();
            } else if (event.name === "activewindowv2") {
                const a = event.data.trim();
                if (a.length === 0 || a === ",")
                    return;
                if (`0x${a}` === root.signinAddress) {
                    root.signinFocused = true;
                } else if (root.signinFocused && root.signinAddress !== "") {
                    signinFocusCheck.target = `0x${a}`;
                    signinFocusCheck.running = true;
                }
            } else if (event.name === "closewindow" && `0x${event.data.trim()}` === root.signinAddress) {
                root.signinAddress = "";
            }
        }
    }

    Process {
        id: signinFocusCheck
        property string target: ""
        command: ["sh", "-c", "hyprctl -j cursorpos; echo '@@'; hyprctl -j clients"]
        stdout: StdioCollector {
            onStreamFinished: {
                let cursor, clients;
                try {
                    const parts = text.split("@@");
                    cursor = JSON.parse(parts[0]);
                    clients = JSON.parse(parts[1]);
                } catch (e) {
                    return;
                }
                const w = clients.find(c => c.address === signinFocusCheck.target);
                const pointed = w && cursor.x >= w.at[0] && cursor.x < w.at[0] + w.size[0] && cursor.y >= w.at[1] && cursor.y < w.at[1] + w.size[1];
                if (w && !pointed && root.signinPhase === "open")
                    root.signinAsideRequested("focus");
            }
        }
    }

    // A code from your phone (KDE Connect relays its notifications) in the last 2 minutes, offered under the page
    // while its code field has the keys. In memory only, never written anywhere; gone after 2 minutes or once used.
    property var phoneCode: null       // { code, at }
    readonly property bool signinCodeShown: root.signinCode && root.phoneCode !== null
    Connections {
        target: Notifications
        function onNotify(notification) {
            const n = notification;
            if ((n.desktopEntry ?? "") !== "org.kde.kdeconnect.daemon" && !/kde ?connect/i.test(n.appName ?? ""))
                return;
            const text = `${n.summary ?? ""} ${n.body ?? ""}`;
            if (!/(code|kod|otp|pin|verif|passcode|password|login|sign.?in|G-\d)/i.test(text))
                return;
            const m = /(^|\D)(\d{3}[ -]\d{3}|\d{4,8})(\D|$)/.exec(text);
            if (!m)
                return;
            root.phoneCode = { "code": m[2].replace(/\D/g, ""), "at": Date.now() };
            phoneCodeExpiry.restart();
        }
    }
    Timer {
        id: phoneCodeExpiry
        interval: 120000
        onTriggered: root.phoneCode = null
    }
    function signinFill() {
        if (!root.phoneCode)
            return;
        root.signinSend({ "op": "fill", "text": root.phoneCode.code });
        root.phoneCode = null;
        phoneCodeExpiry.stop();
    }

    property real lockedAt: 0
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (!root.warmedUp)
                return;
            Journal.log(GlobalStates.screenLocked ? "lock" : "unlock", {});
            if (GlobalStates.screenLocked) {
                root.lockedAt = Date.now();
            } else if (root.lockedAt > 0) {
                // The away report: what changed while you were gone, one beat, only if something did.
                root.awayBrief(root.lockedAt);
                root.lockedAt = 0;
            }
        }
    }
    // Since `since`: sessions finished, sessions waiting now, things that arrived (files, PRs).
    // Locked at 23:00 and unlocked at 08:00, the window opens before midnight - which Journal's
    // in-memory day cannot hold - so it comes from the day files, and the brief is asked for
    // once they have been read.
    function awayBrief(since) {
        Journal.since(since, ev => {
            const done = new Set(ev.filter(e => e.kind === "session.done").map(e => e.session)).size;
            const waiting = AgentSessions.sessions.filter(s => s.state === "waiting").length;
            const arrived = ev.filter(e => e.kind.startsWith("file.") || e.kind.startsWith("pr.")).length;
            const left = [];
            if (done > 0)
                left.push(`${done} finished`);
            if (waiting > 0)
                left.push(`${waiting} waiting`);
            const right = arrived > 0 ? `${arrived} arrived` : "";
            root.requestBrief({ "left": left.join(" · "), "right": right }, 90);
        });
    }

    IpcHandler {
        target: "island"

        function open(): void {
            if (!root.enabled || root.suppressed)
                return;
            root.keyboardScreen = Hyprland.focusedMonitor?.name ?? "";
            root.keyboard = true;
            root.openRequested();
        }

        function close(): void {
            root.closeRequested();
        }

        function ask(): void {
            root.openAsk("shortcut", [], "");
        }

        // a file for the quick chat (the region selector's crop)
        function askWith(path: string): void {
            root.openAsk("capture", [Claude.fileChip(path)], "");
        }

        // a question, asked in the notch
        function askSend(text: string): void {
            root.openAsk("ipc", [], text);
        }

        // `island poll`: run the pull request and disk checks now (after a push, or a test).
        function poll(): void {
            root.pollNow();
        }

        // scripts/activity/hyprland-dialog: an app stopped answering. "shown" when the notch took it;
        // anything else and the wrapper falls back to Hyprland's own dialog.
        function notAnswering(json: string): string {
            let n;
            try {
                n = JSON.parse(json);
            } catch (e) {
                return "no";
            }
            return root.showNotAnswering(n) ? "shown" : "no";
        }

        // `island note <icon> "<text>"`: one line in the notch, for other programs
        function note(icon: string, text: string): void {
            root.request("note", { "icon": icon, "text": text }, 65);
        }

        function notAnsweringGone(id: string): void {
            if (root.notAnswering?.id === id)
                root.clearNotAnswering();
        }

        // `island brief`: the away report for the last N minutes, on demand.
        function brief(minutes: int): void {
            root.awayBrief(Date.now() - Math.max(1, minutes) * 60000);
        }

        function start(name: string, description: string): void {
            root.startActivity(name, description);
        }

        function progress(percent: int): void {
            root.setActivityProgress(percent);
        }

        function end(status: string): void {
            root.endActivity(status);
        }

        // the browser's Ctrl+L (states/IslandAddress.qml): "open", or "off" when no notch shows it
        function address(socket: string, monitor: string, mode: string): string {
            return root.openAddress(socket, monitor, mode);
        }
        function addressType(text: string): void {
            root.addressTyped(text);
        }
        // down, up, enter, alt+enter, shift+enter, tab, escape
        function addressKey(key: string): void {
            root.addressKeyed(key);
        }

        // the browser's sign-in popup in the notch: "open", or "off" when no notch shows it
        function signin(socket: string, monitor: string, mode: string): string {
            return root.openSignin(socket, monitor, mode);
        }
        // read-only, for tests: where the sign-in is
        function signinState(): string {
            return JSON.stringify({ "phase": root.signinPhase, "aside": root.signinAside, "screen": root.signinScreen,
                "page": [root.signinPageWidth, root.signinPageHeight], "sheet": [root.signinSheetWidth, root.signinSheetHeight],
                "band": root.signinBand, "address": root.signinAddress, "focused": root.signinFocused,
                "ask": root.signinAsk ? root.signinAsk.kind : "", "code": root.signinCodeShown, "agents": root.signinAgents,
                "queue": root.queue.map(q => q.name), "transient": root.transientState });
        }
    }

    // SUPER+M and the media corner open the notch instead of the media card (MediaControls.qml).
    readonly property bool ownsMedia: root.enabled && !root.suppressed && (Config.options.island.media.enable ?? false)

    // ------------------------------------------------------------------ waveform
    // MediaControls runs cava only while its own panels are open. Run our own copy of the identical
    // command when nothing else does, and publish into the same shared property, so exactly one
    // cava is alive at a time. othersRunCava is the exact complement of MediaControls.qml's own
    // cavaProc condition: a term dropped from one has to be dropped from the other, or two cava
    // run at once, or none does.
    readonly property bool othersRunCava: GlobalStates.mediaControlsOpen
        || Config.options.background.widgets.visualizer.enable
        || ["leftLayout", "middleLayout", "rightLayout"].some(k => Config.options.bar.layouts[k].includes("visualizer"))

    Process {
        id: cavaProc
        // only while something plays: idle, cava alone was 4% of a core and a stream to parse
        running: root.enabled && !root.suppressed && MprisController.isPlaying
            && Config.options.island.media.enable && Config.options.island.media.waveform
            && !root.othersRunCava
            && MprisController.activePlayer !== null
        command: ["cava", "-p", `${FileUtils.trimFileProtocol(Directories.scriptPath)}/cava/raw_output_config.txt`]
        onRunningChanged: {
            if (!cavaProc.running)
                GlobalStates.visualizerPoints = [];
        }
        stdout: SplitParser {
            onRead: data => {
                let points = data.split(";").map(p => parseFloat(p.trim())).filter(p => !isNaN(p));
                GlobalStates.visualizerPoints = points;
            }
        }
    }
}
