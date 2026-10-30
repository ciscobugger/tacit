import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.tacit

/**
 * Praxis's preferences: what new sessions start with, everywhere and per folder, written as
 * sentences whose phrases open their choices in place under them (AgentChooser, ModelChooser, the
 * mode rows). agent-host keeps every value (AccountsModel.setDefaults), so the notch follows them.
 * A phrase in colInkMain is kept at that level; one in colInkFaint comes from further out (for a
 * folder: everywhere; for everywhere: the agent's own config).
 *
 * A plain slab on `ground` with a hairline, docked at `railEdgeX` with its bottom 19 px above the
 * window's: fill the window's surface with it. It slides out from under the rail. Keys: ↑↓, Enter,
 * Delete or Backspace (a kept phrase back to what it inherits), Esc (the open choice, then the
 * sheet); a click outside closes it.
 */
FocusScope {
    id: sheet

    property var accounts: null        // AccountsModel
    property string folder: ""         // the open session's folder: first among "A folder…"
    property var folders: []           // [{ path, name, hidden? }]: FolderModel.targets, or recent folders
    property color ground: Appearance.m3colors.m3surfaceContainerLow
    property real railEdgeX: 0         // the rail's right edge, or the folded strip's
    readonly property bool open: sheet.on
    signal closed()
    signal settingsRequested(string anchor)

    // ── opening and closing ─────────────────────────────────────────────────
    property bool on: false
    property real shown: 0             // the slide: 0 under the rail, 1 docked (FastSpatial passes 1)
    // `path`: a folder whose sentence opens, kept or not; "" opens only the sheet
    function openFor(path) {
        const p = (path ?? "").startsWith("/") ? path : "";
        sheet.chField = "";
        sheet.pending = p && !sheet.defs.folders?.[p] ? p : "";
        sheet.openKey = p;
        sheet.byKeys = false;
        if (!sheet.on) {
            sheet.on = true;
            outAnim.stop();
            inAnim.restart();
        }
        flick.contentY = 0;
        sheet.cursor = p ? sheet.stopOf("folder", p) : 0;
        sheet.forceActiveFocus();
        Qt.callLater(sheet.askCatalogs);
    }
    function close() {
        if (!sheet.on) return;
        sheet.on = false;
        sheet.chField = "";
        inAnim.stop();
        outAnim.restart();
        sheet.closed();
    }
    Anim { id: inAnim; target: sheet; property: "shown"; to: 1; type: Anim.FastSpatial }
    NumberAnimation {
        id: outAnim
        target: sheet
        property: "shown"
        to: 0
        duration: Appearance.animation.elementMoveExit.duration
        easing.type: Appearance.animation.elementMoveExit.type
        easing.bezierCurve: Appearance.animation.elementMoveExit.bezierCurve
        onFinished: { sheet.openKey = ""; sheet.pending = ""; sheet.cursor = -1; }
    }
    visible: sheet.on || sheet.shown > 0

    // ── what the host keeps, and what each level resolves to ────────────────
    readonly property bool available: !!sheet.accounts?.available
    readonly property var defs: sheet.accounts?.defaults ?? ({})
    readonly property string home: Quickshell.env("HOME") ?? ""
    readonly property var modes: [
        { id: "auto", label: "Auto", words: "in auto mode", about: "decides for itself what needs your OK" },
        { id: "manual", label: "Ask first", words: "asking first", about: "asks before every command and edit" },
        { id: "acceptEdits", label: "Edits ok", words: "with edits ok", about: "edits files freely, asks before commands" },
        { id: "plan", label: "Plan", words: "planning only", about: "reads and plans, changes nothing" },
        { id: "bypassPermissions", label: "Full access", words: "with full access", about: "runs every command and edit without asking; nothing is checked" }
    ]
    readonly property var effortWords: ({ low: "low", medium: "medium", high: "high", xhigh: "extra high", max: "max",
                                          ultra: "ultra", off: "off", minimal: "minimal" })
    function modeOf(id) { return sheet.modes.find(m => m.id === id) ?? sheet.modes[0]; }
    function nameOf(path) {
        const f = (sheet.folders ?? []).find(x => (x.path ?? x.fkey) === path);
        if (f?.name) return f.name;
        return path === sheet.home ? "Home" : path.split("/").filter(s => s.length).pop() ?? path;
    }

    // The entries a level's values come from, nearest first, as agent-host resolves a new session's
    // folder: its own entry, else the nearest folder above it (Home and / only for themselves),
    // then everywhere.
    function chainOf(scope) {
        const ev = { from: "everywhere", e: sheet.defs.everywhere ?? {} };
        if (scope === "everywhere") return [ev];
        const fs = sheet.defs.folders ?? {};
        if (fs[scope]) return [{ from: scope, e: fs[scope] }, ev];
        let best = "";
        for (const p in fs)
            if (p !== sheet.home && p !== "/" && scope.startsWith(p.replace(/\/$/, "") + "/") && p.length > best.length) best = p;
        return best ? [{ from: best, e: fs[best] }, ev] : [ev];
    }
    // each value, and where it comes from: a level's path, "everywhere", or "" (the agent's own)
    function resolvedOf(scope) {
        const acc = sheet.accounts;
        const chain = sheet.chainOf(scope);
        const pick = (get, ok) => {
            for (const c of chain) {
                const v = get(c.e);
                if (v !== undefined && v !== null && v !== "" && (!ok || ok(v))) return { v: v, from: c.from };
            }
            return { v: "", from: "" };
        };
        const ag = pick(e => e.agent, v => acc.agentOrder.includes(v));
        const agent = ag.v || "claude";
        const ac = pick(e => e.run?.[agent]?.account, v => acc.account(v)?.agent === agent);
        const model = pick(e => e.run?.[agent]?.model);
        const effort = pick(e => e.run?.[agent]?.effort);
        const mode = pick(e => e.mode);
        return { agent: agent, agentFrom: ag.from, account: ac.v || (acc.defaultAccount(agent)?.id ?? ""), accountFrom: ac.from,
                 model: model.v, modelFrom: model.from, effort: effort.v, effortFrom: effort.from, mode: mode.v, modeFrom: mode.from };
    }

    // An account's models (AccountsModel keeps one copy per folder; the models are the same in each),
    // null until the host has answered. Asked for outside bindings: asking writes the request tag.
    function modelsOf(agent, account) {
        const cs = sheet.accounts?.catalogs ?? {};
        const pre = `${agent}|${account}|`;
        for (const k in cs)
            if (k.startsWith(pre)) return cs[k].models ?? [];
        return null;
    }
    readonly property var wanted: {
        if (!sheet.available) return [];
        const out = [];
        for (const s of ["everywhere"].concat(sheet.folderPaths)) {
            const r = sheet.resolvedOf(s);
            if (!out.includes(`${r.agent}|${r.account}`)) out.push(`${r.agent}|${r.account}`);
        }
        return out;
    }
    onWantedChanged: Qt.callLater(sheet.askCatalogs)
    function askCatalogs() {
        if (!sheet.available) return;
        for (const k of sheet.wanted) {
            const [agent, account] = k.split("|");
            if (sheet.modelsOf(agent, account) === null) sheet.accounts.catalog(agent, account, "");
        }
    }
    // the row an id runs (a session's full id, "" and "default" the agent's default), as the box's run chip
    function modelRow(ms, id) { return sheet.accounts.modelRowOf(sheet.accounts.shapeModels(ms), id); }
    function modelLabel(ms, id) {
        const m = sheet.modelRow(ms, id);
        if (!m) return id && id !== "default" ? sheet.accounts.plainId(id) : "its default model";
        return m.plainDefault ? "its default model" : m.label;
    }
    // What a level's sentence says. An effort the model does not offer reads as its own default.
    function viewOf(scope) {
        const acc = sheet.accounts;
        const r = sheet.resolvedOf(scope);
        const ms = sheet.modelsOf(r.agent, r.account);
        const row = ms ? sheet.modelRow(ms, r.model) : null;
        const levels = row?.efforts ?? [];
        let effort = r.effort, effortFrom = r.effortFrom;
        if (ms && !levels.includes(effort)) {
            effort = row?.defaultEffort && levels.includes(row.defaultEffort) ? row.defaultEffort : "";
            effortFrom = "";
        }
        const many = acc.accountsOf(r.agent).length > 1;
        return {
            agent: r.agent, account: r.account, model: r.model, chainEffort: r.effort, effort: effort, mode: r.mode || "auto",
            agentText: acc.agentName(r.agent) + (many ? ` · ${acc.account(r.account)?.label ?? ""}` : ""),
            agentKept: r.agentFrom === scope || (many && r.accountFrom === scope),
            modelText: ms ? sheet.modelLabel(ms, r.model) : (r.model && r.model !== "default" ? r.model : "its default model"),
            modelKept: r.modelFrom === scope,
            effortText: sheet.effortWords[effort] ?? effort,
            effortKept: effortFrom === scope,
            showEffort: effort !== "",
            modeKept: r.modeFrom === scope
        };
    }
    // the sentence as words and phrases: { text, field?, kept?, suffix? }
    function tokensOf(scope) {
        const v = sheet.viewOf(scope);
        const t = [];
        const words = s => { for (const x of s.split(" ")) t.push({ text: x }); };
        const phrase = (field, text, kept) => t.push({ text: text, field: field, kept: kept });
        words("start with");
        phrase("agent", v.agentText, v.agentKept);
        words("on");
        phrase("model", v.modelText, v.modelKept);
        if (v.showEffort && v.effort === "off") {
            words("with");
            phrase("effort", "effort off", v.effortKept);
        } else if (v.showEffort) {
            words("at");
            phrase("effort", v.effortText, v.effortKept);
            words("effort");
        }
        t[t.length - 1].suffix = ",";
        phrase("mode", sheet.modeOf(v.mode).words, v.modeKept);
        t[t.length - 1].suffix = ".";
        return t;
    }
    // a folder row's facts: only what differs from everywhere
    function differs(path) {
        const acc = sheet.accounts;
        const v = sheet.viewOf(path), e = sheet.viewOf("everywhere");
        const other = v.agent !== e.agent;
        const out = [];
        if (other) out.push(acc.agentName(v.agent));
        if (acc.accountsOf(v.agent).length > 1 && (other || v.account !== e.account)) out.push(acc.account(v.account)?.label ?? "");
        if (other || v.modelText !== e.modelText) out.push(v.modelText);
        if (v.showEffort && (other || v.effort !== e.effort)) out.push(v.effortText);
        if (v.mode !== e.mode) out.push(sheet.modeOf(v.mode).label);
        return out.filter(s => s.length).join(", ");
    }

    // ── folders ─────────────────────────────────────────────────────────────
    property string openKey: ""        // the folder whose sentence is open
    property string pending: ""        // a folder from "A folder…" with nothing kept yet
    readonly property var folderList: {
        const ks = Object.keys(sheet.defs.folders ?? {});
        if (sheet.pending && !ks.includes(sheet.pending)) ks.push(sheet.pending);
        return ks.sort((a, b) => sheet.nameOf(a).localeCompare(sheet.nameOf(b)) || a.localeCompare(b));
    }
    // the rows are by count, so a state push that keeps the same folders keeps an open choice
    property var folderPaths: []
    onFolderListChanged: if (JSON.stringify(sheet.folderList) !== JSON.stringify(sheet.folderPaths)) sheet.folderPaths = sheet.folderList
    Component.onCompleted: sheet.folderPaths = sheet.folderList
    // "A folder…": the open session's folder, then FolderModel's (or the recent ones), not kept yet
    readonly property var candidates: {
        const out = [], seen = {};
        const add = (path, name) => {
            if (!path || !path.startsWith("/") || seen[path] || sheet.defs.folders?.[path] || path === sheet.pending) return;
            seen[path] = true;
            out.push({ label: name || sheet.nameOf(path), after: path.replace(sheet.home, "~"), middle: true, value: path });
        };
        add(sheet.folder, "");
        for (const f of sheet.folders ?? [])
            if (!f.hidden) add(f.path ?? f.fkey, f.name);
        return out.length ? out.slice(0, 8) : [{ label: "No other folders", why: "Folders you work in are listed here", value: "" }];
    }

    // ── accounts line ───────────────────────────────────────────────────────
    readonly property string signedLine: {
        const n = (sheet.accounts?.readyAgents ?? []).map(a => sheet.accounts.agentName(a));
        return n.length ? `Signed in: ${n.join(", ")}` : "No agent is signed in";
    }
    readonly property var needs: sheet.accounts?.needs ?? []
    readonly property string needLine: {
        const n = sheet.needs[0];
        if (!n) return "";
        const name = sheet.accounts.agentName(n.agent);
        const multi = n.agent === "pi" || n.agent === "opencode";
        const what = ({ signedOut: multi ? `${name} has no provider` : `${name} isn't signed in`,
                        expired: `${name}'s sign-in has expired`, noProvider: `${name} has no provider`,
                        notInstalled: `${name} isn't installed`, needsNode: `${name} needs one more install first`,
                        noKey: `${name} has no key`, keyRefused: `${name}'s key was refused`,
                        locked: "The keyring is locked" })[n.step] ?? "";
        return what + (sheet.needs.length > 1 ? ` and ${sheet.needs.length - 1} more` : "");
    }
    readonly property string needAnchor: sheet.needs[0] && sheet.needs[0].step !== "locked" ? sheet.needs[0].agent : ""

    // ── writing: every value goes to agent-host ─────────────────────────────
    function write(scope, fields) { sheet.accounts.setDefaults(scope, fields); }
    // the account is kept only when the agent has more than one
    function pickAgent(scope, agent, account) {
        const f = { agent: agent };
        if (sheet.accounts.accountsOf(agent).length > 1) f.run = { [agent]: { account: account || null } };
        sheet.write(scope, f);
    }
    // Enter keeps the phrase the menu was opened from; the other value is written only when it changes
    // what the level gets (a new model's effort when it is not that model's own)
    function pickModel(scope, from, model, effort) {
        const r = sheet.resolvedOf(scope);
        const ms = sheet.modelsOf(r.agent, r.account) ?? [];
        const row = sheet.modelRow(ms, model), cur = sheet.modelRow(ms, r.model);
        const entry = {};
        if (from === "model" || r.modelFrom === scope || !(row && cur && row.id === cur.id)) entry.model = model;
        const levels = row?.efforts ?? [];
        const anyway = levels.includes(r.effort) ? r.effort : (row?.defaultEffort ?? "");
        if (from === "effort" || r.effortFrom === scope || (effort && effort !== anyway)) entry.effort = effort || null;
        if (Object.keys(entry).length) sheet.write(scope, { run: { [r.agent]: entry } });
    }
    function pickEffort(scope, level) { sheet.write(scope, { run: { [sheet.resolvedOf(scope).agent]: { effort: level || null } } }); }
    function clearPhrase(scope, field) {
        const v = sheet.viewOf(scope), r = sheet.resolvedOf(scope);
        if (field === "agent" && v.agentKept) {
            const f = { agent: null };
            if (r.accountFrom === scope) f.run = { [r.agent]: { account: null } };
            sheet.write(scope, f);
        } else if (field === "model" && v.modelKept) sheet.write(scope, { run: { [r.agent]: { model: null } } });
        else if (field === "effort" && r.effortFrom === scope) sheet.write(scope, { run: { [r.agent]: { effort: null } } });
        else if (field === "mode" && v.modeKept) sheet.write(scope, { mode: null });
    }
    function clearFolder(path) {
        const e = sheet.defs.folders?.[path];
        if (!e) return;
        const f = { agent: null, mode: null };
        const run = Object.keys(e.run ?? {});
        if (run.length) f.run = Object.fromEntries(run.map(a => [a, null]));
        sheet.write(path, f);
        if (sheet.openKey === path) sheet.openKey = "";
        if (sheet.chScope === path) sheet.closeChooser();
    }

    // ── the keyboard: phrases, folder rows, "A folder…" and the Accounts link ──
    // { kind: phrase | folder | clear | add | accounts, scope, field? }
    readonly property var stops: {
        const out = [];
        if (!sheet.available) return out;
        const phrases = s => { for (const x of sheet.tokensOf(s)) if (x.field) out.push({ kind: "phrase", scope: s, field: x.field }); };
        phrases("everywhere");
        for (const p of sheet.folderPaths) {
            out.push({ kind: "folder", scope: p });
            if (sheet.openKey !== p) continue;
            phrases(p);
            if (sheet.defs.folders?.[p]) out.push({ kind: "clear", scope: p });
        }
        out.push({ kind: "add", scope: "" });
        out.push({ kind: "accounts", scope: "" });
        return out;
    }
    function stopOf(kind, scope, field) { return sheet.stops.findIndex(s => s.kind === kind && s.scope === (scope ?? "") && (!field || s.field === field)); }
    property int cursor: -1
    property bool byKeys: false        // the cursor last moved by key: it is scrolled into view
    function point(i) { sheet.byKeys = false; sheet.cursor = i; }
    function step(d) {
        sheet.byKeys = true;
        sheet.cursor = Math.max(0, Math.min(sheet.stops.length - 1, sheet.cursor < 0 && d < 0 ? sheet.stops.length - 1 : sheet.cursor + d));
    }
    function activate(i) {
        const s = sheet.stops[i];
        if (!s) return;
        sheet.cursor = i;
        if (s.kind === "phrase") sheet.openChooser(s.scope, s.field);
        else if (s.kind === "folder") sheet.toggleFolder(s.scope);
        else if (s.kind === "clear") sheet.clearFolder(s.scope);
        else if (s.kind === "add") sheet.openChooser("", "folder");
        else if (s.kind === "accounts") sheet.settingsRequested(sheet.needAnchor);
    }
    function toggleFolder(path) {
        sheet.closeChooser();
        if (sheet.pending && sheet.pending !== path && !sheet.defs.folders?.[sheet.pending]) sheet.pending = "";
        sheet.openKey = sheet.openKey === path ? "" : path;
        if (sheet.openKey === "" && sheet.pending === path) sheet.pending = "";
        sheet.cursor = sheet.stopOf("folder", path);
    }
    Keys.onPressed: e => {
        if (!sheet.on || sheet.chField !== "") return;
        e.accepted = true;
        if (e.key === Qt.Key_Escape) sheet.close();
        else if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab) sheet.step(1);
        else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab) sheet.step(-1);
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) sheet.activate(sheet.cursor);
        else if (e.key === Qt.Key_Delete || e.key === Qt.Key_Backspace) {
            const s = sheet.stops[sheet.cursor];
            if (s?.kind === "phrase") sheet.clearPhrase(s.scope, s.field);
        } else e.accepted = false;
    }

    // ── the choice open in place: under a sentence, or under "A folder…" ────
    property string chScope: ""        // "everywhere", a folder's path, or "" (A folder…); kept after it closes
    property string chField: ""        // agent | model | effort | mode | folder; "" closed
    property Item chooserItem: null
    readonly property Component chooserComponent: ({ agent: agentComp, model: modelComp, effort: modelComp, mode: modeComp, folder: addComp })[sheet.chField] ?? null
    readonly property real chooserMaxH: Math.max(150, Math.min(340, sheet.height - 38 - 160))
    function openChooser(scope, field) {
        if (sheet.chField === field && sheet.chScope === scope) {
            sheet.closeChooser();
            return;
        }
        sheet.chScope = scope;
        sheet.chField = field;
        sheet.cursor = field === "folder" ? sheet.stopOf("add", "") : sheet.stopOf("phrase", scope, field);
        Qt.callLater(sheet.focusChooser);
    }
    function focusChooser() {
        const c = sheet.chooserItem;
        if (!c || sheet.chField === "") return;
        if (c.reset) c.reset();
        c.forceActiveFocus();
        Qt.callLater(() => sheet.reveal(sheet.chooserItem));
    }
    // a menu that finishes sizing after it opens (its list arrives late) is brought into view again
    Connections {
        target: sheet.chooserItem
        function onHeightChanged() { if (sheet.chField !== "") sheet.reveal(sheet.chooserItem); }
    }
    function closeChooser() {
        if (sheet.chField === "") return;
        sheet.chField = "";
        sheet.forceActiveFocus();
    }
    function pickFolder(path) {
        if (!path) return;
        sheet.closeChooser();
        sheet.pending = path;
        sheet.openKey = path;
        sheet.cursor = sheet.stopOf("folder", path);
        sheet.byKeys = true;
    }

    Component {
        id: agentComp
        AgentChooser {
            readonly property string scope: sheet.chScope
            readonly property var v: sheet.viewOf(scope)
            model: sheet.accounts
            current: ({ agent: v.agent, account: v.account })
            maxHeight: sheet.chooserMaxH
            Component.onCompleted: sheet.chooserItem = this
            // a ready account closes the menu; one with a step keeps it open on the step
            onChosen: (agent, account) => {
                sheet.pickAgent(scope, agent, account);
                if (sheet.accounts.stepOf(agent, account) === "ready") sheet.closeChooser();
            }
            onClosed: sheet.closeChooser()
            onSettingsRequested: anchor => sheet.settingsRequested(anchor)
        }
    }
    Component {
        id: modelComp
        ModelChooser {
            readonly property string scope: sheet.chScope
            readonly property var v: sheet.viewOf(scope)
            model: sheet.accounts
            catalogs: (sheet.accounts?.link?.features ?? []).includes("catalog")
            agent: v.agent
            account: v.account
            cwd: scope === "everywhere" ? "" : scope
            current: v.model
            effort: v.chainEffort
            recent: sheet.recent[v.agent] ?? []
            showKeep: false
            maxHeight: sheet.chooserMaxH
            Component.onCompleted: sheet.chooserItem = this
            onChosen: (model, effort) => {
                const from = sheet.chField;
                sheet.closeChooser();
                sheet.pickModel(scope, from, model, effort);
            }
            onEffortPicked: level => sheet.pickEffort(scope, level)
            onClosed: sheet.closeChooser()
        }
    }
    Component {
        id: modeComp
        Composer.ListMenu {
            readonly property string scope: sheet.chScope
            readonly property var v: sheet.viewOf(scope)
            readonly property var allowed: sheet.accounts?.link?.agents?.[v.agent]?.caps?.modes ?? null
            rows: sheet.modes.filter(m => allowed ? allowed.includes(m.id) : m.id !== "bypassPermissions").map(m => ({ label: m.label, after: m.about, on: m.id === v.mode, value: m.id }))
            Component.onCompleted: sheet.chooserItem = this
            onUsed: value => {
                sheet.closeChooser();
                sheet.write(scope, { mode: value });
            }
            onClosed: sheet.closeChooser()
        }
    }
    Component {
        id: addComp
        Composer.ListMenu {
            rows: sheet.candidates
            Component.onCompleted: sheet.chooserItem = this
            onUsed: value => sheet.pickFolder(value)
            onClosed: sheet.closeChooser()
        }
    }

    // Praxis's own recents (Conversation writes them): the models lately picked, per agent
    FileView {
        id: prefsFile
        path: `${Directories.state}/user/claude-prefs.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property var recent: {
        try { return JSON.parse(prefsFile.text() || "{}").recent ?? {}; } catch (e) { return {}; }
    }

    // ── scrolling the keyboard's place into view ────────────────────────────
    readonly property int padV: 14
    readonly property real viewH: Math.min(col.implicitHeight + 2 * sheet.padV, sheet.height - 38) - 2
    function reveal(it) {
        if (!it || sheet.viewH <= 0) return;
        const y = it.mapToItem(col, 0, 0).y + sheet.padV, h = it.height;
        const max = Math.max(0, col.implicitHeight + 2 * sheet.padV - sheet.viewH);
        if (y + h + sheet.padV > flick.contentY + sheet.viewH) flick.contentY = Math.min(max, y + h + sheet.padV - sheet.viewH);
        if (y - sheet.padV < flick.contentY) flick.contentY = Math.max(0, y - sheet.padV);
    }
    // a stop's look: the pointer or the keyboard is on it
    function picked(kind, scope, field) { return sheet.cursor >= 0 && sheet.cursor === sheet.stopOf(kind, scope, field); }

    // ── the surface ─────────────────────────────────────────────────────────
    // a click outside closes it
    MouseArea {
        anchors.fill: parent
        enabled: sheet.on
        acceptedButtons: Qt.AllButtons
        onPressed: sheet.close()
    }
    FontMetrics { id: m15; font.family: Appearance.font.family.compact; font.pixelSize: 15 }

    // from under the rail: its edge clips the slab's left side (corners and hairline)
    Item {
        x: sheet.railEdgeX
        width: Math.max(0, sheet.width - sheet.railEdgeX)
        height: sheet.height
        clip: true

        Rectangle {
            id: slab
            readonly property real r: Appearance.rounding.small
            readonly property real w: Math.max(0, Math.min(360, sheet.width - sheet.railEdgeX - 24))
            x: -slab.r - 1
            width: slab.w + slab.r + 1
            height: Math.min(col.implicitHeight + 2 * sheet.padV, sheet.height - 38)
            y: sheet.height - 19 - slab.height
            Behavior on height { enabled: sheet.on && !inAnim.running; Anim { type: Anim.EmphasizedSmall } }
            radius: slab.r
            color: sheet.ground
            border.width: 1
            border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            // FastSpatial's overshoot must not lift it off the rail's edge
            transform: Translate { x: -Math.max(0, 1 - sheet.shown) * slab.width }

            // its own ground takes its clicks: none reach the conversation or close it
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.AllButtons
                onWheel: w => w.accepted = true
            }
            Flickable {
                id: flick
                x: slab.r + 1 + 6
                y: 1
                width: slab.w - 12
                height: slab.height - 2
                contentHeight: col.implicitHeight + 2 * sheet.padV
                interactive: contentHeight > height + 1
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                GlideWheel { view: flick; gain: 1.6; gainPerSpeed: 3; gainMax: 6 }

                Column {
                    id: col
                    x: 10
                    y: sheet.padV
                    width: flick.width - 20

                    Label12 { text: "New sessions" }
                    Item { width: 1; height: 6 }
                    Loader {
                        readonly property string scope: "everywhere"
                        width: col.width
                        active: sheet.available
                        sourceComponent: sentenceComp
                    }
                    Item {
                        readonly property bool on: sheet.chField !== "" && sheet.chScope === "everywhere"
                        width: col.width
                        height: on ? everyLoader.height + 12 : 0
                        Loader {
                            id: everyLoader
                            x: -10
                            y: 6
                            width: parent.width + 20
                            active: parent.on
                            sourceComponent: sheet.chooserComponent
                        }
                    }
                    StyledText {
                        visible: !sheet.available
                        width: col.width
                        text: !sheet.accounts?.link?.connected ? "Praxis can't reach its background service."
                            : "Praxis was updated; its background service needs a restart."
                        wrapMode: Text.Wrap
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 13
                        color: Appearance.colors.colInkSecondary
                    }

                    Item { visible: sheet.available; width: 1; height: 16 }
                    Label12 { visible: sheet.available; text: "In folders" }
                    Item { visible: sheet.available; width: 1; height: 2 }
                    Repeater {
                        model: sheet.available ? sheet.folderPaths.length : 0
                        delegate: Column {
                            id: fold
                            required property int index
                            readonly property string path: sheet.folderPaths[fold.index] ?? ""
                            readonly property bool kept: !!sheet.defs.folders?.[fold.path]
                            readonly property bool isOpen: sheet.openKey === fold.path
                            width: col.width

                            Item {
                                id: frow
                                readonly property bool picked: sheet.picked("folder", fold.path)
                                width: parent.width
                                height: 30
                                onPickedChanged: if (frow.picked && sheet.byKeys) sheet.reveal(frow)
                                Rectangle {
                                    anchors { fill: parent; leftMargin: -10; rightMargin: -10 }
                                    radius: 8
                                    color: frow.picked ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                                }
                                StyledText {
                                    id: fname
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, parent.width * 0.6)
                                    text: sheet.nameOf(fold.path)
                                    elide: Text.ElideRight
                                    font.family: Appearance.font.family.compact
                                    font.pixelSize: 15
                                    color: Appearance.colors.colInkMain
                                }
                                StyledText {
                                    anchors { left: fname.right; leftMargin: 10; right: parent.right; rightMargin: clearGlyph.visible ? 26 : 0; verticalCenter: parent.verticalCenter }
                                    visible: !fold.isOpen
                                    text: fold.kept ? sheet.differs(fold.path) : ""
                                    elide: Text.ElideRight
                                    font.family: Appearance.font.family.compact
                                    font.pixelSize: 13
                                    color: Appearance.colors.colInkMeta
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: sheet.point(sheet.stopOf("folder", fold.path))
                                    onClicked: sheet.toggleFolder(fold.path)
                                }
                                MaterialSymbol {
                                    id: clearGlyph
                                    visible: frow.picked && fold.kept
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                    text: "close"
                                    iconSize: 16
                                    color: clearArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                                    MouseArea {
                                        id: clearArea
                                        anchors { fill: parent; margins: -6 }
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: sheet.clearFolder(fold.path)
                                    }
                                    StyledToolTip { text: `Clear ${sheet.nameOf(fold.path)}`; extraVisibleCondition: clearArea.containsMouse }
                                }
                            }
                            Loader {
                                readonly property string scope: fold.path
                                width: parent.width
                                active: fold.isOpen
                                visible: active
                                sourceComponent: sentenceComp
                            }
                            Item {
                                readonly property bool on: sheet.chField !== "" && sheet.chScope === fold.path
                                width: parent.width
                                height: on ? foldLoader.height + 12 : 0
                                Loader {
                                    id: foldLoader
                                    x: -10
                                    y: 6
                                    width: parent.width + 20
                                    active: parent.on
                                    sourceComponent: sheet.chooserComponent
                                }
                            }
                            Item {
                                id: crow
                                readonly property bool picked: sheet.picked("clear", fold.path)
                                visible: fold.isOpen && fold.kept
                                width: parent.width
                                height: visible ? 30 : 0
                                onPickedChanged: if (crow.picked && sheet.byKeys) sheet.reveal(crow)
                                Rectangle {
                                    anchors { fill: parent; leftMargin: -10; rightMargin: -10 }
                                    radius: 8
                                    color: crow.picked ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                                }
                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: `Clear for ${sheet.nameOf(fold.path)}`
                                    font.family: Appearance.font.family.compact
                                    font.pixelSize: 14
                                    color: Appearance.colors.colInkSecondary
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onEntered: sheet.point(sheet.stopOf("clear", fold.path))
                                    onClicked: sheet.clearFolder(fold.path)
                                }
                            }
                        }
                    }
                    Item {
                        id: addRow
                        readonly property bool picked: sheet.picked("add", "")
                        visible: sheet.available
                        width: col.width
                        height: 30
                        onPickedChanged: if (addRow.picked && sheet.byKeys) sheet.reveal(addRow)
                        Rectangle {
                            anchors { fill: parent; leftMargin: -10; rightMargin: -10 }
                            radius: 8
                            color: addRow.picked ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                        }
                        MaterialSymbol {
                            id: addGlyph
                            anchors.verticalCenter: parent.verticalCenter
                            text: "add"
                            iconSize: 16
                            color: Appearance.colors.colInkSecondary
                        }
                        StyledText {
                            anchors { left: addGlyph.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                            text: "A folder…"
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 15
                            color: Appearance.colors.colInkSecondary
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: sheet.point(sheet.stopOf("add", ""))
                            onClicked: sheet.openChooser("", "folder")
                        }
                    }
                    Item {
                        readonly property bool on: sheet.chField === "folder"
                        width: col.width
                        height: on ? addLoader.height + 12 : 0
                        Loader {
                            id: addLoader
                            x: -10
                            y: 6
                            width: parent.width + 20
                            active: parent.on
                            sourceComponent: sheet.chooserComponent
                        }
                    }

                    Item { visible: sheet.available; width: 1; height: 12 }
                    Rectangle { visible: sheet.available; width: col.width; height: 1; color: Appearance.colors.colInkDivider }
                    Item { visible: sheet.available; width: 1; height: 12 }
                    StyledText {
                        visible: sheet.available
                        width: col.width
                        text: sheet.signedLine
                        wrapMode: Text.Wrap
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 13
                        color: Appearance.colors.colInkSecondary
                    }
                    Item {
                        id: linkRow
                        readonly property bool picked: sheet.picked("accounts", "")
                        visible: sheet.available
                        width: col.width
                        height: 26
                        onPickedChanged: if (linkRow.picked && sheet.byKeys) sheet.reveal(linkRow)
                        StyledText {
                            anchors { left: parent.left; right: link.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                            text: sheet.needLine
                            elide: Text.ElideRight
                            font.family: Appearance.font.family.compact
                            font.pixelSize: 13
                            color: Appearance.colors.colInkSecondary
                        }
                        Rectangle {
                            anchors { fill: link; leftMargin: -6; rightMargin: -6; topMargin: -2; bottomMargin: -2 }
                            radius: 8
                            color: linkRow.picked ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
                        }
                        Row {
                            id: link
                            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                            spacing: 3
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Accounts"
                                font.family: Appearance.font.family.compact
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                color: Appearance.colors.colPrimary
                            }
                            MaterialSymbol {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "open_in_new"
                                iconSize: 13
                                color: Appearance.colors.colPrimary
                            }
                        }
                        MouseArea {
                            anchors { fill: link; margins: -6 }
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: sheet.point(sheet.stopOf("accounts", ""))
                            onClicked: sheet.settingsRequested(sheet.needAnchor)
                        }
                    }
                }
            }
        }
    }

    // A level's sentence: connecting words in colInkSecondary, phrases kept here in colInkMain and
    // inherited ones in colInkFaint. Loaded with `scope` on the Loader.
    Component {
        id: sentenceComp
        Flow {
            id: flow
            readonly property string scope: parent ? parent.scope : ""
            spacing: Math.round(m15.advanceWidth(" "))
            Repeater {
                model: flow.scope ? sheet.tokensOf(flow.scope) : []
                delegate: Item {
                    id: tok
                    required property var modelData
                    readonly property bool isPhrase: !!tok.modelData.field
                    readonly property bool picked: tok.isPhrase && sheet.picked("phrase", flow.scope, tok.modelData.field)
                    width: word.implicitWidth + (tok.modelData.suffix ? suffix.implicitWidth : 0)
                    height: 22
                    onPickedChanged: if (tok.picked && sheet.byKeys) sheet.reveal(tok)
                    Rectangle {
                        visible: tok.picked
                        x: -4
                        width: word.implicitWidth + 8
                        height: parent.height
                        radius: Appearance.rounding.chip
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95)
                    }
                    StyledText {
                        id: word
                        anchors.verticalCenter: parent.verticalCenter
                        text: tok.modelData.text
                        textFormat: Text.PlainText
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 15
                        color: !tok.isPhrase ? Appearance.colors.colInkSecondary
                            : tok.modelData.kept ? Appearance.colors.colInkMain : Appearance.colors.colInkFaint
                    }
                    StyledText {
                        id: suffix
                        visible: !!tok.modelData.suffix
                        anchors { left: word.right; verticalCenter: parent.verticalCenter }
                        text: tok.modelData.suffix ?? ""
                        font.family: Appearance.font.family.compact
                        font.pixelSize: 15
                        color: Appearance.colors.colInkSecondary
                    }
                    MouseArea {
                        enabled: tok.isPhrase
                        anchors { fill: word; leftMargin: -4; rightMargin: -4 }
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: sheet.point(sheet.stopOf("phrase", flow.scope, tok.modelData.field))
                        onClicked: sheet.openChooser(flow.scope, tok.modelData.field)
                    }
                }
            }
        }
    }

    // a section's name: 12 Medium colInkMeta
    component Label12: StyledText {
        height: 18
        font.family: Appearance.font.family.compact
        font.pixelSize: 12
        font.weight: Font.Medium
        color: Appearance.colors.colInkMeta
    }
}
