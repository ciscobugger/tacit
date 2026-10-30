import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.tacit

/**
 * The message box under the conversation, after OpenChamber's composer in the shell's tones:
 * a rounded field, attachments above it, then a row of chips (folder and agent for a new
 * session, model and effort, permission mode), the context meter and the send button, which turns
 * into stop while the agent works. Enter sends, Shift+Enter is a new line.
 *
 * A chip opens its choices in a small plain menu above the box (BoxShape), which has the keyboard
 * until it closes; the paperclip's picks, `@` files and folders and `/` commands open in the same
 * menu with the keyboard left in the text. Paste an image (Ctrl+V) or drop files anywhere on the
 * composer: they go with the message, images as images and the rest as files. A session running in
 * a terminal can be followed here but not typed into.
 */
Item {
    id: composer

    property bool working: false
    property bool locked: false        // the session belongs to a terminal
    property bool fresh: false         // a new session: the folder can still change
    property string folder: ""
    property var folders: []           // [{ path, name }] recent project folders
    property string mode: "auto"
    property string model: ""          // a model id; "" or "default" is the agent's default
    property var commands: []          // [{ name, description, hint?, aliases?, kind? }]
    property string meter: ""          // "42% of context used · $0.31"
    property int meterPct: 0           // how full the context is, when the window is known
    // the session's agent, and what the host says of each (Host.agents); a fresh session can change it
    property string agent: "claude"
    property var agents: ({})
    readonly property var agentLabels: ({ claude: "Claude", codex: "Codex", pi: "pi", opencode: "opencode" })
    readonly property string agentLabel: composer.agentLabels[composer.agent] ?? composer.agent
    // why an agent cannot start a session here, or "" when it can (signedIn null: not known)
    // a folder as the rail names it: the home folder is Home, any other its own name
    function placeWord(p) {
        if (!p || p === Quickshell.env("HOME")) return "Home";
        return p.split("/").filter(s => s.length).pop() || "/";
    }
    function agentBlock(tool) {
        const a = composer.agents[tool];
        if (!a) return tool === "claude" ? "" : "Needs the background service restarted";   // a host older than protocol 5
        if (!a.installed) return a.reason || "Not installed";
        return a.signedIn === false ? (a.reason || "Not signed in") : "";
    }
    // accounts, model lists and levels (AccountsModel); with a host that keeps none it is unavailable
    property var accounts: null
    property var features: []          // the hello's features
    property string account: ""        // the chosen account; "" is the agent's default one
    property string effort: ""         // the chosen level; "" until one is picked
    property string reportedEffort: "" // the level the running session reports
    property var recent: []            // the models lately picked for this agent, newest first
    property string keepFolder: ""     // the folder "Use for new sessions in" keeps the run for
    property var modesAllowed: null    // the agent's modes (caps.modes); null offers the four that need nothing from the host
    property color ground: ColorUtils.mix(Appearance.m3colors.m3surfaceContainerLow, Appearance.m3colors.m3primaryContainer, 0.8)
    readonly property bool hasCatalog: composer.features.includes("catalog")
    readonly property bool hasAccounts: !!composer.accounts?.available
    readonly property string acctId: composer.account || (composer.hasAccounts ? composer.accounts.defaultAccount(composer.agent)?.id ?? "" : "")
    property var attachments: []       // files to send: images go as images, the rest as files
    // the conversation's send: false when the message could not go out (no host, a start refused),
    // and then nothing is cleared — a message typed into a dead socket used to vanish
    property var sendFn: null
    // asking aside: the box sends a side question instead of a message (Conversation's AsideCard)
    property bool aside: false
    property bool canAside: false
    signal asideAsked(string question)
    // Flow's dictation, when flowd runs: the mic taps its shortcut (as the Copilot key does), and
    // Flow types what you say into this box
    property bool canDictate: false
    Process {
        running: true
        command: ["bash", "-c", "[ -S \"$XDG_RUNTIME_DIR/flow.sock\" ] && echo yes"]
        stdout: StdioCollector { onStreamFinished: composer.canDictate = this.text.trim() === "yes" }
    }
    function dictate() {
        input.forceActiveFocus();
        Quickshell.execDetached(["hyprctl", "dispatch", 'hl.dsp.global("quickshell:flowHold")']);
    }
    signal stop()
    signal folderPicked(string path)
    signal agentPicked(string agent, string account, bool keep)
    signal modelPicked(string model, string effort, bool keep)
    signal effortPicked(string level, bool keep)
    signal modePicked(string mode, bool keep)
    signal prefsRequested()
    signal settingsRequested(string anchor)

    readonly property var modes: [
        { id: "auto", label: "Auto", glyph: "auto_mode", about: "decides for itself what needs your OK" },
        { id: "manual", label: "Ask first", glyph: "back_hand", about: "asks before every command and edit" },
        { id: "acceptEdits", label: "Edits ok", glyph: "edit_note", about: "edits files freely, asks before commands" },
        { id: "plan", label: "Plan", glyph: "map", about: "reads and plans, changes nothing" },
        // Claude Code's bypassPermissions: offered only when the agent lists it (the host starts Claude able to take it)
        { id: "bypassPermissions", label: "Full access", glyph: "lock-open", about: "runs every command and edit without asking; nothing is checked" }
    ]
    // a host that reads no model lists: Claude Code's own four names
    readonly property var oldModels: [
        { id: "", label: "Default" },
        { id: "opus", label: "Opus" },
        { id: "sonnet", label: "Sonnet" },
        { id: "haiku", label: "Haiku" }
    ]

    // ── the run chip: model label · effort word ─────────────────────────────
    readonly property var effortWords: ({ low: "low", medium: "medium", high: "high", xhigh: "extra high", max: "max",
                                          ultra: "ultra", off: "off", minimal: "minimal" })
    // the copy AccountsModel holds; asked for outside the binding (asking writes the request tag)
    readonly property string catalogKey: composer.hasCatalog && composer.hasAccounts ? composer.accounts.catalogKey(composer.agent, composer.acctId, composer.folder) : ""
    readonly property var catalog: composer.catalogKey ? composer.accounts.catalogs[composer.catalogKey] ?? null : null
    onCatalogKeyChanged: if (composer.catalogKey) Qt.callLater(() => composer.accounts.catalog(composer.agent, composer.account, composer.folder))
    Component.onCompleted: if (composer.catalogKey) composer.accounts.catalog(composer.agent, composer.account, composer.folder)
    // the catalog as the menu shows it: the default folded into its model, variants in words
    readonly property var shapedModels: composer.hasCatalog && composer.hasAccounts ? composer.accounts.shapeModels(composer.catalog?.models ?? []) : []
    readonly property var runModel: composer.hasAccounts ? composer.accounts.modelRowOf(composer.shapedModels, composer.model) : null
    // the catalog's label (the default: the model it runs), else the name made from the id; never a family name
    readonly property string runLabel: {
        if (!composer.hasCatalog) return composer.oldModels.find(m => m.id === composer.model)?.label ?? composer.model;
        const m = composer.runModel;
        if (m) return m.plainDefault ? "Default" : m.label;
        return composer.model && composer.model !== "default" ? (composer.accounts?.plainId(composer.model) ?? composer.model) : "Default";
    }
    // the level picked, else the one the session reports, else the model's own
    readonly property string runLevel: {
        const l = composer.runModel?.efforts ?? [];
        return [composer.effort, composer.reportedEffort, composer.runModel?.defaultEffort].find(x => x && l.includes(x)) ?? "";
    }
    // "high effort"; none set, the model's own ("default effort"); a model with no levels says nothing
    readonly property string runEffort: {
        const e = composer.runLevel;
        if (!e) return (composer.runModel?.efforts ?? []).length ? "default effort" : "";
        return e === "off" || e === "none" ? "effort off" : `${composer.effortWords[e] ?? e} effort`;
    }
    // the level last asked for: a model that offers it again gets it back (Haiku has none, Opus returns to it)
    property string effortWish: ""
    onAgentChanged: composer.effortWish = ""

    // ── what the chosen account needs before it can run ─────────────────────
    readonly property string step: {
        if (!composer.hasAccounts) return "";
        const s = composer.accounts.stepOf(composer.agent, composer.acctId);
        return s === "signedOut" && (composer.agent === "pi" || composer.agent === "opencode") ? "noProvider" : s;
    }
    readonly property bool needsStep: composer.hasAccounts && (composer.accounts.stepWord(composer.step) !== "" || composer.step === "locked")
    // said in the chip row for a fresh session; a started one says it when a send needs it, or
    // when its process ends for want of a sign-in (Conversation)
    readonly property bool showStep: composer.needsStep && composer.fresh
    readonly property string stepLine: {
        const n = composer.agentLabel;
        switch (composer.step) {
        case "signedOut": return `${n} isn't signed in`;
        case "expired": return `Your ${n} sign-in has expired`;
        case "noProvider": return `${n} needs a provider`;
        case "notInstalled": return `${n} isn't installed`;
        case "needsNode": return `${n} needs one more install first`;
        case "locked": return "The keyring is locked";
        case "noKey": return `${n} has no key`;
        case "keyRefused": return `${n}'s key was refused`;
        }
        return composer.hasAccounts ? composer.accounts.factsOf(composer.agent, composer.acctId) : "";
    }
    readonly property var agentAccounts: composer.hasAccounts ? composer.accounts.accountsOf(composer.agent) : []

    // ── the menus ───────────────────────────────────────────────────────────
    // A chip's menu (agent | run | mode | folder) has the keyboard while it is open; the
    // paperclip's, `@` and `/` lists (`suggest`) leave it in the text. One opening closes the other.
    property string menu: ""
    property string menuShown: ""      // what the menu draws: kept while it fades out
    property bool menuSetup: false     // the agent menu opened for the first run
    readonly property bool menuOpen: composer.menu !== "" || composer.suggest.items.length > 0
    readonly property real menuMaxHeight: Math.min(520, (composer.Window.window?.height ?? 800) * 0.6) - 8
    function openMenu(kind, setup) {
        if (composer.locked) return;
        // a started session keeps its agent: its menu only holds the step its account needs
        if (kind === "agent" && !composer.fresh && !composer.needsStep) return;
        if (kind === "run" && !composer.hasCatalog && composer.agent !== "claude") return;   // no lists: only Claude has names
        composer.suggest = { kind: "", items: [], start: 0 };
        composer.menuSetup = !!setup;
        composer.menu = kind;
        composer.menuShown = kind;
        Qt.callLater(() => {
            const c = menuContent.item;
            if (!c || composer.menu !== kind) return;
            if (c.reset) c.reset();
            if (kind === "agent" && composer.needsStep && c.openStep) c.openStep(composer.agent, composer.acctId);
            c.forceActiveFocus();
        });
    }
    // the text has the keyboard again, its cursor where it was
    function closeMenu() {
        if (composer.menu === "") return;
        composer.menu = "";
        input.forceActiveFocus();
    }
    function toggleMenu(kind) { composer.menu === kind ? composer.closeMenu() : composer.openMenu(kind); }
    function dismiss() {
        if (composer.menu !== "") composer.closeMenu();
        else composer.suggest = { kind: "", items: [], start: 0 };
    }
    onFreshChanged: if (!composer.fresh && (composer.menu === "agent" || composer.menu === "folder")) composer.closeMenu()
    onLockedChanged: if (composer.locked) composer.dismiss()
    function focusInput() { input.forceActiveFocus(); }
    function setText(t) { input.text = t; input.cursorPosition = t.length; input.forceActiveFocus(); }
    readonly property string text: input.text
    // a session's own draft, put back when it is opened again (no focus taken: opening a session is not typing)
    function setDraft(t, files) { input.text = t; input.cursorPosition = t.length; composer.attachments = files; }
    function isImage(p) { return /\.(png|jpe?g|gif|webp)$/i.test(p); }
    function submit() {
        if (composer.aside) {
            const q = input.text.trim();
            if (!q.length) return;
            composer.asideAsked(q);
            input.text = "";
            return;
        }
        const t = input.text.trim();
        if ((!t.length && !composer.attachments.length) || composer.locked) return;
        if (t === "/model" || t === "/effort") {
            input.text = "";
            composer.openMenu("run");
            return;
        }
        // an account that needs a step first: its step opens, and the message stays
        if (composer.needsStep) {
            composer.openMenu("agent");
            return;
        }
        const files = composer.attachments.filter(p => !composer.isImage(p));
        const text = t.length ? t : (files.length ? "Look at these." : "Look at this.");
        if (!composer.sendFn || !composer.sendFn(text, composer.attachments.filter(p => composer.isImage(p)), files)) return;
        input.text = "";
        composer.attachments = [];
        composer.suggest = { kind: "", items: [], start: 0 };
    }
    function attach(path) {
        if (!composer.attachments.includes(path)) composer.attachments = composer.attachments.concat([path]);
    }
    // files chosen elsewhere (Files' pick, a drop): they go with the next message
    function take(paths) {
        for (const p of paths) composer.attach(p);
        input.forceActiveFocus();
    }
    function insertAtCursor(s) {
        const c = input.cursorPosition;
        input.text = input.text.substring(0, c) + s + input.text.substring(c);
        input.cursorPosition = c + s.length;
    }

    // ── what you probably want to attach ────────────────────────────────────
    // The desktop's own record of where files came from (Files' origins index, read only): the
    // latest downloads, screenshots and phone files, phrased the way Files phrases them.
    FileView {
        id: originsFile
        path: `${Directories.state}/user/files/origins.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property var recentFiles: {
        let idx = {};
        try { const d = JSON.parse(originsFile.text() || "{}"); idx = d.index ?? d; } catch (e) {}
        const app = a => { const x = (a ?? "").toLowerCase(); return x.startsWith("zen") ? "zen" : x.split(".").pop(); };
        return Object.keys(idx).filter(p => ["download", "screenshot", "phone"].includes(idx[p]?.kind))
            .sort((a, b) => (idx[b].at ?? 0) - (idx[a].at ?? 0)).slice(0, 8)
            .map(p => {
                const o = idx[p];
                const line = o.kind === "screenshot" ? Voice.facts([o.app ? `screenshot of ${app(o.app)}` : "screenshot", o.title])
                    : o.kind === "phone" ? `from ${o.device || "your phone"}` : Voice.facts([o.app ? `from ${app(o.app)}` : "", o.title]);
                return { path: p, kind: o.kind, line: line, at: o.at ?? 0 };
            });
    }
    property bool clipImage: false
    Process {
        id: clipCheck
        command: ["bash", "-c", "wl-paste --list-types 2>/dev/null | grep -q '^image/' && echo yes"]
        stdout: StdioCollector {
            onStreamFinished: {
                const had = composer.clipImage;
                composer.clipImage = this.text.trim() === "yes";
                if (composer.clipImage !== had && composer.suggest.kind === "attach") composer.patchPasteRow();
            }
        }
    }
    readonly property var pasteRow: ({ label: "Image on the clipboard", after: "paste it here", act: "paste" })
    // The probe answers after the list is already open. Only the paste row goes in or out, and what
    // is picked stays on the same entry: rebuilding the list moved every row under the pointer.
    function patchPasteRow() {
        const chosen = composer.suggest.items[composer.pick];
        const rest = composer.suggest.items.filter(i => i.act !== "paste");
        const rows = composer.clipImage ? [composer.pasteRow].concat(rest) : rest;
        composer.suggest = { kind: "attach", start: composer.suggest.start, items: rows };
        composer.pick = Math.max(0, rows.indexOf(chosen));
    }
    function recentRows(n) {
        return composer.recentFiles.slice(0, n).map(r => ({
            label: r.path.split("/").pop(), after: Voice.facts([r.line, Voice.age(r.at)]), act: "attach", path: r.path }));
    }
    // the paperclip: clipboard image, recent files, then Files for anything else
    function openAttach() {
        const rows = [];
        if (composer.clipImage) rows.push(composer.pasteRow);
        if (composer.menu !== "") composer.closeMenu();
        composer.suggest = { kind: "attach", start: -1, items: rows.concat(composer.recentRows(6)).concat([
            { label: "Browse in Files…", after: composer.folder.startsWith("/") ? composer.folder.split("/").pop() || "/" : "home", act: "browse" }]) };
        composer.pick = 0;
        input.forceActiveFocus();
    }
    function browse() {
        Quickshell.execDetached(["qs", "-p", Directories.shellFile, "ipc", "call", "files", "pick",
            composer.folder.startsWith("/") ? composer.folder : Quickshell.env("HOME"),
            FileUtils.trimFileProtocol(Quickshell.shellPath("claude.qml")), "claudeapp", "Attach to Claude"]);
    }

    // ── @ files and / commands ─────────────────────────────────────────────
    property var files: []
    property var dirs: []              // every folder the files are in, "a/" and "a/b/"
    property string filesFor: ""
    property double filesAt: 0
    property var suggest: ({ kind: "", items: [], start: 0 })
    property int pick: 0
    property var shown: []            // what the list draws: kept while it fades out
    property string shownKind: ""
    onSuggestChanged: {
        if (composer.suggest.items.length) {
            if (composer.menu !== "") composer.menu = "";
            composer.shown = composer.suggest.items;
            composer.shownKind = composer.suggest.kind;
            composer.menuShown = "";
            clearShown.stop();
        } else if (composer.shown.length) {
            clearShown.restart();
        }
    }
    Timer { id: clearShown; interval: 160; onTriggered: { composer.shown = []; composer.shownKind = ""; } }
    Process {
        id: listFiles
        command: ["bash", "-c", "cd \"$1\" 2>/dev/null && { git ls-files -co --exclude-standard 2>/dev/null || fd -t f --max-depth 6 . ; } | head -20000", "_", composer.filesFor]
        stdout: StdioCollector {
            onStreamFinished: {
                composer.files = this.text.split("\n").filter(l => l.length);
                const seen = {};
                for (const f of composer.files)
                    for (let i = f.indexOf("/"); i > 0; i = f.indexOf("/", i + 1)) seen[f.substring(0, i + 1)] = true;
                composer.dirs = Object.keys(seen).sort();
                composer.filesAt = Date.now();
                composer.refreshSuggest();
            }
        }
    }
    function score(path, q) {   // a subsequence match, scored for runs and a hit in the name
        const p = path.toLowerCase();
        let i = 0, s = 0, run = 0, last = -2;
        for (const ch of q) {
            const at = p.indexOf(ch, i);
            if (at < 0) return -1;
            run = at === last + 1 ? run + 1 : 0;
            s += 1 + run * 2;
            last = at; i = at + 1;
        }
        const name = p.substring(p.lastIndexOf("/") + 1);
        return s + (name.includes(q) ? 10 : 0) - p.length * 0.01;
    }
    // `@path`, or `@"path with spaces"` (Claude Code's quoted form); a folder keeps the list open on it
    function mention(path, open) {
        return /\s/.test(path) ? `@"${path}` + (open ? "" : `" `) : `@${path}` + (open ? "" : " ");
    }
    function refreshSuggest() {
        const before = input.text.substring(0, input.cursorPosition);
        let m = /(^|\s)@(?:"([^"]*)|([^\s@"]*))$/.exec(before);
        if (m) {
            // read again when the folder changed, or when the list opens on a listing over 10 s old
            if (composer.folder.startsWith("/") && !listFiles.running
                    && (composer.filesFor !== composer.folder || (composer.suggest.kind !== "file" && Date.now() - composer.filesAt > 10000))) {
                composer.filesFor = composer.folder;
                listFiles.running = true;
            }
            const typed = m[2] ?? m[3] ?? "";
            const q = typed.toLowerCase();
            const cut = q.lastIndexOf("/");
            const base = q.substring(0, cut + 1), rest = q.substring(cut + 1);
            const name = p => { const t = p.replace(/\/$/, ""); return t.substring(t.lastIndexOf("/") + 1); };
            const parent = p => { const t = p.replace(/\/$/, ""); return t.includes("/") ? t.substring(0, t.lastIndexOf("/")) : ""; };
            // inside a folder: its own folders and files, matched on what follows it
            const fileHits = [], dirHits = [];
            for (const f of composer.files) {
                if (base && !f.toLowerCase().startsWith(base)) continue;
                const sc = rest.length ? composer.score(base ? f.substring(base.length) : f, rest) : 0;
                if (sc >= 0) fileHits.push({ p: f, sc: sc });
                if (!rest.length && fileHits.length > 40) break;
            }
            for (const d of composer.dirs) {
                const low = d.toLowerCase();
                if (base ? !low.startsWith(base) || low.length === base.length || low.substring(base.length).indexOf("/") !== low.length - base.length - 1
                         : (!rest.length && d.indexOf("/") !== d.length - 1)) continue;
                const sc = rest.length ? composer.score(name(d), rest) : 0;
                if (sc >= 0) dirHits.push({ p: d, sc: sc });
            }
            fileHits.sort((a, b) => b.sc - a.sc);
            dirHits.sort((a, b) => b.sc - a.sc);
            const folders = dirHits.slice(0, 3).map(h => ({ label: name(h.p) + "/", after: parent(h.p), middle: true, insert: composer.mention(h.p, true), keep: true }));
            const project = fileHits.slice(0, 8).map(h => ({ label: name(h.p), after: parent(h.p), middle: true, insert: composer.mention(h.p, false) }));
            const recent = base ? [] : q.length ? composer.recentRows(8).filter(r => composer.score(r.label, q) >= 0).slice(0, 3) : composer.recentRows(3);
            composer.suggest = { kind: "file", start: input.cursorPosition - typed.length - (m[2] !== undefined ? 2 : 1), items: recent.concat(folders, project).slice(0, 9) };
            composer.pick = 0;
            return;
        }
        m = /^\/([\w:.-]*)$/.exec(before);
        if (m) {
            // name prefix, then an alias's prefix, then the name holding it, then a word of what it does
            const q = m[1].toLowerCase();
            const rank = c => {
                const n = c.name.toLowerCase();
                if (n.startsWith(q)) return [0, ""];
                const al = (c.aliases ?? []).find(a => a.toLowerCase().startsWith(q));
                if (al) return [1, al];
                if (n.includes(q)) return [2, ""];
                if ((c.description ?? "").toLowerCase().split(/\W+/).some(w => w.length && w.startsWith(q))) return [3, ""];
                return null;
            };
            const hits = [];
            composer.commands.forEach((c, i) => { const r = rank(c); if (r) hits.push({ c: c, r: r, i: i }); });
            hits.sort((a, b) => a.r[0] - b.r[0] || a.i - b.i);
            composer.suggest = { kind: "command", start: 0,
                items: hits.map(h => ({ label: `/${h.c.name}`, after: [h.c.hint ?? "", h.r[1] ? `also /${h.r[1]}` : "", h.c.description ?? ""].filter(x => x).join("  "),
                                        insert: `/${h.c.name} `, cmd: h.c.name })) };
            composer.pick = 0;
            return;
        }
        composer.suggest = { kind: "", items: [], start: 0 };
    }
    function accept(i) {
        const it = composer.suggest.items[i];
        if (!it) return;
        if (it.act) {   // the paperclip's rows, and recent files offered under @
            if (composer.suggest.start >= 0) {
                const c = input.cursorPosition;
                input.text = input.text.substring(0, composer.suggest.start) + input.text.substring(c);
                input.cursorPosition = composer.suggest.start;
            }
            composer.suggest = { kind: "", items: [], start: 0 };
            if (it.act === "attach") composer.attach(it.path);
            else if (it.act === "paste") pasteImage.running = true;
            else if (it.act === "browse") composer.browse();
            return;
        }
        // /model and /effort are the run menu, not words for the agent
        if (it.cmd === "model" || it.cmd === "effort") {
            input.text = input.text.substring(input.cursorPosition);
            composer.openMenu("run");
            return;
        }
        const c = input.cursorPosition;
        input.text = input.text.substring(0, composer.suggest.start) + it.insert + input.text.substring(c);
        input.cursorPosition = composer.suggest.start + it.insert.length;
        // a folder: the list stays open on what is in it
        if (it.keep) composer.refreshSuggest();
        else composer.suggest = { kind: "", items: [], start: 0 };
    }

    // Ctrl+V with an image on the clipboard saves it and attaches it; anything else pastes as text
    Process {
        id: pasteImage
        // a picture is attached only when there is no text beside it: office apps copy cells as both
        // text and a picture of them, and the table should paste as text
        command: ["bash", "-c", "t=$(wl-paste --list-types 2>/dev/null); if printf '%s\\n' \"$t\" | grep -q '^image/' && ! printf '%s\\n' \"$t\" | grep -q '^text/plain'; then d=\"$HOME/.cache/agent-host/paste\"; mkdir -p \"$d\"; f=\"$d/$(date +%s%N).png\"; wl-paste --type image/png > \"$f\" && echo \"$f\"; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = this.text.trim();
                if (p.length) composer.attach(p);
                else input.paste();
            }
        }
    }

    implicitHeight: box.height + 16

    // a drop anywhere on the composer, its menu included, goes with the message
    readonly property bool dragging: drop.containsDrag || slabDrop.containsDrag
    function dropped(d) {
        for (const u of d.urls ?? []) {
            // Files does not percent-encode its paths: a literal % in a name throws
            const raw = u.toString().replace(/^file:\/\//, "");
            let path = raw;
            try { path = decodeURIComponent(raw); } catch (e) {}
            composer.attach(path);
        }
        input.forceActiveFocus();
    }
    DropArea {
        id: drop
        anchors.fill: parent
        enabled: !composer.locked
        onDropped: d => composer.dropped(d)
    }

    Rectangle {
        id: box
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 16 }
        // grows with its parts, each easing on its own (so no Behavior on the box itself)
        height: trayArea.height + Math.min(flick.contentHeight, 180) + 20 + (composer.locked ? 4 : chips.height + 10)
        radius: Appearance.rounding.card
        // on the window's own frost with a hairline, as Praxis's side panel stands: every ink hits its measured
        // contrast there (main 92, secondary 75, meta 60). A light well greyed the warm frost and dropped the secondary
        // and meta text to 69-73 and 54-58 (APCA, 2026-10-11); the near-solid box read as another material
        color: "transparent"
        border.width: 1
        border.color: composer.dragging || input.activeFocus ? ColorUtils.mix(Appearance.colors.colInkDivider, Appearance.colors.colInkFaint, 0.3)
            : boxHover.hovered ? ColorUtils.mix(Appearance.colors.colInkDivider, Appearance.colors.colInkFaint, 0.12) : Appearance.colors.colInkDivider
        Behavior on border.color { ColorAnimation { duration: 160 } }
        HoverHandler { id: boxHover }

        // attached files, each with a remove button; the tray eases open and shut
        Item {
            id: trayArea
            anchors { left: parent.left; right: parent.right; top: parent.top; topMargin: 6 }
            height: composer.attachments.length ? 64 : 0
            clip: true
            Behavior on height {
                NumberAnimation {
                    duration: Appearance.animation.elementResize.duration
                    easing.type: Appearance.animation.elementResize.type
                    easing.bezierCurve: Appearance.animation.elementResize.bezierCurve
                }
            }
        }
        Row {
            id: tray
            visible: trayArea.height > 0.5
            opacity: Math.min(1, trayArea.height / 48)
            anchors { left: parent.left; top: trayArea.top; leftMargin: 12; topMargin: 4 }
            spacing: Appearance.spacing.small
            height: 56
            Repeater {
                model: composer.attachments
                delegate: Rectangle {
                    id: att
                    required property string modelData
                    required property int index
                    readonly property bool picture: composer.isImage(att.modelData)
                    width: att.picture ? 56 : Math.min(220, fileRow.implicitWidth + 40)
                    height: 56
                    radius: Appearance.rounding.chip
                    clip: true
                    color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                    Image { visible: att.picture; anchors.fill: parent; source: att.picture ? `file://${att.modelData}` : ""; fillMode: Image.PreserveAspectCrop; sourceSize.height: 112; asynchronous: true }
                    // any other file: what kind, and its name
                    Row {
                        id: fileRow
                        visible: !att.picture
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        spacing: Appearance.spacing.small
                        MaterialSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            text: /\.pdf$/i.test(att.modelData) ? "picture_as_pdf" : "description"
                            iconSize: 22
                            color: Appearance.colors.colInkSecondary
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, 150)
                            text: att.modelData.split("/").pop()
                            elide: Text.ElideMiddle
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colInkMain
                        }
                    }
                    Rectangle {
                        anchors { right: parent.right; top: parent.top; margins: 3 }
                        width: 18; height: 18; radius: 9
                        color: ColorUtils.transparentize("black", 0.4)
                        MaterialSymbol { anchors.centerIn: parent; text: "close"; iconSize: Appearance.icon.tiny; color: "white" }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: composer.attachments = composer.attachments.filter((_, j) => j !== index) }
                    }
                }
            }
        }

        Flickable {
            id: flick
            anchors { left: parent.left; right: parent.right; top: trayArea.bottom; leftMargin: 16; rightMargin: 16; topMargin: 6 }
            height: Math.min(contentHeight, 180)
            contentHeight: input.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            TextArea.flickable: TextArea {
                // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)
                font.hintingPreference: Font.PreferNoHinting
                id: input
                enabled: !composer.locked
                wrapMode: TextEdit.Wrap
                font.family: Appearance.font.family.main
                font.pixelSize: Appearance.font.pixelSize.normal
                font.variableAxes: Appearance.font.variableAxes.main
                color: Appearance.colors.colInkMain
                selectionColor: Appearance.colors.colSecondaryContainer
                selectedTextColor: Appearance.m3colors.m3onSecondaryContainer
                placeholderText: composer.aside ? "Ask aside: Claude answers from where it is, without stopping or adding to the conversation"
                    : composer.locked ? "Running in a terminal. Follow it here; exit it there to continue it here."
                    : composer.fresh ? `Start ${/^[aeiou]/i.test(composer.agentLabel) ? "an" : "a"} ${composer.agentLabel} session in ${composer.placeWord(composer.folder)}` : (composer.working ? `Message ${composer.agentLabel} · sending stops what it is doing` : `Message ${composer.agentLabel} · @ for files, / for commands`)
                placeholderTextColor: Appearance.colors.colInkSecondary
                padding: 0
                background: null
                onTextChanged: composer.refreshSuggest()
                // a click into the text closes a chip's menu
                onActiveFocusChanged: if (input.activeFocus && composer.menu !== "") composer.menu = ""
                onCursorPositionChanged: if (composer.suggest.items.length) composer.refreshSuggest()
                Keys.onPressed: e => {
                    const open = composer.suggest.items.length > 0;
                    if (open && (e.key === Qt.Key_Down || e.key === Qt.Key_Up)) {
                        composer.pick = (composer.pick + (e.key === Qt.Key_Down ? 1 : -1) + composer.suggest.items.length) % composer.suggest.items.length;
                        e.accepted = true;
                    } else if (open && (e.key === Qt.Key_Tab || ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)))) {
                        composer.accept(composer.pick);
                        e.accepted = true;
                    } else if (open && e.key === Qt.Key_Escape) {
                        composer.suggest = { kind: "", items: [], start: 0 };
                        e.accepted = true;
                    } else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                        composer.submit();
                        e.accepted = true;
                    } else if (e.key === Qt.Key_V && (e.modifiers === Qt.ControlModifier || e.modifiers === (Qt.ControlModifier | Qt.ShiftModifier))) {
                        pasteImage.running = true;
                        e.accepted = true;
                    } else if (e.key === Qt.Key_Escape && composer.aside) {
                        composer.aside = false;
                        e.accepted = true;
                    } else if (e.key === Qt.Key_Escape && composer.working) {
                        composer.stop();
                        e.accepted = true;
                    }
                }
            }
        }

        RowLayout {
            id: chips
            visible: !composer.locked
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10; rightMargin: 10; bottomMargin: 8 }
            height: 30
            spacing: Appearance.spacing.verysmall
            // the row's width with every label and the meter in full (a chip's `natural` does not follow the layout):
            // narrower, the meter says its percentage alone; narrower still, the model chip its model alone
            readonly property real naturalWidth: {
                let w = 0, n = 0;
                for (const c of chips.children) {
                    if (!c.visible) continue;
                    n++;
                    w += c === meterLabel ? meterFull.advanceWidth : (c.natural ?? (c.Layout.preferredWidth > 0 ? c.Layout.preferredWidth : c.implicitWidth));
                }
                return w + chips.spacing * Math.max(0, n - 1);
            }
            TextMetrics { id: meterFull; font: meterLabel.font; text: composer.meter }
            TextMetrics { id: meterShort; font: meterLabel.font; text: composer.meterPct > 0 ? `${composer.meterPct}%` : composer.meter }

            Chip {
                id: folderChip
                visible: composer.fresh
                glyph: "folder"
                label: composer.placeWord(composer.folder)
                tip: "The folder it works in"
                on: composer.menu === "folder"
                onClicked: composer.toggleMenu("folder")
            }
            Chip {
                id: agentChip
                visible: composer.fresh
                shrink: true
                dot: composer.needsStep
                // the account only when the agent has two or more
                label: composer.hasAccounts ? composer.agentLabel + (composer.agentAccounts.length > 1 ? ` · ${composer.accounts.account(composer.acctId)?.label ?? ""}` : "")
                    : composer.agentBlock(composer.agent) ? `${composer.agentLabel} · ${composer.agentBlock(composer.agent)}` : composer.agentLabel
                tip: composer.needsStep ? `${composer.agentLabel} needs a step before it can run` : "The agent, and its account"
                on: composer.menu === "agent"
                onClicked: composer.toggleMenu("agent")
            }
            Chip {
                id: runChip
                visible: composer.hasCatalog || composer.agent === "claude"   // with no lists, Claude's four names
                glyph: "neurology"
                label: composer.runEffort ? `${composer.runLabel}, ${composer.runEffort}` : composer.runLabel
                tip: "Model and effort (Alt+P)"
                shrink: true
                compact: composer.runLabel
                useCompact: chips.width < chips.naturalWidth - (meterLabel.visible ? meterFull.advanceWidth - meterShort.advanceWidth : 0)
                on: composer.menu === "run"
                onClicked: composer.toggleMenu("run")
            }
            Chip {
                id: modeChip
                glyph: (composer.modes.find(m => m.id === composer.mode) ?? composer.modes[0]).glyph
                label: (composer.modes.find(m => m.id === composer.mode) ?? composer.modes[0]).label
                readonly property var m: composer.modes.find(x => x.id === composer.mode) ?? composer.modes[0]
                tip: `${m.label}: ${m.about}`
                on: composer.menu === "mode"
                onClicked: composer.toggleMenu("mode")
            }
            Chip {
                id: attachChip
                glyph: "attach_file"
                label: "Attach"
                tip: "Attach files or pictures"
                on: composer.suggest.kind === "attach"
                // your Files window, in pick mode; the pick comes back through claude.qml's `picked`
                onClicked: { clipCheck.running = true; composer.suggest.kind === "attach" ? composer.suggest = { kind: "", items: [], start: 0 } : composer.openAttach(); }
            }
            Chip {
                visible: composer.canAside
                glyph: "chat"
                label: "Aside"
                tip: "Ask a side question without stopping the work"
                on: composer.aside
                onClicked: { composer.aside = !composer.aside; input.forceActiveFocus(); }
            }
            Chip {
                visible: composer.canDictate && !composer.locked
                glyph: "mic"
                label: ""
                tip: "Dictate"
                onClicked: composer.dictate()
            }
            Item { Layout.fillWidth: true }
            // the meter's place: what the chosen account needs (elided when the row is full), and
            // the step that does it
            StyledText {
                id: stepReason
                visible: false   // said in full above the box (Conversation's step line)
                opacity: width < 30 ? 0 : 1   // a full row keeps the step word only
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                Layout.maximumWidth: implicitWidth
                text: composer.stepLine
                elide: Text.ElideRight
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colInkSecondary
            }
            Row {
                visible: false
                spacing: 6
                StyledText {
                    visible: stepReason.opacity > 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: "·"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colInkMeta
                }
                StyledText {
                    id: stepAction
                    anchors.verticalCenter: parent.verticalCenter
                    text: composer.hasAccounts ? composer.accounts.stepWord(composer.step) : ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Medium
                    color: Appearance.colors.colPrimary
                    MouseArea {
                        anchors { fill: parent; margins: -4 }
                        cursorShape: Qt.PointingHandCursor
                        onClicked: composer.openMenu("agent")
                    }
                }
            }
            StyledText {
                id: meterLabel
                visible: composer.meter.length > 0 && !composer.showStep
                // a row with no room for it all says the percentage alone, before the model chip loses its name
                text: chips.width < chips.naturalWidth && composer.meterPct > 0 ? `${composer.meterPct}%` : composer.meter
                font.family: Appearance.font.family.numbers
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: composer.meterPct >= 80 ? Appearance.colors.colPrimary : Appearance.colors.colInkSecondary
                MouseArea { id: meterArea; anchors { fill: parent; margins: -4 } hoverEnabled: true }
                StyledToolTip {
                    text: (meterLabel.text !== composer.meter ? `${composer.meter}. ` : "")
                        + (composer.meterPct >= 80 ? "Context nearly full: older turns get compacted soon. /compact does it now, a new session starts fresh."
                        : "How much of the model's context this session uses")
                    extraVisibleCondition: meterArea.containsMouse
                }
            }
            Rectangle {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                radius: 15
                readonly property bool ready: !composer.showStep && (composer.working || input.text.trim().length > 0 || composer.attachments.length > 0)
                // sand when there is something to send (or a run to stop), flat when there is not
                color: ready ? (sendArea.pressed ? Qt.darker(Appearance.colors.colPrimary, 1.1) : sendArea.containsMouse ? Qt.lighter(Appearance.colors.colPrimary, 1.08) : Appearance.colors.colPrimary)
                     : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                Behavior on color { enabled: !sendArea.pressed; ColorAnimation { duration: 110 } }
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: composer.working && input.text.trim().length === 0 ? "stop" : "arrow_upward"
                    fill: composer.working ? 1 : 0
                    iconSize: Appearance.icon.normal
                    color: parent.ready ? Appearance.m3colors.m3onPrimary : Appearance.colors.colInkSecondary
                }
                StyledToolTip {
                    text: composer.showStep ? "Sign in first" : composer.working && input.text.trim().length === 0 ? "Stop (Esc)" : "Send (Enter) · new line Shift+Enter"
                    extraVisibleCondition: sendArea.containsMouse
                }
                MouseArea {
                    id: sendArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: composer.working && input.text.trim().length === 0 ? composer.stop() : composer.submit()
                }
            }
        }
    }

    // ── the menu above the box ──────────────────────────────────────────────
    // At the chip that opened it (the text's start for `@` and `/`), over the conversation's foot.
    BoxShape {
        id: slab
        open: composer.menuOpen
        ground: composer.ground
        onShownChanged: if (slab.shown === 0 && composer.menu === "") composer.menuShown = ""
        readonly property Item from: composer.menuShown !== ""
            ? ({ agent: agentChip, run: runChip, mode: modeChip, folder: folderChip })[composer.menuShown] ?? null
            : composer.shownKind === "attach" ? attachChip : null
        readonly property real want: composer.menuShown !== "" ? (menuContent.item?.implicitWidth ?? 0) : suggestList.want
        width: Math.max(220, Math.min(slab.want + 2 * slab.pad, 460, composer.width))
        height: (composer.menuShown !== "" ? menuContent.height : suggestList.height) + 2 * slab.pad
        // on the box's edge when its chip is the first (text from the box no longer peeks beside it),
        // else just before its chip
        readonly property real chipLeft: slab.from ? box.x + chips.x + slab.from.x : box.x
        x: Math.max(0, Math.min(composer.width - slab.width, slab.chipLeft - box.x < 24 ? box.x : slab.chipLeft - 8))
        y: box.y - 8 - slab.height
        Behavior on width { enabled: slab.settled; Anim { type: Anim.FastSpatial } }
        Behavior on height { enabled: slab.settled; Anim { type: Anim.FastSpatial } }
        Behavior on x { enabled: slab.settled; Anim { type: Anim.FastSpatial } }

        DropArea {
            id: slabDrop
            anchors.fill: parent
            enabled: !composer.locked
            onDropped: d => composer.dropped(d)
        }
        Loader {
            id: menuContent
            x: slab.pad
            y: slab.pad
            width: slab.width - 2 * slab.pad
            active: composer.menuShown !== ""
            sourceComponent: ({ agent: composer.hasAccounts ? agentMenu : oldAgentMenu, run: runMenu, mode: modeMenu, folder: folderMenu })[composer.menuShown] ?? null
        }
        // the paperclip's picks, `@` and `/`: the keyboard stays in the text
        ListView {
            id: suggestList
            visible: composer.menuShown === ""
            x: slab.pad
            y: slab.pad
            width: slab.width - 2 * slab.pad
            height: Math.min(composer.shown.length, 9) * 34
            clip: true
            interactive: composer.shown.length > 9
            boundsBehavior: Flickable.StopAtBounds
            model: composer.shown
            GlideWheel { view: suggestList; gain: 1.6; gainPerSpeed: 3; gainMax: 6 }
            FontMetrics { id: big; font.family: Appearance.font.family.compact; font.pixelSize: 15 }
            FontMetrics { id: small; font.family: Appearance.font.family.compact; font.pixelSize: 13 }
            readonly property real want: {
                let w = 0;
                for (const r of composer.shown.slice(0, 40))
                    w = Math.max(w, 20 + big.advanceWidth(r.label ?? "") + (r.after ? 10 + small.advanceWidth(r.after) : 0));
                return Math.ceil(w);
            }
            delegate: BoxShape.Line {
                required property var modelData
                required property int index
                width: ListView.view.width
                label: modelData.label ?? ""
                after: modelData.after ?? ""
                middle: modelData.middle ?? false
                picked: index === composer.pick
                onEntered: composer.pick = index
                onClicked: composer.accept(index)
            }
        }
    }
    onPickChanged: if (composer.pick >= 0) suggestList.positionViewAtIndex(composer.pick, ListView.Contain)

    Component {
        id: agentMenu
        AgentChooser {
            model: composer.accounts
            current: ({ agent: composer.agent, account: composer.account })
            keepFolder: composer.keepFolder
            setup: composer.menuSetup
            fixed: !composer.fresh
            maxHeight: composer.menuMaxHeight
            // a ready account closes the menu; one with a step keeps it open on the step
            onChosen: (agent, account, keep) => {
                composer.agentPicked(agent, account, keep);
                if (composer.accounts.stepOf(agent, account) === "ready") composer.closeMenu();
            }
            onClosed: composer.closeMenu()
            onSettingsRequested: anchor => composer.settingsRequested(anchor)
        }
    }
    Component {
        id: runMenu
        ModelChooser {
            model: composer.accounts
            catalogs: composer.hasCatalog
            agent: composer.agent
            account: composer.account
            cwd: composer.folder
            current: composer.model
            effort: composer.effort || composer.reportedEffort
            wish: composer.effortWish
            autoOk: composer.reportedEffort === ""
            canStep: composer.needsStep
            recent: composer.recent
            keepFolder: composer.keepFolder
            maxHeight: composer.menuMaxHeight
            onChosen: (model, effort, keep) => {
                if (effort) composer.effortWish = effort;
                composer.closeMenu();
                composer.modelPicked(model, effort, keep);
            }
            onEffortPicked: level => {
                composer.effortWish = level;
                composer.effortPicked(level, false);
            }
            onStepRequested: composer.openMenu("agent")
            onClosed: composer.closeMenu()
            onAllDefaults: {
                composer.closeMenu();
                composer.prefsRequested();
            }
        }
    }
    Component {
        id: modeMenu
        ListMenu {
            rows: (composer.modesAllowed ? composer.modes.filter(m => composer.modesAllowed.includes(m.id)) : composer.modes.filter(m => m.id !== "bypassPermissions"))
                .map(m => ({ label: m.label, after: m.about, on: m.id === composer.mode, value: m.id }))
            keepLabel: composer.hasAccounts && composer.keepFolder.startsWith("/") ? (composer.keepFolder === Quickshell.env("HOME") ? "Home" : composer.keepFolder.split("/").pop()) : ""
            kept: composer.hasAccounts && composer.accounts.defaults?.folders?.[composer.keepFolder]?.mode === composer.mode
            onUsed: (value, keep) => {
                composer.closeMenu();
                composer.modePicked(value, keep);
            }
            onClosed: composer.closeMenu()
        }
    }
    Component {
        id: folderMenu
        ListMenu {
            rows: composer.folders.map(f => ({ label: f.name, after: f.path.replace(Quickshell.env("HOME"), "~"), middle: true, on: f.path === composer.folder, value: f.path }))
            onUsed: value => {
                composer.closeMenu();
                composer.folderPicked(value);
            }
            onClosed: composer.closeMenu()
        }
    }
    // a host that keeps no accounts: the agents its hello names, the ones that cannot start with why
    Component {
        id: oldAgentMenu
        ListMenu {
            rows: ["claude", "codex", "pi", "opencode"].map(t => {
                const why = composer.agentBlock(t);
                return { label: t === "claude" ? "Claude Code" : composer.agentLabels[t], why: why, after: why ? "" : composer.agents[t]?.version ?? "",
                         on: t === composer.agent, value: t };
            })
            onUsed: value => {
                composer.closeMenu();
                composer.agentPicked(value, "", false);
            }
            onClosed: composer.closeMenu()
        }
    }

    // The mode, folder and old-host agent menus: lines to choose from, and the keep line when
    // `keepLabel` names the folder. Keys: ↑↓, Enter, Ctrl+Enter (keep for the folder), Esc.
    component ListMenu: FocusScope {
        id: lm
        property var rows: []          // [{ label, after?, middle?, on?, why?, value }]
        property string keepLabel: ""
        property bool kept: false
        property int pick: 0
        signal used(string value, bool keep)
        signal closed()
        readonly property int count: lm.rows.length + (lm.keepLabel ? 1 : 0)
        function reset() { lm.pick = Math.max(0, lm.rows.findIndex(r => r.on)); }
        function usable(i) { return i < lm.rows.length ? !lm.rows[i].why : !lm.kept; }
        function step(d) {
            for (let i = lm.pick + d; i >= 0 && i < lm.count; i += d)
                if (lm.usable(i)) { lm.pick = i; return; }
        }
        function use(i, keep) {
            if (!lm.usable(i)) return;
            if (i < lm.rows.length) lm.used(lm.rows[i].value, keep);
            else lm.used((lm.rows.find(r => r.on) ?? lm.rows[0]).value, true);
        }
        FontMetrics { id: lmBig; font.family: Appearance.font.family.compact; font.pixelSize: 15 }
        FontMetrics { id: lmSmall; font.family: Appearance.font.family.compact; font.pixelSize: 13 }
        FontMetrics { id: lmNum; font.family: Appearance.font.family.numbers; font.pixelSize: 13 }
        implicitWidth: {
            let w = lm.keepLabel ? 20 + lmBig.advanceWidth(`Use for new sessions in ${lm.keepLabel}`) + 12 + lmNum.advanceWidth("Ctrl+↵") : 0;
            for (const r of lm.rows)
                w = Math.max(w, 20 + lmBig.advanceWidth(r.label) + (r.after ? 10 + lmSmall.advanceWidth(r.after) : 0) + (r.on ? 22 : 0),
                             r.why ? 20 + Math.min(lmSmall.advanceWidth(r.why), 300) : 0);
            return Math.ceil(w);
        }
        implicitHeight: lmCol.implicitHeight
        Keys.onPressed: e => {
            e.accepted = true;
            if (e.key === Qt.Key_Escape) lm.closed();
            else if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) lm.step(1);
            else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) lm.step(-1);
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) lm.use(lm.pick, (e.modifiers & Qt.ControlModifier) !== 0);
            else e.accepted = false;
        }
        Column {
            id: lmCol
            width: parent.width
            Repeater {
                id: lmRows
                model: lm.rows
                delegate: BoxShape.Line {
                    required property var modelData
                    required property int index
                    width: lmCol.width
                    label: modelData.label
                    after: modelData.after ?? ""
                    middle: modelData.middle ?? false
                    why: modelData.why ?? ""
                    on: modelData.on ?? false
                    picked: lm.pick === index
                    onEntered: lm.pick = index
                    onClicked: lm.use(index, false)
                }
            }
            Item {
                visible: lmKeep.visible
                width: parent.width
                height: 9
                Rectangle { x: 8; y: 4; width: parent.width - 16; height: 1; color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9) }
            }
            BoxShape.Line {
                id: lmKeep
                visible: lm.keepLabel !== ""
                width: parent.width
                label: lm.kept ? `Saved for new sessions in ${lm.keepLabel}` : `Use for new sessions in ${lm.keepLabel}`
                detail: lm.kept ? "" : "Ctrl+↵"
                still: lm.kept
                ink: lm.kept ? Appearance.colors.colInkMeta : Appearance.colors.colInkSecondary
                picked: lm.pick === lm.rows.length
                onEntered: lm.pick = lm.rows.length
                onClicked: lm.use(lm.rows.length, true)
            }
        }
    }

    // A small pill: glyph and label, the shell's overlay tones.
    component Chip: Rectangle {
        id: chip
        property string glyph: ""
        property string label: ""
        property bool on: false
        property bool dot: false           // the chosen account needs a step
        property string tip: ""
        property bool shrink: false        // gives way when the row is full: the label elides
        // said instead when the row has no room for the label: the model's name whole, not "Opus 5..." (half a screen)
        property string compact: ""
        property bool useCompact: false
        readonly property string shown: chip.useCompact && chip.compact.length ? chip.compact : chip.label
        signal clicked()
        // the glyph, dot and gaps around the label
        readonly property real chrome: 18 + (chip.glyph ? chipGlyph.implicitWidth : 0) + (chip.dot ? 6 : 0)
            + 5 * Math.max(0, (chip.glyph ? 1 : 0) + (chip.dot ? 1 : 0) + (chip.label ? 1 : 0) - 1)
        // whole pixels: the layout rounds what it gives, and a fraction short elides the label
        // the label's own width, whatever the layout gives: the row reckons with it
        readonly property real natural: Math.ceil(chip.chrome + (chip.label ? Math.min(fullLabel.advanceWidth, 240) : 0))
        readonly property real full: Math.ceil(chip.chrome + (chip.shown ? Math.min(shownLabel.advanceWidth, 240) : 0))
        TextMetrics { id: fullLabel; font: chipLabel.font; text: chip.label }
        TextMetrics { id: shownLabel; font: chipLabel.font; text: chip.shown }
        Layout.preferredHeight: 30
        Layout.preferredWidth: chip.full
        Layout.fillWidth: chip.shrink
        Layout.maximumWidth: chip.full
        Layout.minimumWidth: chip.shrink ? Math.min(chip.full, chip.chrome + 48) : chip.full
        radius: Appearance.rounding.card
        // a glyph and a word at rest, no outline: outlined pills inside the box's own hairline read busy (2026-10-11).
        // Hover shows a soft fill; open, held in the fill the rail gives its current row (sand stays for live
        // things); a press deepens the fill at once and eases back on release
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, chipArea.pressed ? 0.85 : chip.on ? 0.89 : chipArea.containsMouse ? 0.93 : 1)
        Behavior on color { enabled: !chipArea.pressed; ColorAnimation { duration: 110 } }
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 5
            MaterialSymbol { id: chipGlyph; visible: chip.glyph.length > 0; text: chip.glyph; iconSize: 15; color: chip.on || chipArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary; anchors.verticalCenter: parent.verticalCenter }
            Rectangle { visible: chip.dot; width: 6; height: 6; radius: 3; color: Appearance.colors.colPrimary; anchors.verticalCenter: parent.verticalCenter }
            StyledText { id: chipLabel; visible: chip.label.length > 0; width: Math.max(0, Math.min(implicitWidth, 240, chip.width - chip.chrome)); elide: chip.width < chip.full - 1 ? Text.ElideRight : Text.ElideMiddle; text: chip.shown; font.pixelSize: Appearance.font.pixelSize.smallie; color: chip.on || chipArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary; anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
        Loader {
            anchors.fill: parent
            // not while its menu is open: the tip would sit on the menu
            active: chip.tip !== "" && chipArea.containsMouse && !chip.on
            sourceComponent: StyledToolTip { text: chip.tip; extraVisibleCondition: false; alternativeVisibleCondition: true }
        }
    }
}
