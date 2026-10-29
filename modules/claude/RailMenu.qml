import QtQuick
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The rail's menu: a session's verbs, or a folder's "Open here" rows and verbs, in a small plain
 * menu anchored at its row: below it, else above it, beside it only when neither fits. Sized by
 * its content, 200 to 284 px, so it stays inside the 300 px rail.
 *
 * It lies over the whole window: fill the window's surface with it; `anchor` is the row's rect in
 * that frame. What it shows is held while it fades out. dismissed() is sent on Esc, a click
 * outside or a verb run: the keyboard goes back to whoever opened it. A verb that closes the menu
 * sends dismissed() before act(). The rail reads `live` for a waiting row's question.
 */
FocusScope {
    id: menu

    property string mode: ""          // "" | session | folder (set through openFor and close)
    property var row: null            // a FolderModel row: session or hit, or folder
    property rect anchor: Qt.rect(0, 0, 0, 0)
    property var live: ({})           // host.live
    property var caps: ({})           // the row's agent: {fork, rename, delete}
    property bool heldByTerminal: false
    // The folder's, as claude.qml filters them: windows [{address, kind, workspace, special, cwd,
    // cmd, docs [{rel, dirty}]}] and agents [{tool, session, window, title}]. An agent with no
    // window is a session Praxis runs; one with a window shows as its terminal.
    property var presence: ({ windows: [], agents: [] })
    property bool shellUp: true
    property bool hostUp: true
    property color ground: "black"
    property int workspace: -1        // Praxis's own workspace: a window there needs no number

    // Session verbs carry the session id: pin, rename, move, fork, files, copy, archive, delete
    // (copy has already put the command on the clipboard). Folder verbs carry the fkey: new,
    // rename, pin, unpin, hide, unhide. Open-here rows: focus(address), graphis(rel), select(id).
    signal act(string verb, var arg)
    signal dismissed()

    function openFor(keyboard) {
        if (!menu.row)
            return;
        menu.vrow = menu.row;
        menu.vpresence = menu.presence;
        menu.copied = false;
        menu.mode = menu.row.type === "folder" ? "folder" : "session";
        menu.measure();
        menu.cursor = keyboard ? menu.next(-1, 1) : -1;
        menu.forceActiveFocus();
    }
    function close() {
        if (menu.mode === "")
            return;
        menu.heldLines = menu.lines;
        menu.mode = "";
        menu.cursor = -1;
        menu.dismissed();
    }

    // ── state ───────────────────────────────────────────────────────────────
    property int cursor: -1           // the chosen line (pointer or keyboard)
    property bool copied: false
    property var vrow: null           // what it shows: followed while open, held while it fades
    property var vpresence: ({ windows: [], agents: [] })
    onRowChanged: if (menu.mode !== "") menu.vrow = menu.row
    onPresenceChanged: if (menu.mode !== "") menu.vpresence = menu.presence
    property real shown: menu.mode !== "" ? 1 : 0
    Behavior on shown { Anim { type: Anim.FastEffects } }
    readonly property bool showing: menu.mode !== "" || menu.shown > 0

    // ── what it says ────────────────────────────────────────────────────────
    readonly property var agentNames: ({ claude: "Claude", codex: "Codex", pi: "pi", opencode: "opencode" })
    function baseName(p) {
        const parts = (p ?? "").split(/[\\/]/).filter(x => x.length);
        return parts.length ? parts[parts.length - 1] : (p ?? "");
    }
    function resumeOf(r) {
        const s = r.session ?? {};
        if (s.resume)
            return s.resume;
        return (r.tool || s.tool) === "codex" ? `codex resume ${r.id}` : `claude --resume ${r.id}`;
    }

    // line: {kind: "row", verb, arg, label, key, detail, note, mono, why, dirty, middle} or {kind: "rule"}.
    // Built while open (mode is read first: closed, nothing else is a dependency); the last ones are
    // held while it fades out.
    property var heldLines: []
    readonly property var openLines: {
        if (menu.mode === "" || !menu.vrow)
            return [];
        return menu.mode === "folder" ? menu.folderLines(menu.vrow) : menu.sessionLines(menu.vrow);
    }
    readonly property var lines: menu.mode !== "" ? menu.openLines : menu.heldLines
    function line(o) {
        return Object.assign({ kind: "row", verb: "", arg: "", label: "", key: "", detail: "", note: "", mono: false, why: "", dirty: false, middle: false }, o);
    }
    // What the host or the agent cannot do is shown with the reason as its note. A host that is
    // down comes first: without its hello the caps are only the fallback's.
    function sessionLines(r) {
        const s = r.session ?? {};
        const tool = r.tool || s.tool || "claude";
        const agent = menu.agentNames[tool] ?? tool;
        const held = menu.heldByTerminal ? "Open in a terminal" : "";
        const host = menu.hostUp ? "" : "The background service is not answering";
        const no = `Not offered for ${agent}`;
        const id = r.id;
        const running = !!menu.live?.[id]?.alive;
        return [
            menu.line({ verb: "pin", arg: id, label: r.pinned ? "Unpin" : "Pin" }),
            menu.line({ verb: "rename", arg: id, label: "Rename", key: "F2", why: host || (!menu.caps?.rename ? no : "") }),
            menu.line({ verb: "move", arg: id, label: "Move to…", why: held }),
            { kind: "rule" },
            menu.line({ verb: "fork", arg: id, label: "Fork", why: host || (!menu.caps?.fork ? no : held) }),
            menu.line({ verb: "files", arg: id, label: "Show in Pinax",
                        why: !menu.shellUp ? "The shell is not running" : s.local === false ? "Not on this machine" : "" }),
            menu.line({ verb: "copy", arg: id, label: "Copy resume command", mono: !running,
                        note: running ? "Running here: close it before resuming in a terminal" : menu.resumeOf(r) }),
            { kind: "rule" },
            menu.line({ verb: "archive", arg: id, label: r.archived ? "Unarchive" : "Archive" }),
            // Codex and opencode keep their sessions: the delete archives them (FolderModel.sendDelete)
            menu.line({ verb: "delete", arg: id, label: "Delete", key: "Del", why: host || (!menu.caps?.delete ? no : held),
                        note: tool === "codex" || tool === "opencode" ? `${agent} keeps it: it goes to Archived` : "" })
        ];
    }
    function folderLines(r) {
        const out = menu.openRows(r);
        if (out.length)
            out.push({ kind: "rule" });
        const shell = menu.shellUp ? "" : "The shell is not running";
        const k = r.fkey;
        if (r.canStart)
            out.push(menu.line({ verb: "new", arg: k, label: "New session here", key: "Ctrl+N" }));
        if (r.local)
            out.push(menu.line({ verb: "rename", arg: k, label: "Rename", key: "F2", why: shell, note: "The name shows in Pinax too" }));
        if (r.pinned)
            out.push(menu.line({ verb: "unpin", arg: k, label: "Unpin", why: shell, note: "Also leaves Pinax's rail" }));
        else if (r.canPin)
            out.push(menu.line({ verb: "pin", arg: k, label: "Pin", why: shell, note: "Also shows in Pinax's rail" }));
        out.push(menu.line(r.hidden ? { verb: "unhide", arg: k, label: "Unhide", note: "Only in Praxis" }
                                    : { verb: "hide", arg: k, label: "Hide", note: "Only in Praxis" }));
        return out;
    }
    // Praxis's sessions, terminals, Graphis tabs, Pinax windows; special workspaces are left out
    function openRows(r) {
        const p = menu.vpresence ?? {};
        const base = r.path ?? "";
        const sub = c => c && base && c !== base && c.startsWith(base + "/") ? c.slice(base.length + 1) : "";
        const at = (w, name) => w.workspace === menu.workspace ? name : `${name} ${w.workspace}`;
        const sessions = [], terms = [], tabs = [], pinax = [];
        const seen = {};
        for (const a of p.agents ?? []) {
            if (a.window || !a.session || seen[a.session])
                continue;
            seen[a.session] = true;
            sessions.push(menu.line({ verb: "select", arg: a.session, label: a.title || "Session", detail: "Praxis" }));
        }
        for (const w of p.windows ?? []) {
            if (w.special || w.workspace < 0)
                continue;
            if (w.kind === "terminal")
                terms.push(menu.line({ verb: "focus", arg: w.address, label: Voice.facts([w.cmd || "terminal", sub(w.cwd)]), detail: at(w, "Terminal") }));
            else if (w.kind === "graphis") {
                const docs = w.docs ?? [];
                if (!docs.length)
                    tabs.push(menu.line({ verb: "focus", arg: w.address, label: menu.baseName(w.cwd), detail: at(w, "Graphis") }));
                for (const d of docs)
                    tabs.push(menu.line({ verb: "graphis", arg: d.rel, label: d.rel, dirty: !!d.dirty, middle: true, detail: at(w, "Graphis") }));
            } else if (w.kind === "files")
                pinax.push(menu.line({ verb: "focus", arg: w.address, label: menu.baseName(w.cwd), detail: at(w, "Pinax") }));
        }
        return sessions.concat(terms, tabs, pinax);
    }

    // ── running a line ──────────────────────────────────────────────────────
    function usable(i) {
        const l = menu.lines[i];
        return !!l && l.kind === "row" && l.why === "";
    }
    function next(from, step) {
        for (let i = from + step; i >= 0 && i < menu.lines.length; i += step)
            if (menu.usable(i))
                return i;
        return -1;
    }
    function step(d) {
        const i = menu.next(menu.cursor < 0 && d < 0 ? menu.lines.length : menu.cursor, d);
        if (i >= 0)
            menu.cursor = i;
    }
    // a letter: the next usable line whose label starts with it, round from the cursor
    function jump(ch) {
        const n = menu.lines.length;
        for (let k = 1; k <= n; k++) {
            const i = (Math.max(menu.cursor, -1) + k + n) % n;
            if (menu.usable(i) && menu.lines[i].label.toLowerCase().startsWith(ch))
                return menu.cursor = i;
        }
    }
    function run(i) {
        // closed: the fading copy still takes clicks, and they run nothing
        if (menu.mode === "" || !menu.usable(i))
            return;
        const l = menu.lines[i];
        if (l.verb === "copy") {
            Quickshell.clipboardText = menu.resumeOf(menu.vrow);
            menu.copied = true;
            copyTimer.restart();
            menu.act("copy", l.arg);
            return;
        }
        // Closed first: the row is then held if act() drops it, and dismissed() has handed the
        // keyboard back before a verb (rename, new) takes it.
        menu.close();
        menu.act(l.verb, l.arg);
    }
    function runVerb(verb) {
        const i = menu.lines.findIndex(l => l.kind === "row" && l.verb === verb);
        if (i >= 0)
            menu.run(i);
    }
    Timer { id: copyTimer; interval: 1500; onTriggered: menu.copied = false }

    // The window's Ctrl+N Shortcut takes the key unless the focus item claims it here.
    Keys.onShortcutOverride: e => e.accepted = menu.mode === "folder" && e.key === Qt.Key_N && e.modifiers === Qt.ControlModifier
    Keys.onPressed: e => {
        if (menu.mode === "")
            return;
        const mods = e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
        e.accepted = true;
        if (e.key === Qt.Key_Escape)
            menu.close();
        else if (e.key === Qt.Key_Down || e.key === Qt.Key_Tab)
            menu.step(1);
        else if (e.key === Qt.Key_Up || e.key === Qt.Key_Backtab)
            menu.step(-1);
        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space)
            menu.run(menu.cursor);
        else if (e.key === Qt.Key_F2)
            menu.runVerb("rename");
        else if (e.key === Qt.Key_Delete && menu.mode === "session")
            menu.runVerb("delete");
        else if (e.key === Qt.Key_N && e.modifiers === Qt.ControlModifier && menu.mode === "folder")
            menu.runVerb("new");
        else if (mods === 0 && /^[a-z0-9]$/i.test(e.text))
            menu.jump(e.text.toLowerCase());
        else
            e.accepted = false;
    }

    // a click outside closes it
    MouseArea {
        anchors.fill: parent
        enabled: menu.mode !== ""
        acceptedButtons: Qt.AllButtons
        onPressed: menu.close()
    }

    // ── geometry: held while it fades out, whatever the rail does with `anchor` ──
    readonly property int pad: 4
    readonly property real gap: 4
    property real contentW: 0
    onLinesChanged: Qt.callLater(menu.measure)
    function measure() {
        let w = 0;
        for (let i = 0; i < rows.count; i++)
            w = Math.max(w, rows.itemAt(i)?.want ?? 0);
        menu.contentW = w;
    }
    readonly property real panelW: Math.max(200, Math.min(284, menu.contentW + 2 * menu.pad))
    readonly property real panelH: Math.min(col.implicitHeight + 2 * menu.pad, menu.height - 16)
    readonly property string side: {
        const a = menu.anchor;
        if (a.y + a.height + menu.gap + menu.panelH <= menu.height - 8)
            return "below";
        if (a.y - menu.gap - menu.panelH >= 8)
            return "above";
        return "beside";
    }
    readonly property point targetPos: {
        const a = menu.anchor;
        if (menu.side === "beside")
            return Qt.point(Math.min(a.x + a.width + menu.gap, menu.width - menu.panelW - 8),
                            Math.max(8, Math.min(menu.height - menu.panelH - 8, a.y)));
        const x = Math.max(8, Math.min(menu.width - menu.panelW - 8, a.x + a.width - menu.panelW));
        return Qt.point(x, menu.side === "below" ? a.y + a.height + menu.gap : a.y - menu.gap - menu.panelH);
    }
    property point pos: Qt.point(0, 0)
    property string heldSide: "below"
    Binding { target: menu; property: "pos"; value: menu.targetPos; when: menu.mode !== ""; restoreMode: Binding.RestoreNone }
    Binding { target: menu; property: "heldSide"; value: menu.side; when: menu.mode !== ""; restoreMode: Binding.RestoreNone }

    // ── the surface ─────────────────────────────────────────────────────────
    Rectangle {
        id: panel
        x: menu.pos.x
        y: menu.pos.y
        width: menu.panelW
        height: menu.panelH
        visible: menu.showing
        radius: Appearance.rounding.small
        color: menu.ground
        border.width: 1
        border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
        opacity: menu.shown
        scale: 0.96 + 0.04 * menu.shown
        transformOrigin: menu.heldSide === "below" ? Item.TopRight : menu.heldSide === "above" ? Item.BottomRight : Item.TopLeft

        MouseArea {   // its own ground takes its clicks and wheels
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            onWheel: w => w.accepted = true
        }
        Flickable {
            id: flick
            anchors { fill: parent; margins: menu.pad }
            contentHeight: col.implicitHeight
            interactive: contentHeight > height + 1
            clip: interactive
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: col
                width: flick.width
                Repeater {
                    id: rows
                    model: menu.lines
                    delegate: Loader {
                        required property var modelData
                        required property int index
                        readonly property real want: item ? item.want : 0
                        onWantChanged: Qt.callLater(menu.measure)
                        width: col.width
                        sourceComponent: modelData.kind === "rule" ? ruleLine : rowLine
                    }
                }
            }
        }
    }

    Component {
        id: ruleLine
        Item {
            readonly property real want: 0
            implicitHeight: 9
            Rectangle {
                x: 8
                y: 4
                width: parent.width - 16
                height: 1
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            }
        }
    }
    Component {
        id: rowLine
        Item {
            id: ln
            readonly property var d: parent?.modelData ?? ({})
            readonly property int index: parent?.index ?? -1
            readonly property bool inert: (ln.d.why ?? "") !== ""
            readonly property string note: ln.inert ? ln.d.why : (ln.d.note ?? "")
            readonly property bool chosen: menu.cursor === ln.index && !ln.inert
            readonly property string tail: ln.inert ? "" : ln.d.key || ln.d.detail || ""
            // the width this line asks for: a long command elides instead
            readonly property real want: Math.max(10 + labelMetrics.advanceWidth + (ln.d.dirty ? 13 : 0) + (ln.tail ? 16 + rightText.implicitWidth : 0) + 10,
                                                  ln.note && !ln.d.mono ? 10 + noteMetrics.advanceWidth + 10 : 0)
            implicitHeight: ln.note ? 24 + noteText.implicitHeight + 6 : 30

            TextMetrics { id: labelMetrics; font: label.font; text: ln.d.label ?? "" }
            TextMetrics { id: noteMetrics; font: noteText.font; text: ln.note }

            Rectangle {
                anchors.fill: parent
                radius: 8
                color: ln.chosen ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent"
            }
            StyledText {
                id: label
                x: 10
                y: (30 - height) / 2
                width: Math.min(implicitWidth, parent.width - 20 - (ln.tail ? rightText.implicitWidth + 16 : 0) - (ln.d.dirty ? 13 : 0))
                text: ln.d.verb === "copy" && menu.copied ? "Copied" : (ln.d.label ?? "")
                textFormat: Text.PlainText
                font.family: Appearance.font.family.compact
                font.pixelSize: 14
                color: ln.inert ? Appearance.colors.colInkFaint : ln.d.verb === "delete" ? Appearance.colors.colClay : Appearance.colors.colInkMain
                elide: ln.d.middle ? Text.ElideMiddle : Text.ElideRight
            }
            Rectangle {   // unsaved in Graphis: its tab's dot
                visible: !!ln.d.dirty
                anchors { left: label.right; leftMargin: 6; verticalCenter: label.verticalCenter }
                width: 7
                height: 7
                radius: 4
                color: Appearance.colors.colPrimary
            }
            StyledText {   // a key that works here, or where the window is
                id: rightText
                visible: ln.tail !== ""
                anchors { right: parent.right; rightMargin: 10; verticalCenter: label.verticalCenter }
                text: ln.tail
                font.family: Appearance.font.family.compact
                font.pixelSize: 13
                color: Appearance.colors.colInkMeta
            }
            StyledText {
                id: noteText
                visible: ln.note !== ""
                x: 10
                y: 24
                width: parent.width - 20
                text: ln.note
                textFormat: Text.PlainText
                font.family: ln.d.mono ? "Tacit Mono" : Appearance.font.family.compact
                font.pixelSize: 13
                color: Appearance.colors.colInkMeta
                wrapMode: ln.d.mono ? Text.NoWrap : Text.Wrap
                maximumLineCount: ln.d.mono ? 1 : 2
                elide: ln.d.mono ? Text.ElideMiddle : Text.ElideRight
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: ln.inert ? Qt.ArrowCursor : Qt.PointingHandCursor
                onEntered: if (!ln.inert) menu.cursor = ln.index
                onExited: if (menu.cursor === ln.index) menu.cursor = -1
                onClicked: menu.run(ln.index)
            }
        }
    }
}
