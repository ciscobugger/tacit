import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import org.kde.syntaxhighlighting
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import "Engine.js" as Engine
import qs.modules.claude as Praxis
import Tacit.Edit

/**
 * One open file. A file with no change is plain editing. A changed file (M, U)
 * opens as it was before the change, and each key typed brings the change back
 * one character at a time (Engine.js): Backspace and Ctrl+Z take one back, keys
 * that would edit behind it do nothing. Until the last character is in, saving is
 * refused and the status line says why; the file on disk is never overwritten with
 * half a change, and Esc drops the change and shows the file as it is on disk. If
 * the file changes on disk meanwhile, the new version is typed next.
 */
Item {
    id: doc

    required property string rel
    required property string abs
    property var project
    property string status: ""
    property bool active: false
    property bool watchOnOpen: false   // f in the tree: watch the change type itself

    property var session: null
    property bool held: false          // typing session in progress (keys belong to it)
    property bool watching: false      // typing by itself at a person's pace
    property real cps: 6
    property bool dirty: false
    property bool loaded: false
    property bool selfWrite: false
    property string lastDisk: ""
    property string savingText: ""
    property string pendingDisk: ""     // a newer version on disk the buffer has not taken yet
    property bool conflicted: false     // that version arrived while there were unsaved edits
    property bool missing: false        // the file is gone from disk
    property string problem: ""         // nothing to edit here: too large, or not text
    // The editor holds every line ending as "\n" (TextEdit drops "\r"); a file that came with "\r\n" is written back
    // with them, so saving one no longer rewrote every line. lastDisk and savingText are kept in "\n" as well.
    property string eol: "\n"
    function fromDisk(t) {
        if (t.includes("\r\n")) doc.eol = "\r\n";
        return t.includes("\r") ? t.replace(/\r\n?/g, "\n") : t;
    }
    // What Tab puts in: the file's own indentation (a tab, or its width in spaces), found when it opens.
    property string indentUnit: "    "
    readonly property int indentWidth: doc.indentUnit === "\t" ? 4 : doc.indentUnit.length
    readonly property string indentName: doc.indentUnit === "\t" ? "Tabs" : `${doc.indentUnit.length} spaces`
    function detectIndent(t) {
        const base = doc.rel.split("/").pop();
        if (/^(GNUmakefile|[Mm]akefile)$|\.mk$/.test(base)) return "\t";   // make needs tabs
        let tabs = 0, spaced = 0, prev = 0;
        const widths = {};
        const lines = t.split("\n", 4000);
        for (const l of lines) {
            if (!l.trim().length) continue;
            if (l.charAt(0) === "\t") { tabs++; continue; }
            const n = /^ */.exec(l)[0].length;
            if (n > 0) spaced++;
            // the step from one line to a deeper one is the unit; a lone space before a block comment's "*" is not
            if (n > prev && n - prev <= 8 && !(n - prev === 1 && l.charAt(n) === "*")) widths[n - prev] = (widths[n - prev] || 0) + 1;
            prev = n;
        }
        if (tabs > spaced) return "\t";
        let best = 4, count = 0;
        for (const w in widths) if (widths[w] > count) { best = Number(w); count = widths[w]; }
        return " ".repeat(best);
    }
    // Any number of changes as one step of undo (Tacit.Edit): [[start, end, text], ...] in current offsets.
    function edit(pieces) { Edit.apply(area.textDocument, pieces); }
    // area.text once per change: the line arithmetic below reads this instead, because every
    // read of area.text re-serialises the whole document.
    property string cached: ""
    // with lines wrapped a visual row is not a line, so the line is counted from the text (prose files are small)
    readonly property int line: doc.wrap ? (doc.cached.substring(0, area.cursorPosition).match(/\n/g) || []).length + 1
        : Math.round(area.cursorRectangle.y / doc.lineHeight) + 1
    readonly property int column: {
        const p = area.cursorPosition;
        return p - (p > 0 ? doc.cached.lastIndexOf("\n", p - 1) : -1);
    }
    readonly property string language: (highlighter.definition && highlighter.definition.name) || ""
    // Prose (Markdown, plain text) wraps at the window's edge and types quotes as typed; code keeps long lines and
    // closes what it opens. Alt+Z turns wrapping either way for this file.
    readonly property bool prose: /\.(md|markdown|txt|rst|adoc)$/i.test(doc.rel) || doc.language === "Markdown"
    property var wrapSet: null
    readonly property bool wrap: doc.wrapSet === null ? doc.prose : doc.wrapSet
    property int fontSize: 15
    signal menuAt(real x, real y)        // a right click in the text: the window draws the menu

    // ── language smarts (LspClient.qml): problems underlined, where a name is defined, what could go here ──
    // A file whose language has no server installed is plain text, with nothing missing on screen.
    property var lsp: null
    property bool announced: false
    property string announcedPath: ""
    property int layoutTick: 0            // the text moved: the underlines and the list re-measure
    signal openAt(string path, int line, int character)
    function announce() {
        if (!doc.lsp || doc.announced || !doc.loaded || doc.session || doc.problem.length || !doc.lsp.speaks(doc.abs)) return;
        doc.lsp.opened(doc.abs, doc.cached);
        doc.announced = true;
        doc.announcedPath = doc.abs;
    }
    Connections { target: doc.lsp; function onServersKnown() { doc.announce(); } }
    Timer { id: lspLater; interval: 250; onTriggered: { if (doc.announced) doc.lsp.changed(doc.abs, doc.cached); else doc.announce(); } }
    onAbsChanged: if (doc.announced) { doc.lsp.closed(doc.announcedPath); doc.announced = false; doc.announce(); }
    Component.onDestruction: if (doc.announced && doc.lsp) doc.lsp.closed(doc.announcedPath)

    readonly property var diags: {
        if (!doc.lsp || !doc.announced) return [];
        doc.lsp.problemsTick;
        return (doc.lsp.problems[doc.abs] ?? []).filter(d => (d.severity ?? 1) <= 2)
            .sort((a, b) => a.range.start.line - b.range.start.line || a.range.start.character - b.range.start.character);
    }
    function offsetOf(line, ch) { return Math.min(doc.cached.length, Engine.lineStart(doc.cached, line) + ch); }
    function posOf(offset) {
        const before = doc.cached.substring(0, offset);
        return { line: (before.match(/\n/g) || []).length, character: offset - (before.lastIndexOf("\n") + 1) };
    }
    function cleanMessage(m) { return String(m).split("\n")[0].replace(/\s*\[[\w-]+\]$/, "").replace(/\.: /, ": "); }
    readonly property var diagHere: doc.diags.find(d => d.range.start.line <= doc.line - 1 && d.range.end.line >= doc.line - 1) ?? null
    readonly property string diagLine: doc.diagHere ? `${doc.cleanMessage(doc.diagHere.message)} · line ${doc.diagHere.range.start.line + 1}`
        : doc.diags.length ? Voice.count(doc.diags.length, "problem") : ""
    readonly property bool diagIsError: doc.diagHere ? (doc.diagHere.severity ?? 1) === 1 : doc.diags.some(d => (d.severity ?? 1) === 1)
    // F8 the next problem, Shift+F8 the one before
    function nextProblem(back) {
        if (!doc.diags.length) return;
        const at = area.cursorPosition;
        const offs = doc.diags.map(d => doc.offsetOf(d.range.start.line, d.range.start.character));
        let i = -1;
        if (back) { for (let k = offs.length - 1; k >= 0; k--) if (offs[k] < at) { i = k; break; } }
        else i = offs.findIndex(o => o > at);
        if (i < 0) i = back ? offs.length - 1 : 0;
        area.cursorPosition = offs[i];
        flick.ensureVisible(area.cursorRectangle);
    }
    // F12 or Ctrl+click: where the name under it is defined
    function goDefinition(offset) {
        if (!doc.announced) return;
        const p = doc.posOf(offset);
        doc.lsp.definition(doc.abs, p.line, p.character, loc => { if (loc) doc.openAt(loc.path, loc.line, loc.character); });
    }
    function goToLineCol(line, ch) {      // 0-based, as a server says it
        if (!doc.loaded) { doc.pendingLine = line + 1; return; }
        area.cursorPosition = doc.offsetOf(line, ch);
        flick.contentY = Math.max(0, area.cursorRectangle.y - flick.height / 3);
        doc.focusEditor();
    }

    // what could go here: a list under the word being typed (two letters in, after a ".", or Ctrl+Space)
    property var compItems: []
    property var compShown: []
    property int compStart: -1
    property int compAt: 0
    readonly property bool completing: doc.compShown.length > 0
    Timer { id: compLater; interval: 140; onTriggered: doc.maybeComplete(false) }
    function wordStartAt(pos) { let w = pos; const t = doc.cached; while (w > 0 && /[\w$]/.test(t.charAt(w - 1))) w--; return w; }
    function maybeComplete(force) {
        if (!doc.announced || doc.held) return;
        const pos = area.cursorPosition, ws = doc.wordStartAt(pos), prefix = doc.cached.substring(ws, pos);
        const afterDot = ws > 0 && doc.cached.charAt(ws - 1) === ".";
        if (!force && prefix.length < 2 && !afterDot) { doc.hideCompletion(); return; }
        const p = doc.posOf(pos);
        doc.lsp.complete(doc.abs, p.line, p.character, items => {
            if (doc.wordStartAt(area.cursorPosition) !== ws || area.cursorPosition < ws) return;   // the cursor moved on
            doc.compItems = items;
            doc.compStart = ws;
            doc.compAt = 0;
            doc.filterCompletion();
        });
    }
    function filterCompletion() {
        if (doc.compStart < 0) return;
        const pos = area.cursorPosition;
        if (pos < doc.compStart) { doc.hideCompletion(); return; }
        const typed = doc.cached.substring(doc.compStart, pos), pre = typed.toLowerCase();
        const key = it => String(it.filterText ?? it.label).trim().toLowerCase();
        const by = (a, b) => String(a.sortText ?? a.label).localeCompare(String(b.sortText ?? b.label));
        const starts = doc.compItems.filter(it => key(it).startsWith(pre)).sort(by);
        const inside = pre.length ? doc.compItems.filter(it => !key(it).startsWith(pre) && key(it).includes(pre)).sort(by) : [];
        // a language's own insides (__proto__, _q_...) only when a "_" asks for them
        const list = starts.concat(inside).filter(it => pre.startsWith("_") || !/^_/.test(String(it.label).trim())).slice(0, 60);
        // the word already typed in full says nothing new
        doc.compShown = list.length === 1 && String(list[0].label).trim() === typed ? [] : list;
        doc.compAt = Math.min(doc.compAt, Math.max(0, doc.compShown.length - 1));
    }
    function hideCompletion() { if (doc.compStart >= 0 || doc.compShown.length) { doc.compShown = []; doc.compItems = []; doc.compStart = -1; } }
    function acceptCompletion() {
        const it = doc.compShown[doc.compAt];
        if (!it) return;
        let t = String(it.textEdit?.newText ?? it.insertText ?? it.label);
        if (it.insertTextFormat === 2) t = t.replace(/\$\{\d+:([^}]*)\}/g, "$1").replace(/\$\{\d+\}|\$\d+/g, "");
        const st = doc.compStart, en = area.cursorPosition;
        doc.hideCompletion();
        doc.edit([[st, en, t]]);
        area.cursorPosition = st + t.length;
    }
    readonly property string selection: area.selectedText   // what Ctrl+F starts from

    signal closedByUser()
    signal typedOut()                   // the whole change is in: from now on the file counts as written
    signal conflict()                   // the file changed on disk under unsaved edits
    signal writeFailed(string reason)
    signal missingOnSave()              // asked to save a file that is no longer there
    signal edited()                     // the text changed: the window keeps unsaved work aside

    // ── for the window's session and its keeping of unsaved work ────────────
    function text() { return doc.cached; }
    function cursorPos() { return area.cursorPosition; }
    function scrollY() { return flick.contentY; }
    function restoreView(c, y) {
        area.cursorPosition = Math.min(c, area.length);
        Qt.callLater(() => flick.contentY = Math.max(-flick.topMargin, Math.min(y, flick.contentHeight - flick.height / 2)));
    }
    // changes kept from before the window last closed, as one step of undo; nothing if they match the disk
    function takeKept(t) {
        if (doc.problem.length || doc.session || t === doc.cached) return;
        doc.edit([[0, area.length, t]]);
    }

    // ── the diff gutter: what changed against the project's base ────────────
    // line -> "a" added, "m" changed, "d" lines deleted after it; the tree's colours (new =
    // primary, changed = tertiary, deleted = error). Not while typing: the typing is the diff.
    property var marks: ({})
    property bool marksAgain: false
    function refreshMarks() { marksLater.restart(); }
    Timer {
        id: marksLater
        interval: 300
        onTriggered: {
            if (doc.session || doc.problem.length || !doc.project || !doc.project.root.length || !doc.project.repo) { doc.marks = {}; return; }
            if ((doc.project.changes[doc.rel] || "") === "U") {
                const all = {};
                for (let i = 1; i <= area.lineCount; i++) all[i] = "a";
                doc.marks = all;
                return;
            }
            if (diffProc.running) { doc.marksAgain = true; return; }
            diffProc.running = true;
        }
    }
    Process {
        id: diffProc
        onExited: if (doc.marksAgain) { doc.marksAgain = false; marksLater.restart(); }
        command: ["git", "-C", doc.project ? doc.project.root : "", "diff", "--no-color", "-U0", doc.project ? doc.project.base : "HEAD", "--", doc.rel]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                for (const l of this.text.split("\n")) {
                    const h = /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(l);
                    if (!h) continue;
                    const oldN = h[1] === undefined ? 1 : Number(h[1]);
                    const start = Number(h[2]);
                    const newN = h[3] === undefined ? 1 : Number(h[3]);
                    if (newN === 0) m[Math.max(1, start)] = "d";
                    else for (let i = start; i < start + newN; i++) m[i] = oldN === 0 ? "a" : "m";
                }
                doc.marks = m;
            }
        }
    }

    // With nothing to edit, the keyboard stays where it was rather than going nowhere.
    function focusEditor() { if (!doc.problem.length) area.forceActiveFocus(); }
    function snapshot() { return { rel: doc.rel, cursor: area.cursorPosition, held: doc.held, dirty: doc.dirty,
        complete: doc.session ? doc.session.complete() : true, loaded: doc.loaded, line: doc.line,
        problem: doc.problem, missing: doc.missing, conflicted: doc.conflicted, indent: doc.indentName, eol: doc.eol === "\r\n" ? "crlf" : "lf" }; }
    function undo() { area.undo(); }
    function selectRange(a, b) { area.select(a, b); }
    function bench(n) {                                    // n single-letter inserts at the cursor, in ms: the per-key cost
        const t0 = Date.now();
        for (let i = 0; i < n; i++) area.insert(area.cursorPosition, "x");
        return Date.now() - t0;
    }
    function typeKey(t) {                                  // a printable key or "BS" (Backspace), for scripted checks
        const bs = t === "BS";
        if (doc.pairKey(bs ? Qt.Key_Backspace : 0, bs ? "" : t)) return;
        const a = Math.min(area.selectionStart, area.selectionEnd), b = Math.max(area.selectionStart, area.selectionEnd);
        if (bs) { if (a === b && a > 0) area.remove(a - 1, a); else area.remove(a, b); }
        else { area.remove(a, b); area.insert(a, t); }
    }

    // Put the cursor on line n (1-based); remembered until the file has loaded.
    property int pendingLine: 0
    function goToLine(n) {
        if (!doc.loaded) { doc.pendingLine = n; return; }
        area.cursorPosition = Math.min(Engine.lineStart(area.text, Math.max(0, n - 1)), area.length);
        flick.contentY = Math.max(0, area.cursorRectangle.y - flick.height / 3);
    }
    onLoadedChanged: if (doc.loaded && doc.pendingLine > 0) { const n = doc.pendingLine; doc.pendingLine = 0; doc.goToLine(n); }

    // ── the typing ────────────────────────────────────────────────────────────
    readonly property var api: ({
        text: () => area.text,
        insert: (pos, s) => area.insert(pos, s),
        remove: (a, b) => area.remove(a, b),
    })

    function place() {
        if (!doc.session) return;
        area.cursorPosition = Math.min(doc.session.pos, area.length);
    }

    function step() {
        if (!doc.session) return null;
        const c = doc.session.step();
        doc.place(); doc.dirty = true;
        return c;
    }

    function untype() {
        if (doc.session && doc.session.untype()) { doc.place(); doc.dirty = true; }
    }

    function startTyping(before, after, watch) {
        area.text = Engine.norm(before);
        doc.session = Engine.Session(doc.api, before, after);
        doc.held = true; doc.watching = !!watch; doc.dirty = false;
        const first = doc.session.hunks[0];
        area.cursorPosition = first ? Engine.lineStart(area.text, first.row) : 0;
        if (doc.watching) watchTimer.start();
    }

    // Once every character is in, the next Esc or click away hands the file back to
    // plain editing; until then extra keys type nothing.
    function release() {
        if (doc.session && doc.session.complete()) {
            doc.session = null; doc.held = false; doc.watching = false;
            doc.dirty = doc.cached !== doc.lastDisk;   // typed out in full, it is the file on disk: nothing unsaved
            doc.typedOut();
            doc.refreshMarks();
            doc.announce();
        }
    }

    // Esc on a half-typed change, or turning typing off: drop the change and show the
    // file as it is on disk, which is the version an agent already wrote.
    function abandon() {
        if (!doc.session) return;
        watchTimer.stop();
        doc.session = null; doc.held = false; doc.watching = false;
        area.text = doc.lastDisk;
        area.cursorPosition = 0;
        doc.dirty = false;
        doc.refreshMarks();
    }

    function reasonFor(err) {
        if (err == FileViewError.PermissionDenied) return "no permission to write it";
        if (err == FileViewError.FileNotFound) return "its folder is gone";
        if (err == FileViewError.NotAFile) return "that path is not a file";
        return "the write failed";
    }

    // True only once the write is confirmed: the close and quit prompts hang off this.
    function save(force) {
        if (doc.problem.length || (doc.session && !doc.session.complete()) || doc.conflicted) return false;
        if (doc.missing && !force) { doc.missingOnSave(); return false; }
        doc.selfWrite = true;
        doc.savingText = area.text;
        disk.setText(doc.eol === "\r\n" ? doc.savingText.replace(/\n/g, "\r\n") : doc.savingText);
        return !doc.dirty;
    }

    // ── line commands: comment, duplicate, move, Home ────────────────────────
    // the whole lines the selection (or the cursor) is on: [start of the first, end of the last without its "\n"]
    function lineSpan() {
        const t = doc.cached;
        const a = Math.min(area.selectionStart, area.selectionEnd);
        let b = Math.max(area.selectionStart, area.selectionEnd);
        if (b > a && t.charAt(b - 1) === "\n") b--;     // a selection ending at a line's start leaves that line out
        const s = a > 0 ? t.lastIndexOf("\n", a - 1) + 1 : 0;
        let e = t.indexOf("\n", b);
        return [s, e < 0 ? t.length : e];
    }
    function toggleComment() {
        if (doc.held || doc.problem.length) return;
        const m = Edit.commentMarkers(doc.language);
        const t = doc.cached, span = doc.lineSpan(), s = span[0], e = span[1];
        const a = Math.min(area.selectionStart, area.selectionEnd), b = Math.max(area.selectionStart, area.selectionEnd), cur = area.cursorPosition;
        if (m[0].length) {
            const lines = t.substring(s, e).split("\n"), mk = m[0];
            const body = lines.filter(l => l.trim().length);
            if (!body.length) return;
            const off = body.every(l => l.replace(/^\s+/, "").startsWith(mk));
            const col = Math.min(...body.map(l => /^[ \t]*/.exec(l)[0].length));
            const pieces = [];
            let at = s, total = 0, first = null;
            for (const l of lines) {
                if (l.trim().length) {
                    if (off) {
                        const i = l.indexOf(mk), n = mk.length + (l.charAt(i + mk.length) === " " ? 1 : 0);
                        pieces.push([at + i, at + i + n, ""]); total -= n;
                        if (first === null) first = { at: at + i, d: -n };
                    } else {
                        pieces.push([at + col, at + col, mk + " "]); total += mk.length + 1;
                        if (first === null) first = { at: at + col, d: mk.length + 1 };
                    }
                }
                at += l.length + 1;
            }
            doc.edit(pieces);
            if (a !== b) area.select(s, e + total);
            else area.cursorPosition = cur < first.at ? cur : Math.max(first.at, cur + first.d);
            return;
        }
        if (!m[1].length) return;                       // a language with no comments at all
        // only block comments (CSS, HTML, Markdown): around the selection, or around the line's text
        let from = a, to = b;
        if (a === b) { from = s + /^[ \t]*/.exec(t.substring(s, e))[0].length; to = e; }
        const inner = t.substring(from, to), open = m[1], close = m[2];
        if (inner.replace(/^\s+/, "").startsWith(open) && inner.replace(/\s+$/, "").endsWith(close)) {
            const i = from + inner.indexOf(open), j = from + inner.lastIndexOf(close);
            const o = open.length + (t.charAt(i + open.length) === " " ? 1 : 0), c = close.length + (t.charAt(j - 1) === " " ? 1 : 0);
            doc.edit([[i, i + o, ""], [j + close.length - c, j + close.length, ""]]);
        } else doc.edit([[from, from, open + " "], [to, to, " " + close]]);
    }
    function duplicateLines() {
        if (doc.held || doc.problem.length) return;
        const span = doc.lineSpan(), block = doc.cached.substring(span[0], span[1]);
        const a = area.selectionStart, b = area.selectionEnd, d = block.length + 1;
        doc.edit([[span[1], span[1], "\n" + block]]);
        area.select(a + d, b + d);                       // onto the copy, as the next line to work on
    }
    function moveLines(up) {
        if (doc.held || doc.problem.length) return;
        const t = doc.cached, span = doc.lineSpan(), s = span[0], e = span[1], block = t.substring(s, e);
        const a = area.selectionStart, b = area.selectionEnd;
        if (up) {
            if (s === 0) return;
            const ps = s >= 2 ? t.lastIndexOf("\n", s - 2) + 1 : 0, prev = t.substring(ps, s - 1);
            doc.edit([[ps, e, block + "\n" + prev]]);
            area.select(a - prev.length - 1, b - prev.length - 1);
        } else {
            if (e >= t.length) return;
            let ne = t.indexOf("\n", e + 1);
            if (ne < 0) ne = t.length;
            const next = t.substring(e + 1, ne);
            doc.edit([[s, ne, next + "\n" + block]]);
            area.select(a + next.length + 1, b + next.length + 1);
        }
    }
    // Home goes to the line's first letter, and from there to its very start
    function home(extend) {
        const t = doc.cached, p = area.cursorPosition;
        const s = p > 0 ? t.lastIndexOf("\n", p - 1) + 1 : 0;
        let e = t.indexOf("\n", s);
        if (e < 0) e = t.length;
        const first = s + /^[ \t]*/.exec(t.substring(s, e))[0].length;
        const target = p === first ? s : first;
        if (extend) area.moveCursorSelection(target, TextEdit.SelectCharacters);
        else area.cursorPosition = target;
    }
    function cut() { area.cut(); }
    function copy() { area.copy(); }
    function paste() { area.paste(); }
    function selectAll() { area.selectAll(); }
    readonly property bool hasSelection: area.selectionStart !== area.selectionEnd

    // ── find and replace in this file ────────────────────────────────────────
    // Every hit comes off doc.cached; the edits go through the TextEdit so they land on
    // its undo stack.
    function matchAt(text, needle, from, cs) {
        return cs ? text.indexOf(needle, from) : text.toLowerCase().indexOf(needle.toLowerCase(), from);
    }
    function matchBefore(text, needle, before, cs) {
        if (before <= 0) return -1;
        return cs ? text.lastIndexOf(needle, before - 1) : text.toLowerCase().lastIndexOf(needle.toLowerCase(), before - 1);
    }
    function matchCount(needle, cs) {
        if (!needle.length || doc.problem.length) return 0;
        let n = 0, i = 0;
        for (;;) {
            const at = doc.matchAt(doc.cached, needle, i, cs);
            if (at < 0) return n;
            n++; i = at + needle.length;
        }
    }
    function findNext(needle, back, cs) {
        if (!needle.length || doc.problem.length) return false;
        const text = doc.cached;
        let at;
        if (back) {
            at = doc.matchBefore(text, needle, Math.min(area.selectionStart, area.selectionEnd), cs);
            if (at < 0) at = doc.matchBefore(text, needle, text.length, cs);   // round to the end
        } else {
            at = doc.matchAt(text, needle, Math.max(area.selectionStart, area.selectionEnd), cs);
            if (at < 0) at = doc.matchAt(text, needle, 0, cs);                 // round to the start
        }
        if (at < 0) return false;
        area.select(at, at + needle.length);
        flick.ensureVisible(area.cursorRectangle);
        return true;
    }
    function replaceCurrent(needle, with_, cs) {
        if (!needle.length || doc.held || doc.problem.length) return false;
        const a = Math.min(area.selectionStart, area.selectionEnd), b = Math.max(area.selectionStart, area.selectionEnd);
        const sel = doc.cached.substring(a, b);
        if (cs ? sel !== needle : sel.toLowerCase() !== needle.toLowerCase()) return doc.findNext(needle, false, cs);
        doc.edit([[a, b, with_]]);
        area.cursorPosition = a + with_.length;
        doc.findNext(needle, false, cs);
        return true;
    }
    function replaceAll(needle, with_, cs) {
        if (!needle.length || doc.held || doc.problem.length) return 0;
        const text = doc.cached, hits = [];
        let i = 0;
        for (;;) {
            const at = doc.matchAt(text, needle, i, cs);
            if (at < 0) break;
            hits.push([at, at + needle.length, with_]); i = at + needle.length;
        }
        doc.edit(hits);       // every replacement is one Ctrl+Z
        return hits.length;
    }

    // ── indent and outdent every line the selection covers ───────────────────
    function shift(out) {
        const text = doc.cached;
        const from = Math.min(area.selectionStart, area.selectionEnd), to = Math.max(area.selectionStart, area.selectionEnd);
        const first = from > 0 ? text.lastIndexOf("\n", from - 1) + 1 : 0;
        const starts = [first];
        for (let p = first; ;) {
            const nl = text.indexOf("\n", p);
            if (nl < 0 || nl + 1 >= to) break;
            p = nl + 1; starts.push(p);
        }
        let head = 0, total = 0;
        const pieces = [];
        for (let i = starts.length - 1; i >= 0; i--) {
            const at = starts[i];
            let d = doc.indentUnit.length;
            if (out) {
                d = 0;
                if (text.charAt(at) === "\t") d = 1;
                else while (d < doc.indentWidth && text.charAt(at + d) === " ") d++;
                if (d === 0) continue;
                pieces.push([at, at + d, ""]);
                d = -d;
            } else pieces.push([at, at, doc.indentUnit]);
            total += d;
            if (i === 0) head = d;
        }
        doc.edit(pieces);     // the whole block moves in one step of undo
        area.select(Math.max(first, from + head), to + total);
    }

    Timer {
        id: watchTimer
        repeat: false
        onTriggered: {
            if (!doc.watching || !doc.session) return;
            const c = doc.step();
            if (c === null) { doc.watching = false; return; }
            interval = Engine.pause(doc.cps, c);
            start();
        }
    }

    // ── the file on disk ────────────────────────────────────────────────────
    // The shell's pattern (services/Journal.qml): a change on disk asks for a reload,
    // and the new text is read once it has loaded. The first load is the open itself.
    property bool started: false
    FileView {
        id: disk
        path: doc.abs
        blockLoading: true
        blockWrites: true              // save() answers for the write, so its outcome must be in
        watchChanges: true
        onFileChanged: reload()
        onLoaded: { doc.missing = false; if (doc.started) doc.diskChanged(disk.text()); }
        // only a vanished file is news; a read that failed while something rewrote the file is not
        onLoadFailed: err => { if (err == FileViewError.FileNotFound) doc.missing = true; }
        onSaved: {
            doc.lastDisk = doc.savingText;
            doc.dirty = doc.cached !== doc.lastDisk;
            doc.missing = false;
            doc.refreshMarks();
            doc.edited();
            if (doc.announced) doc.lsp.saved(doc.abs);
        }
        onSaveFailed: err => { doc.selfWrite = false; doc.writeFailed(doc.reasonFor(err)); }
    }
    function diskChanged(t) {
        t = doc.fromDisk(t);
        if (doc.selfWrite) { doc.selfWrite = false; doc.lastDisk = t; return; }
        if (t === doc.lastDisk) return;
        if (doc.session) { doc.lastDisk = t; doc.session.feed(t); if (doc.watching && !watchTimer.running) watchTimer.start(); }
        else if (doc.dirty) {
            // Unsaved edits here and a newer version there: lastDisk stays the baseline the
            // buffer was edited from, so the answer can still go either way.
            doc.pendingDisk = t; doc.conflicted = true; doc.conflict();
            return;
        } else { doc.lastDisk = t; doc.applyDisk(t); }
        doc.refreshMarks();
    }
    // The new content as edits rather than a replacement: setting TextEdit.text clears the
    // undo stack and drops the scroll position and the selection.
    function applyDisk(t) {
        const before = doc.cached;
        if (Engine.norm(before) !== before || Engine.norm(t) !== t) { area.text = t; return; }
        const hs = Engine.hunks(before, t);
        if (hs.length === 0) return;
        const y = flick.contentY, p = area.cursorPosition, a = area.selectionStart, b = area.selectionEnd;
        // one step of undo: Ctrl+Z after a reload takes the whole new version back
        doc.edit(hs.map(k => [Engine.lineStart(before, k.row), Engine.lineStart(before, k.row + k.del), k.add > 0 ? k.text + "\n" : ""]));
        if (a !== b) area.select(Math.min(a, area.length), Math.min(b, area.length));
        else area.cursorPosition = Math.min(p, area.length);
        flick.contentY = y;
    }
    function reloadFromDisk() {
        doc.lastDisk = doc.pendingDisk; doc.pendingDisk = ""; doc.conflicted = false;
        doc.applyDisk(doc.lastDisk);
        doc.dirty = doc.cached !== doc.lastDisk;
        doc.refreshMarks();
    }
    function keepMine() {
        doc.lastDisk = doc.pendingDisk; doc.pendingDisk = ""; doc.conflicted = false;
        doc.dirty = doc.cached !== doc.lastDisk;
        doc.refreshMarks();
    }

    Component.onCompleted: {
        const raw = disk.text();
        // A picture, an archive or a compiled object read as text comes back mojibake, and a
        // save would write that over the file; a huge one hangs the window in the highlighter.
        if (raw.length > 2000000) { doc.problem = `Too large to open here — ${Voice.size(raw.length)}.`; doc.loaded = true; return; }
        if (raw.substring(0, 8000).includes("\u0000")) { doc.problem = "Not a text file."; doc.loaded = true; return; }
        const after = doc.fromDisk(raw);
        doc.kind = doc.kindOf(after);
        doc.indentUnit = doc.detectIndent(after);
        doc.lastDisk = after;
        doc.started = true;
        if (doc.status === "M" || doc.status === "U" || doc.watchOnOpen) {
            if (doc.status !== "M") { doc.startTyping("", after, doc.watchOnOpen); doc.loaded = true; }
            else doc.project.before(doc.rel, b => { doc.startTyping(b.replace(/\r\n?/g, "\n"), after, doc.watchOnOpen); doc.loaded = true; });
        } else {
            area.text = after; area.cursorPosition = 0; doc.loaded = true;
            doc.announce();
            doc.refreshMarks();
        }
    }

    // ── drawing ─────────────────────────────────────────────────────────────
    readonly property real lineHeight: area.lineCount > 0 ? area.contentHeight / area.lineCount : 18
    readonly property int gutter: Math.max(3, String(area.lineCount).length) * fm.averageCharacterWidth + 28

    FontMetrics { id: fm; font: area.font }

    StyledText {
        anchors.centerIn: parent
        visible: doc.problem.length > 0
        text: doc.problem
        font.pixelSize: 16
        color: Tacit.inkMeta
    }

    ListView {
        id: numbers
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: doc.wrap ? 20 : doc.gutter
        visible: doc.problem.length === 0 && !doc.wrap
        interactive: false
        clip: true
        model: area.lineCount
        // A Flickable draws its content at -contentY and topMargin only shifts that range, so
        // the numbers follow contentY as it is; subtracting the margin put them a line low.
        contentY: flick.contentY
        delegate: Text {
            required property int index
            width: numbers.width - 14
            height: doc.lineHeight
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: index + 1
            font.family: Appearance.font.family.monospace
            font.hintingPreference: Font.PreferNoHinting
            font.pixelSize: Math.max(10, doc.fontSize - 1)
            color: index + 1 === doc.line ? Tacit.inkMain : Tacit.inkFaint
            Rectangle {
                readonly property string kind: doc.marks[index + 1] ?? ""
                visible: kind.length > 0
                x: numbers.width - 14 + 6
                width: 3
                height: kind === "d" ? 4 : parent.height
                y: kind === "d" ? parent.height - 2 : 0
                radius: 1.5
                color: kind === "a" ? Appearance.m3colors.m3primary : kind === "m" ? Appearance.m3colors.m3tertiary : Appearance.colors.colError
            }
        }
    }

    Flickable {
        id: flick
        anchors { left: numbers.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        visible: doc.problem.length === 0
        clip: true
        topMargin: 6
        bottomMargin: height / 2
        contentWidth: doc.wrap ? width : Math.max(width, area.contentWidth + 40)
        contentHeight: area.contentHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: StyledScrollBar {}
        // StyledScrollBar's handle is built for a vertical bar (implicitWidth 4, implicitHeight
        // from visualSize), so the horizontal one stays stock until that widget is orientation-aware.
        ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
        Praxis.FastWheel { view: flick; ease: true }

        function ensureVisible(r) {
            if (r.y < contentY) contentY = r.y;
            else if (r.y + r.height > contentY + height - bottomMargin * 0.3) contentY = r.y + r.height - height + bottomMargin * 0.3;
            if (r.x < contentX) contentX = Math.max(0, r.x - 40);
            else if (r.x > contentX + width - 40) contentX = r.x - width + 80;
        }

        Rectangle {   // the current line: a quiet band
            width: flick.contentWidth
            height: doc.lineHeight
            y: area.cursorRectangle.y
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95)
            visible: area.activeFocus && area.selectedText.length === 0
        }

        TextEdit {

            // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)

            font.hintingPreference: Font.PreferNoHinting
            id: area
            width: doc.wrap ? flick.width - 24 : Math.max(flick.width, contentWidth)
            textFormat: TextEdit.PlainText
            wrapMode: doc.wrap ? TextEdit.Wrap : TextEdit.NoWrap
            font.family: Appearance.font.family.monospace
            font.pixelSize: doc.fontSize
            color: Tacit.inkMain
            selectionColor: Appearance.colors.colSecondaryContainer
            selectedTextColor: Appearance.colors.colOnSecondaryContainer
            selectByMouse: true
            persistentSelection: true
            tabStopDistance: fm.averageCharacterWidth * 4
            cursorDelegate: Rectangle {
                width: 2
                color: Tacit.accent          // the pointer's sand, where the typing goes
                visible: area.activeFocus
                SequentialAnimation on opacity {
                    running: area.activeFocus
                    loops: Animation.Infinite
                    NumberAnimation { to: 1; duration: 0 }
                    PauseAnimation { duration: 530 }
                    NumberAnimation { to: 0; duration: 0 }
                    PauseAnimation { duration: 530 }
                }
            }
            onCursorRectangleChanged: flick.ensureVisible(cursorRectangle)
            onTextChanged: {
                doc.cached = area.text;
                if (doc.loaded && !doc.session) doc.dirty = doc.cached.length !== doc.lastDisk.length || doc.cached !== doc.lastDisk;
                if (doc.loaded) { doc.refreshMarks(); doc.edited(); }
                doc.layoutTick++;
                if (doc.loaded && !doc.session) {
                    lspLater.restart();
                    if (doc.compStart >= 0) doc.filterCompletion();
                }
            }
            onContentHeightChanged: doc.layoutTick++
            onContentWidthChanged: doc.layoutTick++
            onCursorPositionChanged: if (doc.compStart >= 0 && (area.cursorPosition < doc.compStart || doc.wordStartAt(area.cursorPosition) !== doc.compStart)) doc.hideCompletion()
            onActiveFocusChanged: if (!activeFocus) { doc.release(); doc.hideCompletion(); }
            // the problems: a thin line under each, in the risk colour (a warning in the sand); one line of a
            // problem that spans several
            Repeater {
                model: doc.diags.slice(0, 300)
                delegate: Rectangle {
                    required property var modelData
                    readonly property int from: doc.offsetOf(modelData.range.start.line, modelData.range.start.character)
                    readonly property int lineEnd: { const n = doc.cached.indexOf("\n", from); return n < 0 ? doc.cached.length : n; }
                    readonly property int to: Math.min(lineEnd, Math.max(from + 1, doc.offsetOf(modelData.range.end.line, modelData.range.end.character)))
                    readonly property rect r1: (doc.layoutTick, area.positionToRectangle(from))
                    readonly property rect r2: (doc.layoutTick, area.positionToRectangle(to))
                    x: r1.x
                    y: r1.y + r1.height - 1
                    width: Math.max(8, (r2.y === r1.y ? r2.x : r1.x + 8) - r1.x)
                    height: 1.5
                    radius: 0.75
                    color: (modelData.severity ?? 1) === 1 ? Tacit.risk : Tacit.accent
                }
            }
            // what could go here: a list under the word, in the menus' surface
            Rectangle {
                id: compPopup
                visible: doc.completing && area.activeFocus
                readonly property rect at: (doc.layoutTick, area.positionToRectangle(Math.max(0, doc.compStart)))
                x: Math.max(0, Math.min(at.x - 10, flick.contentX + flick.width - width - 12))
                y: at.y + at.height + 4
                z: 10
                width: 380
                height: Math.min(8, doc.compShown.length) * 28 + 8
                radius: 10
                color: Appearance.m3colors.m3surfaceContainerHigh
                border.width: 1
                border.color: Tacit.hairline
                onVisibleChanged: if (visible) compIn.restart()
                Anim { id: compIn; target: compPopup; property: "opacity"; from: 0; to: 1; type: Anim.FastEffects }
                ListView {
                    id: compList
                    anchors { fill: parent; margins: 4 }
                    model: doc.compShown
                    currentIndex: doc.compAt
                    clip: true
                    interactive: count > 8
                    boundsBehavior: Flickable.StopAtBounds
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    delegate: Rectangle {
                        id: compRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 28
                        radius: 6
                        color: compRow.index === doc.compAt ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88) : "transparent"
                        StyledText {
                            anchors { left: parent.left; leftMargin: 10; right: compDetail.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            text: String(compRow.modelData.label).trim()
                            elide: Text.ElideRight
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: 14
                            color: Tacit.inkMain
                        }
                        StyledText {
                            id: compDetail
                            anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, 160)
                            text: String(compRow.modelData.detail ?? "").split("\n")[0]
                            elide: Text.ElideRight
                            font.pixelSize: 12
                            color: Tacit.inkMeta
                        }
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onEntered: doc.compAt = compRow.index
                            onClicked: { doc.compAt = compRow.index; doc.acceptCompletion(); }
                        }
                    }
                }
            }
            // Ctrl+click: where the name is defined
            TapHandler {
                acceptedButtons: Qt.LeftButton
                acceptedModifiers: Qt.ControlModifier
                onTapped: point => doc.goDefinition(area.positionAt(point.position.x, point.position.y))
            }
            TapHandler {
                acceptedButtons: Qt.RightButton
                onTapped: (point, button) => {
                    if (doc.held) return;
                    const p = point.position, at = area.positionAt(p.x, p.y);
                    const a = Math.min(area.selectionStart, area.selectionEnd), b = Math.max(area.selectionStart, area.selectionEnd);
                    if (at < a || at > b || a === b) area.cursorPosition = at;     // a click outside the selection moves there
                    area.forceActiveFocus();
                    const q = area.mapToItem(doc, p.x, p.y);
                    doc.menuAt(q.x, q.y);
                }
            }

            Keys.onPressed: event => {
                const ctrl = event.modifiers & Qt.ControlModifier, alt = event.modifiers & Qt.AltModifier;
                if (doc.held) {
                    if (event.key === Qt.Key_Escape) {
                        if (doc.session.complete()) doc.release(); else doc.abandon();
                        event.accepted = true; return;
                    }
                    if (ctrl && event.key === Qt.Key_Z) { doc.untype(); event.accepted = true; return; }
                    if (ctrl && event.key === Qt.Key_Y) { doc.step(); event.accepted = true; return; }
                    if (ctrl && (event.key === Qt.Key_V || event.key === Qt.Key_X || event.key === Qt.Key_A)) { event.accepted = true; return; }
                    if (ctrl || alt) return;   // shortcuts pass through
                    if (event.key === Qt.Key_Backspace) { doc.untype(); event.accepted = true; return; }
                    if (event.key === Qt.Key_Delete) { event.accepted = true; return; }
                    const printable = event.text.length > 0 && event.text.charCodeAt(0) >= 32;
                    if (printable || event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                        if (!doc.watching) doc.step();
                        event.accepted = true;
                    }
                    return;
                }
                // the line commands
                const shift = event.modifiers & Qt.ShiftModifier;
                // the list of what could go here holds the arrows, Enter, Tab and Esc while it is open
                if (doc.completing) {
                    if (event.key === Qt.Key_Down) { doc.compAt = (doc.compAt + 1) % doc.compShown.length; event.accepted = true; return; }
                    if (event.key === Qt.Key_Up) { doc.compAt = (doc.compAt - 1 + doc.compShown.length) % doc.compShown.length; event.accepted = true; return; }
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) { doc.acceptCompletion(); event.accepted = true; return; }
                    if (event.key === Qt.Key_Escape) { doc.hideCompletion(); event.accepted = true; return; }
                }
                if (ctrl && event.key === Qt.Key_Space) { doc.maybeComplete(true); event.accepted = true; return; }
                if (event.key === Qt.Key_F12) { doc.goDefinition(area.cursorPosition); event.accepted = true; return; }
                if (event.key === Qt.Key_F8) { doc.nextProblem(shift); event.accepted = true; return; }
                if (!ctrl && !alt && event.text.length === 1) { if (/[\w.$]/.test(event.text)) compLater.restart(); else doc.hideCompletion(); }
                if (ctrl && (event.key === Qt.Key_Slash || event.key === Qt.Key_Question)) { doc.toggleComment(); event.accepted = true; return; }
                if (ctrl && shift && event.key === Qt.Key_D) { doc.duplicateLines(); event.accepted = true; return; }
                if (alt && (event.key === Qt.Key_Up || event.key === Qt.Key_Down)) { doc.moveLines(event.key === Qt.Key_Up); event.accepted = true; return; }
                if (alt && event.key === Qt.Key_Z) { doc.wrapSet = !doc.wrap; event.accepted = true; return; }
                if (event.key === Qt.Key_Home && !ctrl) { doc.home(shift); event.accepted = true; return; }
                if (!ctrl && !alt && doc.pairKey(event.key, event.text)) { event.accepted = true; return; }
                // plain editing: Enter keeps the indentation, Tab indents
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    // the indentation of the line the new text starts on, not of wherever the
                    // cursor happens to sit inside a selection
                    const at = Math.min(area.selectionStart, area.selectionEnd);
                    const start = at > 0 ? doc.cached.lastIndexOf("\n", at - 1) + 1 : 0;
                    const indent = /^[ \t]*/.exec(area.getText(start, at))[0];
                    const end = Math.max(area.selectionStart, area.selectionEnd);
                    doc.edit([[at, end, "\n" + indent]]);
                    area.cursorPosition = at + 1 + indent.length;
                    event.accepted = true;
                } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                    doc.shift(true);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Tab && !ctrl) {
                    if (area.selectionStart !== area.selectionEnd
                        && doc.cached.substring(area.selectionStart, area.selectionEnd).includes("\n")) doc.shift(false);
                    else {
                        const s = Math.min(area.selectionStart, area.selectionEnd);
                        doc.edit([[s, Math.max(area.selectionStart, area.selectionEnd), doc.indentUnit]]);
                        area.cursorPosition = s + doc.indentUnit.length;
                    }
                    event.accepted = true;
                }
            }
        }
    }

    // Pairs, for code: an opening bracket or quote brings its closing one where nothing follows it, wraps a
    // selection, and is stepped over when typed again; Backspace between an empty pair takes both. True if handled.
    function pairKey(key, text) {
        if (doc.prose || doc.held) return false;
        const t = doc.cached, a = Math.min(area.selectionStart, area.selectionEnd), b = Math.max(area.selectionStart, area.selectionEnd);
        const closes = doc.pairs[text], next = t.charAt(b), prev = a > 0 ? t.charAt(a - 1) : "";
        if (key === Qt.Key_Backspace && a === b && a > 0 && doc.pairs[prev] !== undefined && doc.pairs[prev] === next) {
            doc.edit([[a - 1, a + 1, ""]]); return true;
        }
        if (text.length === 1 && a === b && next === text && (")]}".includes(next) || closes === text)) {
            area.cursorPosition = b + 1; return true;          // over the closing one already there
        }
        if (closes === undefined) return false;
        if (a !== b) { doc.edit([[a, a, text], [b, b, closes]]); area.select(a + 1, b + 1); return true; }
        const quote = closes === text;
        if ((next === "" || /[\s)\]},;:]/.test(next)) && !(quote && /[\w\\]/.test(prev))) {
            doc.edit([[a, a, text + closes]]); area.cursorPosition = a + 1; return true;
        }
        return false;
    }
    readonly property var pairs: ({ "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`" })

    // scripts in ~/.local/bin carry no extension, so the filename matches no definition
    // what colours the file, set when it is read: "large", a definition named by its #! line, or "file" (its name)
    property string kind: ""
    function kindOf(t) {
        if (t.length >= 400000) return "large";
        if (Repository.definitionForFileName(doc.rel).name.length > 0 || !t.startsWith("#!")) return "file";
        const first = t.substring(2, t.indexOf("\n") + 1 || 120).trim();
        const words = first.split(/\s+/).map(w => w.split("/").pop());
        const name = (words[0] === "env" ? words[1] : words[0]) || "";
        return doc.shebangs[name.replace(/[\d.]+$/, "")] || name || "file";
    }
    readonly property var shebangs: ({ sh: "Bash", bash: "Bash", zsh: "Bash", dash: "Bash", ksh: "Bash",
        fish: "Fish", python: "Python", node: "JavaScript", perl: "Perl", ruby: "Ruby", lua: "Lua", awk: "AWK" })
    SyntaxHighlighter {
        id: highlighter
        textEdit: area
        // Decided once the file is read (doc.kind), never from the live text: bound to the text, it was looked up
        // again on every key, and a big file was coloured before its size was known - a 1.5 MB file hung the
        // window. Past the same 400 000 characters the Claude app's viewer stops at, the file shows plain.
        definition: {
            if (!doc.kind.length) return Repository.definitionForName("None");
            if (doc.kind === "large") return Repository.definitionForName("None");
            if (doc.kind !== "file") return Repository.definitionForName(doc.kind);
            return Repository.definitionForFileName(doc.rel);
        }
        // the martida role mapping (matugen template kde-syntax/martida.theme); the desktop's
        // Material You theme only if that file is missing
        theme: {
            const t = Repository.theme("Martida");
            return t.name === "Martida" ? t : Repository.theme(Appearance.m3colors.darkmode ? "Material You Dark" : "Material You Light");
        }
    }
}
