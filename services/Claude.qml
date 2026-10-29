pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import "../modules/claude"

/**
 * Claude as one system (plan: ~/book4-edge/claude-unified-plan.md). What every shell surface
 * shares about the notch conversation: the one connection to agent-host, the context taken
 * when you invoke it (chips you can remove), whether a question continues the last
 * conversation or starts a new one, the draft, the send queue. The notch's Ask sheet only
 * draws this; the palette, captures and Files hand their questions and files in through
 * IslandController.openAsk.
 *
 * Continue or new (§4): the last conversation continues when it was used in the last 15
 * minutes from the same folder; otherwise the next question starts a new chat. The sheet says
 * which, and one click flips it.
 */
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")

    // ── the one connection to agent-host ────────────────────────────────────
    Host {
        id: host
        roster: false
        onConnectedChanged: {
            if (!connected)
                return;
            root.attach();
            titlesLater.restart();
            // Questions typed while the host was working sit in the queue, and only a turn ending
            // drains it: when the host itself went away nothing was left to end a turn, so they
            // stayed there for the rest of the session.
            if (root.queue.length)
                Qt.callLater(root.sendNext);
        }
    }
    readonly property bool connected: host.connected
    readonly property var live: host.live
    function request(obj, cb) { host.request(obj, cb); }

    // The conversations' own titles (Claude's, or the name given one), from the host's history. A session's live
    // `prompt` is only the first message sent through the host since it last attached: on a resumed session that is
    // whatever was typed first after resuming ("shell crashed"), which the notch then showed as its name for good.
    property var historyTitles: ({})
    Timer {
        id: titlesLater
        interval: 4000   // history changes with every message of a running session: read it after a quiet moment
        onTriggered: host.request({ op: "history" }, r => {
            if (r.ev !== "history" || !Array.isArray(r.sessions)) return;
            const t = {};
            for (const e of r.sessions) {
                const name = (e.title ?? "") + "";
                if (name.length) t[e.id] = name;
                else if ((e.prompt ?? "").length) t[e.id] = e.prompt + "";
            }
            root.historyTitles = t;
        })
    }
    Connections {
        target: host
        function onHistoryChanged() { titlesLater.restart(); }
    }
    function startHost() { Quickshell.execDetached(["systemctl", "--user", "start", "agent-host.service"]); }

    // ── the notch conversation ──────────────────────────────────────────────
    FileView {
        id: currentFile
        path: `${Directories.state}/user/claude-current.json`
        blockLoading: true
        printErrors: false
    }
    // { id, cwd, title, lastAt }: the conversation the notch last had
    property var current: {
        try { return JSON.parse(currentFile.text() || "null"); } catch (e) { return null; }
    }
    function setCurrent(c) {
        root.current = c;
        currentFile.setText(JSON.stringify(c));
    }
    function touch() {
        if (root.current) root.setCurrent(Object.assign({}, root.current, { lastAt: Date.now() }));
    }
    property bool continuing: false
    readonly property string sid: root.continuing && root.current ? (root.current.id ?? "") : ""
    readonly property var session: root.sid.length ? (host.live[root.sid] ?? null) : null
    readonly property bool busy: root.session !== null && root.session.state === "working"
    readonly property var pending: root.session ? (root.session.pending ?? []) : []
    readonly property int continueWindow: 15 * 60000
    function decide() {
        const c = root.current;
        root.continuing = !!(c && c.id && Date.now() - (c.lastAt ?? 0) < root.continueWindow && c.cwd === root.cwd);
    }
    function newChat() { root.continuing = false; root.note = ""; }
    function continueChat() { if (root.current && root.current.id) root.continuing = true; }
    // Praxis's way in, for every surface that hands something to it: the notch, Files, the
    // recents rows, the session list. The script is not in this repo, and execDetached cannot
    // tell a missing binary from a started one, so a machine without it swallowed every hand-off
    // without a word. The guard runs it by position, so a prompt with quotes in it is untouched.
    readonly property string handRunner: `${Directories.tacitBin}/claude-hand`
    function hand(op, a, b) {
        const args = [op, a, b].filter(x => x !== undefined);
        Quickshell.execDetached(["bash", "-c",
            '[ -x "$0" ] || { notify-send -a Praxis -u critical "Praxis is not installed" "Nothing was handed over: $0 is missing."; exit 1; }; exec "$0" "$@"',
            root.handRunner].concat(args));
    }
    function openInApp() {
        if (root.sid.length)
            root.hand("open", root.sid);
    }
    function stop() {
        if (!root.sid.length) return;
        root.queue = [];
        host.request({ op: "interrupt", id: root.sid });
    }

    // For the "Continuing … · 4m" line: minutes, refreshed while the sheet is up.
    property bool sheetOpen: false
    property real now: Date.now()
    Timer {
        running: root.sheetOpen
        interval: 30000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }
    function ago(t) {
        const m = Math.max(0, Math.round((root.now - (t ?? 0)) / 60000));
        return m < 1 ? "now" : m < 60 ? `${m}m` : m < 1440 ? `${Math.floor(m / 60)}h` : `${Math.floor(m / 1440)}d`;
    }
    // a question as a title: its first line, cut at a word near 40 characters
    function shorten(q) {
        const line = (q ?? "").split("\n")[0].trim();
        if (line.length <= 40) return line;
        const cut = line.lastIndexOf(" ", 40);
        return line.substring(0, cut > 20 ? cut : 40) + "…";
    }
    function folderName(p) { return !p || p === root.home ? "Home" : Files.placeName(p); }

    // ── what the conversation says (the sheet draws these) ──────────────────
    property var earlier: []          // turns before the running process began (the transcript)
    property var items: []            // the running process's messages (host "items")
    property string pendingQ: ""      // what you just sent, until the session echoes it
    // The answer being written out. It keeps revealing after the finished message arrives
    // (liveDone), so the end of an answer never lands as one block.
    property string liveText: ""
    property bool liveDone: false
    property int liveBase: 0          // assistant texts already committed when it started
    property int shown: 0
    property real budget: 0
    property string error: ""
    property string note: ""          // what the continuity line adds ("couldn't resume …")
    signal loaded()                   // a conversation was (re)built: the sheet lands at its end

    // A message carries the desktop context after the question; what you see is the question.
    function strip(text) { return (text ?? "").replace(/\s*<desktop-context>[\s\S]*<\/desktop-context>\s*$/, ""); }
    function committedTexts(list) { return list.filter(i => i.role === "assistant" && i.kind === "text").length; }
    function clearLive() { root.liveText = ""; root.liveDone = false; root.shown = 0; root.budget = 0; }

    onSidChanged: root.attach()
    // the conversation to show changed, or the connection came back: build it again
    function attach() {
        root.unwatchAll();
        root.seenSeq = -1;
        root.replaying = false;
        root.watchingId = "";
        root.earlier = [];
        root.items = [];
        root.clearLive();
        root.error = "";
        root.loadingId = "";   // a load cut off by the reconnect must not block this one
        root.loadGen++;        // and its reply, if it still comes, is not for this conversation
        if (root.sid.length && host.connected) root.load();
    }
    // The host only holds what the running process said, which is nothing once it has idled
    // out: the turns before come from the transcript, up to where the running process began.
    property string loadingId: ""
    // The retry below races the load it replaces, and both replies pass the id guard: the second
    // one rebuilt the conversation again and jumped it to the end. The generation a request went
    // out with says which replies may still be applied, the same way seenSeq does for events.
    property int loadGen: 0
    function load() {
        const id = root.sid;
        if (root.loadingId === id) return;
        root.loadingId = id;
        const gen = ++root.loadGen;
        loadTimeout.restart();
        host.request({ op: "list" }, l => {
            if (gen !== root.loadGen) return;
            if (l.disconnected) { root.loadingId = ""; loadTimeout.stop(); return; }   // attach() reads again on reconnect
            const s = (l.sessions ?? []).find(x => x.id === id);
            host.request({ op: "transcript", id: id, limit: 40 }, m => {
                if (gen !== root.loadGen) return;
                if (root.loadingId === id) { root.loadingId = ""; loadTimeout.stop(); root.loadRetried = false; }
                if (id !== root.sid || m.disconnected) return;
                if (m.ev === "transcript") {
                    const since = s && s.alive ? (s.started ?? 0) : Infinity;
                    root.earlier = (m.items ?? []).filter(i => Number(i.ts ?? 0) < since);
                    root.loaded();
                } else if (!s) {
                    // neither running nor on disk: say so, and the next question is a new chat
                    root.continuing = false;
                    root.note = "That conversation is gone; this is a new chat.";
                    return;
                }
                if (s && s.alive) root.watch();
            });
        });
    }

    // A host that is still starting can drop the request; no reply in 3 s, ask again once.
    property bool loadRetried: false
    Timer {
        id: loadTimeout
        interval: 3000
        onTriggered: {
            if (!root.loadingId.length) return;
            root.loadingId = "";
            if (!root.loadRetried && root.sid.length && host.connected) { root.loadRetried = true; root.load(); }
        }
    }
    // Watching replays everything the running process has streamed so far (events up to the
    // reply's seq), and the reply can arrive before or after that backlog. Replayed text is not
    // written out again: only a block still being written carries on, from where it has got to.
    property string watchingId: ""
    // The host writes a watched session's every event and full item list until it is told to stop,
    // and nothing but op:unwatch stops it. watchingId cannot name them: onExited blanks it while
    // the host still holds the id, so the ids actually sent are kept here instead.
    property var sentWatches: ({})
    function unwatchAll() {
        for (const id in root.sentWatches)
            host.request({ op: "unwatch", id: id });
        root.sentWatches = ({});
    }
    property bool replaying: false
    property int seenSeq: -1          // the running process's events already taken in
    property int replaySeq: -1        // the reply's seq: the last event of the backlog
    property int bufferedSeq: -1
    property string replayBuf: ""
    function watch() {
        const id = root.sid;
        root.watchingId = id;
        root.replaying = true;
        root.replaySeq = -1;
        root.bufferedSeq = -1;
        root.replayBuf = "";
        root.sentWatches[id] = true;
        host.request({ op: "watch", id: id, from: 0 }, m => {
            if (id !== root.sid) return;
            if (m.ev !== "watching") { root.replaying = false; root.watchingId = ""; return; }
            root.items = m.items ?? [];
            root.replaySeq = m.seq ?? 0;
            if (root.bufferedSeq >= root.replaySeq) root.endReplay();
            else replayWait.restart();    // the backlog is still coming, or there is none
        });
    }
    Timer { id: replayWait; interval: 300; onTriggered: if (root.replaying) root.endReplay() }
    function endReplay() {
        root.replaying = false;
        replayWait.stop();
        const texts = root.earlier.concat(root.items).filter(i => i.role === "assistant" && i.kind === "text");
        const last = texts.length ? texts[texts.length - 1].text : "";
        if (root.replayBuf.length && root.replayBuf !== last && root.busy && !root.liveText.length) {
            root.liveText = root.replayBuf;
            root.shown = root.replayBuf.length;
            root.liveDone = false;
            root.liveBase = texts.length;
        }
        root.replayBuf = "";
    }
    Connections {
        target: host
        function onEvent(id, seq, data) {
            if (id !== root.sid) return;
            if (seq <= root.seenSeq) return;   // replayed again by a second watch
            root.seenSeq = seq;
            const e = data.type === "stream_event" ? (data.event ?? {}) : {};
            if (root.replaying) {
                root.bufferedSeq = seq;
                if (e.type === "message_start" || e.type === "content_block_start") root.replayBuf = "";
                else if (e.type === "content_block_delta" && e.delta?.type === "text_delta") root.replayBuf += e.delta.text;
                if (root.replaySeq >= 0 && seq >= root.replaySeq) root.endReplay();
                return;
            }
            if (e.type !== "content_block_delta" || e.delta?.type !== "text_delta") return;
            if (root.liveDone || !root.liveText.length) {   // a new answer block
                root.clearLive();
                root.liveBase = root.committedTexts(root.earlier.concat(root.items));
            }
            root.liveText += e.delta.text;
        }
        function onItems(id, list) {
            if (id !== root.sid) return;
            root.items = list;
            // a slash command echoes as {kind:"command", text:"compact"} while the question keeps its
            // slash: matched on text alone it never clears, and the turn is on screen twice
            const asked = root.pendingQ.replace(/^\//, "");
            if (root.pendingQ.length && list.some(i => i.role === "user"
                    && (i.kind === "text" ? root.strip(i.text) === root.pendingQ : i.kind === "command" && i.text === asked)))
                root.pendingQ = "";
            // the live answer is committed: reveal the rest from the finished text
            if (root.liveText.length && !root.liveDone && root.committedTexts(root.earlier.concat(list)) > root.liveBase) {
                // Counted over both lists, so taken from both: onExited moves the running
                // process's items into earlier and empties list, and the next event's list can
                // carry no assistant text at all. Reading it from list alone threw here and left
                // the reveal armed but never finished, so the answer stopped a word short.
                const done = root.earlier.concat(list).filter(i => i.role === "assistant" && i.kind === "text").pop();
                if (!done)
                    return;
                root.liveText = done.text;
                root.shown = Math.min(root.shown, done.text.length);
                root.liveDone = true;
            }
        }
        function onExited(id, reason, stderr) {
            if (id !== root.sid) return;
            root.seenSeq = -1;             // a resumed process counts from the start again
            root.watchingId = "";
            if (root.sentWatches[id]) { host.request({ op: "unwatch", id: id }); delete root.sentWatches[id]; }
            root.earlier = root.earlier.concat(root.items);
            root.items = [];
            // A block still being written out when the process went is never committed, so it
            // would stay half-revealed and the next answer's text would be appended to it.
            if (!root.liveDone)
                root.clearLive();
            // stopped with a question unanswered: say why, and keep the draft for a retry
            if (reason === "crashed" || (reason === "exited" && root.pendingQ.length)) {
                const why = (stderr ?? []).map(l => String(l).trim()).filter(l => l.length).pop() ?? "";
                root.error = why.length ? `Claude stopped: ${why}` : "Claude stopped before answering.";
                root.pendingQ = "";
            }
        }
    }
    // Written out word by word at a reading pace, quicker only when far behind (it never trails
    // the model by more than about two seconds). Whole words only: a half word at a line's end
    // re-wraps as it completes, and the notch would twitch with it.
    Timer {
        running: root.shown < root.liveText.length
        interval: 33
        repeat: true
        onTriggered: {
            const t = root.liveText;
            root.budget = Math.min(root.budget + Math.max(60, (t.length - root.shown) / 2) * 0.033, 40);
            let next = root.shown;
            while (true) {
                const m = t.substring(next).match(/^\s*\S+/);
                if (!m) break;
                const end = next + m[0].length;
                if (end === t.length && !root.liveDone) break;               // may still be streaming
                if (end - root.shown > root.budget && !(next === root.shown && root.budget >= 40)) break;
                next = end;
            }
            if (root.liveDone && !/\S/.test(t.substring(next))) next = t.length;
            root.budget = Math.max(0, root.budget - (next - root.shown));
            root.shown = next;
        }
    }
    onShownChanged: if (root.liveDone && root.shown >= root.liveText.length) root.clearLive()

    // ── the draft: what you are writing and what goes with it ───────────────
    // chips: { kind: "context" | "image" | "file", glyph, label, text (context), path (files) }
    property var chips: []
    property string draftText: ""
    property double draftAt: 0
    property string pendingText: ""   // a question handed in (palette): sent once the context is in
    function isImage(p) { return /\.(png|jpe?g|gif|webp)$/i.test(p); }
    function fileChip(path) {
        return root.isImage(path) ? { kind: "image", glyph: "image", label: path.split("/").pop(), path: path }
                                  : { kind: "file", glyph: "description", label: path.split("/").pop(), path: path };
    }
    function removeChip(i) { root.chips = root.chips.filter((_, j) => j !== i); }

    // ── what you were looking at (§3) ───────────────────────────────────────
    property string cwd: root.home
    property bool reading: false
    Process {
        id: contextProc
        command: [`${Directories.tacitBin}/claude-context`]
        stdout: StdioCollector { onStreamFinished: root.took(this.text) }
    }
    function snapshot() {
        if (GlobalStates.screenLocked) { root.took("{}"); return; }   // never read while locked
        root.reading = true;
        contextProc.running = false;
        contextProc.running = true;
    }
    // class -> the title suffix it adds; Opsis ("browser") adds " · <thread>" instead (Attention.cleanTitle)
    readonly property var browsers: ({ "zen": "Zen Browser", "firefox": "Mozilla Firefox", "chromium": "Chromium", "google-chrome": "Google Chrome", "brave-browser": "Brave", "vivaldi-stable": "Vivaldi", "browser": "Thyris", "browser-cef": "Thyris" })
    function took(text) {
        let c = {};
        try { c = JSON.parse(text || "{}"); } catch (e) {}
        root.cwd = c.cwd || root.home;
        const out = [];
        const cls = c.class ?? "";
        const title = c.title ?? "";
        if (root.browsers[cls] !== undefined && title.length) {
            const page = cls === "browser" || cls === "browser-cef" ? Attention.cleanTitle(cls, title) : title.replace(new RegExp(`\\s+[—-]\\s+${root.browsers[cls]}$`), "");
            if (page.length)   // "" for an Opsis window with no page
                out.push({ kind: "context", glyph: "language", label: page, text: `The user is looking at the web page "${page}".` });
        } else if (c.cmd !== undefined && ["foot", "footclient", "kitty", "Alacritty", "com.mitchellh.ghostty"].includes(cls)) {
            out.push({ kind: "context", glyph: "terminal", label: root.folderName(root.cwd) + (c.cmd ? ` · ${c.cmd}` : ""),
                       text: `The user is in a terminal at ${root.cwd}${c.cmd ? `, running ${c.cmd}` : ""}.` });
        } else if ((c.file ?? "").length) {
            const where = c.line ? `:${c.line}` : "";
            out.push({ kind: "context", glyph: "code", label: c.file.split("/").pop() + where,
                       text: `The user has ${c.root}/${c.file} open in their editor${c.line ? ` at line ${c.line}` : ""}.` });
        } else if (cls === "org.quickshell" && title === "Files") {
            out.push({ kind: "context", glyph: "folder_open", label: root.folderName(root.cwd), text: `The user is browsing ${root.cwd} in their file manager.` });
        } else if (cls.length && title.length && cls !== "org.quickshell") {
            out.push({ kind: "context", glyph: "select_window", label: title, text: `The user is looking at ${cls}: "${title}".` });
        }
        // a context handed in with the question (the browser's task) stands for the window it came from, this once
        const handed = root.chips.filter(x => x.kind === "context" && x.handed).map(x => Object.assign({}, x, { handed: false }));
        root.chips = (handed.length ? handed : out).concat(root.chips.filter(x => x.kind !== "context"));
        root.reading = false;
        if (root.holdChoice) root.holdChoice = false;   // opened from a peek: show that conversation
        else root.decide();
        // continuing, but nothing on screen (a load lost to a host restart): build it now
        if (root.sid.length && !root.earlier.length && !root.items.length && !root.loadingId.length && host.connected) root.load();
        if (root.pendingText.length) {
            const t = root.pendingText;
            root.pendingText = "";
            root.send(t);
        }
    }

    // Every way in (the shortcut, the palette, a capture, Files, Recents): the draft is kept
    // for 30 minutes; the context is read again unless the sheet is already up.
    function invoke(origin, extra, text) {
        if (root.draftAt > 0 && Date.now() - root.draftAt > 30 * 60000) {
            root.draftText = "";
            root.chips = [];
        }
        root.draftAt = Date.now();
        if (extra && extra.length) root.chips = root.chips.concat(extra);
        if (root.sheetOpen) {
            if (text && text.length) root.send(text);
            return;
        }
        root.note = "";
        if (text && text.length) root.pendingText = text;
        root.snapshot();
    }

    // ── sending ─────────────────────────────────────────────────────────────
    // The context goes once per conversation, and again only when it has changed.
    property var sentContext: ({})
    property var queue: []            // { msg, images, question, ctx }: typed while it works
    property bool starting: false
    onBusyChanged: if (!root.busy && root.queue.length) Qt.callLater(root.sendNext)
    function sendNext() {
        if (root.busy || root.starting || !root.queue.length) return;
        const q = root.queue[0];
        root.queue = root.queue.slice(1);
        root.dispatch(q);
    }
    // false when nothing went: offline, or nothing to say (the draft stays either way)
    function send(text) {
        const t = (text ?? "").trim();
        const attached = root.chips.filter(c => c.kind !== "context");
        if (!t.length && !attached.length) return false;
        if (!host.connected) {   // the sheet says Claude isn't running; the draft stays
            if (t.length) root.draftText = t;
            return false;
        }
        const images = attached.filter(c => c.kind === "image").map(c => c.path);
        const files = attached.filter(c => c.kind === "file").map(c => `@${c.path}`);
        const question = [t.length ? t : "What is this?"].concat(files).join(" ");
        const ctx = root.chips.filter(c => c.kind === "context").map(c => c.text).join("\n");
        const withCtx = ctx.length > 0 && root.sentContext[root.sid] !== ctx;
        const msg = withCtx ? `${question}\n\n<desktop-context>\n${ctx}\n</desktop-context>` : question;
        root.draftText = "";
        root.chips = root.chips.filter(c => c.kind === "context");
        const q = { msg: msg, images: images, question: question, ctx: withCtx ? ctx : "" };
        if (root.busy || root.starting) root.queue = root.queue.concat([q]);
        else root.dispatch(q);
        return true;
    }
    function dispatch(q) {
        root.error = "";
        root.note = "";
        root.pendingQ = q.question;
        root.clearLive();
        if (!root.sid.length) {
            const cwd = root.cwd || root.home;
            root.starting = true;
            host.request({ op: "start", cwd: cwd, text: q.msg, images: q.images, mode: "auto" }, m => {
                root.starting = false;
                if (m.ev !== "started") {
                    root.error = m.message ?? "Could not start.";
                    root.pendingQ = "";
                    if (m.disconnected) root.draftText = q.question;   // nothing was sent: the question stays
                    return;
                }
                if (q.ctx.length) root.sentContext[m.id] = q.ctx;
                root.markShell(m.id);
                root.setCurrent({ id: m.id, cwd: cwd, title: root.shorten(q.question), lastAt: Date.now() });
                root.continuing = true;   // → attach(): reads and watches it
                root.pendingQ = q.question;
                Qt.callLater(root.sendNext);
            });
            return;
        }
        const id = root.sid;
        const resume = root.session === null || !root.session.alive;
        const op = resume ? { op: "start", cwd: root.current.cwd || root.home, resume: id, text: q.msg, images: q.images, mode: "auto" }
                          : { op: "send", id: id, text: q.msg, images: q.images };
        if (resume) root.starting = true;
        host.request(op, m => {
            if (resume) root.starting = false;
            if (m.ev === "error") {
                root.pendingQ = "";
                if (m.disconnected) { root.error = m.message; root.draftText = q.question; return; }   // the socket, not the conversation
                if (resume) { root.continuing = false; root.note = "Couldn't resume that conversation; this is a new chat."; root.draftText = q.question; }
                else root.error = m.message ?? "Could not send.";
                return;
            }
            if (q.ctx.length) root.sentContext[id] = q.ctx;
            root.touch();
            if (id === root.sid && root.watchingId !== id) root.watch();
        });
    }

    // ── signals: the notch is the one place a host session speaks up (§6) ──
    // Sessions started from the shell (the notch, the palette, a capture) get the Live
    // Activity; every host session peeks when it needs you or finishes, unless it is already on
    // screen (this sheet, or the Claude app showing it). Terminal sessions stay with
    // AgentSessions and the hooks, which no longer peek for sessions the host runs.
    FileView {
        id: shellFile
        path: `${Directories.state}/user/claude-shell.json`
        blockLoading: true
        printErrors: false
    }
    property var shellIds: {
        try { return JSON.parse(shellFile.text() || "[]"); } catch (e) { return []; }
    }
    function markShell(id) {
        root.shellIds = [id].concat(root.shellIds.filter(x => x !== id)).slice(0, 50);
        shellFile.setText(JSON.stringify(root.shellIds));
    }
    function isShell(id) { return root.shellIds.includes(id); }
    function owns(id) { return host.live[id] !== undefined; }
    readonly property bool waiting: Object.keys(host.live).some(id => (host.live[id].pending ?? []).length > 0)

    // what the notch conversation is doing now, for the Live Activity line
    readonly property string currentStep: {
        if (!root.busy) return "";
        for (let i = root.items.length - 1; i >= 0; i--)
            if (root.items[i].kind === "tool") return root.items[i].desc || root.items[i].summary || root.items[i].tool;
        return root.liveText.length ? "Writing" : "Thinking";
    }
    onCurrentStepChanged: if (root.activityId.length && root.activityId === root.sid && root.currentStep.length) IslandController.setActivityText(root.currentStep)

    property string activityId: ""    // the session the Live Activity follows
    property var lastStates: ({})
    property var peeked: ({})         // request ids already raised
    property var waitingSince: ({})   // request id -> { at, text, notified }
    Connections {
        target: host
        function onLiveChanged() { root.review(); }
        function onExited(id, reason, stderr) {
            if (id !== root.activityId) return;
            root.activityId = "";
            if (reason === "crashed") {
                const why = (stderr ?? []).map(l => String(l).trim()).filter(l => l.length).pop() ?? "";
                IslandController.endActivity("fail", why.length ? `Claude stopped: ${why}`.substring(0, 60) : "Claude stopped.");
            } else {
                IslandController.endActivity("ok", "", { silent: true });
            }
        }
    }
    function review() {
        const live = host.live;
        const next = {};
        const open = {};
        for (const id of Object.keys(live)) {
            const s = live[id];
            const pend = s.pending ?? [];
            const st = pend.length ? "waiting" : s.state;
            // off stage during a demo take: nothing now, and nothing marked as seen, so the first
            // review after the take raises what changed meanwhile
            if (!AgentSessions.inStage(s)) {
                for (const p of pend) open[p.request] = true;
                if (id in root.lastStates) next[id] = root.lastStates[id];
                continue;
            }
            next[id] = st;
            for (const p of pend) {
                open[p.request] = true;
                if (!root.peeked[p.request]) { root.peeked[p.request] = true; root.needsYou(id, p); }
            }
            const was = root.lastStates[id];
            if (was === st) continue;
            if (st === "working" && root.isShell(id) && root.activityId !== id) root.startActivity(id);
            if (st === "idle" && (was === "working" || was === "waiting")) root.finished(id);
        }
        // answered anywhere (the pill, the sheet, the app): its peek goes, and so does one waiting in the queue
        if (IslandController.transientState === "claudeAsk" && !open[IslandController.payload?.request ?? ""])
            IslandController.dismiss();
        if (IslandController.queue.some(q => q.name === "claudeAsk" && !open[q.data?.request ?? ""]))
            IslandController.queue = IslandController.queue.filter(q => q.name !== "claudeAsk" || open[q.data?.request ?? ""]);
        for (const r of Object.keys(root.waitingSince))
            if (!open[r]) delete root.waitingSince[r];
        root.lastStates = next;
    }
    function titleOf(id) { return root.shorten(root.strip(root.historyTitles[id] ?? host.live[id]?.prompt ?? "")) || "Claude"; }
    function startActivity(id) {
        if (Notifications.silent) return;
        root.activityId = id;
        IslandController.startActivity("Praxis", id === root.sid && root.currentStep.length ? root.currentStep : "Working", true);
    }
    // The pill is one short line: the answer's first line when there is one (what you would
    // read anyway), else the conversation's title and "done".
    function doneText(id) {
        let answer = "";
        if (id === root.sid) {
            const t = root.items.filter(i => i.role === "assistant" && i.kind === "text").pop();
            answer = t ? (root.strip(t.text).split("\n").find(l => l.trim().length) ?? "").trim() : "";
        }
        return answer.length ? answer.replace(/[*`_]/g, "") : `${root.titleOf(id)} done`;
    }
    function finished(id) {
        const text = root.doneText(id);
        if (id === root.activityId) {
            root.activityId = "";
            if (IslandController.activityRunning) {
                root.whenOffScreen(id,
                    () => IslandController.endActivity("ok", text, Notifications.silent ? { silent: true } : { claudeId: id }),
                    () => IslandController.endActivity("ok", "", { silent: true }));
                return;
            }
        }
        if (Notifications.silent) return;
        root.whenOffScreen(id, () => IslandController.request("activityDone", { icon: "check_circle", text: text, claudeId: id }, 35));
    }
    function askLabel(tool) {
        switch (tool) {
        case "Bash": return "Run";
        case "Edit": case "MultiEdit": return "Edit";
        case "Write": return "Write";
        case "WebFetch": return "Fetch";
        }
        return `Use ${tool}`;
    }
    function needsYou(id, p) {
        const question = p.tool === "AskUserQuestion";
        const i = p.input ?? {};
        const text = question ? `Claude asks: ${(i.questions ?? [])[0]?.question ?? "a question"}`
                              : `${root.askLabel(p.tool)} ${i.command ?? i.file_path ?? i.url ?? i.pattern ?? ""}`.trim() + "?";
        root.waitingSince[p.request] = { at: Date.now(), text: `${root.titleOf(id)}: ${text}`, notified: false };
        if (Notifications.silent) return;   // the glyph still shows it waits
        // 140: an ask comes first (above the greeting, battery low, a failed job), below only Flow while you speak
        root.whenOffScreen(id, () => IslandController.request("claudeAsk", { text: text, permission: !question, claudeId: id, request: p.request, icon: "back_hand", tone: "notify" }, 140));
    }
    // a permission answered from the pill; "Always allow" stays in the sheet and the app
    function answer(id, request, allow) {
        const req = { op: "answer", id: id, request: request, allow: allow };
        if (!allow) req.message = "The user declined this from the notch.";
        // The pill dismisses itself the moment it is clicked, so a refused or dropped answer left
        // the agent waiting and nothing said anywhere. The same notifier as an unanswered
        // permission below, and for the same reason: the peek is gone by the time this is known.
        host.request(req, m => {
            if (m.ev !== "error") return;
            Quickshell.execDetached(["notify-send", "-a", "Praxis", "-i", "dialog-error",
                                     "That answer didn't reach Claude", m.message ?? ""]);
        });
    }
    // still unanswered after a minute: one entry in the notifications panel, so it is not lost
    Timer {
        interval: 15000
        repeat: true
        running: root.waiting
        onTriggered: {
            for (const r of Object.keys(root.waitingSince)) {
                const w = root.waitingSince[r];
                if (w.notified || Date.now() - w.at < 60000) continue;
                w.notified = true;
                Quickshell.execDetached(["notify-send", "-a", "Praxis", "-i", "dialog-question", "Claude needs you", w.text]);
            }
        }
    }
    // A peek clicked: a shell conversation opens in the notch, any other in the Claude app.
    property bool holdChoice: false   // the next invoke shows this conversation whatever §4 says
    function openSession(id) {
        if (!root.isShell(id)) {
            root.hand("open", id);
            return;
        }
        const s = host.live[id] ?? {};
        if (!root.current || root.current.id !== id)
            root.setCurrent({ id: id, cwd: s.cwd ?? root.cwd, title: root.titleOf(id), lastAt: Date.now() });
        root.holdChoice = true;
        root.continuing = true;
        IslandController.openAsk("peek", [], "");
    }
    // On screen already (this sheet, or the Claude app in front showing it): no peek.
    Process {
        id: appProbe
        property var jobs: []
        // The running instance's own directory, not a baked-in one: under any other config name
        // or XDG_CONFIG_HOME the probe answered nothing and every conversation peeked twice.
        command: ["qs", "-p", Quickshell.shellPath("claude.qml"), "ipc", "call", "claudeapp", "state"]
        stdout: StdioCollector {
            onStreamFinished: {
                let s = {};
                try { s = JSON.parse(this.text); } catch (e) {}
                const active = ToplevelManager.activeToplevel;
                const jobs = appProbe.jobs;
                appProbe.jobs = [];
                for (const j of jobs)
                    (active && active.title === s.title && s.selected === j.id) ? j.on() : j.off();
            }
        }
    }
    function whenOffScreen(id, off, on) {
        const shown = on ?? (() => {});
        if (root.sheetOpen && id === root.sid) { shown(); return; }
        const active = ToplevelManager.activeToplevel;
        if (!active || !["org.quickshell", "praxis"].includes(active.appId)) { off(); return; }
        appProbe.jobs = appProbe.jobs.concat([{ id: id, off: off, on: shown }]);
        if (!appProbe.running) appProbe.running = true;
    }
}
