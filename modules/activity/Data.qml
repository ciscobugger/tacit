import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.SystemTray
import qs.modules.common

// What Activity shows. scripts/activity/sample.py reads the system every 2 s; this turns its numbers
// into the pages: which state the computer is in, what causes it, the sentence, the names and what
// can be done. The page is laid out again at most every 4 s and never while the pointer is on it.
Item {
    id: d

    property bool frozen: false
    property var raw: null          // the latest sample
    property var snap: null         // the sample the page is laid out from
    property real snapAt: 0
    property var disk: null
    property bool memAlarm: false
    property var quit: null         // an app being closed: {key, name, mem, at, phase, hadWindows}
    property var letFinish: ({})    // processor use the person said to let run
    property bool byProcessor: false // the list's amounts: memory, or the share of the processor (calm only)
    property real watts: 0          // battery power, smoothed (about 20 s)
    property var cpuShare: ({})     // key -> share of the processor, smoothed (about a minute)
    property real clock: Date.now()
    signal stuck(string key)

    readonly property string fixture: Quickshell.env("ACTIVITY_FIXTURE") ?? ""
    readonly property string home: Quickshell.env("HOME")
    readonly property real gib: 1073741824

    property int readerFails: 0
    readonly property bool readerFailed: readerFails >= 3
    Process {
        id: sampler
        running: d.fixture === ""
        command: ["python3", "-I", Quickshell.shellPath("scripts/activity/sample.py")]
        stdinEnabled: true
        stdout: SplitParser { onRead: line => d.receive(line) }
        // the numbers would just stop: start it again, and after three failures in a row say so
        onExited: {
            d.readerFails++;
            restartReader.restart();
        }
    }
    Timer {
        id: restartReader
        interval: 2000
        onTriggered: sampler.running = true
    }
    function send(obj) {
        if (d.fixture === "")
            sampler.write(JSON.stringify(obj) + "\n");
    }

    function receive(line) {
        let m;
        try { m = JSON.parse(line); } catch (e) { return; }
        if (m.ev === "sample") {
            d.readerFails = 0;
            d.raw = m;
            d.smooth(m);
            if (d.snap === null || d.quit !== null)
                d.apply();
        } else if (m.ev === "disk") {
            d.disk = m.disk;
        }
    }
    property var wattsSeen: []
    function smooth(m) {
        const b = m.battery;
        if (b && b.watts !== null && b.watts !== undefined) {
            // the median of the last minute: one spiky reading used to set the time left
            const seen = d.wattsSeen.concat([b.watts]).slice(-30);
            d.wattsSeen = seen;
            const sorted = seen.slice().sort((x, y) => x - y);
            d.watts = sorted[Math.floor(sorted.length / 2)];
        }
        // the first sample has no time span (every app reads 0 %): shares start from the second
        if (m.cpu.busy === null || m.cpu.busy === undefined)
            return;
        const share = Object.assign({}, d.cpuShare);
        for (const g of m.groups)
            share[g.key] = (share[g.key] ?? g.cpu) * 0.95 + g.cpu * 0.05;
        d.cpuShare = share;
    }
    // the calm part: a new layout every 4 s at most, and none while the pointer is on the names
    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            d.clock = Date.now();
            if (d.raw !== null && d.raw !== d.snap && !d.frozen && Date.now() - d.snapAt >= 4000)
                d.apply();
        }
    }
    onFrozenChanged: if (!frozen && raw !== snap && Date.now() - snapAt >= 4000) apply()

    function apply() {
        const s = d.raw;
        d.snap = s;
        d.snapAt = Date.now();
        const free = s.mem.avail / s.mem.total;
        d.memAlarm = d.memAlarm ? !(s.psi.mem < 2 && free > 0.15) : (s.psi.mem >= 10 || free < 0.10);
        if (d.quit !== null)
            d.followQuit(s);
    }

    // ------------------------------------------------------------------ closing an app
    function group(key) {
        return (d.snap?.groups ?? []).find(g => g.key === key) ?? null;
    }
    // Agent sessions running inside an app's windows (Claude Code in a terminal): closing the windows
    // ends them mid-work, so Quit asks first.
    function hostedIn(g) {
        const addrs = (g?.windows ?? []).map(w => w.address);
        return (d.snap?.groups ?? []).filter(x => x.kind === "cli" && addrs.includes(x.session?.window ?? ""));
    }
    function startQuit(item, anyway) {
        const g = d.group(item.key);
        if (!g)
            return;
        const name = item.kind === "left" ? item.quitName : item.n;
        const hosted = d.hostedIn(g);
        if (hosted.length > 0 && !anyway) {
            const tool = d.toolNames[hosted[0].tool] ?? hosted[0].tool;
            d.quit = { key: item.key, name: name, item: item, phase: "confirm", at: Date.now(), mem: g.mem,
                       hosted: hosted.length === 1 ? `a ${tool} session` : `${hosted.length} ${tool} sessions` };
            return;
        }
        d.quit = { key: item.key, name: name, mem: g.mem, at: Date.now(), phase: "closing", hadWindows: g.windows.length > 0,
                   left: item.kind === "left", background: item.background ?? false };
        if (item.tray)
            d.quitViaTray(item);
        else
            d.send({ op: "quit", key: item.key });
    }
    // An app in the background with a tray icon: its own Quit entry closes it the way the app means to;
    // the menu loads over D-Bus, so wait for it, and without a Quit entry it is ended as any other app.
    function quitViaTray(item) {
        const o = trayQuitter.createObject(d, { item: item });
        if (!o)
            d.send({ op: "quit", key: item.key });
    }
    Component {
        id: trayQuitter
        Item {
            id: o
            property var item
            property bool done: false
            function settle(last) {
                if (o.done)
                    return;
                const e = (opener.children?.values ?? []).find(x => !x.isSeparator && x.enabled && /^(quit|exit)\b/i.test((x.text ?? "").replace(/[_&]/g, "")));
                if (!e && !last)
                    return;
                o.done = true;
                if (e)
                    e.triggered();
                else
                    d.send({ op: "quit", key: o.item.key });
                o.destroy();
            }
            QsMenuOpener {
                id: opener
                menu: o.item.tray.menu
                onChildrenChanged: o.settle(false)
            }
            Connections {
                target: opener.children
                function onValuesChanged() { o.settle(false); }
            }
            Timer {
                running: true
                interval: 1500
                onTriggered: o.settle(true)
            }
        }
    }
    // the tray icon the app's own processes show (sample.py asks D-Bus which process owns each icon)
    function trayOf(g) {
        return g?.tray ? (SystemTray.items.values.find(t => t.id === g.tray) ?? null) : null;
    }
    function forceQuit(key) {
        d.send({ op: "quit", key: key, force: true });
        if (d.quit && d.quit.key === key)
            d.quit = Object.assign({}, d.quit, { phase: "closing", forced: true });
    }
    function keepRunning() {
        d.quit = null;
    }
    function waitMore() {
        if (d.quit)
            d.quit = Object.assign({}, d.quit, { phase: "closing", at: Date.now() });
    }
    function followQuit(s) {
        const q = d.quit;
        if (q.phase === "confirm")
            return;
        const g = s.groups.find(x => x.key === q.key);
        const t = (Date.now() - q.at) / 1000;
        if (!g) {
            if (q.phase !== "freed")
                d.quit = Object.assign({}, q, { phase: "freed", freedAt: Date.now() });
            else if (Date.now() - q.freedAt > 6000)
                d.quit = null;
            return;
        }
        // still a window after the close: the app is asking something (unsaved work)
        if (q.phase === "closing" && q.hadWindows && g.windows.length > 0 && t > 2.5)
            d.quit = Object.assign({}, q, { phase: "asking" });
        else if (q.phase === "asking" && g.windows.length === 0)
            d.quit = Object.assign({}, q, { phase: "closing" });
        else if (q.phase === "closing" && g.windows.length === 0 && t > 6 && !q.background) {
            d.quit = Object.assign({}, q, { phase: "stuck" });
            d.stuck(q.key);
        }
    }
    // from the notch's "Details": the app Hyprland found not answering, by its process
    function stuckFromPid(pid, seconds) {
        const g = (d.raw?.groups ?? []).find(x => x.pids.includes(pid));
        if (!g)
            return "";
        if (d.snap !== d.raw)
            d.apply();
        d.quit = { key: g.key, name: d.itemOf(g).n, mem: g.mem, at: Date.now() - seconds * 1000, phase: "stuck", hadWindows: true, frozenApp: true };
        return g.key;
    }

    // ------------------------------------------------------------------ actions
    function act(item, what) {
        if (what === "quit") {
            if (item.kind === "agents")
                d.stopAgents(item);
            else
                d.startQuit(item, false);
        } else if (what === "quitAnyway") {
            d.startQuit(d.quit.item, true);
        } else if (what === "forceQuit") {
            d.forceQuit(item.key);
        } else if (what === "openTray") {
            item.tray?.activate();
        } else if (what === "keep") {
            d.keepRunning();
        } else if (what === "focus") {
            const g = d.group(item.key);
            const w = g?.windows?.[g.windows.length - 1];
            if (w)
                Quickshell.execDetached(["hyprctl", "dispatch", `hl.dsp.focus({ window = "address:${w.address}" })`]);
        } else if (what === "closeWindow") {
            Quickshell.execDetached(["hyprctl", "dispatch", `hl.dsp.window.close({ window = "address:${item.address}" })`]);
        } else if (what === "showWindow") {
            Quickshell.execDetached(["hyprctl", "dispatch", `hl.dsp.focus({ window = "address:${item.address}" })`]);
        } else if (what === "letFinish") {
            const l = Object.assign({}, d.letFinish);
            l[item.key] = true;
            d.letFinish = l;
        } else if (what === "stop") {
            d.send({ op: "interrupt", id: item.id });
        } else if (what === "praxis") {
            Quickshell.execDetached(["sh", "-c", `"\${TACIT_BIN:-$HOME/.local/bin}/tacit-app" ensure praxis >/dev/null && "\${TACIT_BIN:-$HOME/.local/bin}/tacit-app" call praxis open "$1" >/dev/null; "\${TACIT_BIN:-$HOME/.local/bin}/tacit-app" call praxis present >/dev/null; "\${TACIT_BIN:-$HOME/.local/bin}/tacit-app" focus praxis`, "sh", item.id]);
        } else if (what === "quitWindowless") {
            for (const a of d.windowless())
                d.send({ op: "quit", key: a.key });
        } else if (what === "dim") {
            Quickshell.execDetached(["brightnessctl", "set", "15%-"]);
        } else if (what === "openFolder") {
            Quickshell.execDetached(["xdg-open", item.path]);
        } else if (what === "trashOld" || what === "clearCaches") {
            d.send({ op: what });
        }
    }
    // Stop on the agents together: their processes end, which gives the memory back; each
    // conversation stays in Praxis and goes on with the next message. Terminal sessions are not touched.
    function stopAgents(item) {
        for (const s of item.sessions ?? [])
            if (s.id)
                d.send({ op: "close", id: s.id });
    }
    function windowless() {
        return d.apps().filter(a => a.kind === "app" && a.windows.length === 0 && a.id !== "activity");
    }

    // ------------------------------------------------------------------ words
    function gb(bytes) {
        if (bytes >= 0.095 * d.gib)
            return `${(bytes / d.gib).toFixed(1)} GB`;
        return `${Math.max(1, Math.round(bytes / 1048576))} MB`;
    }
    function diskGb(bytes) {
        return bytes >= 1e9 ? `${Math.round(bytes / 1e9)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`;
    }
    function pct(f) {
        return `${Math.round(f * 100)} %`;
    }
    function dur(sec) {
        const m = Math.round(sec / 60);
        if (m < 1)
            return `${Math.round(sec)} seconds`;
        if (m < 60)
            return m === 1 ? "a minute" : `${m} minutes`;
        const h = Math.floor(m / 60), r = m % 60;
        return r === 0 ? `${h} h` : `${h} h ${r} min`;
    }
    function both(names) {
        return names.length <= 1 ? (names[0] ?? "") : names.slice(0, -1).join(", ") + " and " + names[names.length - 1];
    }
    function short(text, n) {
        return text.length > n ? text.slice(0, n - 1).replace(/\s+$/, "") + "…" : text;
    }

    // ------------------------------------------------------------------ names and icons
    readonly property var appNames: ({ zen: "Zen", foot: "Terminal", chromium: "Chromium", praxis: "Praxis", graphis: "Graphis",
                                       viewer: "Viewer", settings: "Settings", opsis: "Thyris", activity: "Activity", welcome: "Welcome" })
    readonly property var toolNames: ({ claude: "Claude", codex: "Codex", opencode: "OpenCode", pi: "pi" })
    readonly property string tiles: `file://${d.home}/dev/tacit-icons/sketch/`
    // app-scope turns "google-chrome" into "google_chrome"; the desktop entry knows the real name
    function entryOf(id) {
        return DesktopEntries.heuristicLookup(id) ?? DesktopEntries.heuristicLookup(id.replace(/_/g, "-"));
    }
    function appName(id) {
        const n = d.appNames[id] ?? d.entryOf(id)?.name ?? id.replace(/[_-]+/g, " ");
        return n.charAt(0).toUpperCase() + n.slice(1);
    }
    function appIcon(id) {
        if (["praxis", "graphis", "settings", "opsis", "files"].includes(id))
            return d.tiles + `tile-${id}.png`;
        const e = d.entryOf(id);
        const p = Quickshell.iconPath(id === "viewer" ? "tacit-viewer" : (e?.icon ?? id), true);
        return p ?? "";
    }
    readonly property var syms: ({ praxis: "forum", graphis: "code", settings: "settings", opsis: "visibility", files: "folder",
                                   foot: "terminal", viewer: "image" })

    function itemOf(g) {
        return { key: g.key, kind: "app", id: g.id, n: d.appName(g.id), icon: d.appIcon(g.id), sym: d.syms[g.id] ?? "apps",
                 mem: g.mem, cpu: g.cpu, windows: g.windows, parts: g.parts, busyFor: g.busyFor, pids: g.pids, open: true,
                 background: g.background ?? false };
    }
    function apps() {
        const groups = d.snap?.groups ?? [];
        // what a terminal left running once its shell or agent was gone (test browsers, servers): a row of
        // its own, so freeing it does not mean quitting the terminal. Under 50 MB it is not worth a row.
        const left = groups.filter(g => g.kind === "left" && g.mem >= 50 * 1048576).map(g => {
            const app = d.appName(g.id);
            return { key: g.key, kind: "left", id: g.id, n: `Left running in ${app}`, quitName: `what ${app} left running`,
                     detail: g.n === 1 ? "1 program" : `${g.n} programs`, sym: "more_horiz", icon: "",
                     mem: g.mem, cpu: g.cpu, windows: [], parts: [], busyFor: g.busyFor, pids: g.pids, open: false };
        });
        return groups.filter(g => g.kind === "app" && g.id !== "activity").map(g => d.itemOf(g)).concat(left);
    }
    function sessionOf(g) {
        const s = g.session ?? {};
        const cwd = s.cwd ?? "";
        const folder = cwd === "" || cwd === d.home ? "" : cwd.split("/").pop();
        const title = (s.title ?? "").replace(/^[^A-Za-z0-9]+/, "").trim();   // Claude Code's spinner glyph
        const waiting = g.kind === "agent" && (s.pending || s.state === "waiting");
        return { key: g.key, kind: g.kind, id: s.id ?? "", tool: g.tool, mem: g.mem, cpu: g.cpu, busyFor: g.busyFor,
                 n: d.short(folder || title || "Home", 24), waiting: waiting, working: g.kind === "agent" ? s.state === "working" : g.cpu > 0.02,
                 address: s.window ?? "", praxis: g.kind === "agent", sym: "smart_toy" };
    }
    function agents() {
        const by = {};
        for (const g of (d.snap?.groups ?? []).filter(g => g.kind === "agent" || g.kind === "cli")) {
            const t = g.tool ?? "claude";
            const a = by[t] ?? (by[t] = { key: `agents:${t}`, kind: "agents", tool: t, n: d.toolNames[t] ?? t, sym: "smart_toy",
                                          mem: 0, cpu: 0, busyFor: 0, sessions: [], open: true });
            a.mem += g.mem;
            a.cpu += g.cpu;
            a.busyFor = Math.max(a.busyFor, g.busyFor);
            a.sessions.push(d.sessionOf(g));
        }
        return Object.values(by).map(a => {
            const waiting = a.sessions.filter(s => s.waiting).length;
            const working = a.sessions.filter(s => s.working).length;
            const word = waiting > 0 ? "waiting for you" : a.sessions.length > 1 ? `${a.sessions.length} sessions` : working > 0 ? "working" : "idle";
            const own = a.sessions.filter(s => s.praxis);
            return Object.assign(a, { waiting: waiting, stoppable: own.length > 0, stoppableMem: own.reduce((n, s) => n + s.mem, 0), word: word,
                                      quit: own.length > 0 ? "Stop" : "" });
        });
    }

    // ------------------------------------------------------------------ the Now page
    readonly property var now: d.snap ? d.makeNow() : null
    function makeNow() {
        const s = d.snap;
        // names and icons come from the desktop entries, which load after the first sample: read
        // them here so the page is made again when they arrive
        const entries = DesktopEntries.applications.values.length;
        const total = s.mem.total, used = total - s.mem.avail;
        const totalWord = `${Math.round(total / d.gib)} GB`;
        const usedWord = `${(used / d.gib).toFixed(1)} of ${Math.round(total / d.gib)} GB`;
        const apps = d.apps();
        const agents = d.agents();
        const tacitG = s.groups.find(g => g.kind === "tacit");
        const busy = s.cpu.busy ?? 0;
        const page = { mode: "rest", alarm: false, headline: "", cause: "", rest: "", gauge: null, verbs: [], apps: [], background: [], agents: [],
                       tacit: [], foldHot: false, cpuView: false, canSwitch: false };
        // the sentence right above says what the bar measures: no label beside it
        const gauge = { value: used / total, word: "", warn: d.memAlarm };
        const all = apps.concat(agents).sort((a, b) => b.mem - a.mem);
        const held = all.reduce((n, i) => n + i.mem, 0);
        const quitVerb = (i, primary) => i.kind === "agents"
            ? (i.stoppable ? { text: `Stop ${i.n} · ${d.gb(i.stoppableMem)}`, primary: primary, act: "quit", item: i } : { text: `Show ${i.n}`, primary: primary, act: "open", item: i })
            : i.kind === "left" ? { text: `Stop ${i.quitName} · ${d.gb(i.mem)}`, primary: primary, act: "quit", item: i }
            : { text: `Quit ${i.n} · ${d.gb(i.mem)}`, primary: primary, act: "quit", item: i };

        // the processor: one thing has had most of it for a while
        const hog = all.slice().sort((a, b) => b.cpu - a.cpu)[0];
        const cpuCause = hog && hog.cpu >= 0.5 && hog.busyFor >= 20 && busy >= 0.75 && !d.letFinish[hog.key] ? hog : null;

        let cause = [];
        let tail = false;
        const q = d.quit;
        if (q !== null && q.phase !== "stuck") {
            page.mode = q.phase;
            page.gauge = q.phase === "asking" || q.phase === "confirm" ? null : gauge;
            if (q.phase === "confirm") {
                page.headline = `${q.name} has ${q.hosted} in it.`;
                page.rest = q.hosted.startsWith("a ") ? `Quitting ${q.name} closes it too, in the middle of its work.`
                                                      : `Quitting ${q.name} closes them too, in the middle of their work.`;
                const it = { key: q.key, n: q.name };
                page.verbs = [{ text: `Keep ${q.name}`, primary: true, act: "keep", item: it }, { text: "Quit anyway", act: "quitAnyway", item: it }];
            } else if (q.phase === "closing" && q.left) {
                page.headline = `Stopping ${q.name}…`;
                page.rest = "Terminal itself and anything still in its windows keep running.";
            } else if (q.phase === "closing") {
                page.headline = `Closing ${q.name}…`;
                page.rest = q.hadWindows ? `${q.name} is saving and closing its windows.` : `${q.name} is finishing what it was doing.`;
            } else if (q.phase === "asking") {
                page.headline = `${q.name} is asking about unsaved work.`;
                page.rest = `Answer it in ${q.name}'s window, and it finishes closing.`;
                const it = { key: q.key, n: q.name };
                page.verbs = [{ text: `Show ${q.name}`, primary: true, act: "focus", item: it }, { text: `Keep ${q.name} running`, act: "keep", item: it }];
            } else {
                page.headline = `Freed ${d.gb(q.mem)}. ${d.memAlarm ? "Memory is still full." : "Memory is fine now."}`;
                page.rest = `${usedWord} in use.`;
            }
        } else if (d.memAlarm) {
            page.alarm = true;
            page.mode = "memory";
            page.headline = "Slow, because memory is full.";
            // many small things: together they hold about as much as the five biggest
            const top5 = all.slice(0, 5).reduce((n, i) => n + i.mem, 0);
            tail = all.length > 12 && held - top5 > top5 * 0.9;
            if (tail) {
                const small = all.slice(5);
                page.cause = `${small.length} small things`;
                page.rest = ` add up to ${d.gb(small.reduce((n, i) => n + i.mem, 0))}. Nothing big, but together they fill it.`;
                const idle = d.windowless();
                if (idle.length > 0)
                    page.verbs.push({ text: `Quit the ${idle.length} apps with no window · ${d.gb(idle.reduce((n, a) => n + a.mem, 0))}`, primary: true, act: "quitWindowless", item: {} });
                page.verbs.push({ text: "Show them", primary: idle.length === 0, act: "all", item: {} });
                page.foldHot = true;
            } else {
                let sum = 0;
                for (const i of all) {
                    if (cause.length >= 2 || sum >= held * 0.45)
                        break;
                    cause.push(i);
                    sum += i.mem;
                }
                page.cause = d.both(cause.map(i => i.n));
                page.rest = ` ${cause.length > 1 ? "hold" : "holds"} most of the ${d.gb(used)} in use.` + (apps.length > 8 ? ` ${apps.length} apps are open.` : "");
                page.verbs = cause.map((i, k) => quitVerb(i, k === 0));
            }
        } else if (cpuCause) {
            page.alarm = true;
            page.mode = "cpu";
            page.cpuView = true;
            cause = [cpuCause];
            page.headline = `Slow, because ${cpuCause.n} is busy.`;
            page.cause = cpuCause.n;
            page.rest = ` has had the whole processor for ${d.dur(cpuCause.busyFor)}.`;
            const first = cpuCause.kind === "agents"
                ? (cpuCause.stoppable ? { text: `Stop ${cpuCause.n}`, primary: true, act: "quit", item: cpuCause } : { text: `Show ${cpuCause.n}`, primary: true, act: "open", item: cpuCause })
                : { text: `Quit ${cpuCause.n}`, primary: true, act: "quit", item: cpuCause };
            page.verbs = [first, { text: "Let it finish", act: "letFinish", item: cpuCause }];
        } else {
            page.headline = "Nothing is slowing it down.";
            page.canSwitch = true;
            page.cpuView = d.byProcessor;
            page.rest = `${usedWord} of memory in use, processor ${busy < 0.25 ? "mostly idle" : busy < 0.6 ? "partly busy" : "busy"}.`;
            page.gauge = gauge;
        }

        // the bands
        const keyOfCause = cause.map(i => i.key);
        const val = page.cpuView ? (i => i.cpu) : (i => i.mem);
        const dress = i => Object.assign({}, i, {
            c1: page.cpuView ? d.pct(i.cpu) : d.gb(i.mem),
            detail: i.kind === "agents" ? i.word : (i.detail ?? ""),
            detailHot: i.kind === "agents" && i.waiting > 0,
            hot: page.alarm && keyOfCause.includes(i.key),
            dim: page.alarm && !keyOfCause.includes(i.key),
            fade: q !== null && q.key === i.key && (q.phase === "closing" || q.phase === "asking") ? 0.35 : 1,
            quit: i.kind === "agents" ? i.quit : i.kind === "left" ? "Stop them" : `Quit ${i.n}`
        });
        // apps with no window are listed once, in their own section (they still count above)
        const ranked = apps.sort((a, b) => val(b) - val(a)).map(dress);
        page.apps = ranked.filter(i => !i.background);
        page.background = ranked.filter(i => i.background).map(i => {
            const tray = d.trayOf(d.group(i.key));
            // Quit (or, for a Quit that is not taking effect, Quit anyway) as on any other row; Open when there is a tray icon
            const force = q !== null && q.key === i.key && q.background && q.phase === "closing" && Date.now() - q.at > 5000;
            return Object.assign({}, i, { detail: "no window open", tray: tray, fade: force ? 1 : i.fade,
                quit: force ? "" : i.quit,
                verbs: force ? [{ text: "Quit anyway", act: "forceQuit" }] : tray ? [{ text: "Open", act: "openTray" }] : [],
                verbsOnHover: !force });
        });
        page.agents = agents.sort((a, b) => val(b) - val(a)).map(dress);
        page.tacit = tacitG ? [{ key: "tacit", kind: "tacit", n: "Tacit itself", detail: "the desktop, sound, networking", sym: "deployed_code",
                                 c1: page.cpuView ? d.pct(tacitG.cpu) : d.gb(tacitG.mem), dim: page.alarm, quit: "", open: true }] : [];
        page.appsTotal = apps.length;
        page.windowless = d.windowless().length;
        return page;
    }
    function foldWord(rest, cpuView) {
        return cpuView ? d.pct(rest.reduce((n, i) => n + (i.cpu ?? 0), 0)) : d.gb(rest.reduce((n, i) => n + (i.mem ?? 0), 0));
    }

    // ------------------------------------------------------------------ an app opened
    readonly property var partWords: ({ "Web pages": "web pages", "Extensions": "extensions", "Graphics": "graphics",
                                        "Video and sound": "video and sound", "Network": "the network", "Helpers": "helpers" })
    function appPage(key) {
        const g = d.group(key);
        if (!g)
            return null;
        const i = d.itemOf(g);
        const parts = (g.parts ?? []).filter(p => p.mem > 0).map(p => ({ key: `part:${p.name}`, n: p.name === "itself" ? `${i.n} itself` : p.name,
                                     mem: p.mem, sym: p.name === "Web pages" ? "public" : p.name === "Graphics" ? "texture"
                                         : p.name === "itself" ? "deployed_code" : p.name === "Extensions" ? "extension" : "memory",
                                     c1: d.gb(p.mem), quit: "", open: false }))
                                  .sort((a, b) => b.mem - a.mem);
        const top = parts[0];
        const rest = top && top.n !== `${i.n} itself` && top.mem >= g.mem * 0.4 ? `Most of it is ${d.partWords[top.n] ?? top.n.toLowerCase()}.`
                   : g.windows.length > 1 ? `It has ${g.windows.length} windows open.`
                   : `It uses ${d.pct(g.cpu)} of the processor.`;
        const hosted = d.hostedIn(g);
        const windows = g.windows.length > 1 ? g.windows.map((w, k) => {
            const agent = hosted.find(x => x.session?.window === w.address);
            return { key: `win:${w.address}`, address: w.address, n: d.short((w.title || i.n).replace(/^[^A-Za-z0-9]+/, ""), 40),
                     detail: agent ? `${d.toolNames[agent.tool] ?? agent.tool} is running here` : "",
                     c1: "", sym: "select_window", quit: "", open: false,
                     verbs: agent ? [{ text: "Show", act: "showWindow" }] : [{ text: "Show", act: "showWindow" }, { text: "Close", act: "closeWindow" }] };
        }) : [];
        return { item: i, headline: `${i.n} holds ${d.gb(g.mem)}.`, rest: rest, windows: windows,
                 parts: parts };
    }

    // ------------------------------------------------------------------ Tacit itself opened
    function tacitPage() {
        const g = (d.snap?.groups ?? []).find(x => x.kind === "tacit");
        if (!g)
            return null;
        const syms = { "The desktop": "desktop_windows", "Sound and sharing": "volume_up", "Helpers": "handyman", "The system": "settings" };
        const parts = (g.tacitParts ?? []).slice().sort((x, y) => y.mem - x.mem)
            .map(p => ({ key: `tacit:${p.name}`, n: p.name, detail: p.what, c1: d.gb(p.mem), sym: syms[p.name] ?? "memory", quit: "", open: false }));
        return { headline: `Tacit itself holds ${d.gb(g.mem)}.`, rest: "What the computer needs to run. None of it can be quit from here.",
                 parts: parts };
    }

    // ------------------------------------------------------------------ agents opened
    function agentsPage(tool) {
        const a = d.agents().find(x => x.tool === tool);
        if (!a)
            return null;
        const sessions = a.sessions.slice().sort((x, y) => (y.waiting - x.waiting) || (y.mem - x.mem));
        const waiting = sessions.filter(s => s.waiting);
        const n = sessions.length;
        const items = sessions.map(s => Object.assign({}, s, {
            c1: d.gb(s.mem),
            detail: s.waiting ? "waiting for you" : !s.praxis ? "in Terminal" : s.working ? "working" : "idle",
            detailHot: s.waiting,
            hot: s.waiting, dim: waiting.length > 0 && !s.waiting, quit: "", open: false,
            verbs: s.praxis ? (s.waiting ? [{ text: "Open in Praxis", primary: true, act: "praxis" }, { text: "Stop", act: "stop" }]
                                         : s.working ? [{ text: "Stop", act: "stop" }] : [{ text: "Open in Praxis", act: "praxis" }])
                            : (s.address !== "" ? [{ text: "Show", act: "showWindow" }] : [])
        }));
        return { item: a, headline: n === 1 ? `One ${a.n} session is running.` : `${n} ${a.n} sessions are running.`,
                 cause: waiting.length > 0 ? waiting[0].n : "",
                 rest: waiting.length > 0 ? (waiting.length > 1 ? ` and ${waiting.length - 1} more are waiting for you.` : " is waiting for you.") : `They hold ${d.gb(a.mem)}.`,
                 sessions: items };   // the ones waiting for you lead
    }

    // ------------------------------------------------------------------ the not-answering page
    function stuckPage() {
        const q = d.quit;
        if (!q || q.phase !== "stuck")
            return null;
        const t = Math.max(0, Math.round((d.clock - q.at) / 1000));
        const grace = 10;
        const g = d.group(q.key);
        const asked = q.frozenApp ? `It stopped ${t} seconds ago.` : `Asked to close ${t} seconds ago.`;
        const rest = t < grace ? ` In ${grace - t} seconds you can close it; that loses anything it hasn't saved.`
                               : " Closing it now loses anything it hasn't saved.";
        const p = g ? d.appPage(q.key) : null;
        return { headline: `${q.name} is not answering.`, rest: asked + rest, canClose: t >= grace, key: q.key,
                 parts: (p?.parts ?? []).map((x, k) => Object.assign({}, x, { dim: true })) };
    }

    // ------------------------------------------------------------------ battery
    function batteryPage() {
        const b = d.snap?.battery;
        if (!b)
            return null;
        const w = d.watts || b.watts || 0;
        // An estimate, said as shares: the screen from its brightness (about 2.2 W at full, measured
        // 2026-09-29), the apps from their share of the processor (about 12 W with every core busy),
        // the computer itself the rest. Nothing on this machine measures power per app.
        const screen = 2.2 * (b.light ?? 0.5);
        const tacitG = (d.snap?.groups ?? []).find(x => x.kind === "tacit");
        const items = d.apps().concat(d.agents())
            .concat(tacitG ? [{ key: tacitG.key, kind: "tacit", n: "Tacit itself", sym: "deployed_code", open: true }] : []);
        const appW = items.map(i => {
            const keys = i.kind === "agents" ? i.sessions.map(s => s.key) : [i.key];
            return { i: i, w: keys.reduce((n, k) => n + (d.cpuShare[k] ?? 0), 0) * 12 };
        });
        const appsW = appW.reduce((n, x) => n + x.w, 0);
        const total = Math.max(w, screen + appsW + 0.5);
        const itself = total - screen - appsW;
        const share = x => x / total;
        const charging = b.status === "Charging";
        const full = b.status === "Full" || (b.status === "Not charging" && b.pct >= 95);
        const headline = full ? "Fully charged."
            : charging ? (b.whFull && b.wh && w > 0.5 ? `Charging. Full in about ${d.dur((b.whFull - b.wh) / w * 3600)}.` : "Charging.")
            : (b.wh && w > 0.3 ? `About ${d.dur(b.wh / w * 3600)} left.` : `${b.pct} % left.`);
        const top = [
            { key: "screen", n: "Screen", sym: "light_mode", f: share(screen), quit: "", open: false,
              verbs: (b.light ?? 0) > 0.2 ? [{ text: "Lower brightness", act: "dim" }] : [] },
            { key: "itself", n: "The computer itself", sym: "memory", f: share(itself), quit: "", open: false }
        ].concat(appW.filter(x => x.i.kind === "tacit").map(x => Object.assign({}, x.i, { f: share(x.w), quit: "" })))   // not an app
         .sort((x, y) => y.f - x.f).map(x => Object.assign(x, { c1: d.pct(x.f) }));
        const apps = appW.filter(x => x.i.kind !== "tacit" && x.w / total >= 0.005).sort((x, y) => y.w - x.w)
            .map(x => Object.assign({}, x.i, { f: share(x.w), c1: d.pct(share(x.w)), quit: x.i.kind === "app" ? `Quit ${x.i.n}` : "" }));
        return { headline: headline, pct: b.pct,
                 rest: b.ac ? `${b.pct} % charged, on the charger. Shares of what the computer uses.` : `${b.pct} % charged. Shares of what the battery is going to.`,
                 top: top, apps: apps };
    }

    // ------------------------------------------------------------------ disk
    readonly property var folderSyms: ({ Videos: "movie", Downloads: "download", Pictures: "image", Music: "music_note", Documents: "description",
                                         Desktop: "desktop_windows", Caches: "cached", "App data": "inventory_2", "Tacit and apps": "deployed_code", dev: "code" })
    function diskPage() {
        const k = d.disk;
        if (!k)
            return null;
        const used = k.total - k.free;
        const mine = k.folders.filter(f => !f.hidden && f.size > 0);
        // your own folders first; the system's share and the hidden ones after them, never the big name
        const order = k.folders.filter(f => !f.hidden).concat(k.folders.filter(f => f.hidden));
        const folders = order.filter(f => f.size >= 1e8).map((f, n) => ({
            key: `dir:${f.name}`, n: f.name, path: f.path, sym: d.folderSyms[f.name] ?? "folder", c1: d.diskGb(f.size), size: f.size,
            mine: f.path !== "" && !f.hidden,
            quit: "", open: f.path !== "" && !f.hidden }));
        const can = [];
        if (k.old.n > 0 && k.old.size >= 5e7)
            can.push({ key: "old", n: "Downloads older than a month", sym: "download", c1: d.diskGb(k.old.size), quit: "", open: false, size: k.old.size,
                       verbs: [{ text: "Move to the bin", primary: true, act: "trashOld" }] });
        if (k.caches.size >= 1e8)
            can.push({ key: "caches", n: "Download caches", sym: "cached", c1: d.diskGb(k.caches.size), quit: "", open: false, size: k.caches.size,
                       verbs: [{ text: "Clear", primary: can.length === 0, act: "clearCaches" }] });
        return { headline: `${d.diskGb(k.free)} free of ${d.diskGb(k.total)}.`,
                 rest: mine.length >= 2 ? `${mine[0].name} and ${mine[1].name} take the most of your files.` : "",
                 gauge: { value: used / k.total, word: "", warn: k.free / k.total < 0.1 },
                 folders: folders, can: can };
    }

    // the render harness (activity.qml) feeds fixture samples through here
    function feed(lines) {
        for (const l of lines)
            d.receive(l);
        if (d.raw)
            d.apply();
    }
}
