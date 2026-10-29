import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.tacit
import "Markdown.js" as Md

/**
 * A session's conversation, laid out after OpenChamber's chat column in the shell's colours.
 *
 * Past items come from the transcript through the host (newest 400; "Earlier" pages back). An
 * open session keeps following its transcript as Claude Code appends to it, so commands,
 * results, thinking and replies land as they happen, whether the session runs in the host or
 * in a terminal. A session the host runs also streams its words as they are written (the
 * footer: thinking and text in progress), and can be typed into, stopped, and asked for
 * permission. The list is a ListModel updated row by row, so following never resets scroll.
 */
Item {
    id: conv

    property var host
    property var session: null     // { id, tool, cwd, title, ... }; { fresh: true, cwd } for a new one
    property bool pinned: false
    property var folders: []
    property var items: []
    // where the shown page begins: a byte in the transcript when the host reads Claude Code files from
    // the end (byteCursor), else an item number; above 0 there is more before it
    property real start: 0
    property bool byteCursor: false
    property int total: 0
    property int offset: -1        // transcript byte offset to follow from; -1 = not loaded
    property bool loading: false
    property bool following: false
    property int followGen: 0
    property bool followAgain: false    // asked for while a follow was in flight: run once more after it
    property string partialText: ""
    property string partialThinking: ""
    property int shownChars: 0          // how much of partialText is on screen: it catches up smoothly
    // The Working line's timer: from the start of the turn as the transcript has it, or from when a session run here was
    // seen to start one (its message is read a moment later). It counted from when Praxis saw the session busy: opened
    // mid-turn, ten minutes in, it said "Working 4s"; a switch between two busy sessions kept the first one's.
    property double busyFlipAt: 0
    readonly property double turnStart: conv.turnStartOf(conv.items)
    readonly property double busySince: Math.max(conv.turnStart, conv.busyFlipAt)
    property int busySeconds: 0
    onBusySinceChanged: conv.tickBusy()
    function tickBusy() { conv.busySeconds = conv.busy && conv.busySince > 0 ? Math.max(0, Math.round((Date.now() - conv.busySince) / 1000)) : 0; }
    // The item that began the newest turn: a message of yours, or a note (a background task's report, an agent's
    // hand-back), right after the last reply or a stop. One that comes after a step was read mid-turn.
    function turnStartOf(items) {
        const starts = i => {
            let j = i - 1;
            while (j >= 0 && (items[j].kind === "queue" || (items[j].kind === "note" && items[j].text !== "Interrupted"))) j--;
            return j < 0 || items[j].kind === "note" || (items[j].role === "assistant" && items[j].kind === "text");
        };
        for (let i = items.length - 1; i >= 0; i--) {
            const it = items[i];
            const said = it.role === "user" && (it.kind === "text" || it.kind === "command" || it.kind === "image");
            const told = it.kind === "note" && it.text !== "Interrupted" && it.text !== "Conversation compacted";
            if ((said || told) && starts(i)) return it.ts ?? 0;
        }
        return 0;
    }
    // A terminal session that compacts mid-turn writes nothing more to its transcript until the turn ends (Claude Code
    // 2.1.295, 2026-10-10: eleven minutes of work written at once), so the conversation here stops at the note meanwhile.
    readonly property bool afterCompact: {
        if (conv.terminal === null) return false;
        for (let i = conv.items.length - 1; i >= 0; i--) {
            const it = conv.items[i];
            if (it.kind !== "queue") return it.kind === "note" && it.text === "Conversation compacted";
        }
        return false;
    }
    property bool settled: false        // first load done: from here on, new rows ease in
    property string pendingUser: ""
    property string error: ""
    property string chosenMode: "auto"
    property string chosenModel: ""     // a model id; "" until one is chosen or resolved
    property string chosenEffort: ""    // a level; "" until one is chosen or resolved
    property string chosenAccount: ""   // an account id; "" is the agent's default one
    property bool accountPicked: false  // chosen in the agent menu: a folder's default does not replace it
    property string watching: ""
    property int seenSeq: -1           // the running process's events already taken in
    property string starting: ""       // the session this pane has just started: its echo survives the swap
    property bool paging: false        // an "Earlier" page is being read
    property bool readFailed: false    // the host could not read this transcript
    property bool loadRetried: false
    // the tool calls whose output is open, by call id (a group by its first call's id): the rows
    // are rebuilt on every update and dropped past the cache buffer, so this outlives them
    property var openIds: ({})
    function toggleOpen(key) {
        if (!key.length) return;
        const m = Object.assign({}, conv.openIds);
        if (m[key]) delete m[key];
        else m[key] = true;
        conv.openIds = m;
    }
    property var changes: ({ files: [], add: 0, del: 0 })
    property var viewer: null
    property var files: null          // the side panel: file links open there at their line
    property bool panelOpen: false
    property var queued: []            // messages typed while it works: sent in order when it stops
    property bool sendingNow: false    // a message handed to the host whose row has not come back yet

    // ── test probe: on only in a scripts/praxis/check.py run (PRAXIS_TEST=1), which drives sessions it made ──
    readonly property bool testRun: Quickshell.env("PRAXIS_TEST") === "1"
    readonly property var testSessions: (Quickshell.env("PRAXIS_TEST_SESSIONS") ?? "").split(",").filter(x => x.length)
    property var testSnaps: []        // moves of the view that neither following nor the reader made: jumps
    property int testRebuiltOld: 0    // rebuilds of a session that is no longer the one selected
    property var testEvents: []       // what happened, in order: sends, queue checks, turn changes, rows read
    property real testFooterH: 0      // the live part under the rows, and the bubble in it
    property real testEchoH: 0
    // the frames shown after the last switch: how far from the end, the rows at the top and middle of the view (-1: none)
    property var testSwitch: []
    property int testSwitchLeft: 0
    property var testBuilt: ({})      // rows built since the reset, by type: how many and how long it took (ms)
    function testLog(what) { if (conv.testRun) conv.testEvents = conv.testEvents.slice(-60).concat([`${Date.now() % 100000} ${what}`]); }
    onSendingNowChanged: conv.testLog(`sendingNow ${conv.sendingNow}`)
    IpcHandler {
        enabled: conv.testRun
        target: "praxistest"
        // only into a session the run made: a test once wrote into the owner's own conversation (2026-10-10)
        function send(text: string): string {
            if (!conv.session || !conv.testSessions.includes(conv.session.id)) return "refused";
            return conv.send(text, [], [], false) ? "sent" : "failed";
        }
        function state(): string {
            return JSON.stringify({ session: conv.session?.id ?? "", busy: conv.busy, turnOpen: conv.turnOpen, echo: conv.pendingUser,
                busySince: conv.busySince, busySeconds: conv.busySeconds, afterCompact: conv.afterCompact,
                queuedRows: conv.queued.filter(q => !q.shown).length, waitingRows: conv.waitingShown.length,
                liveTools: conv.liveTools.map(t => [t.tool, t.desc]), blocks: blockModel.count, users: conv.items.filter(i => i.role === "user").length,
                snaps: conv.testSnaps, rebuiltOld: conv.testRebuiltOld, loading: conv.loading, events: conv.testEvents,
                watch: { row: list.testRow, y: Math.round(list.testRowY), cy: Math.round(list.contentY), ch: Math.round(list.contentHeight),
                         h: Math.round(list.height), frames: list.testFrames, settled: conv.settled, swapping: conv.swapping, chase: chase.running, atEnd: list.atEnd } });
        }
        function reset(): void { conv.testSnaps = []; conv.testRebuiltOld = 0; conv.testEvents = []; list.testTimes = []; conv.testBuilt = ({}); }
        function built(): string { return JSON.stringify(conv.testBuilt); }
        function switchFrames(): string { return JSON.stringify(conv.testSwitch); }
        // frame times since the reset: how many, the middle, the slowest 5 %, the worst, and frames over 33 ms (a skip)
        function frames(): string {
            const t = list.testTimes.slice(1).sort((a, b) => a - b);
            const at = q => t.length ? Math.round(t[Math.min(t.length - 1, Math.floor(q * t.length))] * 10) / 10 : 0;
            return JSON.stringify({ n: t.length, p50: at(0.5), p95: at(0.95), max: t.length ? Math.round(t[t.length - 1]) : 0, over33: t.filter(x => x > 33).length });
        }
        // a reader scrolling the whole conversation up and back down, 1.5 s each way
        function scroll(): void { testScroll.restart(); }
        // a jump made on purpose: the check first proves the watch sees one
        function nudge(): void { list.contentY = list.contentY - 40; }
        function collect(): void { gc(); }
    }
    property bool echoHandoff: false   // its row is read: the bubble goes as the row is drawn (userC)
    // The live part under the rows may only shrink once the rows that take its place are drawn. Rows read from the
    // transcript are drawn a frame after the model has them, while the live part (the bubble, the text being
    // written, a tool call being written) gave way at once: the end pulled back for a frame and the view jumped.
    property real footerNow: 0
    property real footerHold: 0
    property int footerHoldUntil: -1
    function holdFooter() { conv.footerHold = Math.max(conv.footerHold, conv.footerNow); footerRelease.restart(); }
    function releaseFooter() { conv.footerHold = 0; footerRelease.stop(); }
    Timer { id: footerRelease; interval: 300; onTriggered: conv.footerHold = 0 }   // rows not drawn (scrolled away)
    function takeEcho() { conv.testLog(`takeEcho "${conv.pendingUser.substring(0, 20)}"`); conv.echoHandoff = false; echoHandoffTimer.stop(); conv.pendingUser = ""; conv.pendingImages = []; }
    // a row not drawn (the view scrolled away from the end): the bubble goes anyway
    Timer { id: echoHandoffTimer; interval: 300; onTriggered: if (conv.echoHandoff) conv.takeEcho() }
    // messages waiting in Claude Code's own queue (typed in its terminal while it works), as the transcript tells it
    property var waiting: []
    // only a terminal's session: one Praxis runs passes every message through Claude Code's queue for a moment,
    // and it flashed there beside its own bubble (owner 2026-10-10: "when i send message it sometimes shows queue")
    readonly property var waitingShown: conv.working && conv.locked
        ? conv.waiting.filter(t => t.trim().length > 0 && !t.trim().startsWith("<") && t.trim() !== conv.pendingUser.trim()) : []
    property var pendingImages: []
    // the / commands: the running session's own (host "info", then each commands_changed), else
    // what the catalog has for this agent, account and folder, else the usual ones
    property var liveCommands: null
    readonly property string catalogKey: conv.acc?.available && conv.host.features.includes("catalog") && conv.session
        ? conv.acc.catalogKey(conv.agent, conv.chosenAccount || (conv.acc.defaultAccount(conv.agent)?.id ?? ""), conv.session.cwd ?? "") : ""
    readonly property var catalogCommands: conv.catalogKey ? conv.acc.catalogs[conv.catalogKey]?.commands ?? null : null
    onCatalogKeyChanged: if (conv.catalogKey) Qt.callLater(() => conv.acc.catalog(conv.agent, conv.chosenAccount, conv.session?.cwd ?? ""))
    Component.onCompleted: if (conv.catalogKey) conv.acc.catalog(conv.agent, conv.chosenAccount, conv.session?.cwd ?? "")
    readonly property var commands: conv.liveCommands ?? conv.catalogCommands ?? conv.defaultCommands
    function commandsOf(list) {
        return (list ?? []).filter(c => c?.name).map(c => ({ name: c.name, description: c.description ?? "", hint: c.hint ?? c.argumentHint ?? "",
                                                            aliases: c.aliases ?? [] }));
    }
    property real cost: 0              // this run's spend, from the host's result events
    readonly property var defaultCommands: [
        { name: "compact", description: "Summarise the conversation to free context" },
        { name: "context", description: "What is using the context" },
        { name: "cost", description: "What this session has cost" },
        { name: "model", description: "Switch model" },
        { name: "review", description: "Review the current changes" },
        { name: "init", description: "Write a CLAUDE.md for this project" },
        { name: "clear", description: "Start over in this session" }
    ]
    // context for the last call: tokens, and a share when the window size is known (the host
    // reports the model with its [1m] suffix; a terminal session's transcript does not)
    // how full the context is, when the window is known (Composer turns sand from 80)
    readonly property int meterPct: {
        let ctx = 0;
        for (let i = conv.items.length - 1; i >= 0 && !ctx; i--) ctx = conv.items[i].ctx ?? 0;
        const window = conv.live && (conv.live.model ?? "").includes("[1m]") ? 1000000 : (ctx > 200000 ? 1000000 : (conv.live ? 200000 : 0));
        return ctx > 0 && window ? Math.round(ctx * 100 / window) : 0;
    }
    readonly property string meter: {
        let ctx = 0;
        for (let i = conv.items.length - 1; i >= 0 && !ctx; i--) ctx = conv.items[i].ctx ?? 0;
        const parts = [];
        if (ctx > 0) {
            const window = conv.live && (conv.live.model ?? "").includes("[1m]") ? 1000000 : (ctx > 200000 ? 1000000 : (conv.live ? 200000 : 0));
            const k = ctx >= 1000 ? `${Math.round(ctx / 1000)}k` : `${ctx}`;
            parts.push(window ? `${Math.round(ctx * 100 / window)}% of context used` : `${k} of context used`);
        }
        if (conv.cost > 0) parts.push(`$${conv.cost.toFixed(2)}`);
        return parts.join(" · ");
    }
    // ── find in the conversation (Ctrl+F): the blocks that mention it, Enter walks them ──
    property bool finding: false
    property string findQuery: ""
    property int findAt: -1
    readonly property var findHits: {
        const q = conv.findQuery.trim().toLowerCase();
        if (q.length < 2) return [];
        const hits = [];
        // the blocks, not the list rows: get(i) is not tracked, so hits went stale where a row changed
        const blocks = conv.build(conv.items);
        for (let i = 0; i < blocks.length; i++) {
            const b = blocks[i];
            const tools = b.type === "activity" ? b.tools : b.type === "tool" ? [b.item] : [];
            const hay = [b.content, b.type === "footer" ? "" : b.text].concat(tools.map(t => `${t.desc ?? ""} ${t.summary ?? ""} ${t.text ?? ""}`)).join(" ");
            if (hay.toLowerCase().includes(q)) hits.push(i);
        }
        return hits;
    }
    // a new query starts over; a live session growing keeps your place
    onFindQueryChanged: conv.findAt = -1
    onFindHitsChanged: if (conv.findAt >= conv.findHits.length) conv.findAt = conv.findHits.length - 1
    function openFind() { conv.finding = true; findField.forceActiveFocus(); findField.selectAll(); }
    function find(q) { conv.openFind(); findField.text = q; conv.findStep(1); }
    function closeFind() { conv.finding = false; conv.findQuery = ""; findField.text = ""; composer.focusInput(); }
    function findStep(step) {
        // only the loaded part is searched: walking up past its first match, or a find with none in it, reads
        // the earlier part (a long session said "None" for words a few pages up, with no way to reach them)
        if (conv.start > 0 && (!conv.findHits.length || (step < 0 && conv.findAt === 0))) { conv.findEarlier(5); return; }
        if (!conv.findHits.length) return;
        // up from a new find starts at the newest match
        conv.findAt = conv.findAt < 0 && step < 0 ? conv.findHits.length - 1 : (conv.findAt + step + conv.findHits.length) % conv.findHits.length;
        conv.findShow();
    }
    function findShow() {
        // no longer following: a pending jump to the end would take the view off the match
        list.atEnd = false;
        toEnd.stop();
        toEndAgain.stop();
        list.positionViewAtIndex(conv.findHits[conv.findAt], ListView.Center);
    }
    // a page at a time, up to `pages`, until one has a match: then its newest one is shown
    function findEarlier(pages) {
        conv.earlier(added => {
            const older = conv.findHits.filter(i => i < added);
            if (older.length) { conv.findAt = conv.findHits.indexOf(older[older.length - 1]); conv.findShow(); }
            else if (pages > 1 && conv.start > 0 && conv.finding) conv.findEarlier(pages - 1);
        });
    }

    // the session's agents, workflow runs and background commands (agent-host "agents"), the clock
    // their running times count on, and which one the side panel shows
    property var agentsInfo: null
    onAgentsInfoChanged: conv.testLog("switch: agents info in")
    onChangesChanged: conv.testLog("switch: changes in")
    property real clock: Date.now()
    property string openAgent: ""
    property string openRun: ""
    property bool canStop: false
    readonly property int runningCount: !conv.agentsInfo ? 0
        : (conv.agentsInfo.agents ?? []).filter(a => a.state === "running").length
          + (conv.agentsInfo.workflows ?? []).filter(w => w.state === "running").length
          + (conv.agentsInfo.shells ?? []).filter(x => x.state === "running").length
    property string need: ""          // missing | signedOut: Claude Code is not ready (SetupNotice)
    property string hostNote: ""      // reconnecting | unreachable | outdated: the line above the box
    signal recheck()
    signal restartHost()
    // ── the agent: Claude Code, Codex, pi or opencode ─────────────────────────
    readonly property string agent: conv.session?.tool || "claude"
    readonly property var agentNames: ({ claude: "Claude Code", codex: "Codex", pi: "pi", opencode: "opencode" })
    readonly property string agentName: conv.agentNames[conv.agent] ?? conv.agent
    // what the host can do with this agent's sessions; a host older than protocol 5 reports none
    readonly property var caps: conv.live?.caps ?? conv.host.agents[conv.agent]?.caps
        ?? ({ rewind: conv.agent === "claude", rewindFiles: conv.agent === "claude", aside: conv.agent === "claude" })
    // A host older than protocol 5 runs every session as Claude Code (`claude --resume <codex id>`):
    // other agents' sessions are not sent to it.
    readonly property bool oldHost: conv.host.protoMismatch && conv.agent !== "claude"
    // the host changes a running session's level (Claude: apply_flag_settings; others: next turn)
    readonly property bool canEffort: conv.host.features.includes("effort") && conv.caps?.effort !== false
    readonly property string resumeCommand: {
        const s = conv.session;
        if (!s || s.fresh) return "";
        if (s.resume) return s.resume;
        const run = { codex: `codex resume ${s.id}`, pi: `pi --session ${s.id}`, opencode: `opencode --session ${s.id}` }[conv.agent] ?? `claude --resume ${s.id}`;
        return s.cwd ? `cd '${s.cwd.replace(/'/g, "'\\''")}' && ${run}` : run;
    }
    // Appended to the first message of a fresh session in the notch's form (a dropped file's or
    // page's provenance, from claude.qml's startIn), then cleared.
    property string desktopContext: ""
    function prefill(text) { composer.setText(text); }
    signal agentChosen(string tool)
    // ── accounts, model, effort ─────────────────────────────────────────────
    property var accounts: null       // AccountsModel; with none given this makes its own
    readonly property var acc: conv.accounts ?? ownAccounts.item
    Loader {
        id: ownAccounts
        active: conv.accounts === null
        sourceComponent: AccountsModel { host: conv.host }
    }
    // the box's menus' ground: the window binds its overlay (the rail menu's ground); the fallback
    // is that mix over surfaceContainerLow instead of the terminal background
    property color ground: ColorUtils.mix(Appearance.m3colors.m3surfaceContainerLow, Appearance.m3colors.m3primaryContainer, 0.8)
    signal prefsRequested()
    signal settingsRequested(string anchor)
    function openRunCove() { composer.toggleMenu("run"); }
    // a fresh session's agent menu; a started session's only when its account needs a step
    function openAgentCove(setup) { composer.menu === "agent" ? composer.closeMenu() : composer.openMenu("agent", setup); }
    // A fresh session takes its folder's defaults for the agent (agent-host `resolve`): account,
    // model, effort and mode, shown on the chips and sent with the first message.
    function resolveRun() {
        const s = conv.session;
        if (!s?.fresh || !conv.acc?.available) return;
        const cwd = s.cwd, agent = conv.agent;
        conv.acc.resolve(cwd, agent, r => {
            if (!r || !conv.session?.fresh || conv.session.cwd !== cwd || conv.agent !== agent) return;
            if (!conv.accountPicked) conv.chosenAccount = r.account ?? "";
            conv.chosenModel = r.model ?? "";
            conv.chosenEffort = r.effort ?? "";
            if (r.mode) conv.chosenMode = conv.modeOf(r.mode);
        });
    }
    onAgentChanged: if (conv.session?.fresh) {
        if (!conv.accountPicked) conv.chosenAccount = "";
        conv.resolveRun();
    }
    // "Use for new sessions in <folder>": this run becomes the folder's default; asked again on the
    // run that already is, it is cleared
    function keep(over) {
        const f = composer.keepFolder;
        if (!f.length || !conv.acc?.available) return;
        const r = Object.assign({ agent: conv.agent, account: conv.chosenAccount, model: conv.chosenModel, effort: conv.chosenEffort, mode: conv.chosenMode }, over);
        const entry = { account: r.account || null, model: r.model || null, effort: r.effort || null };
        const cur = conv.acc.defaults?.folders?.[f];
        const had = cur?.run?.[r.agent] ?? {};
        const same = cur && cur.agent === r.agent && (cur.mode ?? "") === r.mode
            && ["account", "model", "effort"].every(k => (had[k] ?? null) === entry[k]);
        if (same) conv.acc.setDefaults(f, { agent: null, mode: null, run: { [r.agent]: null } });
        else conv.acc.setDefaults(f, { agent: r.agent, mode: r.mode, run: { [r.agent]: entry } });
    }
    // Praxis's own preferences: the models lately picked, per agent (newest first, five)
    FileView {
        id: prefsFile
        path: `${Directories.state}/user/claude-prefs.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property var prefs: {
        try { return JSON.parse(prefsFile.text() || "{}"); } catch (e) { return {}; }
    }
    function noteRecent(agent, id) {
        if (!id || id === "default") return;
        const p = Object.assign({ version: 1 }, conv.prefs);
        const recent = Object.assign({}, p.recent ?? {});
        recent[agent] = [id].concat((recent[agent] ?? []).filter(x => x !== id)).slice(0, 5);
        p.recent = recent;
        prefsFile.setText(JSON.stringify(p) + "\n");
    }
    // a process that ended because its sign-in is gone: { reason, text, images, files } of the
    // message it was given, for Send again once the account is back
    property var authLost: null
    property var lastSent: null
    // ── going back, and asking aside ──────────────────────────────────────────
    // Both are requests to the session's own process (Claude Code's rewind_conversation /
    // rewind_files / side_question, through agent-host). A session the host does not hold yet is
    // opened (resumed, nothing sent) first.
    function ensureHosted(then) {
        const s = conv.session;
        if (!s || s.fresh) return;
        if (conv.live) { then(); return; }
        conv.host.request({ op: "start", cwd: s.cwd, resume: s.id, mode: conv.chosenMode }, m => {
            if (m.ev === "started") then();
            else { conv.error = m.message ?? "Could not open the session."; errorFade.restart(); }
        });
    }
    function lastUserRec() {
        for (let i = conv.items.length - 1; i >= 0; i--)
            if (conv.items[i].role === "user" && (conv.items[i].rec ?? "").length) return conv.items[i].rec;
        return "";
    }
    property string rewindAt: ""      // the message whose "go back" question is open
    property var rewindFiles: null    // what putting files back would change (a dry run), null while it is asked
    property bool rewinding: false
    // Claude Code writes the rewind into the transcript only with the next message: until then the
    // file still reads as before, so the cut is kept here (session -> the message it went back to)
    property var cuts: ({})
    function askRewind(rec) {
        conv.rewindAt = rec;
        conv.rewindFiles = null;
        const id = conv.session.id;
        conv.ensureHosted(() => conv.host.request({ op: "rewind_files", id: id, message: rec, dry: true }, m => {
            if (conv.rewindAt === rec) conv.rewindFiles = m.ev === "control" ? (m.response ?? {}) : { canRewind: false };
        }));
    }
    function doRewind(rec, withFiles) {
        const id = conv.session.id;
        const lastSeen = conv.lastUserRec();
        conv.rewinding = true;
        const fail = why => { conv.rewinding = false; conv.rewindAt = ""; conv.error = why; errorFade.restart(); };
        const back = () => conv.host.request({ op: "rewind", id: id, message: rec, lastSeen: lastSeen }, m => {
            if (m.ev !== "control" || !m.response?.rewound) { fail(`Could not go back: ${m.message ?? m.response?.error ?? "no answer"}`); return; }
            conv.rewinding = false;
            conv.rewindAt = "";
            conv.cuts = Object.assign({}, conv.cuts, { [id]: rec });
            conv.applyCut();
            composer.setText(m.response.prefillText ?? "");
            conv.loadChanges();
        });
        conv.ensureHosted(() => {
            if (!withFiles) { back(); return; }
            conv.host.request({ op: "rewind_files", id: id, message: rec }, m => {
                if (m.ev !== "control" || m.response?.canRewind === false) { fail(`Could not put the files back: ${m.message ?? m.response?.error ?? "no answer"}`); return; }
                back();
            });
        });
    }
    // the conversation as it stands after a rewind: everything from the message it went back to
    function applyCut() {
        const s = conv.session;
        const rec = s ? conv.cuts[s.id] : undefined;
        if (!rec) return;
        const at = conv.items.findIndex(i => i.role === "user" && i.rec === rec);
        if (at < 0) {
            // the transcript has the rewind itself now (the message is off its branch)
            const c = Object.assign({}, conv.cuts);
            delete c[s.id];
            conv.cuts = c;
            return;
        }
        conv.items = conv.items.slice(0, at);
        conv.sync();
    }
    // an answer to a card: one the session can no longer take says so instead of vanishing
    function answer(req) {
        conv.host.request(req, m => {
            if (m.ev !== "error") return;
            conv.error = m.message === "no such request" ? "That request had already closed, so your answer was not used."
                : `Your answer did not reach ${conv.agentName}: ${m.message ?? "no reply"}`;
            errorFade.restart();
        });
    }
    property int hoverTurn: -1        // the turn under the pointer: its footer shows
    // Undo on a turn's changes card: the files go back to how they were before that turn's message
    function undoTurn(rec, done) {
        const id = conv.session.id;
        conv.ensureHosted(() => conv.host.request({ op: "rewind_files", id: id, message: rec }, m => {
            const ok = m.ev === "control" && m.response?.canRewind !== false && !m.response?.error;
            if (!ok) { conv.error = `Could not undo: ${m.message ?? m.response?.error ?? "no answer"}`; errorFade.restart(); }
            done(ok);
            conv.loadChanges();
        }));
    }
    property var asideThread: []      // [{ question, response, pending, error }]
    function askAside(q) {
        const s = conv.session;
        if (!s || s.fresh) return;
        const history = conv.asideThread.filter(e => (e.response ?? "").length).map(e => ({ question: e.question, response: e.response }));
        const at = conv.asideThread.length;
        conv.asideThread = conv.asideThread.concat([{ question: q, pending: true }]);
        const id = s.id;
        conv.ensureHosted(() => conv.host.request({ op: "side_question", id: id, question: q, history: history }, m => {
            if (!conv.session || conv.session.id !== id || at >= conv.asideThread.length) return;
            const t = conv.asideThread.slice();
            t[at] = m.ev === "control" ? { question: q, response: m.response?.response ?? "" } : { question: q, error: m.message ?? "No answer came." };
            conv.asideThread = t;
        }));
    }
    signal agentOpened(string agent)
    signal runOpened(string run)
    signal stopTask(string task)
    signal agentsToggled()
    signal pinToggled()
    signal changesViewed(var edits)   // a turn's card: that turn's edits, for the review
    signal filesToggled()
    signal started(var session)
    signal folderChosen(string path)

    readonly property var live: conv.session && !conv.session.fresh ? (conv.host.live[conv.session.id] ?? null) : null
    readonly property var terminal: conv.session && !conv.session.fresh ? (conv.host.terminals[conv.session.id] ?? null) : null
    // a turn agent-host's previous process is finishing (Host.leftovers): followed, and a message waits for its end
    readonly property var leftover: conv.session && !conv.session.fresh ? (conv.host.leftovers[conv.session.id] ?? null) : null
    readonly property bool running: (conv.live !== null && (conv.live.alive || conv.live.state !== "idle")) || conv.terminal !== null || conv.leftover !== null
    readonly property bool working: (conv.live !== null && conv.live.state === "working") || (conv.terminal !== null && conv.terminal.status === "busy")
        || (conv.leftover !== null && conv.leftover.status === "busy")
    // Open in a terminal: followed here, not typed into (two processes would write one conversation). The host
    // holding it too no longer unlocks it once the roster can tell its own processes from a terminal (`checked`).
    readonly property bool locked: conv.terminal !== null && (conv.live === null || conv.terminal.checked === true)
    readonly property var pending: conv.live ? (conv.live.pending ?? []) : []
    // 768 in a window, growing with it to 960 (60 % of the room): full screen read as squeezed
    readonly property real columnWidth: Math.min(conv.width - 48, Math.max(768, Math.min(960, conv.width * 0.6)))
    readonly property var lastItem: conv.items.length ? conv.items[conv.items.length - 1] : null
    // The newest turn's steps still without a result: several run at once (a slow command beside a quick read,
    // whose result used to end the slow one's "running"). They run while the turn is open; with it over, only an
    // agent's does (a subagent still working in the background) - a step left by a process that died mid-way
    // kept the session "working" for good.
    readonly property var openSteps: {
        const out = [];
        for (let i = conv.items.length - 1; i >= 0; i--) {
            const it = conv.items[i];
            if (it.role === "user") break;
            if (it.kind === "tool" && it.result === undefined && !it.error) out.push(it);
        }
        return out;
    }
    readonly property var runningIds: !conv.running ? [] : conv.openSteps
        .filter(s => conv.turnOpen || conv.working || s.tool === "Agent" || s.tool === "Task").map(s => s.id)
    readonly property bool stepRunning: conv.runningIds.length > 0
    readonly property bool busy: conv.working || conv.stepRunning
    // The agent's own process is in a turn (working, or waiting on a permission answer): only then does a
    // message wait, and the run stop for it. `busy` alone also holds while a step shown has no result yet -
    // a subagent still running in the background after its turn ended - and a message sent then sat queued.
    readonly property bool turnOpen: (conv.live !== null && conv.live.state !== "idle") || (conv.leftover !== null && conv.leftover.status === "busy")
    onTurnOpenChanged: { conv.testLog(`turnOpen ${conv.turnOpen}`); conv.sendQueued(); }

    // ── items → blocks (one list row each) ─────────────────────────────────
    function build(items) {
        const out = [];
        let run = [];
        let no = 0;   // the turn each block belongs to: hovering any of a turn's rows shows its footer
        const push = b => { b.turn = no; out.push(b); };
        const flush = () => {
            if (run.length) push({ type: "activity", tools: run });
            run = [];
        };
        // a turn's end: what it changed in files, then its footer (the model, how long it took,
        // when, and all its prose for copying)
        let turn = null;
        const close = () => {
            if (turn) {
                const files = Object.values(turn.files);
                if (files.length) push({ type: "changes", files: files, rec: turn.rec, edits: turn.edits,
                                         add: files.reduce((a, f) => a + f.add, 0), del: files.reduce((a, f) => a + f.del, 0) });
                if (turn.text.length) push({ type: "footer", model: turn.model, secs: Math.round((turn.end - turn.start) / 1000), ts: turn.end, text: turn.text.join("\n\n") });
            }
            turn = null;
        };
        // steps (tool calls and thinking) between two pieces of prose fold into one Activity group,
        // so the answers carry the page and the process stays one quiet block
        for (const it of items) {
            if (turn && it.ts > 0) turn.end = Math.max(turn.end, it.ts);
            if (turn && it.kind === "tool" && it.error !== true && (it.files ?? []).length) turn.edits.push(it);
            if (turn && it.kind === "tool" && it.error !== true)
                for (const f of it.files ?? []) {
                    const e = turn.files[f.path] ?? (turn.files[f.path] = { path: f.path, add: 0, del: 0 });
                    e.add += f.add ?? 0;
                    e.del += f.del ?? 0;
                }
            if (it.kind === "tool" && (it.tool === "Agent" || it.tool === "Task")) {
                flush();
                const last = out[out.length - 1];
                if (last && last.type === "agents") last.calls.push(it);
                else push({ type: "agents", calls: [it] });
                continue;
            }
            if (it.kind === "tool" && it.tool === "Workflow") { flush(); push({ type: "workflow", item: it }); continue; }
            // a question to you is part of the conversation, not a step
            if (it.kind === "tool" && it.tool === "AskUserQuestion") { flush(); push({ type: "tool", item: it }); continue; }
            if (it.kind === "tool" || it.kind === "thinking") { run.push(it); continue; }
            if (it.kind === "result") continue;
            if (it.kind === "queue") continue;   // Claude Code's queue: shown above the box, not as rows
            flush();
            if (it.kind === "note") push({ type: "note", text: it.text });
            else if (it.role === "user") {
                const last = out[out.length - 1];
                const ts = it.ts ?? 0;
                // A message's image blocks are written either side of its text, and both halves carry
                // the message's own timestamp: one message stays one bubble whichever comes first.
                const same = last && last.type === "user" && last.ts === ts;
                if (it.kind === "image") {
                    if (same) { last.images = (last.images ?? []).concat(it.images ?? []); continue; }
                    close();
                    no++;
                    push({ type: "user", text: "", mono: false, images: it.images ?? [], ts: ts, rec: it.rec ?? "" });
                    turn = { start: ts, end: ts, model: "", text: [], files: {}, edits: [], rec: it.rec ?? "" };
                    continue;
                }
                // the desktop context the notch sends after a question is not part of what you said
                const said = it.text.replace(/\s*<desktop-context>[\s\S]*<\/desktop-context>\s*$/, "");
                if (same && !last.text.length) { last.text = said; last.mono = it.kind === "command"; last.rec = it.rec ?? last.rec; if (turn) turn.rec = last.rec; continue; }
                close();
                no++;
                push({ type: "user", text: said, mono: it.kind === "command", images: it.images ?? [], ts: ts, rec: it.rec ?? "" });
                turn = { start: ts, end: ts, model: "", text: [], files: {}, edits: [], rec: it.rec ?? "" };
            } else if (it.kind === "text") {
                if (turn) { turn.text.push(it.text); if (it.model) turn.model = it.model; }
                for (const b of conv.blocksOf(it.text)) push(Object.assign({}, b));
            }
        }
        flush();
        if (!conv.busy) close();
        // only the newest turn's changes can be undone: an older turn's are under later ones
        let lastUser = -1;
        for (let i = out.length - 1; i >= 0 && lastUser < 0; i--) if (out[i].type === "user") lastUser = i;
        for (let i = lastUser + 1; i < out.length; i++) if (out[i].type === "changes") { out[i].latest = true; break; }
        return out.filter(b => b.type !== "text" || b.content.length > 0);
    }
    // Splitting markdown is the cost in build(), and build() runs on every follow tick: prose is
    // split once and kept by its text. The blocks are read, never changed, so they can be shared.
    property var mdCache: ({})
    function blocksOf(text) {
        let blocks = conv.mdCache[text];
        if (blocks) return blocks;
        blocks = StringUtils.splitMarkdownBlocks(text).map(b => b.type === "code"
            ? { type: "code", content: conv.dedent(b.content), lang: b.lang ?? "", indent: conv.indentOf(b.content) >= 2 ? 16 : 0 }
            : { type: "text", content: b.content.trim() });
        conv.mdCache[text] = blocks;
        return blocks;
    }
    // a fence inside a list item keeps the list's indent on every line: that indent says it
    // belongs under the bullet, and the block is drawn there
    function indentOf(code) {
        const pads = code.replace(/\n+$/, "").split("\n").filter(l => l.trim().length).map(l => l.match(/^[ \t]*/)[0].length);
        return pads.length ? Math.min(...pads) : 0;
    }
    function dedent(code) {
        const lines = code.replace(/\n+$/, "").split("\n");
        const pads = lines.filter(l => l.trim().length).map(l => l.match(/^[ \t]*/)[0].length);
        const cut = pads.length ? Math.min(...pads) : 0;
        return lines.map(l => l.substring(Math.min(cut, l.match(/^[ \t]*/)[0].length))).join("\n");
    }
    // The blocks on screen, as built: a block made of the same items as last time is the same row,
    // and is not serialised again (that was most of a sync, a frame's worth on a long session).
    property var shownBlocks: []
    function sameBlock(a, b) {
        if (!a || !b) return false;
        const ka = Object.keys(a);
        if (ka.length !== Object.keys(b).length) return false;
        for (const k of ka) {
            const x = a[k], y = b[k];
            if (x === y) continue;
            if (Array.isArray(x) && Array.isArray(y) && x.length === y.length && x.every((v, i) => v === y[i])) continue;
            return false;
        }
        return true;
    }
    function sync() {
        if (conv.testRun && conv.shownSession !== conv.session) conv.testRebuiltOld++;
        const tb = Date.now();
        const blocks = conv.build(conv.items);
        if (conv.testRun && conv.swapping) conv.testLog(`swap build ${blocks.length} blocks ${Date.now() - tb} ms`);
        const ta = Date.now();
        const prev = conv.shownBlocks;
        const atEnd = list.atYEnd || list.contentHeight <= list.height + 4;
        for (let i = 0; i < blocks.length; i++) {
            if (i < blockModel.count) {
                if (conv.sameBlock(prev[i], blocks[i])) continue;
                const row = JSON.stringify(blocks[i]);
                if (blockModel.get(i).json !== row) { blockModel.setProperty(i, "json", row); blockModel.setProperty(i, "turn", blocks[i].turn); }
            } else {
                if (!conv.swapping) conv.testLog(`row + ${blocks[i].type}`);
                conv.footerHoldUntil = i;
                const shown = conv.replacing && (blocks[i].type === "text" || blocks[i].type === "code") || conv.echoed && blocks[i].type === "user";
                blockModel.append({ json: JSON.stringify(blocks[i]), born: conv.settled && !conv.swapping && !shown ? Date.now() : 0, turn: blocks[i].turn });
            }
        }
        if (conv.testRun && conv.swapping) conv.testLog(`swap rows into the model ${Date.now() - ta} ms`);
        conv.shownBlocks = blocks;
        if (conv.footerHold > 0 && conv.footerHoldUntil < prev.length) conv.releaseFooter();   // no new row coming
        while (blockModel.count > blocks.length) blockModel.remove(blockModel.count - 1);
        if (atEnd && !list.atEnd && !conv.swapping) toEnd.restart();   // following: onContentHeightChanged
        conv.dropStale();
    }
    // new items from a follow: results attach to their call, the rest append
    function merge(fresh) {
        conv.holdFooter();
        const next = conv.items.slice();
        let echoed = false;
        for (const it of fresh) {
            if (it.kind === "result") {
                for (let j = next.length - 1; j >= 0; j--)
                    if (next[j].id === it.id) { next[j] = conv.attachResult(next[j], it); break; }
                continue;
            }
            // a slash command echoes as kind "command": without it the grey bubble stays beside it
            if (it.role === "user" && (it.kind === "text" || it.kind === "image" || it.kind === "command")) {
                if (conv.pendingUser.length || conv.pendingImages.length) { echoed = true; Qt.callLater(conv.sendQueued); }
                // the bubble goes when its row is drawn, in the same frame: cleared here, it went a frame before the
                // row came, the list was 144 px shorter for that frame, and the view jumped as a reply began (2026-10-10)
                conv.testLog(`row read "${String(it.text ?? "").substring(0, 20)}" echo="${conv.pendingUser.substring(0, 20)}"`);
                if (conv.pendingUser.length || conv.pendingImages.length) { conv.echoHandoff = true; echoHandoffTimer.restart(); }
                conv.sendingNow = false;
            }
            if (it.kind === "queue") continue;
            // the transcript can carry one thinking twice (a second message id); show it once
            if ((it.kind === "thinking" || it.narration) && next.slice(-8).some(x => x.kind === it.kind && x.text === it.text)) continue;
            next.push(it);
        }
        conv.waiting = conv.applyQueue(conv.waiting, fresh);
        if (conv.liveTools.length) conv.liveTools = conv.liveTools.filter(t => !next.some(i => i.kind === "tool" && i.id === t.id));
        conv.items = next;
        conv.echoed = echoed;
        conv.sync();
        conv.echoed = false;
    }
    property bool echoed: false     // this sync's user row replaces the echo already on screen

    // Tool calls being written (an agent's brief can take Claude half a minute): shown as they start, as the
    // terminal does ("Initializing..."), with their short description once it is in. The transcript has a call
    // only when it is complete; its row then takes the place of this one, matched by id.
    property var liveTools: []
    property var liveInput: ({})   // id -> the input JSON so far (changed in place: no rebuild per delta)
    function toolStarted(index, block) {
        if (!block?.id) return;
        conv.liveInput[block.id] = "";
        conv.liveTools = conv.liveTools.concat([{ kind: "tool", tool: block.name ?? "", id: block.id, index: index, desc: "" }]);
    }
    function toolInput(index, part) {
        let at = -1;
        for (let i = conv.liveTools.length - 1; i >= 0 && at < 0; i--) if (conv.liveTools[i].index === index) at = i;
        if (at < 0) return;
        const t = conv.liveTools[at];
        const json = (conv.liveInput[t.id] ?? "") + part;
        conv.liveInput[t.id] = json;
        const field = k => { const m = json.match(new RegExp(`"${k}"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)`)); return m ? m[1].replace(/\\n/g, " ").replace(/\\(.)/g, "$1") : ""; };
        const path = field("file_path");
        const desc = field("description") || (path ? path.split("/").pop() : "") || field("command").substring(0, 80) || field("pattern") || field("query");
        if (desc !== t.desc) {
            const next = conv.liveTools.slice();
            next[at] = Object.assign({}, t, { desc: desc });
            conv.liveTools = next;
        }
    }

    // Claude Code's queue as the transcript tells it, for what a person typed: in when typed (enqueue), out when it
    // is said (its user row, mid-turn or as the next turn), taken back (remove) or pulled into the box (popAll).
    // Task notifications share the queue and leave it in Claude Code's own order, and a dequeue names nothing:
    // read first-in-first-out, one stray notification left every later message showing as waiting while it was
    // already sent (owner 2026-10-09).
    function applyQueue(list, ops) {
        let q = list.slice();
        for (const it of ops) {
            if (it.kind === "queue") {
                const t = String(it.text ?? "").trim();
                if (it.op === "enqueue" && t.length && !t.startsWith("<")) q.push(t);
                else if (it.op === "remove") { const i = q.indexOf(t); if (i >= 0) q.splice(i, 1); }
                else if (it.op === "popAll") q = [];
            } else if (q.length && it.role === "user" && (it.kind === "text" || it.kind === "command")) {
                const said = String(it.text ?? "").trim();
                const i = q.findIndex(t => t === said || (t.length >= 8 && said.includes(t)) || (said.length >= 8 && t.includes(said)));
                if (i >= 0) q.splice(i, 1);
            }
        }
        return q;
    }
    // A watch first replays the stream's backlog, then answers: what streams in between is old. Text rebuilt
    // from it is stale once its finished copy is a row - it stood under the next command and into the next turn
    // as if it were the reply (2026-10-09). Only replayed text is checked: a new reply that starts or reads like
    // an earlier one stays, and a block replayed from its middle is matched as part of its row.
    property bool replaying: false
    function emptyReplay() { return { text: "", thought: "", hasText: false, hasThought: false }; }
    property var replayBuf: conv.emptyReplay()   // filled in place while replaying: no redraw per word
    property bool textReplayed: false
    property bool thoughtReplayed: false
    function dropStale() {
        if (!conv.textReplayed && !conv.thoughtReplayed) return;
        const norm = t => String(t ?? "").trim().replace(/\s+/g, " ");
        const seen = live => {
            const t = norm(live);
            if (t.length < 24) return false;
            for (let i = conv.items.length - 1; i >= 0; i--) {
                const it = conv.items[i];
                if (it.role === "assistant" && (it.kind === "text" || it.kind === "thinking") && norm(it.text).includes(t)) return true;
            }
            return false;
        };
        if (conv.textReplayed && seen(conv.partialText)) { conv.partialText = ""; conv.textReplayed = false; }
        if (conv.thoughtReplayed && seen(conv.partialThinking)) { conv.partialThinking = ""; conv.thoughtReplayed = false; }
    }

    // A result read in a later chunk than its call comes back on its own for us to join up, and
    // it brings the pictures the call looked at: they are the only way ToolLine can draw them.
    function attachResult(call, result) {
        const out = Object.assign({}, call, { result: result.result, error: result.error });
        if ((result.images ?? []).length) out.images = result.images;
        return out;
    }

    // ── loading and following ───────────────────────────────────────────────
    ListModel { id: blockModel }

    // Switching sessions: the one on screen stays until the next has arrived, then the whole list
    // is replaced in one go and put at its end before the frame is drawn. No blank frame, no
    // fade, no scroll; "Reading…" only when a transcript is slow to read.
    property real testChosenAt: 0
    function load() {
        conv.testChosenAt = Date.now();
        conv.testLog("switch: load starts");
        // the message that started this session keeps its echo through the swap to the real one
        const startedHere = conv.starting.length > 0 && conv.session !== null && conv.session.id === conv.starting;
        conv.starting = "";
        conv.offset = -1;
        conv.busyFlipAt = 0;
        conv.partialText = "";
        conv.partialThinking = "";
        if (!startedHere) { conv.pendingUser = ""; conv.pendingImages = []; }
        conv.error = "";
        conv.settled = false;
        conv.shownChars = 0;
        conv.seenSeq = -1;
        conv.queued = [];
        conv.sendingNow = false;
        conv.echoHandoff = false;
        conv.waiting = [];
        conv.liveTools = [];
        conv.textReplayed = false;
        conv.thoughtReplayed = false;
        conv.replayBuf = conv.emptyReplay();
        conv.cost = 0;
        conv.liveCommands = null;
        conv.authLost = null;
        // a message sent from another session is not this one's to send again
        if (!startedHere) conv.lastSent = null;
        composer.dismiss();
        conv.openIds = ({});
        conv.mdCache = ({});
        conv.readFailed = false;
        conv.rewindAt = "";
        conv.asideThread = [];
        if (conv.session && !conv.session.fresh) conv.desktopContext = "";
        // a request lost with the socket never answers: its flag would park the follow loop for good
        conv.following = false;
        conv.loading = false;
        // the chips belong to the session: what the host reports for a running one, else the default.
        // Read from the new session: inside onSessionChanged `conv.live` is still the previous one's,
        // which gave a fresh Codex session the last Claude session's model.
        // A session started from here keeps what was chosen for it. Any other takes what it reports:
        // the full model value, so a resume runs the same model.
        const live = conv.session && !conv.session.fresh ? (conv.host.live[conv.session.id] ?? null) : null;
        if (!startedHere) {
            conv.chosenMode = conv.modeOf(live ? (live.mode ?? "") : "");
            conv.chosenModel = live?.model || conv.session?.model || "";
            conv.chosenEffort = "";
            conv.chosenAccount = live?.account || conv.session?.account || "";
            conv.accountPicked = false;
        }
        if (conv.session?.fresh) conv.resolveRun();
        if (conv.watching.length) { conv.host.request({ op: "unwatch", id: conv.watching }); conv.watching = ""; }
        if (!conv.session || conv.session.fresh) { conv.swapIn([], 0, 0); conv.changes = { files: [], add: 0, del: 0 }; return; }
        const id = conv.session.id;
        // Only the newest read may change the screen. A session started a moment ago is not on disk
        // yet, its first read can outlast loadTimeout, and that read's late "not found" used to wipe
        // what the retry had already shown (the first message vanished for seconds).
        const gen = ++conv.loadGen;
        conv.loading = true;
        slowRead.restart();
        loadTimeout.restart();
        conv.testLog("switch: transcript asked");
        conv.host.request({ op: "transcript", id: id, limit: 400 }, m => {
            conv.testLog(`switch: reply here (${(m.items ?? []).length} items)`);
            if (gen !== conv.loadGen || !conv.session || conv.session.id !== id) return;
            conv.loading = false;
            if (m.disconnected) return;   // the socket went: what is on screen stays until it is back
            loadTimeout.stop();
            conv.loadRetried = false;
            if (m.ev !== "transcript") {
                // a session started a moment ago has no file yet; for any other it is a read that failed
                conv.swapIn([], 0, 0);
                // one started from here a moment ago may not be listed as running yet either
                conv.offset = conv.live || startedHere ? 0 : -1;
                conv.readFailed = conv.live === null && !startedHere;
                // its rows come with the follow: from here they ease in, as after any first read (a session opened
                // before its transcript was on disk stayed unsettled for good)
                conv.settled = !conv.readFailed;
                if (conv.readFailed) { conv.error = m.message ?? "That conversation could not be read."; errorFade.restart(); }
                return;
            }
            conv.byteCursor = m.startByte !== undefined;
            conv.waiting = conv.applyQueue([], m.items);
            const typed = conv.pendingUser.trim();
            if (typed.length && m.items.some(i => i.role === "user" && (i.text ?? "").trim() === typed)) { conv.pendingUser = ""; conv.pendingImages = []; }
            conv.swapIn(m.items, m.startByte ?? m.start, m.total ?? m.items.length);
            conv.offset = m.offset;
            conv.settled = true;
            conv.applyCut();
        });
        conv.loadChanges();
        if (conv.live) conv.watch();
    }
    // the mode a running session reports, as the composer names it (Claude Code says "default" for
    // asking first); one the composer does not offer, or none, leaves the default
    function modeOf(mode) {
        const m = mode === "default" ? "manual" : mode;
        return ["auto", "manual", "acceptEdits", "plan", "bypassPermissions"].includes(m) ? m : "auto";
    }
    property var shownSession: null   // the session whose conversation is on screen (header follows it)
    function swapIn(items, start, total) {
        conv.swapping = true;
        conv.shownSession = conv.session;
        conv.items = items;
        conv.start = start;
        conv.total = total;
        const t0 = Date.now();
        // only the rows on screen at once; the ones kept ready off screen (cacheBuffer) follow in steps, one per
        // frame (a switch 17-23 ms instead of 28-43)
        list.cacheBuffer = 0;
        bufferGrow.restart();
        blockModel.clear();
        // the empty list keeps the last conversation's scroll position, and the new rows were laid out from the
        // top down to it: a long one built every row (246, 280 ms) before the jump to the end. Above all of
        // them, none are laid out until the jump.
        if (items.length) list.contentY = -1e7;
        conv.sync();
        const t1 = Date.now();
        conv.jumpToEnd();          // same handler, same frame: drawn already at the end
        // rows change height once laid out (a long one 64 px shorter left the top of the view empty for two frames,
        // the blink on a switch): what is on screen is laid out again and the view goes back to the end
        list.cacheBuffer = 1;
        conv.jumpToEnd();
        if (conv.testRun) { conv.testSwitch = []; conv.testSwitchLeft = 30; }
        if (conv.testRun) conv.testLog(`swap total ${Date.now() - t0} ms (sync ${t1 - t0}, to the end ${Date.now() - t1}); click to rows ${Date.now() - conv.testChosenAt} ms`);
        conv.swapping = false;
        openSettle.restart();      // once more when the rows near the end have their real heights
    }
    property bool swapping: false
    property bool replacing: false    // a follow is turning the streamed reply into rows
    property int loadGen: 0
    Timer { id: slowRead; interval: 300 }
    // the running session's own command list (its skills and plugins included)
    function loadCommands() {
        if (!conv.live || !conv.live.alive) return;
        const id = conv.session.id;
        conv.host.request({ op: "info", id: id }, m => {
            const list = m.info?.commands ?? [];
            if (conv.session && conv.session.id === id && list.length) conv.liveCommands = conv.commandsOf(list);
        });
    }
    // when it stops, the next queued message goes
    function sendQueued() {
        if (conv.queued.length) conv.testLog(`sendQueued open=${conv.turnOpen} n=${conv.queued.length} locked=${conv.locked} sending=${conv.sendingNow}`);
        if (conv.turnOpen || !conv.queued.length || conv.locked || conv.sendingNow) return;
        const next = conv.queued[0];
        conv.queued = conv.queued.slice(1);
        conv.send(next.text, next.images, next.files, true);
    }
    function loadChanges() {
        if (!conv.session || conv.session.fresh) return;
        const id = conv.session.id;
        conv.host.request({ op: "changes", id: id, before: conv.cuts[id] }, m => { if (m.ev === "changes" && conv.session && conv.session.id === id) conv.changes = m; });
    }
    function follow() {
        // A follow in flight can come back just before the line that asked for this one was written:
        // dropping the ask left the reply's finished text unread until the next event (after the command
        // it led into had run), so the text the reply had shown was gone from the screen for that long.
        if (conv.following) { conv.followAgain = true; return; }
        if (!conv.session || conv.session.fresh || conv.offset < 0) return;
        const id = conv.session.id;
        conv.following = true;
        followTimeout.restart();
        const gen = ++conv.followGen;
        conv.host.request({ op: "transcript", id: id, after: conv.offset }, m => {
            if (gen !== conv.followGen) return;   // timed out and asked again: the newer read carries it
            conv.following = false;
            followTimeout.stop();
            if (conv.followAgain) { conv.followAgain = false; followSoon.restart(); }
            if (!conv.session || conv.session.id !== id || m.ev !== "transcript") return;
            conv.offset = m.offset;
            if (m.items.length) {
                conv.holdFooter();
                // The live text and thought give way only to their own finished copies: a follow that brings
                // the thinking before the text is done used to wipe the text being written (it started over
                // mid-sentence). Matched on their start, which the transcript keeps as streamed.
                const has = (kind, live) => {
                    const head = live.trim().replace(/\s+/g, " ").substring(0, 160);
                    return head.length > 0 && m.items.some(i => i.role === "assistant" && i.kind === kind
                        && (i.text ?? "").trim().replace(/\s+/g, " ").startsWith(head));
                };
                const textIn = has("text", conv.partialText);
                // the reply already on screen becomes its rows: they take its place, not rise in
                conv.replacing = textIn;
                if (textIn) conv.partialText = "";
                // narration streams as a thinking block and its finished copy is text
                if (has("thinking", conv.partialThinking) || has("text", conv.partialThinking)) conv.partialThinking = "";
                conv.merge(m.items);
                conv.replacing = false;
            }
            // the turn is over and its transcript read: nothing is being written any more
            if (!conv.busy && conv.partialText.length) conv.partialText = "";
        });
    }
    // The reply's replayed items are not read: the transcript follow carries the conversation. What
    // it is read for is failure - a watch the host refused must not leave `watching` set, or
    // onLiveChanged's guard blocks every retry and the session never streams again.
    function watch() {
        if (!conv.session || conv.session.fresh) return;
        const id = conv.session.id;
        conv.watching = id;
        conv.replaying = true;
        conv.host.request({ op: "watch", id: id, from: (conv.live?.seq ?? 0) + 1 }, m => {
            conv.replaying = false;
            const b = conv.replayBuf;
            conv.replayBuf = conv.emptyReplay();
            if (b.hasText) { conv.partialText = b.text; conv.textReplayed = true; }
            if (b.hasThought) { conv.partialThinking = b.thought; conv.thoughtReplayed = true; }
            conv.dropStale();
            if (conv.watching === id && m.ev !== "watching") conv.watching = "";
        });
    }
    // done(n): called with the number of blocks the earlier part added at the top
    function earlier(done) {
        if (conv.paging || !conv.session || conv.session.fresh) return;
        const id = conv.session.id;
        conv.paging = true;
        const req = { op: "transcript", id: id, limit: 400 };
        if (conv.byteCursor) req.beforeByte = conv.start; else req.before = conv.start;
        conv.host.request(req, m => {
            conv.paging = false;
            if (!conv.session || conv.session.id !== id || m.ev !== "transcript") return;
            // the whole list is rebuilt, so it is a swap: no rows ease in, and the end is not chased
            const was = blockModel.count;
            const hitsWere = conv.findHits.length;
            conv.swapping = true;
            conv.items = m.items.concat(conv.items);
            // the match being shown keeps its place: the matches above it moved its number
            if (conv.findAt >= 0) conv.findAt += conv.findHits.length - hitsWere;
            conv.start = m.startByte ?? m.start;
            blockModel.clear();
            conv.sync();
            toEnd.stop();
            toEndAgain.stop();
            list.atEnd = false;
            list.smooth = false;
            list.positionViewAtIndex(Math.max(0, blockModel.count - was), ListView.Beginning);
            list.smooth = true;
            conv.swapping = false;
            if (done) done(blockModel.count - was);
        });
    }
    // the list's 20 s refresh hands over a new copy of the same session: keep what is on screen
    property string loadedKey: ""
    property var drafts: ({})          // session key -> { text, files } typed there and not sent
    onSessionChanged: {
        const key = conv.session ? (conv.session.fresh ? `fresh:${conv.session.cwd}` : conv.session.id) : "";
        if (key === conv.loadedKey && key.length) {
            if (conv.shownSession && conv.session && conv.shownSession.id === conv.session.id) conv.shownSession = conv.session;
            return;
        }
        conv.closeFind();   // another session starts without the find
        // The box's draft belongs to its session: it stayed in the box when another was opened, ready to be sent
        // there by mistake. Kept by session while the app runs; a pre-fill (a drop, a page) comes after this.
        const d = Object.assign({}, conv.drafts);
        if (conv.loadedKey.length) {
            if (composer.text.trim().length || composer.attachments.length) d[conv.loadedKey] = { text: composer.text, files: composer.attachments };
            else delete d[conv.loadedKey];
        }
        const draft = d[key];
        delete d[key];
        conv.drafts = d;
        composer.setDraft(draft?.text ?? "", draft?.files ?? []);
        conv.loadedKey = key;
        conv.load();
    }
    // the turn's footer when the turn on screen ends - not when a switch to an idle session flips busy while the
    // old session's rows are still up (that rebuilt them and scrolled them down just before the swap)
    onBusyChanged: {
        // a turn seen starting in a session run here; not a switch, nor a session opened mid-turn: those count from the transcript
        conv.busyFlipAt = conv.busy && conv.live !== null && conv.shownSession === conv.session && !conv.loading ? Date.now() : 0;
        conv.tickBusy();
        if (!conv.busy && conv.shownSession === conv.session && !conv.loading) conv.sync();
        conv.sendQueued();
    }
    Timer { running: conv.busy; interval: 1000; repeat: true; onTriggered: conv.tickBusy() }
    onPartialTextChanged: if (conv.partialText.length < conv.shownChars) conv.shownChars = 0
    // deltas arrive in lumps; the reveal eats them at a steady rate, faster when far behind
    Timer {
        running: conv.shownChars < conv.partialText.length
        interval: 24
        repeat: true
        onTriggered: conv.shownChars = Math.min(conv.partialText.length, conv.shownChars + Math.max(2, Math.ceil((conv.partialText.length - conv.shownChars) / 10)))
    }
    // The reply on screen is drawn as its rows will be once the transcript has it. What is finished
    // is drawn once (livePieces): text up to a closed fence, the fenced code, and whole paragraphs
    // and list items. Only the tail being written is laid out again on each reveal step.
    ListModel { id: livePieces }
    property int liveAt: 0             // partialText before this is in livePieces
    property string liveTail: ""
    property var liveCode: null        // a fence still open: { content, indent }
    onShownCharsChanged: conv.reveal()
    function liveReset() { livePieces.clear(); conv.liveAt = 0; conv.liveTail = ""; conv.liveCode = null; }
    // a run of text that is final; `next` says what follows it in the same text: "para" (a paragraph:
    // the margin under the run's last paragraph is kept), "item" (its bulleted list goes on), "block"
    // (a list or a quote); "" when the text ends there, as a row does
    function livePush(text, next) {
        const t = text.trim();
        if (t.length) livePieces.append({ json: JSON.stringify({ type: "text", content: t, next: next }) });
    }
    function reveal() {
        const shown = conv.partialText.substring(0, conv.shownChars);
        if (shown.length < conv.liveAt) conv.liveReset();
        let at = conv.liveAt;
        let rest = shown.substring(at);
        // closed fences: the text before the first ends its block, the rest are blocks as blocksOf has them
        const fence = /```(\w+)?\n([\s\S]*?)```|<think>([\s\S]*?)<\/think>/g;
        let m, first = -1, last = 0;
        while ((m = fence.exec(rest)) !== null) { if (first < 0) first = m.index; last = fence.lastIndex; }
        if (first >= 0) {
            conv.livePush(rest.substring(0, first), "");
            for (const b of conv.blocksOf(rest.substring(first, last)))
                livePieces.append({ json: JSON.stringify(Object.assign({ next: "" }, b)) });
            at += last;
            rest = rest.substring(last);
        }
        // a fence still open: the text before it is final, the code shows as it comes
        const open = rest.search(/```\w*\n/);
        if (open >= 0) {
            conv.livePush(rest.substring(0, open), "");
            at += open;
            const head = /^```(\w*)\n/.exec(rest.substring(open));
            const code = rest.substring(open + head[0].length).replace(/(^|\n)`{1,2}$/, "");
            conv.liveCode = code.trim().length ? { content: conv.dedent(code), indent: conv.indentOf(code) >= 2 ? 16 : 0 } : null;
            conv.liveTail = "";
            conv.liveAt = at;
            return;
        }
        conv.liveCode = null;
        rest = rest.replace(/^\s+/, "");
        const cut = conv.liveCut(rest);
        if (cut) {
            conv.livePush(rest.substring(0, cut.at), cut.next);
            at = shown.length - rest.length + cut.at;
            rest = rest.substring(cut.at);
        }
        conv.liveAt = at;
        // a fence being opened is not shown as text first
        conv.liveTail = rest.replace(/(^|\n)`{1,3}\w*$/, "");
    }
    // Where text being written can be cut so that the two parts drawn one under the other look like
    // the whole drawn at once (Qt's layout, checked line for line): before a paragraph, a list or a
    // quote at the top level, or between two items of a bulleted list with nothing nested yet. Not
    // before a heading: drawn on its own it loses its top margin. A cut needs the line there to say
    // what it starts. Mirrors the block loop of Markdown.js toHtml(); returns { at, next } or null.
    function liveCut(text) {
        const lines = text.split("\n");
        const n = lines.length;          // the last line is still being written
        const starts = [];
        let o = 0;
        for (const l of lines) { starts.push(o); o += l.length + 1; }
        // a paragraph is known by its first letters (a "`" can still open a fence); anything else by its whole line
        const known = (j, para) => j < n - 1 || (para && /^([^\s\-*+_#>|\d`]|[-*+_][^\s\-*+_]|\*\*[^*\s]|__[^_\s]|\d+[^\d.)]|`[^`])/.test(lines[j]));
        let cut = null, seen = false;
        let i = 0;
        while (i < n) {
            const line = lines[i];
            if (!line.trim().length) { i++; continue; }
            const kind = Md.HEAD.test(line) ? "h" : Md.RULE.test(line) ? "r" : /^\s*>/.test(line) ? "q"
                : /^\s*\|/.test(line) && i + 1 < n && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1]) ? "t" : Md.LIST.test(line) ? "l" : "p";
            // (a line starting "|" is a table or not by the line under it)
            if (seen && (kind === "p" || kind === "l" || kind === "q") && /^[^\s|]/.test(line) && known(i, kind === "p"))
                cut = { at: starts[i], next: kind === "p" ? "para" : "block" };
            seen = true;
            if (kind === "h" || kind === "r") i++;
            else if (kind === "q") { while (i < n && /^\s*>/.test(lines[i])) i++; }
            else if (kind === "t") { i += 2; while (i < n && /^\s*\|/.test(lines[i])) i++; }
            else if (kind === "l") {
                const r = conv.listWalk(lines, i);
                // (a numbered item in a bulleted list is drawn with a bullet: a cut before it would number it)
                if (/^[-*+]\s/.test(line))
                    for (const it of r.items) if (it > i && it < r.nested && /^[-*+]\s/.test(lines[it])) cut = { at: starts[it], next: "item" };
                i = r.next;
            } else {
                i++;
                while (i < n && lines[i].trim().length && !Md.startsBlock(lines[i])) i++;
            }
        }
        return cut;
    }
    // Markdown.js list()'s walk: its top-level items, and the first nested line
    function listWalk(lines, i) {
        const base = Md.LIST.exec(lines[i])[1].length;
        const items = [];
        let nested = lines.length;
        while (i < lines.length) {
            const m = Md.LIST.exec(lines[i]);
            if (!m || m[1].length < base) break;
            if (m[1].length > base) {
                nested = Math.min(nested, i);
                i = conv.listWalk(lines, i).next;
                continue;
            }
            items.push(i);
            i++;
            while (i < lines.length && lines[i].trim().length && !Md.LIST.test(lines[i]) && !Md.startsBlock(lines[i].replace(/^\s+/, "")) && /^\s/.test(lines[i])) i++;
            while (i < lines.length && !lines[i].trim().length && i + 1 < lines.length && Md.LIST.test(lines[i + 1]) && Md.LIST.exec(lines[i + 1])[1].length >= base) i++;
        }
        return { next: i, items: items, nested: nested };
    }
    // the margin under a run's last paragraph or heading, which a separate document leaves out
    function lastGap(html) {
        if (!html.endsWith("</p>")) return 0;
        const m = /margin-bottom:(\d+)px/.exec(html.substring(html.lastIndexOf("<p ")));
        return m ? Number(m[1]) : 0;
    }
    onLiveChanged: {
        if (conv.live && conv.session && conv.watching !== conv.session.id) conv.watch();
        if (conv.live && conv.session && !conv.session.fresh && conv.offset < 0 && !conv.loading && !conv.readFailed) conv.offset = 0;
        if (conv.live && conv.live.alive && conv.liveCommands === null) conv.loadCommands();
    }
    // a session in a terminal is read every 0.4 s (a read of the new bytes takes the host about 1 ms):
    // its steps come as the CLI writes them
    Timer { running: conv.running && conv.offset >= 0; interval: conv.terminal !== null ? 400 : conv.busy ? 600 : 1500; repeat: true; onTriggered: conv.follow() }
    Timer { id: followSoon; interval: 60; onTriggered: conv.follow() }
    // a glide already under way is heading for the end: a jump would cut it short by the distance left
    Timer { id: toEnd; interval: 30; onTriggered: { list.atEnd = true; if (!chase.running) list.positionViewAtEnd(); toEndAgain.restart(); } }
    // opening a session: jump (no glide) to the end twice, once rows have real heights, then show
    function jumpToEnd() { list.smooth = false; list.atEnd = true; list.jumping = true; list.positionViewAtEnd(); list.jumping = false; list.smooth = true; }
    Timer {
        id: bufferGrow
        interval: 16
        repeat: true
        onTriggered: { list.cacheBuffer = Math.min(1600, list.cacheBuffer + 400); if (list.cacheBuffer >= 1600) stop(); }
    }
    Timer { id: openSettle; interval: 60; onTriggered: { conv.testLog("switch: settle jump"); if (list.atEnd) conv.jumpToEnd(); } }
    Timer { id: toEndAgain; interval: 120; onTriggered: if (list.atEnd && !chase.running) list.positionViewAtEnd() }
    Timer { id: errorFade; interval: 8000; onTriggered: conv.error = "" }
    // A host that is still starting can drop a request: no reply in 5 s, unwind and ask once more.
    Timer {
        id: loadTimeout
        interval: 5000
        onTriggered: {
            if (!conv.loading) return;
            conv.loading = false;
            if (!conv.loadRetried && conv.host.connected) { conv.loadRetried = true; conv.load(); }
        }
    }
    Timer { id: followTimeout; interval: 5000; onTriggered: conv.following = false }

    Connections {
        target: conv.host
        function onEvent(id, seq, data) {
            if (!conv.session || id !== conv.session.id) return;
            // A watch replays the backlog from `from`, which is behind whenever the host has not
            // announced state lately: without this the replayed deltas are appended a second time.
            if (seq <= conv.seenSeq) return;
            conv.seenSeq = seq;
            if (data.type === "system" && data.subtype === "commands_changed") {
                conv.liveCommands = conv.commandsOf(data.commands);
            } else if (data.type === "stream_event" && typeof data.parent_tool_use_id === "string") {
                // a subagent's own stream: its text is not this reply's
            } else if (data.type === "stream_event" && conv.replaying) {
                // The backlog a watch replays is gathered quietly and shown once, when the watch answers: a long
                // reply replayed word by word redrew the live text hundreds of times in one go (a switch froze ~120 ms)
                const e = data.event ?? {}, b = conv.replayBuf;
                const block = e.type === "content_block_start" ? (e.content_block?.type ?? "") : "";
                if (block === "text") b.text = "";
                else if (block === "thinking") b.thought = "";
                else if (e.type === "content_block_delta" && e.delta?.type === "text_delta") { b.text += e.delta.text; b.hasText = true; }
                else if (e.type === "content_block_delta" && e.delta?.type === "thinking_delta") { b.thought += e.delta.thinking; b.hasThought = true; }
            } else if (data.type === "stream_event") {
                const e = data.event ?? {};
                // A new text or thought writes its own buffer (two blocks in one turn ran together). A tool call
                // starting leaves the text before it on screen until the transcript brings that text as a row:
                // cleared here, it vanished for as long as the command ran.
                const block = e.type === "content_block_start" ? (e.content_block?.type ?? "") : "";
                if (block === "text") { conv.partialText = ""; conv.shownChars = 0; conv.textReplayed = conv.replaying; }
                else if (block === "thinking") { conv.partialThinking = ""; conv.thoughtReplayed = conv.replaying; }
                else if (block === "tool_use" && !conv.replaying) conv.toolStarted(e.index, e.content_block);
                else if (e.type === "content_block_delta" && e.delta?.type === "input_json_delta") conv.toolInput(e.index, e.delta.partial_json ?? "");
                else if (e.type === "content_block_delta" && e.delta?.type === "text_delta") { if (conv.replaying) conv.textReplayed = true; conv.partialText += e.delta.text; }
                else if (e.type === "content_block_delta" && e.delta?.type === "thinking_delta") { if (conv.replaying) conv.thoughtReplayed = true; conv.partialThinking += e.delta.thinking; }
                else if (e.type === "content_block_stop") conv.dropStale();
                // while it follows, onContentHeightChanged carries the view; this only picks up a reader
                // left at the bottom (a jump here also pulled the view back under the fingers)
                if (list.atYEnd && !list.atEnd) toEnd.restart();
            } else if (data.type === "assistant" || data.type === "user") {
                followSoon.restart();
            } else if (data.type === "result") {
                // the turn is over: a thought still drawn as coming in would say it is still thinking
                conv.partialThinking = "";
                conv.liveTools = [];
                followSoon.restart();
                conv.loadChanges();
                if (data.total_cost_usd) conv.cost = data.total_cost_usd;
            }
        }
        function onExited(id, reason, stderr) {
            if (!conv.session || id !== conv.session.id) return;
            conv.partialThinking = "";
            conv.partialText = "";
            conv.liveTools = [];
            followSoon.restart();   // the rows it wrote last: the follow timer stops with it
            conv.seenSeq = -1;   // a resumed process counts its events from the start again
            if (reason === "signedOut" || reason === "expired") {
                conv.authLost = Object.assign({ reason: reason }, conv.lastSent ?? {});
                if (conv.acc?.available) conv.acc.send({ op: "account_check", account: conv.chosenAccount || undefined });
                return;
            }
            if (reason === "crashed") {
                const why = (stderr ?? []).map(l => String(l).trim()).filter(l => l.length).pop() ?? "";
                conv.error = why.length ? `${conv.agentName} stopped unexpectedly: ${why}` : `${conv.agentName} stopped unexpectedly. Send again to pick up where it left off.`;
                errorFade.restart();
            }
        }
        // A dropped socket strands every request in flight (Host answers them as failures), and the
        // watch it held is gone with it: the pane is read again from the host that came back, since
        // nothing else re-arms following or the stream.
        function onConnectedChanged() {
            if (!conv.host.connected) { conv.pendingUser = ""; conv.pendingImages = []; return; }
            conv.watching = "";
            conv.following = false;
            conv.loading = false;
            if (conv.session && !conv.session.fresh) {
                // load() starts the session over, queue included: messages typed while it worked
                // were never sent, so they stay on screen and in line across the reconnect
                const queued = conv.queued;
                conv.load();
                conv.queued = queued;
            }
        }
    }

    // ── sending ─────────────────────────────────────────────────────────────
    // true when the message is on its way or queued: the box only clears then, so nothing is typed
    // into a dead socket and lost
    function send(text, images, files, fromQueue) {
        conv.testLog(`send fromQueue=${!!fromQueue} open=${conv.turnOpen} "${String(text).substring(0, 20)}"`);
        const s = conv.session;
        if (!s) return false;
        images = images ?? [];
        files = files ?? [];
        // Sent while it works: the run stops and this goes in as soon as it has (owner 2026-10-08, "stop and
        // send now"). Held until the run ended, a message sat unsent and a second click landed on stop. Slipped
        // into the running turn instead, Claude Code hands it over beside a command's output, where it can be
        // taken for an injection and skipped, and the transcript keeps it as an attachment, not your message.
        // It shows in the conversation at once, as sent, while the run stops (Paseo's pending message): a row in
        // the queue for that second read as not sent. A second one typed meanwhile waits in the queue.
        if (!fromQueue && conv.turnOpen && !s.fresh) {
            const echo = !conv.pendingUser.length && !conv.pendingImages.length;
            conv.queued = conv.queued.concat([{ text: text, images: images, files: files, shown: echo }]);
            if (echo) { conv.pendingUser = text; conv.pendingImages = images; }
            if (conv.live) conv.host.request({ op: "interrupt", id: s.id });
            return true;
        }
        if (!conv.host.connected) {
            conv.error = "Nothing was sent: Praxis isn't connected to its background service yet. It reconnects on its own; send again in a moment.";
            errorFade.restart();
            return false;
        }
        if (conv.oldHost) {
            conv.error = s.fresh ? `Nothing was sent: starting a ${conv.agentName} session needs the background service restarted.`
                : `Nothing was sent: continue this ${conv.agentName} session in a terminal, or restart the background service.`;
            errorFade.restart();
            return false;
        }
        // the agent a folder remembers may since have been signed out or removed: the chip says so,
        // and the text stays in the box
        const blocked = s.fresh && !conv.acc?.available ? composer.agentBlock(conv.agent) : "";
        if (blocked.length) {
            conv.error = `Nothing was sent: ${conv.agentName} cannot start a session (${blocked.charAt(0).toLowerCase() + blocked.slice(1)}). Choose another agent in the box.`;
            errorFade.restart();
            return false;
        }
        // a host before protocol 6 takes no files: they go in the text as @paths
        if (files.length && !conv.host.features.includes("catalog")) {
            text = [text].concat(files.map(p => /\s/.test(p) ? `@"${p}"` : `@${p}`)).join(" ");
            files = [];
        }
        const opts = { mode: conv.chosenMode };
        if (conv.chosenModel.length) opts.model = conv.chosenModel;
        if (conv.chosenEffort.length) opts.effort = conv.chosenEffort;
        if (conv.chosenAccount.length) opts.account = conv.chosenAccount;
        conv.lastSent = { text: text, images: images, files: files };
        conv.authLost = null;
        if (s.fresh) {
            // the echo shows at once, and load() keeps it when the real session swaps in
            conv.pendingUser = text;
            conv.pendingImages = images;
            const said = conv.desktopContext.length ? `${text}\n\n${conv.desktopContext}` : text;
            conv.desktopContext = "";
            conv.host.request(Object.assign({ op: "start", cwd: s.cwd, text: said, images: images, files: files, agent: conv.agent }, opts), m => {
                if (m.ev !== "started") {
                    conv.pendingUser = "";
                    conv.pendingImages = [];
                    conv.giveBack(text, images, files);
                    conv.error = m.message ?? "Could not start.";
                    errorFade.restart();
                    return;
                }
                conv.starting = m.id;
                conv.started({ id: m.id, tool: m.tool || s.tool || "claude", cwd: s.cwd, title: text.split("\n")[0].slice(0, 80), prompt: text, lastPrompt: "",
                               started: Date.now(), updated: Date.now() });
            });
            toEnd.restart();
            return true;
        }
        // a new turn: what was being written for the last one is over (it stood as this turn's reply)
        conv.partialText = "";
        conv.partialThinking = "";
        conv.liveTools = [];
        conv.pendingUser = text;
        conv.pendingImages = images;
        conv.sendingNow = true;
        const op = conv.live ? { op: "send", id: s.id, text: text, images: images, files: files }
            : Object.assign({ op: "start", cwd: s.cwd, resume: s.id, text: text, images: images, files: files }, opts);
        conv.host.request(op, m => {
            conv.testLog(`send reply ${m.ev} ${m.message ?? ""}`);
            if (m.ev === "error") {
                conv.sendingNow = false;
                conv.pendingUser = "";
                conv.pendingImages = [];
                // a queued message goes back at the head of the queue rather than disappearing; a typed one, into the box
                if (fromQueue) conv.queued = [{ text: text, images: images, files: files }].concat(conv.queued);
                else conv.giveBack(text, images, files);
                conv.error = m.message;
                errorFade.restart();
                return;
            }
            if (conv.offset < 0) conv.offset = 0;
            conv.watch();
        });
        toEnd.restart();
        return true;
    }
    // A message the host refused goes back into the box (the box clears as soon as it is handed over, and the
    // refusal comes after: it was lost and had to be typed again). Not over something typed since.
    function giveBack(text, images, files) {
        if (composer.text.trim().length) return;
        composer.setText(text);
        composer.take(images.concat(files));
    }
    function focusComposer() { composer.focusInput(); }
    // Clicking a reply or a code block to read it moves the focus into that text, which then eats
    // what you type. Read-only text passes the key on, so it is caught here and typed into the box.
    function typeInto(e) {
        if (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return;
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { composer.focusInput(); e.accepted = true; return; }
        if (!e.text.length || e.text.charCodeAt(0) < 32) return;
        composer.focusInput();
        composer.insertAtCursor(e.text);
        e.accepted = true;
    }
    function take(paths) { composer.take(paths); }

    function place(cwd) {
        const home = Quickshell.env("HOME");
        return cwd.startsWith(home) ? "~" + cwd.substring(home.length) : cwd;
    }

    // ── header: title, where it ran, changes, pin ──────────────────────────
    Item {
        id: header
        visible: conv.session !== null
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 62
        StyledText {
            id: title
            anchors { left: parent.left; leftMargin: 24; right: conv.finding ? findBox.left : tools.left; rightMargin: 12; top: parent.top; topMargin: 12 }
            text: conv.shownSession ? (conv.shownSession.fresh ? "New session" : (conv.shownSession.title || conv.shownSession.lastPrompt || conv.shownSession.prompt || "Untitled").replace(/\s*<desktop-context>[\s\S]*$/, "")) : ""
            elide: Text.ElideRight
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: Appearance.colors.colInkMain
        }
        StyledText {
            anchors { left: title.left; right: title.right; top: title.bottom; topMargin: 2 }
            text: {
                if (!conv.shownSession) return "";
                const s = conv.shownSession;
                const parts = [conv.place(s.cwd || ""), conv.agentNames[s.tool || "claude"] ?? s.tool];
                // a permission or question card open: the step it holds has no result yet, so `busy` is true too
                if (conv.pending.length) parts.push("waiting for you");
                else if (conv.busy) parts.push("working");
                else if (conv.locked) parts.push("in a terminal");
                else if (s.started > 0) parts.push(Qt.formatDateTime(new Date(s.started), "d MMM yyyy"));
                return parts.filter(p => p.length).join(" · ");
            }
            elide: Text.ElideMiddle
            font.pixelSize: 13
            color: Appearance.colors.colInkSecondary
        }
        // the find field: the sidebar search's box, in the header while finding
        Rectangle {
            id: findBox
            visible: conv.finding
            anchors { right: tools.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
            width: 320
            height: 32
            radius: Appearance.rounding.small
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94)
            MaterialSymbol { id: findGlyph; anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter } text: "search"; iconSize: 17; color: Appearance.colors.colInkSecondary }
            TextInput {
                // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)
                font.hintingPreference: Font.PreferNoHinting
                id: findField
                anchors { left: findGlyph.right; leftMargin: 7; right: findCount.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                // Enter the next match, Shift+Enter the one before, Esc closes
                font.family: Appearance.font.family.main
                font.variableAxes: Appearance.font.variableAxes.main
                font.pixelSize: 15
                color: Appearance.colors.colInkMain
                selectionColor: Appearance.colors.colSecondaryContainer
                clip: true
                onTextChanged: conv.findQuery = text
                Keys.onReturnPressed: e => conv.findStep((e.modifiers & Qt.ShiftModifier) ? -1 : 1)
                Keys.onEnterPressed: e => conv.findStep((e.modifiers & Qt.ShiftModifier) ? -1 : 1)
                Keys.onEscapePressed: conv.closeFind()
            }
            StyledText {
                anchors { left: findField.left; verticalCenter: parent.verticalCenter }
                visible: findField.text.length === 0
                text: "Find in this session"
                font.pixelSize: 15
                color: Appearance.colors.colInkSecondary
            }
            StyledText {
                id: findCount
                anchors { right: findButtons.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                text: conv.findQuery.trim().length < 2 ? "" : conv.findHits.length === 0 ? (conv.paging ? "Looking earlier" : conv.start > 0 ? "None loaded" : "None")
                    : conv.findAt < 0 ? `${conv.findHits.length} found` : `${conv.findAt + 1} of ${conv.findHits.length}`
                font.family: Appearance.font.family.numbers
                font.pixelSize: 13
                color: Appearance.colors.colInkSecondary
            }
            Row {
                id: findButtons
                anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                spacing: 2
                Repeater {
                    model: [["keyboard_arrow_up", "Previous (Shift+Enter)", -1], ["keyboard_arrow_down", "Next (Enter)", 1], ["close", "Close (Esc)", 0]]
                    delegate: Rectangle {
                        id: fb
                        required property var modelData
                        // up also reaches the part not loaded yet
                        readonly property bool usable: fb.modelData[2] === 0 || conv.findHits.length > 0 || (fb.modelData[2] < 0 && conv.start > 0 && conv.findQuery.trim().length >= 2)
                        width: 24
                        height: 24
                        radius: 6
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, !fb.usable ? 1 : fbArea.pressed ? 0.84 : fbArea.containsMouse ? 0.9 : 1)
                        Behavior on color { enabled: !fbArea.pressed; ColorAnimation { duration: 110 } }
                        MaterialSymbol { anchors.centerIn: parent; text: fb.modelData[0]; iconSize: 17; color: fb.usable ? Appearance.colors.colInkSecondary : Appearance.colors.colInkFaint }
                        MouseArea { id: fbArea; anchors.fill: parent; hoverEnabled: true; cursorShape: fb.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: { if (fb.modelData[2] === 0) conv.closeFind(); else if (fb.usable) conv.findStep(fb.modelData[2]); } }
                        StyledToolTip { text: fb.modelData[1]; extraVisibleCondition: fbArea.containsMouse }
                    }
                }
            }
        }
        Row {
            id: tools
            anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter }
            spacing: 14
            Rectangle {
                visible: conv.runningCount > 0
                anchors.verticalCenter: parent.verticalCenter
                width: runRow.implicitWidth + 24
                height: 30
                radius: 15
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, runArea.containsMouse ? 0.88 : 0.93)
                Behavior on color { ColorAnimation { duration: 140 } }
                Row {
                    id: runRow
                    anchors.centerIn: parent
                    spacing: 7
                    Rectangle { width: 6; height: 6; radius: 3; color: Appearance.colors.colPrimary; anchors.verticalCenter: parent.verticalCenter }
                    StyledText { text: `${conv.runningCount} running`; font.family: Appearance.font.family.numbers; font.pixelSize: 13; color: Appearance.colors.colInkMain; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea { id: runArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: conv.agentsToggled() }
                StyledToolTip { text: "Agents, workflows and commands running"; extraVisibleCondition: runArea.containsMouse }
            }
            MaterialSymbol {
                visible: conv.session !== null && !conv.finding && !(conv.session?.fresh ?? false)
                anchors.verticalCenter: parent.verticalCenter
                text: "search"
                iconSize: 18
                color: findOpenArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                MouseArea { id: findOpenArea; anchors { fill: parent; margins: -8 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: conv.openFind() }
                StyledToolTip { text: "Find in this session (Ctrl+F)"; extraVisibleCondition: findOpenArea.containsMouse }
            }
            MaterialSymbol {
                visible: conv.session !== null
                anchors.verticalCenter: parent.verticalCenter
                text: "view_sidebar"
                fill: conv.panelOpen ? 1 : 0
                iconSize: 18
                color: conv.panelOpen ? Appearance.colors.colInkMain : (panelArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary)
                MouseArea {
                    id: panelArea
                    anchors { fill: parent; margins: -8 }
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: conv.filesToggled()
                }
                StyledToolTip { text: "Side panel (Ctrl+Alt+B)"; extraVisibleCondition: panelArea.containsMouse }
            }
            MaterialSymbol {
                visible: conv.session !== null && !conv.session.fresh
                anchors.verticalCenter: parent.verticalCenter
                text: "push_pin"
                fill: conv.pinned ? 1 : 0
                iconSize: 18
                color: conv.pinned ? Appearance.colors.colPrimary : (pinArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary)
                MouseArea {
                    id: pinArea
                    anchors { fill: parent; margins: -8 }
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: conv.pinToggled()
                }
                StyledToolTip { text: conv.pinned ? "Unpin" : "Pin"; extraVisibleCondition: pinArea.containsMouse }
            }
        }
    }

    // ── the conversation ────────────────────────────────────────────────────
    ListView {
        id: list
        visible: conv.need.length === 0   // Claude Code not ready: SetupNotice instead
        anchors { left: parent.left; right: parent.right; top: header.bottom; bottom: bottomArea.top }
        clip: true
        model: blockModel
        cacheBuffer: 1600
        Keys.onPressed: e => conv.typeInto(e)
        maximumFlickVelocity: 3500
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: StyledScrollBar { id: bar; onPressedChanged: if (!pressed) list.chaseEnd() }
        // Tacit's touchpad scroll (Files has it too): one to one with the fingers, a glide after a
        // flick, one eased step per mouse notch. FastWheel restarted a 200 ms easing on every
        // touchpad event, which came out as surges and stalls (2026-10-02 "stuttering").
        // faster than Files: a conversation is long and read in passes
        GlideWheel { id: wheel; view: list; gain: 1.6; gainPerSpeed: 3; gainMax: 6; onActiveChanged: if (!active) list.chaseEnd() }
        HoverHandler {
            onPointChanged: {
                const i = list.indexAt(point.position.x + list.contentX, point.position.y + list.contentY);
                conv.hoverTurn = i >= 0 ? blockModel.get(i).turn : -1;
            }
            onHoveredChanged: if (!hovered) conv.hoverTurn = -1
        }
        // where the reader scrolls to (wheel, touchpad, scrollbar or a drag) decides whether new messages
        // pull the view along: a move up leaves the end, reaching the end follows again. A move down
        // short of the end changes nothing: the glide trails the end, and a nudge down kept following off.
        onContentYChanged: {
            if (wheel.active || bar.pressed || list.moving) {
                if (list.contentY >= list.originY + list.contentHeight - list.height - 2) list.atEnd = true;
                else if (list.contentY < list.lastY) list.atEnd = false;
            }
            list.lastY = list.contentY;
        }
        property real lastY: 0
        property bool smooth: true        // false while a jump moves the view: the end is then held at once
        property bool atEnd: true         // where the reader left it: at the end, it stays there
        onMovementEnded: list.chaseEnd()
        // rows settle taller after they are laid out (rich text, the footer line), and a reply grows
        // line by line: at the end, the view goes along. Under the reader's fingers it waits and
        // glides on when they stop.
        // the jump's own move: holding the end from in here, inside the list's move, kept it from laying out the rows
        // above the last one until the next frame (an empty view, then the rows 400-640 px up sliding down)
        property bool jumping: false
        onContentHeightChanged: if (list.atEnd && !list.jumping && !list.moving && !bar.pressed && list.contentHeight > list.height) {
            if (!list.smooth) list.contentY = list.originY + list.contentHeight - list.height;
            else if (!wheel.active) chase.start();
        }
        function chaseEnd() { if (list.atEnd && !list.moving && !wheel.active && !bar.pressed && list.contentHeight > list.height) chase.start(); }
        // a row already drawn changing size (an agent's details coming in, a finished step) while the view is at the
        // end: the end stays put in that frame; following it a frame late pushed the bottom down first
        function pinEnd() {
            if (!list.atEnd || list.moving || wheel.active || bar.pressed || list.contentHeight <= list.height) return;
            chase.stop();
            chase.v = 0;
            list.contentY = list.originY + list.contentHeight - list.height;
        }
        // Following: the view glides after the end, a critically damped spring on the distance
        // left, so its speed follows how fast the reply grows instead of a 200 ms ease per new
        // line. It never passes the end, never turns back unless the end moved up, comes to rest
        // exactly at the end, and stops the moment the reader scrolls.
        FrameAnimation {
            id: chase
            property real v: 0                // px per second
            readonly property real rate: 24   // per second: higher trails closer, lower glides softer
            onTriggered: {
                if (!list.atEnd || list.moving || wheel.active || bar.pressed) { chase.v = 0; chase.stop(); return; }
                const end = Math.max(list.originY, list.originY + list.contentHeight - list.height);
                const x = list.contentY - end;
                const dt = Math.min(frameTime, 0.05);
                // toward the end only, and never so fast that it would land past it
                const v = x < 0 ? Math.max(0, Math.min(chase.v, -chase.rate * x)) : Math.min(0, Math.max(chase.v, -chase.rate * x));
                const b = v + chase.rate * x;
                const e = Math.exp(-chase.rate * dt);
                const nx = (x + b * dt) * e;
                chase.v = (v - chase.rate * b * dt) * e;
                if (Math.abs(nx) < 0.5 && Math.abs(chase.v) < 20) { chase.v = 0; chase.stop(); list.contentY = end; }
                else list.contentY = end + nx;
            }
        }
        // A window on another workspace draws no frames, and the glide runs on frames: back on screen,
        // the first frame showed the reply it had stopped at and glided down through what came
        // meanwhile. The first frame after a second without one goes straight to the end instead.
        property real lastFrame: 0
        Connections {
            target: list.Window.window
            function onFrameSwapped() {
                const now = Date.now();
                if (now - list.lastFrame > 1000 && list.atEnd && !list.moving && list.contentHeight > list.height) {
                    chase.stop();
                    chase.v = 0;
                    list.contentY = list.originY + list.contentHeight - list.height;
                }
                list.lastFrame = now;
            }
        }
        // test runs: a jump is a row on screen moving by itself (not the follow, not the reader) - watched each
        // frame on the row near the bottom of the view; the scroll position alone also moves when rows above
        // change size and the list keeps what is seen in place
        SequentialAnimation {
            id: testScroll
            // a fast skim back: six screens up in 2 s and down again (a reader's flick, not the whole conversation at once)
            NumberAnimation { target: list; property: "contentY"; to: Math.max(list.originY, list.contentY - 6 * list.height); duration: 2000; easing.type: Easing.InOutQuad }
            NumberAnimation { target: list; property: "contentY"; to: list.originY + list.contentHeight - list.height; duration: 2000; easing.type: Easing.InOutQuad }
        }
        property int testRow: -1
        Connections {
            target: list.Window.window
            enabled: conv.testRun
            function onFrameSwapped() {
                if (conv.testSwitchLeft <= 0) return;
                conv.testSwitchLeft--;
                conv.testSwitch = conv.testSwitch.concat([{ off: Math.round(list.contentY - (list.originY + list.contentHeight - list.height)),
                    top: list.indexAt(list.width / 2, list.contentY + 4), mid: list.indexAt(list.width / 2, list.contentY + list.height / 2), tall: list.contentHeight > list.height }]);
            }
        }
        property real testRowY: 0
        property int testFrames: 0
        property var testTimes: []      // frame times (ms) since the last reset: smoothness while streaming, scrolling, switching
        FrameAnimation {
            running: conv.testRun
            onTriggered: {
                list.testFrames++;
                if (list.testTimes.length < 4000) list.testTimes.push(frameTime * 1000);
                if (frameTime > 0.033) conv.testLog(`slow frame ${Math.round(frameTime * 1000)} ms`);
                // the row watched last frame, wherever it is now
                const was = list.testRow >= 0 ? list.itemAtIndex(list.testRow) : null;
                if (was) {
                    const y = was.y - list.contentY;
                    // at the end rows only ever go up, as new lines come (the follow); one going down is the list pulling
                    // back - what was seen as the jump, and the follow starts in that same frame. Away from the end
                    // nothing moves by itself.
                    const d = y - list.testRowY;
                    if ((list.atEnd ? d > 12 : Math.abs(d) > 12) && !list.moving && !conv.swapping && !conv.loading && conv.settled)
                        conv.testSnaps = conv.testSnaps.concat([{ t: Date.now() % 100000, d: Math.round(y - list.testRowY), row: list.testRow, type: conv.shownBlocks[list.testRow]?.type ?? "",
                            cy: Math.round(list.contentY), ch: Math.round(list.contentHeight), oy: Math.round(list.originY), ry: Math.round(was.y), atEnd: list.atEnd, chase: chase.running,
                            blocks: blockModel.count, echo: conv.pendingUser.length > 0, text: conv.partialText.length, thought: conv.partialThinking.length,
                            tools: conv.liveTools.length, busy: conv.busy, h: Math.round(list.height) }]);
                }
                // then the row near the bottom of the view, for the next frame
                let i = -1;
                for (const off of [40, 120, 240, list.height / 2]) {
                    i = list.indexAt(list.width / 2, list.contentY + list.height - off);
                    if (i >= 0) break;
                }
                const it = i >= 0 ? list.itemAtIndex(i) : null;
                list.testRow = it ? i : -1;
                list.testRowY = it ? it.y - list.contentY : 0;
            }
        }
        onHeightChanged: if (list.atEnd && list.contentHeight > list.height) {
            list.smooth = false;
            list.contentY = list.originY + list.contentHeight - list.height;
            list.smooth = true;
        }
        header: Item {
            width: ListView.view.width
            height: conv.start > 0 ? 48 : 8
            StyledText {
                anchors.centerIn: parent
                visible: conv.start > 0
                text: conv.byteCursor ? "Earlier" : `Earlier · ${conv.start}`
                font.pixelSize: 13
                color: earlierArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkMeta
                MouseArea {
                    id: earlierArea
                    anchors { fill: parent; margins: -8 }
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: conv.earlier()
                }
            }
        }
        // what is still being written: your message until the transcript has it, the thinking
        // and text coming in word by word, or a quiet "Working" while a tool runs
        footer: Item {
            width: ListView.view.width
            // while the reply's head is here ("Working", then its thinking or first words) the live part keeps at
            // least "Working"'s 34 px: a first line of text is shorter, and the end pulling back snapped the view
            height: Math.max(conv.footerHold, echo.height + Math.max(liveColumn.implicitHeight,
                (conv.busy && !conv.stepRunning) || conv.partialText.length || conv.partialThinking.length ? 34 : 0) + 16)
            // your message until the transcript has it, in exactly the space its row will take (the row's
            // 40 above, the bubble, 26 under it, 12 below): the swap moves nothing (2026-10-08, "when i am
            // sending the message jumps": the echo had 20 above and nothing under, the row grew it by ~58 px)
            onHeightChanged: {
                conv.footerNow = height;
                if (conv.testRun) { conv.testLog(`footer ${Math.round(conv.testFooterH)} -> ${Math.round(height)}`); conv.testFooterH = height; }
            }
            Item {
                id: echo
                onHeightChanged: if (conv.testRun) conv.testEchoH = height
                visible: conv.pendingUser.length > 0
                x: (parent.width - conv.columnWidth) / 2
                width: conv.columnWidth
                height: visible ? 40 + pendingBubble.height + 26 + 12 : 0
                UserBubble {
                    id: pendingBubble
                    anchors { right: parent.right; top: parent.top; topMargin: 40 }
                    maxWidth: parent.width * 0.85
                    text: conv.pendingUser
                    images: conv.pendingImages
                    viewer: conv.viewer
                }
            }
            Column {
                id: liveColumn
                x: (parent.width - conv.columnWidth) / 2
                y: echo.height
                width: conv.columnWidth
                spacing: 6
                ThinkingLine { visible: conv.partialThinking.length > 0 && conv.partialText.length === 0; width: parent.width; live: true; text: conv.partialThinking }
                // the reply being written: its finished parts laid out as its rows will be, then the tail
                Column {
                    id: liveText
                    visible: conv.partialText.length > 0
                    width: parent.width
                    Repeater {
                        model: livePieces
                        delegate: Item {
                            id: piece
                            required property string json
                            readonly property var p: JSON.parse(piece.json)
                            width: liveText.width
                            height: pieceLoader.item ? pieceLoader.item.implicitHeight + pieceLoader.item.gap : 0
                            Loader {
                                id: pieceLoader
                                x: piece.p.indent ?? 0
                                y: piece.p.type === "code" ? 6 : 0
                                width: parent.width - x
                                sourceComponent: piece.p.type === "code" ? pieceCodeC : pieceTextC
                            }
                            Component {
                                id: pieceTextC
                                ClaudeText {
                                    readonly property string html: Md.toHtml(piece.p.content, tokens)
                                    // a row's 4 under the text's end; within the text, the margin a paragraph keeps
                                    // over the next (a separate document drops it)
                                    readonly property real gap: piece.p.next === "" ? 4 : piece.p.next === "para" ? conv.lastGap(html) : 0
                                    // a list that goes on in the next run: the space under it is that run's
                                    text: piece.p.next !== "item" ? html
                                        : html.substring(0, html.lastIndexOf("<table")) + html.substring(html.lastIndexOf("<table")).replace(/margin-bottom:\d+px/, "margin-bottom:0px")
                                }
                            }
                            Component { id: pieceCodeC; CodeBlock { readonly property real gap: 22; code: piece.p.content; lang: piece.p.lang } }
                        }
                    }
                    // code still being written, uncoloured: its colours come with the block once the fence
                    // closes. Bound to the fence's language as well, this block crashed qs in the highlighter
                    // (QSyntaxHighlighter::rehighlightBlock on a stale line).
                    Item {
                        visible: conv.liveCode !== null
                        width: parent.width
                        height: visible ? liveCodeBlock.implicitHeight + 22 : 0
                        CodeBlock {
                            id: liveCodeBlock
                            x: conv.liveCode?.indent ?? 0
                            y: 6
                            width: parent.width - x
                            code: conv.liveCode?.content ?? ""
                        }
                    }
                    ClaudeText {
                        visible: conv.liveTail.length > 0 || (livePieces.count === 0 && conv.liveCode === null)
                        width: parent.width
                        markdown: conv.liveTail
                    }
                }
                ActivityGroup {
                    visible: conv.liveTools.length > 0
                    width: parent.width
                    tools: conv.liveTools
                    runningIds: conv.liveTools.map(t => t.id)
                    openIds: conv.openIds
                    viewer: conv.viewer
                    files: conv.files
                }
                Row {
                    visible: conv.busy && !conv.stepRunning && conv.partialText.length === 0 && conv.partialThinking.length === 0 && conv.liveTools.length === 0
                    height: visible ? 34 : 0
                    spacing: 7
                    Item { width: 17; height: 17; anchors.verticalCenter: parent.verticalCenter; LiveDot { anchors.centerIn: parent } }
                    ShineText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: implicitWidth
                        text: "Working"
                        pixelSize: 15
                        weight: Font.Medium
                        active: parent.visible
                        rests: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: conv.busySeconds > 0
                        text: conv.busySeconds < 60 ? `${conv.busySeconds}s` : `${Math.floor(conv.busySeconds / 60)}m ${conv.busySeconds % 60}s`
                        font.family: Appearance.font.family.numbers
                        font.pixelSize: 14
                        color: Appearance.colors.colInkSecondary
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: conv.afterCompact
                        text: "· the rest shows here when the turn ends in the terminal"
                        font.pixelSize: 14
                        color: Appearance.colors.colInkMeta
                    }
                }
            }
        }

        delegate: Item {
            id: d
            required property string json
            required property double born
            required property int index
            readonly property var b: JSON.parse(d.json)
            readonly property bool isLast: d.index === blockModel.count - 1
            width: ListView.view.width
            height: loader.item ? loader.item.implicitHeight + d.above + d.below : 0
            readonly property real above: d.b.type === "user" ? 40 : d.b.type === "note" ? 12 : d.b.type === "code" ? 6 : d.b.type === "footer" ? 2 : d.b.type === "changes" ? 10
                : d.b.type === "activity" || d.b.type === "thinking" || d.b.type === "tool" ? 8 : 0
            readonly property real below: d.b.type === "text" ? 4 : d.b.type === "code" ? 16 : d.b.type === "note" ? 12 : d.b.type === "user" ? 12 : d.b.type === "footer" ? 8
                : d.b.type === "activity" || d.b.type === "thinking" ? 2 : 4
            // a row that just arrived rises into place
            opacity: 1
            transform: Translate { id: rise; y: 0 }
            property bool drawn: false
            readonly property real testT0: conv.testRun ? Date.now() : 0
            onHeightChanged: if (d.drawn && conv.settled && !conv.swapping) Qt.callLater(list.pinEnd)
            Component.onCompleted: {
                if (conv.testRun) {
                    const k = d.b.type, e = conv.testBuilt[k] ?? { n: 0, ms: 0, max: 0 }, ms = Date.now() - d.testT0;
                    e.n++; e.ms += ms; e.max = Math.max(e.max, ms);
                    conv.testBuilt[k] = e;
                }
                // a row released before the next frame (rows built and dropped during a jump) is gone by then
                Qt.callLater(() => { if (d) d.drawn = true; });
                if (conv.testRun && conv.settled) conv.testLog(`drawn ${d.index} ${d.b.type} h=${Math.round(d.height)} hold=${Math.round(conv.footerHold)} until=${conv.footerHoldUntil}`);
                if (conv.footerHold > 0 && d.index >= conv.footerHoldUntil) conv.releaseFooter();
                if (d.born > 0 && Date.now() - d.born < 800) appear.start();
            }
            ParallelAnimation {
                id: appear
                NumberAnimation { target: d; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
                NumberAnimation { target: rise; property: "y"; from: 10; to: 0; duration: 320; easing.type: Easing.OutCubic }
            }
            Loader {
                id: loader
                x: (d.width - conv.columnWidth) / 2 + (d.b.indent ?? 0)
                y: d.above
                width: conv.columnWidth - (d.b.indent ?? 0)
                sourceComponent: {
                    switch (d.b.type) {
                    case "user": return userC;
                    case "code": return codeC;
                    case "tool": return toolC;
                    case "activity": return activityC;
                    case "agents": return agentsC;
                    case "workflow": return workflowC;
                    case "thinking": return thinkC;
                    case "note": return noteC;
                    case "footer": return footerC;
                    case "changes": return changesC;
                    }
                    return textC;
                }
            }
            Component {
                id: userC
                // your message; hovering shows when you sent it and what you can do with it
                Item {
                    implicitHeight: bubble.height + 26 + (goBack.visible ? goBack.height + 10 : 0)
                    Component.onCompleted: if (conv.echoHandoff) { conv.testLog(`handoff row=${Math.round(implicitHeight + 52)} echo=${Math.round(conv.testEchoH)}`); conv.takeEcho(); }
                    HoverHandler { id: userHover }
                    // "go back to here": what it does, what changed in files since, and the choice
                    Rectangle {
                        id: goBack
                        visible: conv.rewindAt.length > 0 && conv.rewindAt === (d.b.rec ?? "")
                        anchors { right: parent.right; top: bubble.bottom; topMargin: 30 }
                        width: Math.min(parent.width, 520)
                        height: visible ? backCol.implicitHeight + 24 : 0
                        radius: 18
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                        readonly property var files: conv.rewindFiles?.filesChanged ?? []
                        readonly property bool canFiles: !!conv.caps?.rewindFiles && (conv.rewindFiles?.canRewind ?? false) && goBack.files.length > 0
                        Column {
                            id: backCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12; leftMargin: 16; rightMargin: 16 }
                            spacing: 8
                            StyledText { text: "Go back to before this message?"; font.pixelSize: 15; font.weight: Font.Medium; color: Appearance.colors.colInkMain }
                            StyledText {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "Everything after it is set aside, and this message returns to the box so you can change it and send it again."
                                font.pixelSize: 14
                                color: Appearance.colors.colInkSecondary
                            }
                            Row {
                                visible: conv.rewindFiles === null
                                spacing: 8
                                Spinner { implicitSize: 14; colShape: Appearance.colors.colPrimary; anchors.verticalCenter: parent.verticalCenter }
                                StyledText { text: "Checking which files changed since…"; font.pixelSize: 13; color: Appearance.colors.colInkSecondary; anchors.verticalCenter: parent.verticalCenter }
                            }
                            StyledText {
                                visible: goBack.canFiles
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: `${goBack.files.length} ${goBack.files.length === 1 ? "file has" : "files have"} changed since: ${goBack.files.map(f => f.split("/").pop()).slice(0, 4).join(", ")}${goBack.files.length > 4 ? ", …" : ""}`
                                font.pixelSize: 13
                                color: Appearance.colors.colInkSecondary
                            }
                            Row {
                                spacing: 8
                                PillButton { text: conv.rewinding ? "Going back…" : "Go back"; onClicked: if (!conv.rewinding) conv.doRewind(d.b.rec, false) }
                                PillButton {
                                    visible: goBack.canFiles
                                    text: `Go back and restore ${goBack.files.length === 1 ? "the file" : goBack.files.length + " files"}`
                                    onClicked: if (!conv.rewinding) conv.doRewind(d.b.rec, true)
                                }
                                PillButton { text: "Cancel"; onClicked: conv.rewindAt = "" }
                            }
                        }
                    }
                    UserBubble { id: bubble; anchors.right: parent.right; maxWidth: parent.width * 0.85; text: d.b.text; mono: d.b.mono ?? false; images: d.b.images ?? []; viewer: conv.viewer }
                    Row {
                        anchors { right: parent.right; top: bubble.bottom; topMargin: 4 }
                        spacing: 12
                        opacity: userHover.hovered ? 1 : 0
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: (d.b.ts ?? 0) > 0
                            text: Qt.formatDateTime(new Date(d.b.ts), "d MMM, hh:mm")
                            font.family: Appearance.font.family.numbers
                            font.pixelSize: 13
                            color: Appearance.colors.colInkSecondary
                        }
                        Repeater {
                            model: [{ glyph: "content_copy", tip: "Copy", run: () => Quickshell.clipboardText = d.b.text },
                                    { glyph: "edit", tip: "Edit in the box", run: () => composer.setText(d.b.text), hide: conv.locked },
                                    { glyph: "replay", tip: "Send again", run: () => conv.send(d.b.text), hide: conv.locked || conv.busy },
                                    { glyph: "undo", tip: "Go back to here", run: () => conv.askRewind(d.b.rec), hide: conv.locked || conv.busy || conv.rewinding || !(d.b.rec ?? "").length || !conv.caps?.rewind }]
                            delegate: MaterialSymbol {
                                required property var modelData
                                visible: !modelData.hide && d.b.text.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.glyph
                                iconSize: 16
                                color: actArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                                MouseArea { id: actArea; anchors { fill: parent; margins: -5 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: modelData.run() }
                                StyledToolTip { text: modelData.tip; extraVisibleCondition: actArea.containsMouse }
                            }
                        }
                    }
                }
            }
            Component {
                id: changesC
                ChangesCard {
                    files: d.b.files
                    add: d.b.add
                    del: d.b.del
                    cwd: conv.session?.cwd ?? ""
                    canUndo: (d.b.latest ?? false) && (d.b.rec ?? "").length > 0 && !conv.locked && !conv.busy && !!conv.caps?.rewindFiles
                    onViewChanges: conv.changesViewed(d.b.edits ?? [])
                    onUndoAsked: done => conv.undoTurn(d.b.rec, done)
                }
            }
            Component {
                id: footerC
                // under a finished reply: model · how long · when, and copy; shown while the pointer is
                // on that turn
                Row {
                    spacing: 10
                    height: 24
                    opacity: conv.hoverTurn === d.b.turn ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                    function pretty(m) {
                        const x = /claude-([a-z]+)-(\d+)(?:-(\d+))?/.exec(m ?? "");
                        if (!x) return m ?? "";
                        return x[1].charAt(0).toUpperCase() + x[1].substring(1) + " " + x[2] + (x[3] && x[3].length <= 2 ? "." + x[3] : "");
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text.length > 0
                        text: [parent.pretty(d.b.model), d.b.secs > 0 ? (d.b.secs < 60 ? `${d.b.secs}s` : `${Math.floor(d.b.secs / 60)}m ${d.b.secs % 60}s`) : "",
                               d.b.ts > 0 ? Qt.formatDateTime(new Date(d.b.ts), "hh:mm") : ""].filter(x => x.length).join(" · ")
                        font.pixelSize: 13
                        color: Appearance.colors.colInkSecondary
                    }
                    MaterialSymbol {
                        id: copyTurn
                        property bool done: false
                        anchors.verticalCenter: parent.verticalCenter
                        text: copyTurn.done ? "check" : "content_copy"
                        iconSize: 15
                        color: copyArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                        MouseArea { id: copyArea; anchors { fill: parent; margins: -5 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { Quickshell.clipboardText = d.b.text; copyTurn.done = true; copyReset.restart(); } }
                        Timer { id: copyReset; interval: 1500; onTriggered: copyTurn.done = false }
                        StyledToolTip { text: "Copy reply"; extraVisibleCondition: copyArea.containsMouse }
                    }
                }
            }
            Component { id: textC; ClaudeText { markdown: d.b.content; highlight: conv.finding ? conv.findQuery.trim() : "" } }
            Component { id: codeC; CodeBlock { code: d.b.content; lang: d.b.lang } }
            Component { id: toolC; ToolLine { item: d.b.item; openIds: conv.openIds; onToggled: key => conv.toggleOpen(key); viewer: conv.viewer; files: conv.files; running: conv.runningIds.includes(d.b.item.id) } }
            Component { id: activityC; ActivityGroup { tools: d.b.tools; openIds: conv.openIds; onToggled: key => conv.toggleOpen(key); viewer: conv.viewer; files: conv.files; runningIds: conv.runningIds; asking: conv.pending.length > 0 && d.isLast } }
            Component { id: agentsC; AgentsGroup { calls: d.b.calls; info: conv.agentsInfo; now: conv.clock; openAgent: conv.openAgent; onOpened: a => conv.agentOpened(a) } }
            Component {
                id: workflowC
                WorkflowCard {
                    item: d.b.item
                    run: (conv.agentsInfo?.workflows ?? []).find(w => w.call === d.b.item.id) ?? null
                    open: run !== null && conv.openRun === run.run
                    canStop: conv.canStop
                    now: conv.clock
                    onOpened: if (run) conv.runOpened(run.run)
                    onStopRequested: task => conv.stopTask(task)
                }
            }
            Component { id: thinkC; ThinkingLine { text: d.b.text; openIds: conv.openIds; onToggled: key => conv.toggleOpen(key) } }
            Component {
                id: noteC
                // one line, cut short: a long background-task summary ran off both sides; meta ink, not faded with opacity
                StyledText { horizontalAlignment: Text.AlignHCenter; text: d.b.text; elide: Text.ElideRight; maximumLineCount: 1; font.pixelSize: 14; color: Appearance.colors.colInkMeta }
            }
        }
    }

    Rectangle {
        id: toLatest
        readonly property bool wanted: !list.atEnd && list.contentHeight > list.height + 40 && conv.session !== null
        anchors { horizontalCenter: list.horizontalCenter; bottom: list.bottom; bottomMargin: 16 }
        width: latestRow.implicitWidth + 26
        height: 34
        radius: 17
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, latestArea.pressed ? 0.76 : latestArea.containsMouse ? 0.82 : 0.88)
        Behavior on color { enabled: !latestArea.pressed; ColorAnimation { duration: 110 } }
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3outlineVariant, 0.3)
        opacity: wanted ? 1 : 0
        visible: opacity > 0
        scale: wanted ? 1 : 0.85
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        Row {
            id: latestRow
            anchors.centerIn: parent
            spacing: 6
            MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; text: "arrow_downward"; iconSize: 17; color: Appearance.colors.colInkMain }
            StyledText { anchors.verticalCenter: parent.verticalCenter; text: conv.busy ? "Back to the work" : "Latest"; font.pixelSize: 14; color: Appearance.colors.colInkMain }
        }
        MouseArea { id: latestArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: toEnd.restart() }
        StyledToolTip { text: conv.busy ? "Back to what it's doing" : "Latest"; extraVisibleCondition: latestArea.containsMouse }
    }

    // a click beside the box's open menu closes it, and does nothing else
    MouseArea {
        anchors.fill: parent
        enabled: composer.menuOpen
        acceptedButtons: Qt.AllButtons
        onPressed: composer.dismiss()
    }

    // ── bottom: changes line, permission questions, the message box ────────
    Column {
        id: bottomArea
        z: 1   // the box's menu opens over the conversation and what lies on it
        visible: conv.session !== null && conv.need.length === 0   // Claude Code not ready: SetupNotice instead
        x: (parent.width - conv.columnWidth) / 2
        width: conv.columnWidth
        anchors.bottom: parent.bottom
        spacing: 8
        Item {
            visible: conv.hostNote.length > 0
            width: parent.width
            height: visible ? 30 : 0
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                Spinner { visible: conv.hostNote === "reconnecting"; implicitSize: 14; colShape: Appearance.colors.colPrimary; anchors.verticalCenter: parent.verticalCenter }
                MaterialSymbol { visible: conv.hostNote !== "reconnecting"; text: "error"; iconSize: 16; color: Appearance.colors.colInkSecondary; anchors.verticalCenter: parent.verticalCenter }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: conv.hostNote === "reconnecting" ? "Reconnecting to Praxis's background service…"
                        : conv.hostNote === "outdated" ? "Praxis was updated; its background service needs a restart."
                        : "Praxis can't reach its background service."
                    font.pixelSize: 13
                    color: Appearance.colors.colInkSecondary
                }
            }
            PillButton {
                visible: conv.hostNote !== "reconnecting"
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: "Restart it"
                onClicked: conv.restartHost()
            }
        }
        // an old host would run this session as Claude Code: it goes on in its own CLI
        Item {
            id: oldHostNote
            property bool copied: false
            visible: conv.oldHost && conv.host.connected && conv.resumeCommand.length > 0
            width: parent.width
            height: visible ? 30 : 0
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                MaterialSymbol { text: "terminal"; iconSize: 16; color: Appearance.colors.colInkSecondary; anchors.verticalCenter: parent.verticalCenter }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: `Continue this ${conv.agentName} session in a terminal`
                    font.pixelSize: 13
                    color: Appearance.colors.colInkSecondary
                }
            }
            PillButton {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: oldHostNote.copied ? "Copied" : "Copy resume command"
                onClicked: { Quickshell.clipboardText = conv.resumeCommand; oldHostNote.copied = true; copiedReset.restart(); }
            }
            Timer { id: copiedReset; interval: 1500; onTriggered: oldHostNote.copied = false }
        }
        // the process ended for want of a sign-in: Sign in opens the account's step; once it is
        // back, Send again sends the message it was given
        Item {
            id: authNote
            readonly property bool back: !!conv.acc?.available && conv.acc.stepOf(conv.agent, conv.chosenAccount) === "ready"
            // Send again only for a message sent from here
            readonly property bool act: !authNote.back || !!conv.authLost?.text
            visible: conv.authLost !== null
            width: parent.width
            height: visible ? 30 : 0
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: authNote.back ? `Signed in to ${conv.agentName}`
                        : conv.authLost?.reason === "expired" ? `Your ${conv.agentName} sign-in has expired` : `${conv.agentName} isn't signed in`
                    font.pixelSize: 13
                    color: Appearance.colors.colInkSecondary
                }
                StyledText {
                    visible: authNote.act
                    anchors.verticalCenter: parent.verticalCenter
                    text: "·"
                    font.pixelSize: 13
                    color: Appearance.colors.colInkMeta
                }
                StyledText {
                    visible: authNote.act
                    anchors.verticalCenter: parent.verticalCenter
                    text: authNote.back ? "Send again" : "Sign in"
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    color: Appearance.colors.colPrimary
                    MouseArea {
                        anchors { fill: parent; margins: -4 }
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!authNote.back) {
                                composer.openMenu("agent");
                                return;
                            }
                            const l = conv.authLost;
                            conv.authLost = null;
                            if (l?.text) conv.send(l.text, l.images, l.files);
                        }
                    }
                }
            }
        }
        StyledText {
            visible: conv.error.length > 0
            width: parent.width
            text: conv.error
            wrapMode: Text.Wrap
            font.pixelSize: 13
            color: Appearance.colors.colClay
        }
        Repeater {
            model: conv.waitingShown
            delegate: Rectangle {
                id: w
                required property var modelData
                width: bottomArea.width
                height: 36
                radius: 10
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.96)
                HoverHandler { id: wHover }
                MaterialSymbol {
                    id: wGlyph
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    text: "schedule_send"
                    iconSize: 16
                    color: Appearance.colors.colInkSecondary
                }
                StyledText {
                    anchors { left: wGlyph.right; leftMargin: 8; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: w.modelData
                    elide: Text.ElideRight
                    font.pixelSize: 15
                    color: Appearance.colors.colInkSecondary
                }
                StyledToolTip { text: "Waiting in the terminal: Claude reads it after its current step"; extraVisibleCondition: wHover.hovered }
            }
        }
        Repeater {
            model: conv.queued.filter(q => !q.shown)
            delegate: Rectangle {
                id: q
                required property var modelData
                required property int index
                width: bottomArea.width
                height: 36
                radius: 10
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.96)
                HoverHandler { id: qHover }
                MaterialSymbol {
                    id: qGlyph
                    anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                    text: "schedule_send"
                    iconSize: 16
                    color: Appearance.colors.colInkSecondary
                }
                StyledText {
                    anchors { left: qGlyph.right; leftMargin: 8; right: qClose.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                    text: q.modelData.text
                    elide: Text.ElideRight
                    font.pixelSize: 15
                    color: Appearance.colors.colInkSecondary
                }
                MaterialSymbol {
                    id: qClose
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                    text: "close"
                    iconSize: 16
                    color: qArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                    MouseArea {
                        id: qArea
                        anchors { fill: parent; margins: -6 }
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: conv.queued = conv.queued.filter(x => x !== q.modelData)
                    }
                }
                StyledToolTip { text: "Sends when the agent stops"; extraVisibleCondition: qHover.hovered }
            }
        }
        Repeater {
            model: conv.pending
            delegate: Loader {
                id: ask
                required property var modelData
                width: bottomArea.width
                sourceComponent: ask.modelData.tool === "AskUserQuestion" ? questionCard : permissionCard
                Component {
                    id: questionCard
                    QuestionCard {
                        pending: ask.modelData
                        // the conversation keeps the rest of the window
                        maxHeight: (conv.height - header.height) * 0.6
                        onAnswered: input => conv.answer({ op: "answer", id: conv.session.id, request: ask.modelData.request, allow: true, input: input })
                        onSkipped: conv.answer({ op: "answer", id: conv.session.id, request: ask.modelData.request, allow: false, message: "The user skipped the question." })
                    }
                }
                Component {
                    id: permissionCard
                    PermissionCard {
                        pending: ask.modelData
                        onAnswered: (allow, permissions) => {
                            const req = { op: "answer", id: conv.session.id, request: ask.modelData.request, allow: allow };
                            if (permissions) req.permissions = permissions;
                            conv.answer(req);
                        }
                    }
                }
            }
        }
        PlanStrip { width: parent.width; items: conv.items; working: conv.busy; turnStart: conv.turnStart; sessionId: conv.session?.id ?? "" }
        AsideCard { width: parent.width; thread: conv.asideThread; onClosed: conv.asideThread = [] }
        Item {
            id: stepNote
            visible: composer.showStep
            width: parent.width
            height: visible ? 34 : 0
            Row {
                anchors { left: parent.left; leftMargin: 4; verticalCenter: parent.verticalCenter }
                spacing: 8
                MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; text: "key"; iconSize: 16; color: Appearance.colors.colInkSecondary }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, stepNote.width - 180)
                    elide: Text.ElideRight
                    text: composer.stepLine
                    font.pixelSize: 14
                    color: Appearance.colors.colInkSecondary
                }
            }
            PillButton {
                visible: text.length > 0
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                text: composer.hasAccounts ? composer.accounts.stepWord(composer.step) : ""
                onClicked: composer.openMenu("agent")
            }
        }
        Rectangle {
            id: terminalNote
            property bool copied: false
            visible: conv.locked
            width: parent.width
            height: visible ? 64 : 0
            radius: 16
            color: "transparent"
            border.width: 1
            border.color: ColorUtils.transparentize(Appearance.m3colors.m3outlineVariant, 0.3)
            MaterialSymbol { x: 18; anchors.verticalCenter: parent.verticalCenter; text: "terminal"; iconSize: 20; color: Appearance.colors.colInkSecondary }
            Column {
                anchors { left: parent.left; leftMargin: 50; right: termCopy.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 2
                StyledText { width: parent.width; elide: Text.ElideRight; text: "This session is running in a terminal"; font.pixelSize: 15; font.weight: Font.Medium; color: Appearance.colors.colInkMain }
                StyledText { width: parent.width; elide: Text.ElideRight; text: "Follow it here. Close it there to carry on here."; font.pixelSize: 14; color: Appearance.colors.colInkSecondary }
            }
            PillButton {
                id: termCopy
                visible: conv.resumeCommand.length > 0
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                text: terminalNote.copied ? "Copied" : "Copy resume command"
                onClicked: { Quickshell.clipboardText = conv.resumeCommand; terminalNote.copied = true; termCopied.restart(); }
            }
            Timer { id: termCopied; interval: 1500; onTriggered: terminalNote.copied = false }
        }
        // the card keeps the composer box's 16 px off the window's bottom edge (column spacing 8 + this 8);
        // flush on the edge, the window's rounded corner cut into its border
        Item { visible: terminalNote.visible; width: 1; height: 8 }
        Composer {
            id: composer
            visible: !conv.locked
            width: parent.width
            canAside: conv.session !== null && !(conv.session?.fresh ?? false) && !conv.locked && !!conv.caps?.aside
            onAsideAsked: q => conv.askAside(q)
            agent: conv.agent
            agents: conv.host.agents
            accounts: conv.acc
            features: conv.host.features
            account: conv.chosenAccount
            effort: conv.chosenEffort
            reportedEffort: conv.live?.effort ?? ""
            recent: conv.prefs.recent?.[conv.agent] ?? []
            keepFolder: (conv.session?.cwd ?? "").startsWith("/") ? conv.session.cwd : ""
            modesAllowed: conv.caps?.modes ?? null
            ground: conv.ground
            // the stop button: only while the agent's process is in a turn. A subagent still running in the
            // background after the turn ended kept it showing, and a stop sent to the idle process did nothing
            // (those stop from the agents panel)
            working: conv.turnOpen
            locked: conv.locked
            fresh: conv.session?.fresh ?? false
            folder: conv.session?.cwd ?? ""
            folders: conv.folders
            // the CLI reports ask-first as "default"
            mode: { const m = conv.live && (conv.live.mode ?? "").length ? conv.live.mode : conv.chosenMode; return m === "default" ? "manual" : m; }
            model: conv.chosenModel
            commands: conv.commands
            meter: conv.meter
            meterPct: conv.meterPct
            sendFn: (text, images, files) => conv.send(text, images, files)
            onStop: if (conv.live) conv.host.request({ op: "interrupt", id: conv.session.id })
            onFolderPicked: path => conv.folderChosen(path)
            // Only a fresh session takes another agent (folders plan: agentChosen); its model and
            // level come from the folder's defaults for that agent (resolveRun).
            onAgentPicked: (agent, account, keep) => {
                if (!conv.session?.fresh) return;
                conv.accountPicked = true;
                conv.chosenAccount = account;
                if (agent !== conv.agent) {
                    conv.chosenModel = "";
                    conv.chosenEffort = "";
                    conv.agentChosen(agent);
                }
                if (keep) conv.keep({ agent: agent, account: account });
            }
            onModePicked: (m, keep) => {
                conv.chosenMode = m;
                // the host keeps it for a process it has closed while idle, and starts it so next time
                if (conv.live) conv.host.request({ op: "mode", id: conv.session.id, mode: m });
                if (keep) conv.keep({ mode: m });
            }
            // "Default" is the agent's own model ("default"; a host without model lists takes nothing)
            onModelPicked: (m, effort, keep) => {
                const was = conv.chosenEffort || (conv.live?.effort ?? "");
                conv.chosenModel = m;
                conv.chosenEffort = effort;
                conv.noteRecent(conv.agent, m);
                if (conv.live) {
                    if (m.length || conv.host.features.includes("catalog"))
                        conv.host.request({ op: "model", id: conv.session.id, model: m.length ? m : "default" });
                    if (effort.length && effort !== was && conv.canEffort)
                        conv.host.request({ op: "effort", id: conv.session.id, effort: effort });
                }
                if (keep) conv.keep({ model: m, effort: effort });
            }
            onEffortPicked: (level, keep) => {
                conv.chosenEffort = level;
                if (conv.live && conv.canEffort && level.length) conv.host.request({ op: "effort", id: conv.session.id, effort: level });
                if (keep) conv.keep({ effort: level });
            }
            onPrefsRequested: conv.prefsRequested()
            onSettingsRequested: anchor => conv.settingsRequested(anchor)
        }
    }

    SetupNotice {
        id: setupNotice
        anchors.fill: parent
        visible: shown
        accounts: conv.acc
        need: conv.need
        fresh: conv.session?.fresh ?? false
        hostNote: conv.hostNote
        reserve: bottomArea.visible ? bottomArea.height : 0
        onRecheck: conv.recheck()
        onSetupRequested: conv.openAgentCove(true)
    }
    // no session open and no host: the reason, where the conversation would be
    Column {
        anchors.centerIn: parent
        visible: conv.need.length === 0 && conv.session === null && conv.hostNote.length > 0
        spacing: 12
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 8
            Spinner { visible: conv.hostNote === "reconnecting"; implicitSize: 15; colShape: Appearance.colors.colPrimary; anchors.verticalCenter: parent.verticalCenter }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: conv.hostNote === "reconnecting" ? "Reconnecting to Praxis's background service…"
                    : conv.hostNote === "outdated" ? "Praxis was updated; its background service needs a restart."
                    : "Praxis can't reach its background service, so your sessions can't load."
                font.pixelSize: 15
                color: Appearance.colors.colInkSecondary
            }
        }
        PillButton { visible: conv.hostNote !== "reconnecting"; anchors.horizontalCenter: parent.horizontalCenter; text: "Restart it"; onClicked: conv.restartHost() }
    }
    Column {
        anchors.centerIn: parent
        visible: conv.need.length === 0 && setupNotice.form !== "setup" && !(conv.session === null && conv.hostNote.length > 0)
            && (conv.session === null || (conv.loading && !slowRead.running && conv.items.length === 0) || (conv.session?.fresh ?? false))
            || (conv.readFailed && conv.items.length === 0)
        spacing: 8
        readonly property bool fresh: conv.session?.fresh ?? false
        // a new session: what to do; where and with whom are the chips below
        StyledText {
            visible: parent.fresh
            anchors.horizontalCenter: parent.horizontalCenter
            text: `What should ${conv.agentName} do in ${composer.placeWord(conv.session?.cwd ?? "")}?`
            font.pixelSize: 22
            font.weight: Font.DemiBold
            color: Appearance.colors.colInkMain
        }
        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            text: conv.session === null ? "Pick a session on the left."
                : parent.fresh ? "Write it below: @ adds files, / runs a command."
                : conv.readFailed ? "That conversation could not be read." : "Reading…"
            font.pixelSize: 15
            color: Appearance.colors.colInkSecondary
        }
    }
}
