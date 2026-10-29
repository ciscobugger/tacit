pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.modules.common
import qs.modules.common.functions

/**
 * The person's own keyboard shortcuts (Settings > Keyboard & touchpad > Shortcuts).
 *
 * What the shortcuts do, grouped and named, is the `groups` list below; its keys are the ones Tacit ships
 * (session/hypr/tacit/keybinds.lua and hyprland/keybinds.lua). What the person changed is one file,
 * ~/.config/hypr/hyprland/shellOverrides/shortcuts.lua, which hyprland.lua reads after Tacit's keys and the
 * person's own (tacit/shortcuts.lua). The file is data, and its first line after the header carries the same
 * state as JSON, so this service reads back exactly what it wrote. A change is saved, then Hyprland reloads its
 * config (`hyprctl reload`): no log out. A key is never taken from a shortcut without saying so first, and Undo
 * puts back the keys the change replaced.
 *
 * Combos are written "Super+Shift+S": modifiers in the order Super, Ctrl, Alt, Shift, then the key as Hyprland names it.
 */
Singleton {
    id: root

    readonly property string filePath: FileUtils.trimFileProtocol(`${Directories.config}/hypr/hyprland/shellOverrides/shortcuts.lua`)

    // ── what the shortcuts do ────────────────────────────────────────────────
    // fixed: Tacit keeps its keys (a family of numbers, the bare Super key): listed, not changed here.
    // does: how a clash names it ("Super E already opens Files."); use: the words after "Use it for".
    readonly property var groups: [
        { name: "Open an app", rows: [
            { id: "term", glyph: "terminal", name: "Terminal", use: "the Terminal", does: "opens the Terminal", keys: ["Super+Return", "Super+T"] },
            { id: "files", glyph: "folder", name: "Files", use: "Files", does: "opens Files", keys: ["Super+E"] },
            { id: "web", glyph: "globe", name: "Browser", use: "the Browser", does: "opens the Browser", keys: ["Super+W"] },
            { id: "code", glyph: "code", name: "Code editor", use: "the Code editor", does: "opens the Code editor", keys: ["Super+C"] },
            { id: "text", glyph: "edit_note", name: "Text editor", use: "the Text editor", does: "opens the Text editor", keys: ["Super+X"] },
            { id: "settings", glyph: "settings", name: "Settings", use: "Settings", does: "opens Settings", keys: ["Super+I"] } ] },
        { name: "Windows", rows: [
            { id: "close", glyph: "close", name: "Close the window", use: "closing a window", does: "closes the window", keys: ["Super+Q", "Alt+F4"] },
            { id: "full", glyph: "fullscreen", name: "Full screen", use: "full screen", does: "makes a window full screen", keys: ["Super+F"] },
            { id: "fill", glyph: "aspect_ratio", name: "Fill the screen", use: "filling the screen", does: "makes a window fill the screen", keys: ["Super+D"] },
            { id: "float", glyph: "window", name: "Float or tile", use: "floating or tiling", does: "floats or tiles a window", keys: ["Super+Alt+space"] },
            { id: "pin", glyph: "push_pin", name: "Keep on top", use: "keeping on top", does: "keeps a window on top", keys: ["Super+P"] } ] },
        { name: "Workspaces", rows: [
            { id: "over", glyph: "grid_view", name: "See all workspaces", use: "the workspaces view", does: "shows all workspaces", keys: ["Super+Tab"] },
            { id: "goto", glyph: "numbers", name: "Go to workspace 1 to 10", use: "workspaces", does: "goes to a workspace", keys: ["Super+1"], fixed: true },
            { id: "scratch", glyph: "layers", name: "Show the scratchpad", use: "the scratchpad", does: "shows the scratchpad", keys: ["Super+S"] } ] },
        { name: "Capture", rows: [
            { id: "shot", glyph: "screenshot_region", name: "Screenshot of an area", use: "screenshots", does: "takes a screenshot of an area", keys: ["Super+Shift+S"] },
            { id: "rec", glyph: "screen_record", name: "Record the screen", use: "recording", does: "records the screen", keys: ["Super+Shift+R"] },
            { id: "ocr", glyph: "document_scanner", name: "Copy text from the screen", use: "copying text", does: "copies text from the screen", keys: ["Super+Shift+X"] },
            { id: "pick", glyph: "colorize", name: "Pick a colour", use: "picking a colour", does: "picks a colour", keys: ["Super+Shift+C"] } ] },
        { name: "Tacit", rows: [
            { id: "palette", glyph: "search", name: "Palette", use: "the Palette", does: "opens the Palette", keys: ["Super"], fixed: true },
            { id: "notch", glyph: "notch", name: "Open the notch", use: "the notch", does: "opens the notch", keys: ["Super+space"] },
            { id: "ask", glyph: "assistant", name: "Ask your agent", use: "asking your agent", does: "asks your agent", keys: ["Super+Shift+space"] },
            { id: "clip", glyph: "content_paste", name: "Clipboard", use: "the Clipboard", does: "opens the Clipboard", keys: ["Super+V"] },
            { id: "emoji", glyph: "mood", name: "Emoji", use: "Emoji", does: "opens Emoji", keys: ["Super+period"] },
            { id: "panel", glyph: "tune", name: "Control panel", use: "the Control panel", does: "opens the Control panel", keys: ["Super+N"] },
            { id: "session", glyph: "power_settings_new", name: "Session menu", use: "the session menu", does: "opens the session menu", keys: ["Super+Escape"] },
            { id: "lock", glyph: "lock", name: "Lock the screen", use: "locking the screen", does: "locks the screen", keys: ["Super+L"] } ] }
    ]
    readonly property var rowIndex: {
        const m = {};
        for (const g of root.groups) for (const r of g.rows) m[r.id] = r;
        return m;
    }

    // ── what the person changed ──────────────────────────────────────────────
    property var changed: ({})     // row id -> its keys now (an empty list is "No shortcut")
    property var apps: []          // { name, run, keys } shortcuts the person added for an app
    property bool broken: false    // the file is there but its state could not be read

    // a row's key sets by place ("" where one was given to another shortcut), and as they are shown
    function slotsOf(id: string): var { return root.changed[id] ?? root.rowIndex[id]?.keys ?? []; }
    function keysOf(id: string): var { return root.slotsOf(id).filter(k => k !== ""); }
    function isChanged(id: string): bool { return root.changed[id] !== undefined; }
    function canChange(id: string): bool { const r = root.rowIndex[id]; return !!r && !r.fixed; }

    // ── key names ────────────────────────────────────────────────────────────
    readonly property var capNames: ({ "Return": "Enter", "Escape": "Esc", "period": ".", "comma": ",", "slash": "/", "minus": "-",
        "equal": "=", "semicolon": ";", "apostrophe": "'", "space": "Space", "grave": "`", "bracketleft": "[", "bracketright": "]",
        "backslash": "\\", "Page_Up": "Page up", "Page_Down": "Page down", "BackSpace": "Backspace", "Print": "Print screen" })
    function capName(part: string): string { return root.capNames[part] ?? (part.length === 1 ? part.toUpperCase() : part); }
    // "Super+Shift+S" -> the words a sentence says, "Super Shift S"
    function said(combo: string): string { return combo.split("+").map(root.capName).join(" "); }

    readonly property var modOrder: ["Super", "Ctrl", "Alt", "Shift"]
    function norm(combo: string): string {
        const parts = (combo ?? "").split("+").map(p => p.trim()).filter(p => p !== "");
        const mods = [];
        let key = "";
        for (const p of parts) {
            const m = root.modOrder.find(x => x.toLowerCase() === p.toLowerCase());
            if (m) { if (!mods.includes(m)) mods.push(m); }
            else key = p.toLowerCase();
        }
        mods.sort((a, b) => root.modOrder.indexOf(a) - root.modOrder.indexOf(b));
        return key === "" && mods.length === 1 ? mods[0].toLowerCase() : [...mods, key].join("+").toLowerCase();
    }
    // the same combination in the file's words: SUPER+SHIFT+S
    function forHypr(combo: string): string {
        return combo.split("+").map(p => root.modOrder.includes(p) ? p.toUpperCase() : p).join("+");
    }

    // ── capture: Qt's key to the key Hyprland calls it ───────────────────────
    readonly property var qtKeys: ({
        [Qt.Key_Return]: "Return", [Qt.Key_Enter]: "Return", [Qt.Key_Tab]: "Tab", [Qt.Key_Backtab]: "Tab", [Qt.Key_Space]: "space",
        [Qt.Key_Backspace]: "BackSpace", [Qt.Key_Delete]: "Delete", [Qt.Key_Insert]: "Insert", [Qt.Key_Home]: "Home", [Qt.Key_End]: "End",
        [Qt.Key_PageUp]: "Page_Up", [Qt.Key_PageDown]: "Page_Down", [Qt.Key_Left]: "Left", [Qt.Key_Right]: "Right", [Qt.Key_Up]: "Up",
        [Qt.Key_Down]: "Down", [Qt.Key_Print]: "Print", [Qt.Key_Comma]: "comma", [Qt.Key_Period]: "period", [Qt.Key_Slash]: "slash",
        [Qt.Key_Semicolon]: "semicolon", [Qt.Key_Apostrophe]: "apostrophe", [Qt.Key_BracketLeft]: "bracketleft",
        [Qt.Key_BracketRight]: "bracketright", [Qt.Key_Backslash]: "backslash", [Qt.Key_Minus]: "minus", [Qt.Key_Equal]: "equal",
        [Qt.Key_QuoteLeft]: "grave",
        // what Shift turns a key into: the key itself is what the shortcut is on
        [Qt.Key_Exclam]: "1", [Qt.Key_At]: "2", [Qt.Key_NumberSign]: "3", [Qt.Key_Dollar]: "4", [Qt.Key_Percent]: "5",
        [Qt.Key_AsciiCircum]: "6", [Qt.Key_Ampersand]: "7", [Qt.Key_Asterisk]: "8", [Qt.Key_ParenLeft]: "9", [Qt.Key_ParenRight]: "0",
        [Qt.Key_Underscore]: "minus", [Qt.Key_Plus]: "equal", [Qt.Key_BraceLeft]: "bracketleft", [Qt.Key_BraceRight]: "bracketright",
        [Qt.Key_Bar]: "backslash", [Qt.Key_Colon]: "semicolon", [Qt.Key_QuoteDbl]: "apostrophe", [Qt.Key_Less]: "comma",
        [Qt.Key_Greater]: "period", [Qt.Key_Question]: "slash", [Qt.Key_AsciiTilde]: "grave"
    })
    // The key name for a key event, or "" when it is only a modifier or is not a key a shortcut can be on.
    function keyName(key: int): string {
        if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key);
        if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key);
        if (key >= Qt.Key_F1 && key <= Qt.Key_F24) return `F${key - Qt.Key_F1 + 1}`;
        return root.qtKeys[key] ?? "";
    }
    // Modifiers held, as the words of a combo ("Super+Shift")
    function modsOf(mods: int): string {
        const out = [];
        if (mods & Qt.MetaModifier) out.push("Super");
        if (mods & Qt.ControlModifier) out.push("Ctrl");
        if (mods & Qt.AltModifier) out.push("Alt");
        if (mods & Qt.ShiftModifier) out.push("Shift");
        return out.join("+");
    }

    // What a pressed combination may be. A shortcut with no Super would take that key from every app (Ctrl+W), so
    // it needs Super; "" says it is fine.
    function problem(combo: string): string {
        if (!combo.split("+").includes("Super")) return "Use Super with another key, so no app loses a key it needs.";
        if (combo.split("+").length < 2) return "Add another key to Super.";
        return "";
    }

    // a command line for a desktop entry's command, quoted for the shell
    function quote(args: var): string { return args.map(a => `'${String(a).replace(/'/g, "'\\''")}'`).join(" "); }

    // ── clashes ──────────────────────────────────────────────────────────────
    // What already has these keys: { kind: "row", id, name, does } for a listed shortcut, { kind: "other", does } for a
    // shortcut Tacit keeps (read from the compositor), or null when they are free. `except` is the row being changed.
    function holder(combo: string, except: string): var {
        const n = root.norm(combo);
        for (const g of root.groups) for (const r of g.rows) {
            if (r.id === except) continue;
            if (root.keysOf(r.id).some(k => root.norm(k) === n)) return r.fixed ? { kind: "other", does: r.does } : { kind: "row", id: r.id, name: r.name, use: r.use, does: r.does };
        }
        for (let i = 0; i < root.apps.length; i++) {
            if (`app${i}` !== except && root.norm(root.apps[i].keys) === n) return { kind: "app", index: i, name: root.apps[i].name, use: root.apps[i].name, does: `opens ${root.apps[i].name}` };
        }
        // the row's own keys, shipped or current, are never "somebody else's" in a stale live list
        const own = (root.rowIndex[except]?.keys ?? []).concat(root.slotsOf(except)).map(root.norm);
        const other = own.includes(n) ? undefined : root.live.find(b => b.norm === n);
        if (other) return { kind: "other", does: other.does };
        return null;
    }

    // ── changing ─────────────────────────────────────────────────────────────
    property var undoState: null      // { id, what, before: { changed, apps } }

    function without(id: string, combo: string): var { return root.slotsOf(id).map(k => root.norm(k) === root.norm(combo) ? "" : k); }
    function snapshot(): var { return { changed: JSON.parse(JSON.stringify(root.changed)), apps: JSON.parse(JSON.stringify(root.apps)) }; }

    // `keys` replaces the first of a row's key sets and keeps the others ("Super+Return or Super+T")
    function setKeys(id: string, combo: string, takeFrom: var): void {
        const before = root.snapshot();
        const next = Object.assign({}, root.changed);
        if (takeFrom && takeFrom.kind === "row") next[takeFrom.id] = root.without(takeFrom.id, combo);
        const keys = root.slotsOf(id).slice();
        keys[0] = combo;
        next[id] = keys;
        // back to what Tacit ships: nothing to remember
        if (JSON.stringify(next[id]) === JSON.stringify(root.rowIndex[id].keys)) delete next[id];
        let apps = root.apps;
        if (takeFrom && takeFrom.kind === "app") apps = apps.filter((a, i) => i !== takeFrom.index);
        root.undoState = { id, before };
        root.save(next, apps);
    }
    // Who has the keys Tacit ships for a row, now that the row would take them back: [{ combo, holder }]
    function resetHolders(id: string): var {
        const out = [];
        const row = root.rowIndex[id];
        if (!row) return out;
        const mine = root.keysOf(id).map(root.norm);
        for (const k of row.keys) {
            if (mine.includes(root.norm(k))) continue;
            const h = root.holder(k, id);
            if (h && h.kind !== "other") out.push({ combo: k, holder: h });
        }
        return out;
    }
    // `takeFrom` is resetHolders(id): the keys go back to the row and are taken from whoever has them
    function resetRow(id: string, takeFrom: var): void {
        const before = root.snapshot();
        const next = Object.assign({}, root.changed);
        let apps = root.apps;
        const gone = [];
        for (const t of takeFrom ?? []) {
            if (t.holder.kind === "row") next[t.holder.id] = root.without(t.holder.id, t.combo);
            else if (t.holder.kind === "app") gone.push(t.holder.index);
        }
        if (gone.length) apps = apps.filter((a, i) => !gone.includes(i));
        delete next[id];
        root.undoState = { id, before };
        root.save(next, apps);
    }
    function addApp(name: string, run: string, icon: string, combo: string, takeFrom: var): void {
        const before = root.snapshot();
        const next = Object.assign({}, root.changed);
        if (takeFrom && takeFrom.kind === "row") next[takeFrom.id] = root.without(takeFrom.id, combo);
        root.undoState = { id: `app${root.apps.length}`, before };
        root.save(next, [...root.apps.filter(a => !(takeFrom && takeFrom.kind === "app" && a.name === takeFrom.name)), { name, run, icon, keys: combo }]);
    }
    // an added app's shortcut takes other keys
    function setAppKeys(index: int, combo: string, takeFrom: var): void {
        const before = root.snapshot();
        const next = Object.assign({}, root.changed);
        if (takeFrom && takeFrom.kind === "row") next[takeFrom.id] = root.without(takeFrom.id, combo);
        let apps = root.apps.map((a, i) => i === index ? Object.assign({}, a, { keys: combo }) : a);
        if (takeFrom && takeFrom.kind === "app") apps = apps.filter((a, i) => i !== takeFrom.index);
        root.undoState = { id: `app${index}`, before };
        root.save(next, apps);
    }
    function removeApp(index: int): void {
        root.undoState = null;
        root.save(root.changed, root.apps.filter((a, i) => i !== index));
    }
    function undo(): void {
        if (!root.undoState) return;
        const b = root.undoState.before;
        root.undoState = null;
        root.save(b.changed, b.apps);
    }

    // ── the file ─────────────────────────────────────────────────────────────
    function luaString(s: string): string {
        return `"${String(s).replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, " ")}"`;
    }
    // What Hyprland has to do: move what is on a shipped key to the new one ("" = no keys), for every key set that differs.
    function moves(changed: var): var {
        const out = [];
        for (const id of Object.keys(changed)) {
            const row = root.rowIndex[id];
            if (!row || row.fixed) continue;
            const now = changed[id];
            for (let i = 0; i < row.keys.length; i++) {
                if ((now[i] ?? "") !== row.keys[i]) out.push([row.keys[i], now[i] ?? ""]);
            }
        }
        return out;
    }
    function fileText(changed: var, apps: var): string {
        const mv = root.moves(changed).map(m => `{ ${root.luaString(root.forHypr(m[0]))}, ${root.luaString(m[1] === "" ? "" : root.forHypr(m[1]))} }`);
        const ap = apps.map(a => `{ name = ${root.luaString(a.name)}, run = ${root.luaString(a.run)}, keys = ${root.luaString(root.forHypr(a.keys))} }`);
        return "-- Written by Settings > Keyboard & touchpad > Shortcuts. Change shortcuts there; this file is rewritten.\n"
            + `-- state ${JSON.stringify({ changed, apps })}\n`
            + `return {\n  moves = { ${mv.join(", ")} },\n  apps = { ${ap.join(", ")} },\n}\n`;
    }
    function save(changed: var, apps: var): void {
        root.changed = changed;
        root.apps = apps;
        file.setText(root.fileText(changed, apps));
        reloadTimer.restart();
    }

    FileView {
        id: file
        path: root.filePath
        printErrors: false
        watchChanges: true
        onFileChanged: file.reload()
        onLoaded: {
            const m = file.text().match(/^-- state (.*)$/m);
            let s = null;
            try { s = m ? JSON.parse(m[1]) : null; } catch (e) { s = null; }
            root.broken = m === null && file.text().trim() !== "";
            root.changed = s?.changed ?? {};
            root.apps = s?.apps ?? [];
        }
        onLoadFailed: { root.changed = {}; root.apps = []; }
    }

    // Hyprland reads the Lua config at load, so a saved change is loaded by reloading it; a dragged-out run of changes
    // settles into one reload
    Timer {
        id: reloadTimer
        interval: 250
        onTriggered: { Quickshell.execDetached(["hyprctl", "reload"]); liveTimer.restart(); }
    }

    // ── the keys the compositor holds now, to say what a new key would take ──
    property var live: []
    Timer { id: liveTimer; interval: 900; onTriggered: root.readLive() }
    function readLive(): void { liveProc.running = true; }
    Process {
        id: liveProc
        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const bits = [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"]];
                    const out = [];
                    for (const b of JSON.parse(text)) {
                        if ((b.submap ?? "") !== "" || b.mouse || b.release || b.catchall || !b.key) continue;
                        const mods = bits.filter(x => b.modmask & x[0]).map(x => x[1]);
                        const key = b.key.startsWith("code:") || b.key.startsWith("mouse") ? "" : b.key;
                        if (key === "") continue;
                        const desc = (b.description ?? "").replace(/^[^:]*:\s*/, "");
                        out.push({ norm: root.norm([...mods, key].join("+")),
                                   does: desc !== "" ? `is used for "${desc}"` : "is used by Tacit" });
                    }
                    root.live = out;
                } catch (e) {}
            }
        }
    }

    // ── listening for keys ───────────────────────────────────────────────────
    // While a row listens, the compositor's own shortcuts are off (the "tacit-capture" submap, which Esc and a timer also
    // leave), so the keys pressed reach this window instead of being run.
    property bool listening: false
    function listen(on: bool): void {
        if (root.listening === on) return;
        root.listening = on;
        Hyprland.dispatch(`hl.dsp.submap("${on ? "tacit-capture" : "reset"}")`);
    }

    Component.onCompleted: root.readLive()
}
