pragma Singleton
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

/**
 * The Claude Code sessions on this machine, as the notch sees them: which terminal window,
 * idle / working / waiting / done, what each is doing right now, and the last thing it said.
 *
 * Sources: the hooks in ~/.claude/settings.json run ~/.local/bin/notch-session, which reports
 * over IPC (`sessions update|activity|last|end`) and keeps state files for a restart; the
 * official roster (`claude agents --json`) supplies names and statuses every five seconds.
 * The notch (IslandController) asks for the peeks; the sheet (IslandContent) draws the rows.
 */
Singleton {
    id: root

    // Every session that reports. `sessions` is what the notch shows: all of them, except while a
    // demo take runs. Then $XDG_RUNTIME_DIR/notch-stage holds the demo repo's path, and only
    // sessions under it show, so real work stays off camera. The others keep reporting here and
    // reappear with their true state when the file goes.
    property var all: []
    property string stage: ""
    readonly property var sessions: root.stage.length > 0 ? root.all.filter(s => root.inStage(s)) : root.all
    function inStage(s) {
        const c = (s?.cwd ?? "") + "";
        return root.stage.length === 0 || c === root.stage || c.startsWith(root.stage + "/");
    }
    FileView {
        id: stageFile
        path: `${Quickshell.env("XDG_RUNTIME_DIR")}/notch-stage`
        watchChanges: true
        printErrors: false
        onFileChanged: stageFile.reload()
        onLoaded: root.stage = stageFile.text().trim()
        onLoadFailed: root.stage = ""
    }
    readonly property bool waiting: root.sessions.some(s => s.state === "waiting")
    // how many work at once: the resting wing names one and counts the rest ("+2")
    readonly property int workingCount: root.sessions.filter(s => s.state === "working").length
    // The session to read at rest: working, with an activity line; the one in front of you
    // first, else the newest. The resting wings show its name and what it is doing.
    readonly property var active: {
        const w = root.sessions.filter(s => s.state === "working" && (s.activity ?? "").length > 0);
        if (w.length === 0)
            return null;
        return w.find(s => root.focused(s)) ?? w.slice().sort((a, b) => (b.lastToolAt ?? 0) - (a.lastToolAt ?? 0))[0];
    }
    // Strings for the resting wings. `active` is the same object across updates (its fields
    // are mutated), so a binding through it never re-fires; these read root.sessions, which
    // is a new list on every update, so they follow every tool call.
    readonly property string activeLabel: {
        const list = root.sessions;
        const a = root.active;
        return a && list.includes(a) ? root.label(a) : "";
    }
    readonly property string activeLine: {
        const list = root.sessions;
        const a = root.active;
        return a && list.includes(a) ? (a.activity ?? "") : "";
    }
    // A session just finished a turn: the resting glyph shows a tick for a few seconds, whether
    // or not you are looking at that window. Peeks stay conditional; the glyph does not.
    property bool justDone: false
    Timer {
        id: doneTimer
        interval: 6000
        repeat: false
        onTriggered: root.justDone = false
    }
    // Waiting first, then oldest first. Sessions always keep their rows, player or not: they
    // are "now". The player only lowers the total cap (snapshotRows).
    readonly property var rows: root.sessions.slice().sort((a, b) => ((b.state === "waiting") - (a.state === "waiting")) || (a.since - b.since))

    // A terminal closed without a SessionEnd (killed, crashed): its row must not linger.
    function prune() {
        const alive = ToplevelManager.toplevels.values.map(t => `0x${t.HyprlandToplevel?.address ?? ""}`);
        const kept = root.all.filter(s => (s.address + "").length === 0 || alive.includes(s.address));
        if (kept.length !== root.all.length)
            root.all = kept;
    }
    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() {
            root.prune();
        }
    }

    function label(s) {
        // Claude's own session name when the roster gave one; else the terminal title carries
        // Claude Code's task after a state glyph - strip the glyph.
        // The thread's name first (crew), then Claude's own session name - unless it is the automatic one ("abdul-a9",
        // the folder and two characters, which says nothing): then the conversation's first question as Praxis titles
        // it, the title, and the automatic name last.
        const thread = Threads.forSession(s.id);
        if (thread && (thread.name ?? "").length > 0)
            return thread.name;
        const name = (s.name ?? "") + "";
        const automatic = /^\S+-[0-9a-f]{2}$/i.test(name);
        if (name.length > 0 && !automatic)
            return name;
        if (Claude.owns(s.id) && Claude.titleOf(s.id) !== "Claude")
            return Claude.titleOf(s.id);
        const t = ToplevelManager.toplevels.values.find(t => `0x${t.HyprlandToplevel?.address ?? ""}` === s.address);
        const title = ((t?.title ?? "") + "").replace(/^[^A-Za-z0-9]+\s*/, "").trim();
        if (title.length > 0)
            return title;
        return name.length > 0 ? name : ((s.cwd + "").split("/").pop() || "session");
    }
    function focused(s) {
        const a = ToplevelManager.activeToplevel?.HyprlandToplevel?.address;
        return a !== undefined && a !== null && `0x${a}` === s.address;
    }
    function focus(s) {
        if ((s.address + "").length > 0)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${s.address}" })`);
        else
            Claude.hand("open", s.id);
    }
    function update(id, state, address, cwd) {
        let list = root.all.slice();
        let s = list.find(x => x.id === id);
        if (!s) {
            s = { "id": id, "address": address, "cwd": cwd, "state": state, "since": Date.now(), "lastToolAt": Date.now() };
            list.push(s);
        } else {
            if (s.state !== state)
                s.since = Date.now();
            s.state = state;
            if (address.length > 0)
                s.address = address;
            if (cwd.length > 0)
                s.cwd = cwd;
        }
        if (state === "working") {
            s.lastToolAt = Date.now();   // a fresh prompt is activity
            s.quietTold = false;
        }
        if (state === "done") {
            root.justDone = true;
            doneTimer.restart();
        }
        if (state !== "working")
            s.activity = "";
        root.all = list;
        if (!s.polled) {
            s.polled = true;
            IslandController.refreshDirty();
        }
        // sessions agent-host runs peek through the Claude service (one event, one signal)
        if ((state === "waiting" || state === "done") && !root.focused(s) && !Claude.owns(id) && root.inStage(s))
            IslandController.request("session", {
                "icon": state === "waiting" ? "back_hand" : "check",
                "text": (state === "waiting" ? "Needs you · " : "Done · ") + root.label(s),
                "tone": state === "done" ? "success" : "notify"
            }, 60);
    }
    function end(id) {
        root.all = root.all.filter(x => x.id !== id);
    }

    // A restarted shell rebuilds its rows from the hooks' state files (no peeks for those).
    Process {
        id: restoreProc
        running: IslandController.enabled
        command: [Directories.tacitBin + "/notch-sessions-restore"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = text.split("\n").filter(l => l.includes("\t")).map(l => {
                    const f = l.split("\t");
                    return { "id": f[0], "state": f[1], "cwd": f[2], "address": f[3], "since": parseInt(f[4]) * 1000, "polled": true };
                });
                if (list.length === 0)
                    return;
                const known = root.all.map(s => s.id);
                root.all = root.all.concat(list.filter(s => !known.includes(s.id)));
                IslandController.refreshDirty();
            }
        }
    }


    // The activity line ("running make", "editing Island.qml") from PreToolUse, and the last
    // assistant line from Stop, which the recap on return reads.
    function activity(id, line) {
        let list = root.all.slice();
        const s = list.find(x => x.id === id);
        if (!s)
            return;
        s.activity = line;
        s.lastToolAt = Date.now();
        s.quietTold = false;
        root.all = list;
    }
    function last(id, line) {
        let list = root.all.slice();
        const s = list.find(x => x.id === id);
        if (!s)
            return;
        s.last = line;
        s.lastAt = Date.now();
        root.all = list;
    }

    // ---- the official roster: `claude agents --json` (about 150ms) every 5s. It carries the
    // session's own name and status; hooks stay for instant transitions and the window. Without
    // Claude Code installed nothing is started: a missing binary logged a failed start every poll.
    Process {
        id: rosterProc
        command: ["sh", "-c", "command -v claude >/dev/null && exec claude agents --json"]
        stdout: StdioCollector {
            onStreamFinished: {
                let rows;
                try {
                    rows = JSON.parse(text);
                } catch (e) {
                    return;
                }
                if (!Array.isArray(rows))
                    return;
                let list = root.all.slice();
                let changed = false;
                for (const r of rows) {
                    if (r.kind !== "interactive" || !r.sessionId)
                        continue;
                    let s = list.find(x => x.id === r.sessionId);
                    if (!s) {
                        // a session the hooks never saw (started before the shell): adopt it.
                        // Without its cwd: the roster reports the project root, so every session
                        // here comes back as /home/abdul whatever directory it is really in, and
                        // that value is what the row's folder label and the hand-off to a new
                        // Claude session read. No cwd leaves both to fall back; a wrong one does not.
                        s = { "id": r.sessionId, "address": "", "cwd": "", "state": r.status === "busy" ? "working" : "idle",
                              "since": r.startedAt ?? Date.now(), "lastToolAt": Date.now(), "polled": true };
                        list.push(s);
                        changed = true;
                    }
                    if ((r.name ?? "").length > 0 && s.name !== r.name) {
                        s.name = r.name;
                        changed = true;
                    }
                    // a session no hook reports on (an install has no notch-session hooks in ~/.claude/settings.json)
                    // follows the roster: adopted busy, it read "working" for good and raised "Quiet" peeks
                    if (s.polled) {
                        const now = r.status === "busy" ? "working" : "idle";
                        if (s.state !== now) {
                            s.state = now;
                            changed = true;
                        }
                        if (now === "working")
                            s.lastToolAt = Date.now();
                    }
                }
                // gone from the roster = ended, however it ended
                const alive = rows.map(r => r.sessionId);
                const kept = list.filter(s => alive.includes(s.id) || s.id.startsWith("demo") || s.id.startsWith("probe"));
                if (kept.length !== list.length)
                    changed = true;
                if (changed)
                    root.all = kept;
            }
        }
    }
    Timer {
        running: IslandController.enabled
        // the hooks carry state as it happens; the roster only adopts and prunes. Each poll
        // starts the agent CLI (0.15 s of CPU), so every 15 s, not 5.
        interval: 15000
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            rosterProc.running = false;
            rosterProc.running = true;
        }
    }

    // ---- quiet-for: a working session with no tool call for 45s reads "quiet Nm"; at four
    // minutes one peek, if its window is not in front of you. An observation, not a verdict.
    property real quietNow: Date.now()
    function quietMinutes(s) {
        if (s.state !== "working" || !(s.lastToolAt > 0))
            return 0;
        const secs = (root.quietNow - s.lastToolAt) / 1000;
        return secs < 45 ? 0 : Math.max(1, Math.floor(secs / 60));
    }
    Timer {
        running: IslandController.enabled && root.sessions.length > 0
        interval: 15000
        repeat: true
        onTriggered: {
            root.quietNow = Date.now();
            for (const s of root.sessions) {
                if (root.quietMinutes(s) >= 4 && !s.quietTold && !root.focused(s)) {
                    s.quietTold = true;
                    IslandController.request("session", { "icon": "hourglass_empty", "text": `Quiet ${root.quietMinutes(s)}m · ${root.label(s)}` }, 55);
                }
            }
        }
    }

    // ---- recap on return: coming back to a session's window after three minutes away shows
    // the last thing it said, one line. The one peek that shows WHILE the window is focused.
    property string lastFocusAddress: ""
    property var unfocusedSince: ({})
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() {
            const a = ToplevelManager.activeToplevel?.HyprlandToplevel?.address;
            const now = a !== undefined && a !== null ? `0x${a}` : "";
            if (now === root.lastFocusAddress)
                return;
            let map = Object.assign({}, root.unfocusedSince);
            if (root.lastFocusAddress.length > 0)
                map[root.lastFocusAddress] = Date.now();
            root.lastFocusAddress = now;
            const away = map[now] ?? 0;
            delete map[now];
            root.unfocusedSince = map;
            if (!(away > 0) || Date.now() - away < 180000)
                return;
            const s = root.sessions.find(x => x.address === now);
            if (s && (s.last ?? "").length > 0 && s.lastAt > away)
                IslandController.request("session", { "icon": "history", "text": s.last }, 55);
        }
    }

    // Delegated agents (the Agent tool) run inside a session; they get sub-rows while alive.
    function agentStart(sid, aid, desc) {
        let list = root.all.slice();
        const s = list.find(x => x.id === sid);
        if (!s)
            return;
        const agents = (s.agents ?? []).filter(a => a.id !== aid);
        agents.push({ "id": aid, "desc": desc, "since": Date.now() });
        s.agents = agents;
        root.all = list;
    }
    function agentStop(sid, aid) {
        let list = root.all.slice();
        const s = list.find(x => x.id === sid);
        if (!s)
            return;
        s.agents = (s.agents ?? []).filter(a => a.id !== aid);
        root.all = list;
    }

    IpcHandler {
        target: "sessions"
        // read by the demo take before it records: `qs ipc prop get sessions stage`
        readonly property string stage: root.stage
        readonly property int shown: root.sessions.length
        readonly property int total: root.all.length

        function update(id: string, state: string, address: string, cwd: string): void {
            root.update(id, state, address, cwd);
        }

        function activity(id: string, line: string): void {
            root.activity(id, line);
        }

        function last(id: string, line: string): void {
            root.last(id, line);
        }

        function end(id: string): void {
            root.end(id);
        }

        function agentStart(id: string, agent: string, desc: string): void {
            root.agentStart(id, agent, desc);
        }

        function agentStop(id: string, agent: string): void {
            root.agentStop(id, agent);
        }
    }

}
