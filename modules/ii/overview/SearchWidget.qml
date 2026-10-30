pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The palette, docked into the bottom edge (2026-10-01 design, the dock-search motion study).
 *
 * The field is the part that meets the edge and it never moves; results rise out of it, the best
 * one nearest, one line each (SearchItem.qml). Sand marks what Enter will do: the search disc
 * while nothing is chosen, the chosen row once something is, the answer when the field holds a
 * sum. The kind of search is named at the field's right and Tab steps it. Keyboard-first: the
 * input keeps focus for the whole life of the palette and drives `chosen`, the row Enter acts on.
 *
 * Motion is the shell's own (Anim.qml): the whole palette slides out of the edge on
 * DefaultSpatial, the list grows on Emphasized, the chosen wash travels on Emphasized.
 */
Item {
    id: root

    // ------------------------------------------------- API used by Overview.qml
    property string searchingText: PaletteSearch.query
    // The workspace grid shares this window. An invisible Qt Quick item still holds active
    // focus, so without this the hidden input was the window's focus item in workspace mode
    // and swallowed every key - including the Left/Right the grid is bound to.
    required property bool paletteMode
    // The dock is up (the bottom edge was touched): the same shape, its row of programs instead of
    // the field. Searching from it widens it into the field; Esc comes back to it.
    property bool dockShown: false
    // false while the dock holds the keyboard (opened with Super): the first letter typed turns it
    // into the search
    property bool searchActive: true
    readonly property bool searching: GlobalStates.overviewOpen && root.paletteMode && root.searchActive
    readonly property bool dockKeys: GlobalStates.overviewOpen && root.paletteMode && root.dockMode

    // While the dock widens into the search, nothing is searched: rebuilding every source and
    // creating the rows in the same frames made the morph stutter. The letters wait in the field
    // and the search runs once the widening is mostly done; the results then rise on their own curve.
    property bool morphing: false
    onSearchingChanged: {
        if (root.searching && root.dockShown) {
            unfreezeTimer.stop();
            root.rowsFrozen = false;
            root.morphing = true;
            morphTimer.restart();
        } else if (!root.searching && root.dockShown) {
            root.rowsFrozen = true;
            unfreezeTimer.restart();
        }
    }
    Timer {
        id: morphTimer
        // past the front-loaded part of the widening (FastSpatial covers most of its way in the
        // first half); waiting for all of it left a still field before the results rose
        interval: Math.round(Appearance.animationCurves.expressiveFastSpatialDuration / 2)
        onTriggered: {
            root.morphing = false;
            root.applyQuery();
        }
    }
    // Typing faster than a frame or two is one search, not one per letter
    Timer {
        id: queryTimer
        interval: 45
        onTriggered: root.applyQuery()
    }
    function applyQuery() {
        PaletteSearch.query = root.kindPrefix + searchInput.text;
    }
    readonly property bool dockMode: root.dockShown && !root.searching
    // Emitted once the palette has slid back into the edge after a close (Overview.qml keeps the
    // window up until then).
    signal closed
    // the dock asks to become the search (its disc was clicked)
    signal searchRequested
    // the pointer left the dock, or a program was opened from it
    signal dockDone
    // Esc in a search that was opened from the dock: back to the dock
    signal backToDock

    function focusFirstItem() {
        root.selectFirstResult();
    }

    function focusSearchInput() {
        searchInput.forceActiveFocus();
    }

    function disableExpandAnimation() {} // kept for the old call site

    function cancelSearch() {
        root.setSearchingText("");
    }

    // A query arrives whole (a prefix hotkey, IPC): its prefix becomes the kind, the rest the text
    function setSearchingText(text) {
        const prefix = PaletteSearch.prefixOf(text);
        root.kindPrefix = prefix;
        root.settingText = true;
        searchInput.text = prefix.length > 0 ? text.slice(prefix.length) : text;
        root.settingText = false;
        PaletteSearch.query = root.kindPrefix + searchInput.text;
        searchInput.cursorPosition = searchInput.text.length;
    }

    // ------------------------------------------------------------------ geometry
    readonly property int paletteWidth: 880
    // The dock may run wider than the field on a wide screen: its names are what make it this dock, and at
    // 880 a dozen programs dropped every one of them.
    readonly property int dockMaxWidth: Math.max(root.paletteWidth, Math.min(1100, (Quickshell.screens[0]?.width ?? 1280) - 220))
    readonly property int fieldHeight: 78
    readonly property int rowHeight: 52
    readonly property int maxListHeight: 7 * root.rowHeight
    readonly property int dockCornerSize: 12

    implicitWidth: root.dockMaxWidth + root.dockCornerSize * 2
    implicitHeight: frame.height + peekTab.height

    // Out of the bottom edge as one piece, like the control panel (SidebarRight.qml): one scalar,
    // the default spatial Anim both ways, no fade - Hyprland blurs only pixels above ignore_alpha,
    // so a fading panel would pop its blur in half-way.
    readonly property bool out: !root.searching && !root.dockShown
    // Docked into the edge, so no overshoot: a spring past the rest lifted the shape off the edge and
    // showed a gap under its coves. Out on the palette's curve, away on the quick accelerating exit.
    // The slide starts once the window has drawn its first frames: creating the window takes a
    // long first frame, and a slide already under way then jumped.
    property bool armed: false
    property real offsetScale: !root.out && root.armed ? 0 : 1
    transform: Translate {
        y: (root.implicitHeight + 16) * root.offsetScale
    }
    // the direction is read from the state, not from offsetScale itself, so it holds for the whole slide
    readonly property bool showing: !root.out && root.armed
    // In decelerating; away on the palette's own emphasized curve, which starts gently and then
    // goes into the edge. A decelerating exit spent its motion in the first two frames and read as
    // a pop; the eased end of a slide-out happens off screen, so the start is what is seen.
    Behavior on offsetScale {
        NumberAnimation {
            duration: root.showing ? Appearance.animationCurves.normalDuration : 350
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.showing ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.emphasized
        }
    }
    FrameAnimation {
        id: armFrames
        running: !root.out && !root.armed
        onTriggered: {
            if (armFrames.currentFrame >= 2)
                root.armed = true;
        }
    }
    onOutChanged: {
        if (root.out) {
            root.armed = false;
            closedTimer.restart();
        } else {
            closedTimer.stop();
        }
    }
    Timer {
        id: closedTimer
        interval: Appearance.animationCurves.expressiveDefaultSpatialDuration
        onTriggered: root.closed()
    }

    // 0 the dock, 1 the search: the disc travels between the dock's end and the field's start
    // on the palette's highlight curve, and back on the notch's close. While the shape slides away
    // it keeps what it showed (the Binding lets go when out): the field used to vanish and the dock
    // appear on the departing surface. Opened from nothing, it is set at once (armed is false).
    property real travel: 0
    Binding {
        target: root
        property: "travel"
        value: root.searching ? 1 : 0
        when: !root.out
        restoreMode: Binding.RestoreNone
    }
    Behavior on travel {
        enabled: !root.out && root.armed
        NumberAnimation {
            duration: root.searching ? Appearance.animationCurves.normalDuration : 450
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.searching ? Appearance.animationCurves.emphasized : Appearance.animationCurves.emphasizedDecel
        }
    }

    // the dock goes when the pointer has left it for a moment
    // Until the pointer has been over it (it may reach the edge beside a short dock), it waits longer.
    property bool dockVisited: false
    onDockShownChanged: root.dockVisited = false
    HoverHandler {
        id: dockHover
        enabled: root.dockMode
        onHoveredChanged: {
            if (dockHover.hovered) {
                root.dockVisited = true;
                dockLeaveTimer.stop();
            } else if (root.dockMode) {
                dockLeaveTimer.restart();
            }
        }
    }
    Timer {
        id: dockLeaveTimer
        interval: root.dockVisited ? 450 : 1500
        onTriggered: {
            // the dock that holds the keyboard stays until Esc or a click elsewhere
            if (root.dockMode && !root.dockKeys && !dockHover.hovered && dock.draggingId.length === 0 && !WindowBand.holdDock)
                root.dockDone();
        }
    }
    // the window band let the dock go: it leaves as it does when the pointer leaves it
    Connections {
        target: WindowBand
        function onHoldDockChanged() {
            if (!WindowBand.holdDock && root.dockMode && !dockHover.hovered)
                dockLeaveTimer.restart();
        }
    }
    onDockModeChanged: {
        if (root.dockMode && !dockHover.hovered)
            dockLeaveTimer.restart();
        if (!root.dockMode)
            dock.reset();
    }

    // ------------------------------------------------------------------- kinds
    // What Tab steps through: the palette's own prefixes, named. "" is everything.
    property string kindPrefix: ""
    property bool settingText: false
    readonly property var kinds: {
        const p = Config.options.search.prefix;
        const t = PaletteSearch.sectionTitles;
        return [
            { "prefix": "", "title": Translation.tr("All") },
            { "prefix": p.app, "title": t.apps },
            { "prefix": p.windows ?? "@", "title": t.windows },
            { "prefix": p.files ?? "~", "title": t.files },
            { "prefix": p.clipboard, "title": t.clipboard },
            { "prefix": p.emojis, "title": t.emoji },
            { "prefix": p.keybinds ?? "<", "title": t.keybinds },
            { "prefix": p.action, "title": t.actions },
            { "prefix": p.math, "title": t.calculator },
            { "prefix": p.symbols, "title": t.symbols },
            { "prefix": p.dictation ?? "'", "title": t.flow },
            { "prefix": p.shellCommand, "title": t.command },
            { "prefix": p.webSearch, "title": t.web }
        ].filter(kind => kind.prefix !== undefined && kind.prefix !== null);
    }
    readonly property string kindTitle: root.kinds.find(kind => kind.prefix === root.kindPrefix)?.title ?? Translation.tr("All")

    function stepKind(delta) {
        const count = root.kinds.length;
        const at = Math.max(0, root.kinds.findIndex(kind => kind.prefix === root.kindPrefix));
        root.kindPrefix = root.kinds[((at + delta) % count + count) % count].prefix;
        PaletteSearch.query = root.kindPrefix + searchInput.text;
    }

    // --------------------------------------------------------------- row model
    // Nothing typed reads like a question, "how do I ..." puts asking Praxis first.
    readonly property bool questionLike: {
        const body = PaletteSearch.body.trim();
        return body.length > 0 && (/\?$/.test(body) || /^(how|what|why|when|where|who|which|can|could|should|would|is|are|do|does|did|explain|help|tell)\b/i.test(body));
    }
    // A sum, a unit or a date is answered in the field, not as a row
    readonly property var answerEntry: (PaletteSearch.sections.find(section => section.key === "calculator")?.entries ?? [])[0] ?? null

    // Built once per turn of the event loop, not as a binding: one query change updates some twenty
    // sources one after another, and a binding rebuilt the list (and every row in it) 19-45 times
    // per letter, about 100 ms of frozen frames.
    property var rows: []
    Connections {
        target: PaletteSearch
        function onSectionsChanged() {
            Qt.callLater(root.buildRows);
        }
    }
    onQuestionLikeChanged: Qt.callLater(root.buildRows)
    Component.onCompleted: root.buildRows()
    // Back to the dock: the list collapses with the rows it had, then takes the new ones
    property bool rowsFrozen: false
    Timer {
        id: unfreezeTimer
        interval: 460
        onTriggered: {
            root.rowsFrozen = false;
            root.buildRows();
        }
    }
    function buildRows() {
        if (root.rowsFrozen)
            return;
        let sections = PaletteSearch.sections.filter(section => section.key !== "calculator");
        // a sum answered in the field needs no shell, web or Praxis row under it
        if (root.answerEntry !== null)
            sections = sections.filter(section => section.key !== "command" && section.key !== "web" && section.key !== "claude");
        // a question goes to Praxis first; a sentence is not a shell command
        if (root.questionLike)
            sections = sections.filter(section => section.key === "claude").concat(sections.filter(section => section.key !== "claude" && section.key !== "command"));
        const out = [];
        for (const section of sections) {
            for (const entry of section.entries) {
                out.push({
                    "title": section.title,
                    "key": section.key,
                    "entry": entry
                });
            }
        }
        // The chosen row is settled in the same step as the rows, so no frame ever shows the list
        // without it: chosen through a later callback, every letter blinked the wash, the sand tile,
        // the verbs and the disc. Kept by identity while the query is the one it was picked under.
        // A choice is kept across the rows changing only when you made it (arrows, the pointer): the palette's own
        // first pick, made before the files had come back, used to stick, and Enter ran "Run budget" while the
        // file called Budget sat below the fold. Each new query starts without a hand-made choice.
        if (root.selectedQuery !== PaletteSearch.query)
            root.chosenByHand = false;
        const wanted = root.chosenByHand ? root.selectedKey : "";
        let index = wanted.length > 0 ? out.findIndex(row => root.keyOfRow(row) === wanted) : -1;
        if (index < 0)
            index = root.selectionFloor < 0 || out.length === 0 ? -1 : 0;
        root.rowsChanging = true;
        root.lastPointer = Qt.point(-1, -1);
        root.rows = out;
        root.select(index);
        Qt.callLater(() => root.rowsChanging = false);
    }

    // -1 is the answer in the field (or nothing); 0 the best row, nearest the field
    property int chosen: -1
    readonly property var selectedEntry: root.chosen >= 0 ? (root.rows[root.chosen]?.entry ?? null) : root.answerEntry
    readonly property bool rowChosen: root.chosen >= 0 && root.selectedEntry !== null
    readonly property bool answerChosen: root.chosen < 0 && root.answerEntry !== null
    // Which verb Enter runs. Reset when another row is chosen, not when the same row is rebuilt
    // (the sections recreate their entries whenever a source lands).
    property int verbIndex: 0
    onSelectedKeyChanged: root.verbIndex = 0
    // qalc answers after the rows are built: once it has, the answer is what Enter does
    onAnswerEntryChanged: {
        if (root.answerEntry !== null)
            Qt.callLater(() => root.select(-1));
    }

    readonly property var selectedVerbs: {
        const entry = root.selectedEntry;
        if (!entry)
            return [];
        const own = (entry.verb ?? "").length > 0 ? entry.verb : Translation.tr("Open");
        return [own].concat((entry.actions ?? []).map(action => action.name).filter(name => name !== own));
    }

    // while the rows themselves change, the wash snaps instead of travelling
    property bool rowsChanging: false

    property string selectedKey: ""
    property string selectedQuery: ""
    property bool chosenByHand: false

    function keyOfRow(row) {
        if (!row || !row.entry)
            return "";
        return `${row.title}\u0000${row.entry.name ?? ""}`;
    }

    function indexOfKey(key) {
        if (key.length === 0)
            return -1;
        for (let i = 0; i < root.rows.length; i++) {
            if (root.keyOfRow(root.rows[i]) === key)
                return i;
        }
        return -1;
    }

    // Hover follows the pointer only once it has moved since the rows last changed, so rows
    // sliding in under a resting pointer do not take the choice from the keyboard.
    property point lastPointer: Qt.point(-1, -1)
    function pointerAt(index, at) {
        const moved = root.lastPointer.x >= 0 && (Math.abs(at.x - root.lastPointer.x) > 1 || Math.abs(at.y - root.lastPointer.y) > 1);
        root.lastPointer = at;
        if (moved && index !== root.chosen) {
            root.chosenByHand = true;
            root.select(index);
        }
    }

    function select(index) {
        root.chosen = index;
        if (index >= 0)
            resultsList.positionViewAtIndex(index, ListView.Contain);
        root.selectedKey = root.keyOfRow(root.rows[index]);
        root.selectedQuery = PaletteSearch.query;
    }

    // Goes true once the slide has settled: until then the chosen wash snaps instead of travelling.
    property bool settled: false

    Timer {
        id: settleTimer
        interval: Appearance.animationCurves.expressiveDefaultSpatialDuration
        onTriggered: root.settled = true
    }

    Connections {
        target: GlobalStates
        function onOverviewOpenChanged() {
            root.settled = false;
            root.selectedKey = "";
            root.chosenByHand = false;
            root.lastPointer = Qt.point(-1, -1);
            if (GlobalStates.overviewOpen) {
                closedTimer.stop();
                settleTimer.restart();
                PaletteRecent.reload();
            } else {
                settleTimer.stop();
                closedTimer.restart();
            }
        }
    }

    // Nothing typed: nothing is chosen, so Enter cannot open a recent thing by surprise; Up picks one.
    readonly property int selectionFloor: root.answerEntry !== null || PaletteSearch.query.length === 0 ? -1 : 0

    function selectFirstResult() {
        root.select(root.selectionFloor < 0 || root.rows.length === 0 ? -1 : 0);
    }

    // +1 is up, away from the field, to the next result; -1 back toward the field
    function moveSelection(delta) {
        const top = root.rows.length - 1;
        if (top < 0)
            return;
        root.chosenByHand = true;
        root.select(Math.max(root.selectionFloor, Math.min(top, root.chosen + delta)));
    }

    function jumpSection(delta) {
        const starts = [];
        let last = null;
        for (let i = 0; i < root.rows.length; i++) {
            if (root.rows[i].key !== last) {
                starts.push(i);
                last = root.rows[i].key;
            }
        }
        if (starts.length === 0)
            return;
        let section = 0;
        for (let i = 0; i < starts.length; i++) {
            if (starts[i] <= root.chosen)
                section = i;
        }
        section = ((section + delta) % starts.length + starts.length) % starts.length;
        root.chosenByHand = true;
        root.select(starts[section]);
    }

    function activate(keepOpen) {
        // Cached before closing: closing empties the sections
        const entry = root.selectedEntry;
        if (!entry)
            return;
        if (!keepOpen)
            root.dockDone();
        const own = (entry.verb ?? "").length > 0 ? entry.verb : Translation.tr("Open");
        const actions = (entry.actions ?? []).filter(action => action.name !== own);
        const action = root.verbIndex > 0 ? actions[root.verbIndex - 1] : null;
        if (!keepOpen)
            GlobalStates.overviewOpen = false;
        if (action)
            action.execute();
        else
            entry.execute();
    }

    function completeSelection() {
        const entry = root.rowChosen ? root.selectedEntry : null;
        if (!entry)
            return;
        root.settingText = true;
        searchInput.text = entry.name;
        root.settingText = false;
        PaletteSearch.query = root.kindPrefix + searchInput.text;
        searchInput.cursorPosition = searchInput.text.length;
    }

    /**
     * The selected row's Shift+Enter action, if it has one. Only window rows carry it today:
     * Enter focuses the window, Shift+Enter pulls it onto the current workspace instead.
     */
    readonly property var secondaryAction: (root.selectedEntry?.actions ?? []).find(candidate => candidate.name === PaletteWindows.moveHereLabel) ?? null

    function runSecondaryAction() {
        const action = root.secondaryAction;
        if (!action)
            return false;
        GlobalStates.overviewOpen = false;
        action.execute();
        return true;
    }

    function runDeleteAction() {
        const entry = root.selectedEntry;
        if (!entry)
            return;
        const action = (entry.actions ?? []).find(candidate => candidate.name === Translation.tr("Delete"));
        if (action)
            action.execute();
    }

    // ------------------------------------------------------------- voice: empty
    readonly property string emptyQuery: PaletteSearch.body
    // "Nothing matches" only once nothing has come for a moment: shown at once, it flashed between
    // letters while the sources were still answering
    readonly property bool emptyNow: PaletteSearch.query.length > 0 && root.rows.length === 0 && root.answerEntry === null && !PaletteSearch.busy
    property bool showEmpty: false
    onEmptyNowChanged: {
        if (root.emptyNow) {
            emptyTimer.restart();
        } else {
            emptyTimer.stop();
            root.showEmpty = false;
        }
    }
    Timer {
        id: emptyTimer
        interval: 260
        onTriggered: root.showEmpty = root.emptyNow
    }
    readonly property string emptyTitle: {
        const section = PaletteSearch.activeSection;
        if (section === "files" && !PaletteFiles.available)
            return Translation.tr("File search is not available on this computer.");
        if (section === "files" && PaletteFiles.failed)
            return Translation.tr("File search failed.");
        if (section === "calculator" && PaletteSearch.mathError)
            return Translation.tr("Not a valid expression.");
        if (PaletteSearch.busy)
            return Translation.tr("Still looking.");
        // a kind chosen with nothing typed yet: say what to do, not what was not found for ""
        if (section.length > 0 && root.emptyQuery.trim().length === 0 && section !== "clipboard") {
            if (section === "windows")
                return Translation.tr("No windows open.");
            return Translation.tr("Type to search %1.").arg(PaletteSearch.activeSectionTitle);
        }
        if (section === "clipboard" && Cliphist.entries.length === 0)
            return Translation.tr("Clipboard is empty.");
        if (section === "emoji")
            return Translation.tr("No emoji for \"%1\".").arg(root.emptyQuery);
        if (section === "files")
            return Translation.tr("No files matching \"%1\".").arg(root.emptyQuery);
        if (section === "keybinds")
            return Translation.tr("No keybind mentions \"%1\".").arg(root.emptyQuery);
        return Translation.tr("Nothing matches \"%1\".").arg(root.emptyQuery);
    }

    // Any printable key typed while the input somehow lost focus goes to the input
    Keys.onPressed: event => {
        if (searchInput.activeFocus)
            return;
        if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 0x20) {
            root.focusSearchInput();
            searchInput.insert(searchInput.cursorPosition, event.text);
            event.accepted = true;
        }
    }

    readonly property color colWash: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
    readonly property color colKey: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)

    component KeyChip: Rectangle {
        property string label
        implicitHeight: 20
        implicitWidth: keyChipLabel.implicitWidth + 14
        radius: 6
        color: root.colKey
        StyledText {
            id: keyChipLabel
            anchors.centerIn: parent
            text: parent.label
            font.pixelSize: 13
            font.weight: Font.Medium
            color: Tacit.inkSec
        }
    }

    // ------------------------------------------------------------ the peek: Lift
    // Rest on an open program and one large live picture of its window grows up out of the pill: a
    // slab with coves where it meets the dock's top edge, the notch's way of leaving an edge. Slide
    // the pointer across the picture to step through the program's other windows; click to go there.
    // The slab takes one size for all of a program's windows (the largest), so sliding never moves or
    // resizes it under the pointer. Corners are concentric with the dock's (30 = picture 16 + 14).
    Item {
        id: peekTab
        readonly property bool wanted: root.dockMode && dock.peeking
        readonly property int pad: 14
        readonly property int lineHeight: 22
        readonly property int corner: Appearance.rounding.verylarge
        // the coves land on the dock's straight top, clear of its round corners
        readonly property real margin: peekTab.corner + 12

        // what the slab is sized for (the program rested on) and what it shows (the same, after a
        // program switch has faded the old one out)
        readonly property var target: peekTab.layoutFor(dock.shownEntry)
        property var showing: null
        readonly property var shown: peekTab.layoutFor(peekTab.showing)
        property int index: 0
        readonly property var current: peekTab.shown.windows[peekTab.index] ?? null

        // the program's windows, those on this workspace first, each fitted to the picture's height
        function layoutFor(entry) {
            const list = (entry?.toplevels ?? []).slice();
            const here = HyprlandData.activeWorkspace?.id;
            const wsOf = t => HyprlandData.clientForToplevel(t)?.workspace?.id ?? 0;
            list.sort((a, b) => (wsOf(a) === here ? -1 : 0) - (wsOf(b) === here ? -1 : 0) || wsOf(a) - wsOf(b));
            const maxW = Math.min(520, frame.width - peekTab.margin * 2 - peekTab.pad * 2);
            const sizes = list.map(t => {
                const size = HyprlandData.clientForToplevel(t)?.size ?? [16, 10];
                let h = 300, w = h * size[0] / size[1];
                if (w > maxW) {
                    w = maxW;
                    h = w * size[1] / size[0];
                }
                return Qt.size(Math.round(w), Math.round(h));
            });
            const picW = Math.max(292, ...sizes.map(z => z.width)), picH = Math.max(0, ...sizes.map(z => z.height));
            return {
                "windows": list,
                "sizes": sizes,
                "picW": picW,
                "picH": picH,
                "width": picW + peekTab.pad * 2,
                "height": peekTab.pad + picH + 12 + peekTab.lineHeight + 12
            };
        }
        function wordFor(t) {
            const ws = HyprlandData.clientForToplevel(t)?.workspace?.id;
            return ws === undefined || ws === HyprlandData.activeWorkspace?.id ? Translation.tr("here") : Translation.tr("workspace %1").arg(ws);
        }

        // the slab: from the pill's own place up to its size over it, and back
        property real slabX: 0
        property real slabWidth: 0
        property real slabHeight: 0
        x: peekTab.slabX
        width: peekTab.slabWidth
        height: peekTab.slabHeight
        anchors.bottom: frame.top
        visible: peekTab.slabHeight > 0.5

        readonly property real pillLeft: frame.x + dock.x + dock.peekPill.x
        readonly property real targetX: Math.max(frame.x + peekTab.margin, Math.min(frame.x + frame.width - peekTab.margin - peekTab.target.width,
            peekTab.pillLeft + dock.peekPill.width / 2 - peekTab.target.width / 2))
        function moveTo(x, w, h, duration) {
            slabMove.duration = duration;
            moveX.to = x;
            moveW.to = w;
            moveH.to = h;
            slabMove.restart();
        }
        ParallelAnimation {
            id: slabMove
            property int duration: Appearance.animationCurves.normalDuration
            NumberAnimation {
                id: moveX
                target: peekTab
                property: "slabX"
                duration: slabMove.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasized
            }
            NumberAnimation {
                id: moveW
                target: peekTab
                property: "slabWidth"
                duration: slabMove.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasized
            }
            NumberAnimation {
                id: moveH
                target: peekTab
                property: "slabHeight"
                duration: slabMove.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasized
            }
        }
        function open() {
            // rising again while it still sinks carries on from where it is
            if (peekTab.slabHeight < 1) {
                peekTab.slabX = peekTab.pillLeft;
                peekTab.slabWidth = dock.peekPill.width;
                peekTab.slabHeight = 0;
                swap.stop();
                content.opacity = 1;
                peekTab.showing = dock.shownEntry;
                peekTab.index = 0;
            } else if (peekTab.showing !== dock.shownEntry) {
                swap.restart();
            }
            peekTab.moveTo(peekTab.targetX, peekTab.target.width, peekTab.target.height, Appearance.animationCurves.normalDuration);
        }
        onWantedChanged: {
            if (peekTab.wanted)
                peekTab.open();
            else
                peekTab.moveTo(peekTab.pillLeft, dock.peekPill.width, 0, 300);
        }
        Connections {
            target: dock
            function onShownEntryChanged() {
                if (peekTab.wanted)
                    peekTab.open();
            }
        }
        // a window opened or closed while it shows: the slab takes the new size
        onTargetChanged: if (peekTab.wanted && !swap.running && peekTab.showing === dock.shownEntry) {
            peekTab.index = Math.min(peekTab.index, Math.max(0, peekTab.target.windows.length - 1));
            peekTab.moveTo(peekTab.targetX, peekTab.target.width, peekTab.target.height, Appearance.animationCurves.normalDuration);
        }
        // another program: the old picture fades out, then the new one in, while the slab reshapes
        SequentialAnimation {
            id: swap
            NumberAnimation {
                target: content
                property: "opacity"
                to: 0
                duration: 120
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasizedAccel
            }
            ScriptAction {
                script: {
                    peekTab.showing = dock.shownEntry;
                    peekTab.index = 0;
                }
            }
            NumberAnimation {
                target: content
                property: "opacity"
                to: 1
                duration: Appearance.animationCurves.expressiveEffectsDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
            }
        }

        HoverHandler {
            onHoveredChanged: hovered ? dock.hold() : dock.leave()
        }
        DockedRect {
            anchors.fill: parent
            edge: "bottom"
            cornerRadius: peekTab.corner
            fillet: 12
            color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerHigh, 0.08)
        }
        // uncovered as the slab grows, centred in it (the slab itself does not clip: its coves reach past its sides)
        Item {
            anchors.fill: parent
            clip: true

            Item {
                id: content
                x: (peekTab.width - content.width) / 2
                anchors.bottom: parent.bottom
                width: peekTab.shown.width
                height: peekTab.shown.height

                Item {
                    id: picture
                    x: peekTab.pad
                    y: peekTab.pad
                    width: peekTab.shown.picW
                    height: peekTab.shown.picH

                    Repeater {
                        model: peekTab.shown.windows
                        Item {
                            id: shot
                            required property var modelData
                            required property int index
                            readonly property size size: peekTab.shown.sizes[shot.index] ?? Qt.size(0, 0)
                            readonly property int rel: shot.index - peekTab.index
                            readonly property string symbol: dock.known[shot.modelData.appId]?.symbol ?? ""
                            anchors.fill: parent
                            // the next window slides in from the side the pointer moved toward
                            opacity: shot.rel === 0 ? 1 : 0
                            visible: opacity > 0
                            transform: Translate {
                                x: shot.rel === 0 ? 0 : (shot.rel > 0 ? 20 : -20)
                                Behavior on x {
                                    Anim {
                                        type: Anim.EmphasizedSmall
                                    }
                                }
                            }
                            Behavior on opacity {
                                Anim {
                                    type: Anim.EmphasizedSmall
                                }
                            }
                            ClippingRectangle {
                                anchors.centerIn: parent
                                width: shot.size.width
                                height: shot.size.height
                                radius: 16
                                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
                                // until the first frame arrives, the program's own symbol or icon
                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    visible: !copy.hasContent && shot.symbol.length > 0
                                    text: shot.symbol
                                    iconSize: 36
                                    color: Appearance.colors.colSubtext
                                }
                                IconImage {
                                    anchors.centerIn: parent
                                    visible: !copy.hasContent && shot.symbol.length === 0
                                    source: visible ? Quickshell.iconPath(AppSearch.guessIcon(shot.modelData.appId), "image-missing") : ""
                                    implicitSize: 40
                                }
                                ScreencopyView {
                                    id: copy
                                    anchors.fill: parent
                                    // the shown window and its neighbours hold a frame, so sliding to one shows it at once; only the one shown stays live
                                    captureSource: peekTab.visible && Math.abs(shot.rel) <= 1 ? shot.modelData : null
                                    live: shot.rel === 0
                                    opacity: copy.hasContent ? 1 : 0
                                    Behavior on opacity {
                                        Anim {
                                            type: Anim.EmphasizedSmall
                                        }
                                    }
                                }
                            }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPositionChanged: mouse => {
                            const n = peekTab.shown.windows.length;
                            if (n > 1)
                                peekTab.index = Math.min(n - 1, Math.max(0, Math.floor(mouse.x / width * n)));
                        }
                        onClicked: {
                            peekTab.current?.activate();
                            root.dockDone();
                        }
                    }
                }

                // the window's title, where it lives, and which of the program's windows this is
                Item {
                    x: peekTab.pad + 6
                    y: peekTab.pad + peekTab.shown.picH + 12
                    width: content.width - peekTab.pad * 2 - 12
                    height: peekTab.lineHeight
                    StyledText {
                        id: liftTitle
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width - liftWord.implicitWidth - dots.width - 24)
                        elide: Text.ElideRight
                        text: peekTab.current?.title ?? ""
                        font.pixelSize: Appearance.font.pixelSize.small
                        font.weight: Font.Medium
                        color: Appearance.m3colors.m3onSurface
                    }
                    StyledText {
                        id: liftWord
                        x: liftTitle.width + 12
                        anchors.baseline: liftTitle.baseline
                        text: peekTab.current ? peekTab.wordFor(peekTab.current) : ""
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                    Row {
                        id: dots
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        visible: peekTab.shown.windows.length > 1
                        Repeater {
                            model: peekTab.shown.windows.length
                            Rectangle {
                                required property int index
                                readonly property bool lit: index === peekTab.index
                                width: lit ? 16 : 6
                                height: 6
                                radius: 3
                                color: lit ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.72)
                                Behavior on width {
                                    Anim {
                                        type: Anim.EmphasizedSmall
                                    }
                                }
                                Behavior on color {
                                    ColorAnimation {
                                        duration: Appearance.animationCurves.expressiveEffectsDuration
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // One silhouette with the edge. The control panel's frost: this one also opens on the
    // brightest part of the wallpaper, where 0.76 let the colour behind it through as rust.
    DockedRect {
        anchors.fill: frame
        edge: "bottom"
        cornerRadius: Appearance.rounding.verylarge
        fillet: root.dockCornerSize
        color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerHigh, 0.08)
    }

    Item {
        id: frame
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        // The dock's width, widened into the search's on the notch's quick curve, and back on its close;
        // kept as it is while the shape slides away (it jumped to the search's width as the dock left)
        property real shapeWidth: root.paletteWidth
        Binding {
            target: frame
            property: "shapeWidth"
            value: root.dockMode ? Math.min(root.dockMaxWidth, dock.implicitWidth) : root.paletteWidth
            when: !root.out
            restoreMode: Binding.RestoreNone
        }
        width: frame.shapeWidth
        Behavior on width {
            enabled: !root.out && root.armed
            NumberAnimation {
                duration: root.searching ? Appearance.animationCurves.expressiveFastSpatialDuration : 450
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.searching ? Appearance.animationCurves.expressiveFastSpatial : Appearance.animationCurves.emphasizedDecel
            }
        }
        // the bottom band (the field, or the dock with its peek) and the results above it; the list
        // collapses on its own curve, so search -> dock lowers smoothly
        height: root.fieldHeight
            + resultsList.height + (resultsList.height > 0 ? 20 : 0) + emptyBand.height
        clip: true

        // ------------------------------------------------------------ the dock
        PaletteDock {
            id: dock
            anchors.bottom: parent.bottom
            x: (frame.width - dock.implicitWidth) / 2
            maxWidth: root.dockMaxWidth
            restOffset: (root.implicitHeight + 16) * root.offsetScale
            discX: disc.x - dock.x
            visible: root.travel < 1
            enabled: root.dockMode
            onOpened: root.dockDone()
        }

        // ------------------------------------------------------------ results
        ListView {
            id: resultsList
            anchors.bottom: field.top
            anchors.bottomMargin: 4
            width: parent.width
            // the best result nearest the field; the list grows up out of it
            verticalLayoutDirection: ListView.BottomToTop
            readonly property real wanted: root.rows.length > 0 && root.offsetScale < 1 && !root.dockMode && !root.morphing ? Math.min(root.maxListHeight, root.rows.length * root.rowHeight) : 0
            height: resultsList.wanted
            // the palette's list: Emphasized, no overshoot; the first rise on the full curve, the
            // changes while typing on the short one so the list keeps up with the letters
            Behavior on height {
                enabled: !root.out
                Anim {
                    type: resultsList.height > 1 && resultsList.wanted > 1 ? Anim.EmphasizedSmall : Anim.Emphasized
                }
            }
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            model: root.rows
            // rows are handed back to a pool and reused when the results change, not destroyed and
            // created again on every letter
            reuseItems: true
            // only the rows on screen are built; the ones below are made as the list scrolls
            cacheBuffer: 0

            // the chosen row's wash, under the rows. Bottom-to-top, row i sits at -(i + 1) rows.
            Rectangle {
                parent: resultsList.contentItem
                z: -1
                visible: root.chosen >= 0 && root.chosen < root.rows.length
                x: 10
                width: resultsList.width - 20
                y: -(Math.max(0, root.chosen) + 1) * root.rowHeight
                height: root.rowHeight
                radius: 17
                color: root.colWash
                // the short emphasized curve: an arrow held down hops row after row
                Behavior on y {
                    enabled: root.settled && !root.rowsChanging
                    Anim {
                        type: Anim.EmphasizedSmall
                    }
                }
            }

            delegate: SearchItem {
                id: rowItem
                required property int index
                required property var modelData
                width: resultsList.width
                entry: rowItem.modelData.entry
                current: rowItem.index === root.chosen
                verbIndex: rowItem.index === root.chosen ? root.verbIndex : 0
                onPointerMoved: at => root.pointerAt(rowItem.index, at)
                onPicked: {
                    root.chosenByHand = true;
                    root.select(rowItem.index);
                    root.activate(false);
                }
                onVerbPicked: index => {
                    root.chosenByHand = true;
                    root.select(rowItem.index);
                    root.verbIndex = index;
                    root.activate(false);
                }
            }
        }

        // ---------------------------------------------------- nothing found
        Item {
            id: emptyBand
            anchors.bottom: field.top
            width: parent.width
            height: root.showEmpty && !root.dockMode ? 56 : 0
            visible: height > 0
            StyledText {
                anchors.centerIn: parent
                text: root.emptyTitle
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
        }

        // ------------------------------------------------------------ the field
        Item {
            id: field
            anchors.bottom: parent.bottom
            width: parent.width
            height: root.fieldHeight

            // The search disc: sand while it is what Enter does, the quiet wash once a row is
            Rectangle {
                id: disc
                readonly property real dockEnd: dock.x + dock.implicitWidth - 18 - 44
                x: disc.dockEnd * (1 - root.travel) + 20 * root.travel
                anchors.verticalCenter: parent.verticalCenter
                width: 44 - 4 * root.travel
                height: width
                radius: width / 2
                readonly property bool quiet: root.searching && (root.rowChosen || root.answerChosen)
                MouseArea {
                    anchors.fill: parent
                    enabled: root.dockMode
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.searchRequested()
                }
                color: disc.quiet ? root.colWash : Appearance.colors.colPrimary
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "search"
                    iconSize: 20
                    color: disc.quiet ? Appearance.colors.colSubtext : Appearance.colors.colOnPrimary
                }
            }

            StyledTextInput {
                id: searchInput
                x: disc.x + 56
                // kept visible while transparent: an invisible item cannot hold the keyboard, and
                // the dock types into it
                opacity: Math.max(0, Math.min(1, root.travel * 1.6 - 0.4))
                anchors.verticalCenter: parent.verticalCenter
                width: rightSide.x - searchInput.x - 24 - (answerText.visible ? answerText.implicitWidth + 12 : 0)
                focus: GlobalStates.overviewOpen && root.paletteMode
                font.pixelSize: Appearance.font.pixelSize.larger
                color: Appearance.m3colors.m3onSurface
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                clip: true

                onTextChanged: {
                    if (root.settingText)
                        return;
                    // a prefix typed first picks the kind, as it always has
                    if (root.kindPrefix.length === 0 && searchInput.text.length > 0) {
                        const prefix = PaletteSearch.prefixOf(searchInput.text);
                        if (prefix.length > 0) {
                            root.kindPrefix = prefix;
                            root.settingText = true;
                            searchInput.text = searchInput.text.slice(prefix.length);
                            root.settingText = false;
                        }
                    }
                    // typing on the dock turns it into the search, the letters already in the field
                    if (root.dockKeys && (searchInput.text.length > 0 || root.kindPrefix.length > 0)) {
                        root.searchRequested();
                        return;
                    }
                    // everything erased in a search that came from the dock: back to the dock
                    if (root.searching && root.dockShown && searchInput.text.length === 0 && root.kindPrefix.length === 0) {
                        root.backToDock();
                        return;
                    }
                    if (!root.morphing)
                        queryTimer.restart();
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text.length === 0
                    text: Translation.tr("Search")
                    font.pixelSize: Appearance.font.pixelSize.larger
                    color: Tacit.inkFaint             // by brightness, never by opacity
                }

                Keys.onPressed: event => {
                    const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
                    const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
                    const alt = (event.modifiers & Qt.AltModifier) !== 0;
                    if (root.dockKeys) {
                        if (event.key === Qt.Key_Escape)
                            GlobalStates.overviewOpen = false;
                        else if (alt && (event.key === Qt.Key_Left || event.key === Qt.Key_Right))
                            dock.moveFocusedBy(event.key === Qt.Key_Left ? -1 : 1);
                        else if (ctrl && event.key === Qt.Key_P)
                            dock.togglePinFocused();
                        else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab)
                            dock.moveFocus(-1);
                        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
                            dock.moveFocus(1);
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            shift ? dock.launchFocused() : dock.openFocused();
                        else
                            return; // a letter: typed into the field, which starts the search
                        event.accepted = true;
                        return;
                    }
                    if (event.key === Qt.Key_Escape) {
                        // Esc clears what is typed, then closes (or goes back to the dock it came
                        // from); Backspace on an empty field goes back to All
                        if (root.dockShown)
                            root.backToDock();
                        else if (searchInput.text.length > 0)
                            root.setSearchingText(root.kindPrefix);
                        else
                            GlobalStates.overviewOpen = false;
                    } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && ctrl)) {
                        root.moveSelection(1);
                    } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && ctrl)) {
                        root.moveSelection(-1);
                    } else if (event.key === Qt.Key_Right && !ctrl && searchInput.cursorPosition === searchInput.text.length && root.verbIndex < root.selectedVerbs.length - 1) {
                        root.verbIndex += 1;
                    } else if (event.key === Qt.Key_Left && !ctrl && root.verbIndex > 0) {
                        root.verbIndex -= 1;
                    } else if (event.key === Qt.Key_K && ctrl) {
                        // the old Ctrl+K sheet's keys: step through the verbs, round
                        if (root.selectedVerbs.length > 0)
                            root.verbIndex = (root.verbIndex + 1) % root.selectedVerbs.length;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // Enter faster than the search waits: run it now, so Enter acts on what
                        // was typed, not on the rows from before
                        if (root.morphing || queryTimer.running) {
                            morphTimer.stop();
                            queryTimer.stop();
                            root.morphing = false;
                            root.applyQuery();
                            root.selectFirstResult();
                        }
                        // Shift+Enter runs the row's secondary action when it has one (window
                        // rows: move here), else keeps the palette open
                        if (!shift || !root.runSecondaryAction())
                            root.activate(shift);
                    } else if (event.key === Qt.Key_Tab && ctrl) {
                        root.jumpSection(shift ? -1 : 1);
                    } else if (event.key === Qt.Key_Backtab) {
                        root.stepKind(-1);
                    } else if (event.key === Qt.Key_Tab) {
                        root.stepKind(1);
                    } else if (event.key === Qt.Key_Space && ctrl) {
                        root.completeSelection();
                    } else if (event.key === Qt.Key_Delete && shift) {
                        root.runDeleteAction();
                    } else if (event.key === Qt.Key_Backspace && searchInput.text.length === 0 && root.kindPrefix.length > 0) {
                        root.setSearchingText("");
                    } else {
                        return;
                    }
                    event.accepted = true;
                }
            }

            // a sum answered in the field, in the sand of what Enter will do
            StyledText {
                id: answerText
                x: searchInput.x + Math.min(searchInput.contentWidth, searchInput.width) + 12
                anchors.verticalCenter: parent.verticalCenter
                visible: root.answerEntry !== null && searchInput.text.length > 0
                text: `= ${root.answerEntry?.name ?? ""}`
                font.pixelSize: Appearance.font.pixelSize.larger
                font.weight: Font.Medium
                color: root.answerChosen ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }

            // the kind word and its Tab chip step the kind on a click too (right-click steps back)
            MouseArea {
                id: kindArea
                enabled: root.searching
                x: rightSide.x + kindWord.x - 8
                y: rightSide.y - 10
                width: rightSide.width - kindWord.x + 16
                height: rightSide.height + 20
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                    root.stepKind(mouse.button === Qt.RightButton ? -1 : 1);
                    searchInput.forceActiveFocus();
                }
            }

            // what Enter does with the answer, the kind of search, and Tab
            Row {
                id: rightSide
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                opacity: Math.max(0, Math.min(1, root.travel * 2 - 1))
                visible: opacity > 0

                StyledText {
                    visible: root.answerChosen
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.answerEntry?.verb ?? ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    font.weight: Font.Medium
                    color: Appearance.colors.colSubtext
                }
                KeyChip {
                    visible: root.answerChosen
                    anchors.verticalCenter: parent.verticalCenter
                    label: "↵"
                }
                Item {
                    visible: root.answerChosen
                    width: 8
                    height: 1
                }
                MaterialSymbol {
                    id: spinner
                    visible: PaletteSearch.busy
                    anchors.verticalCenter: parent.verticalCenter
                    text: "progress_activity"
                    iconSize: 16
                    color: Appearance.colors.colSubtext
                    RotationAnimation on rotation {
                        running: spinner.visible
                        loops: Animation.Infinite
                        duration: 1000
                        from: 0
                        to: 360
                    }
                }
                StyledText {
                    id: kindWord
                    anchors.verticalCenter: parent.verticalCenter
                    // out upward, the next one in from below
                    property string shown: root.kindTitle
                    text: kindWord.shown
                    transform: Translate {
                        id: kindShift
                    }
                    Connections {
                        target: root
                        function onKindTitleChanged() {
                            kindSwap.restart();
                        }
                    }
                    SequentialAnimation {
                        id: kindSwap
                        ParallelAnimation {
                            NumberAnimation { target: kindWord; property: "opacity"; to: 0; duration: 90; easing.type: Easing.InQuad }
                            NumberAnimation { target: kindShift; property: "y"; to: -6; duration: 90; easing.type: Easing.InQuad }
                        }
                        ScriptAction { script: kindWord.shown = root.kindTitle }
                        PropertyAction { target: kindShift; property: "y"; value: 6 }
                        ParallelAnimation {
                            NumberAnimation { target: kindWord; property: "opacity"; to: 1; duration: 160; easing.type: Easing.OutCubic }
                            NumberAnimation { target: kindShift; property: "y"; to: 0; duration: 160; easing.type: Easing.OutCubic }
                        }
                    }
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    font.weight: Font.Medium
                    color: kindArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                }
                KeyChip {
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Tab"
                }
            }
        }
    }
}
