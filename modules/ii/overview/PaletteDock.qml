pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

/**
 * The dock: the palette's bottom row while nothing is searched (SearchWidget.qml). Programs as
 * symbol + name pills, the open ones raised in the wash an "on" toggle wears; the search disc
 * waits at the end (SearchWidget draws it). Rest on an open program and its windows rise above
 * it as live pictures. Click opens or focuses (again: the next window); middle-click opens a new
 * one; right-click (a two-finger tap) opens its menu; drag a pinned program to move it: the row opens its place as it
 * goes and settles it in before the order is written. The peek itself is drawn by
 * SearchWidget.qml, outside the dock's shape (it grows out of the dock's top edge).
 *
 * Never wider than the search: when the names would make it so, closed programs lose theirs
 * first, then all do.
 *
 * The pills are the dock's own form (a tile under every program read as any other dock): closed
 * programs bare, open ones on the wash, the one you are in on the brighter wash with Praxis's sand
 * tick under it. One tick, which travels to the program you go to. Each state's ink is solved for its
 * contrast on the ground it stands on (see inkClosed). An initial when a program has no icon (it was an empty circle). Pressing sinks
 * a pill; a program starting breathes until its window is there. Once the names have had to go, a
 * closed program says its name above itself while pointed at (an open one shows its windows). A
 * hairline parts the pinned from the others running.
 */
Item {
    id: root

    property real maxWidth: 880
    // how far the dock still is from where it rests while it slides in (SearchWidget's slide), so the window band can
    // name a button's place before the dock has arrived
    property real restOffset: 0
    // where the disc stands, in this item's x: programs fade where it has passed over them
    property real discX: width
    // the peek, above the row (SearchWidget draws it)
    readonly property bool peeking: root.peekEntry !== null
    signal opened

    readonly property real rowHeight: 78
    readonly property real discSpace: 44 + 10
    implicitWidth: programRow.width + 18 * 2 + root.discSpace
    implicitHeight: root.rowHeight
    // where the program peeked sits, in this item's x: the peek grows out of it and sinks back into it
    readonly property var peekPill: {
        for (let i = 0; i < programRow.children.length; i++) {
            const child = programRow.children[i];
            if (child.appId && root.shownEntry && child.appId === root.shownEntry.appId)
                return { "x": programRow.x + child.x, "width": child.width };
        }
        return { "x": root.width / 2 - 22, "width": 44 };
    }

    // ------------------------------------------------------------- programs
    readonly property var programs: TaskbarApps.apps.filter(app => app.appId !== "SEPARATOR")

    // Tacit's own programs carry Tacit's names and symbols; any other program shows its own icon
    readonly property var known: ({
            "org.quickshell": { "name": "Pinax", "symbol": "folder" },
            "praxis": { "name": "Praxis", "symbol": "auto_awesome" },
            "browser": { "name": "Thyris", "symbol": "public" },
            "browser-cef": { "name": "Thyris", "symbol": "public" },
            "thyris": { "name": "Thyris", "symbol": "public" },   // the package's entry id (installed systems)
            "viewer": { "name": "Viewer", "symbol": "photo" },
            "graphis": { "name": "Graphis", "symbol": "code" },
            "settings": { "name": "Settings", "symbol": "tune" },
            "foot": { "name": "Terminal", "symbol": "terminal" }
        })

    function entryFor(appId) {
        return DesktopEntries.heuristicLookup(appId);
    }
    // Quickshell reads the menu entries only when something first asks for their list, and a lookup before that
    // finds nothing: on a fresh session the first click on a closed program did nothing (2026-10-29). Asked at start.
    readonly property int entryCount: DesktopEntries.applications.values.length
    // A program's own name; when its menu entry cannot be found, its id made readable ("brave-browser" is Brave,
    // "app.zen_browser.zen" is Zen), never the raw id
    function nameFor(appId) {
        const known = root.known[appId]?.name ?? root.entryFor(appId)?.name;
        if (known) return known;
        const words = String(appId).split(".").pop().split(/[-_]+/).filter(w => w.length && !/^(browser|desktop|app|bin|stable)$/i.test(w));
        const pretty = (words.length ? words : [String(appId)]).map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(" ");
        return pretty;
    }

    readonly property int tile: 44
    // the program just asked to start, until its window is there (or 8 s have gone)
    property string launching: ""
    // until the window shows or the start is known to have failed (AppScope); a minute at most. At 8 s it went out while
    // a slow app was still starting, and an app that never started looked the same as one on its way
    Timer { id: launchTimer; interval: 60000; onTriggered: root.launching = "" }
    Connections {
        target: AppScope
        function onStartFailed(entryId) {
            if (root.launching !== "" && root.entryFor(root.launching)?.id === entryId) {
                root.launching = "";
                launchTimer.stop();
            }
        }
    }
    // 0 every name, 1 open programs only, 2 symbols only
    readonly property int tier: {
        const room = root.maxWidth - 36 - root.discSpace;
        let full = 0, openOnly = 0;
        for (let i = 0; i < measures.count; i++) {
            const m = measures.itemAt(i);
            if (!m)
                continue;
            full += m.fullWidth + 6;
            openOnly += (m.open ? m.fullWidth : root.tile) + 6;
        }
        return full <= room ? 0 : (openOnly <= room ? 1 : 2);
    }
    Repeater {
        id: measures
        model: root.programs
        StyledText {
            required property var modelData
            readonly property bool open: modelData.toplevels.length > 0
            readonly property real fullWidth: 24 + 8 + implicitWidth + 24
            visible: false
            text: root.nameFor(modelData.appId)
            font.pixelSize: Appearance.font.pixelSize.smallish
        }
    }

    function activate(app) {
        // the windows the window band hid come back, all of them, each to its own place (the last one in front); held
        // windows are never cycled through
        const hidden = app.toplevels.filter(t => WindowBand.heldAs(t) === "hidden");
        // a window still on its way into the dock comes back out as soon as it lands
        const folding = app.toplevels.filter(t => WindowBand.heldAs(t) === "folding");
        if (hidden.length > 0 || folding.length > 0) {
            if (hidden.length > 0)
                WindowBand.reopenAll(hidden.map(t => WindowBand.addressOf(t)));
            for (const t of folding)
                WindowBand.reopenWhenHidden(WindowBand.addressOf(t));
            root.opened();
            return;
        }
        const windows = app.toplevels.filter(t => WindowBand.heldAs(t) === "");
        if (windows.length === 0) {
            root.launch(app.appId);
            return;
        }
        // again: the next window of the same program
        const active = windows.findIndex(t => t.activated);
        windows[(active + 1) % windows.length].activate();
        root.opened();
    }

    function launch(appId) {
        root.launching = appId;
        launchTimer.restart();
        if (appId === "org.quickshell")
            Files.openNew();
        else if (appId === "settings")
            SettingsApp.open("");
        else {
            const entry = root.entryFor(appId);
            if (entry) {
                PaletteFrecency.record(`app:${entry.id}`);
                AppScope.launch(entry);
            } else {
                root.launching = "";
                launchTimer.stop();
            }
        }
        root.opened();
    }

    // ------------------------------------------------------------- the keyboard
    // Opened with Super, the dock takes the keyboard: Left/Right move a soft sand wash across the
    // programs, Enter opens the one it is on. -1 is none (typing goes to the search instead).
    property int focusIndex: -1
    function moveFocus(delta) {
        const count = root.programs.length;
        if (count === 0)
            return;
        root.focusIndex = root.focusIndex < 0 ? (delta > 0 ? 0 : count - 1) : Math.max(0, Math.min(count - 1, root.focusIndex + delta));
        root.rest(root.programs[root.focusIndex]);
    }
    function openFocused() {
        const app = root.programs[root.focusIndex];
        if (app)
            root.activate(app);
    }
    // The keys for what the pointer does with a pill: Shift+Enter is the middle click (a new window), Ctrl+P the
    // right click (pin or unpin), Alt+Left/Right the drag. The wash stays on the program when the row re-forms.
    function keepFocusOn(appId) {
        const was = root.focusIndex;
        Qt.callLater(() => {
            const at = root.programs.findIndex(app => app.appId === appId);
            root.focusIndex = at >= 0 ? at : Math.min(was, root.programs.length - 1);
        });
    }
    function launchFocused() {
        const app = root.programs[root.focusIndex];
        if (app)
            root.launch(app.appId);
    }
    function togglePinFocused() {
        const app = root.programs[root.focusIndex];
        if (!app)
            return;
        TaskbarApps.togglePin(app.appId);
        root.keepFocusOn(app.appId);
    }
    function moveFocusedBy(delta) {
        const app = root.programs[root.focusIndex];
        if (!app || !app.pinned)
            return;
        const pins = (Config.options.dock.pinnedApps ?? []).slice();
        const from = pins.findIndex(id => id.toLowerCase() === app.appId);
        const to = from + delta;
        if (from < 0 || to < 0 || to >= pins.length)
            return;
        pins.splice(to, 0, pins.splice(from, 1)[0]);
        Config.options.dock.pinnedApps = pins;
        root.keepFocusOn(app.appId);
    }

    // ------------------------------------------------------------- reordering
    // A pinned pill is carried by the pointer. The row makes its room as it goes: the pills between it and
    // the place it would take slide over by its own width, so it is not laid on top of them. Let go, and it
    // settles into that place before the order is written: writing it rebuilds every pill at once, and a
    // pill still in the hand would leave it.
    property string draggingId: ""
    property real dragOffset: 0
    property int dragFrom: -1      // its place among the pinned programs
    property int dragTo: -1        // the place it would take
    property real dragHome: 0      // its centre where it rests, in the row
    property real dragWidth: 0     // its width: the room the others make for it
    property bool landing: false   // let go: it is going into dragTo now

    // Arrive, small (the guide's motion): it decelerates and ends still, so the pill reads as put down
    NumberAnimation {
        id: land
        target: root
        property: "dragOffset"
        duration: Appearance.animationCurves.smallDuration
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
        onFinished: {
            if (root.landing)
                root.finishDrag();
        }
    }

    function beginDrag(appId, homeX, width) {
        root.reset();
        root.draggingId = appId;
        const pins = Config.options.dock.pinnedApps ?? [];
        root.dragFrom = pins.findIndex(id => id.toLowerCase() === appId.toLowerCase());
        root.dragTo = root.dragFrom;
        root.dragHome = homeX;
        root.dragWidth = width;
    }

    // The place the carried pill has reached: the other pinned pills it has come past. Half the way to a
    // neighbour's centre already counts, so a pill a little short of the neighbour is in its place; laid
    // exactly on the neighbour's centre was the whole way, and the hand had to overshoot to change the row.
    function slotFor(x) {
        let to = 0;
        for (let i = 0; i < programRow.children.length; i++) {
            const child = programRow.children[i];
            if (!child.appId || !child.pinned || child.appId === root.draggingId)
                continue;
            const centre = child.x + child.width / 2;
            const reach = (root.dragWidth + child.width) / 2 + programRow.spacing;
            // the side the pill rests on: the room it gives is on the side it is coming from
            const bias = root.dragHome <= centre ? -reach / 2 : reach / 2;
            if (x > centre + bias)
                to++;
        }
        return to;
    }

    // the carried pill's centre where it comes to rest: the slots of the pills that keep their place up to
    // dragTo, then half its own width
    function landingOffset() {
        let x = 0, kept = 0;
        for (let i = 0; i < programRow.children.length; i++) {
            const child = programRow.children[i];
            if (!child.appId || !child.pinned || child.appId === root.draggingId)
                continue;
            if (kept === root.dragTo)
                break;
            x += child.width + programRow.spacing;
            kept++;
        }
        return x + root.dragWidth / 2 - root.dragHome;
    }

    function cancelDrag() {
        land.stop();
        root.landing = false;
        root.draggingId = "";
        root.dragFrom = -1;
        root.dragTo = -1;
        root.dragHome = 0;
        root.dragWidth = 0;
        root.dragOffset = 0;
    }

    function finishDrag() {
        const appId = root.draggingId;
        const from = root.dragFrom;
        const to = root.dragTo;
        root.cancelDrag();
        if (appId.length === 0 || from < 0 || to < 0 || from === to)
            return;
        const pins = (Config.options.dock.pinnedApps ?? []).slice();
        const at = pins.findIndex(id => id.toLowerCase() === appId.toLowerCase());
        if (at < 0)
            return;
        pins.splice(to, 0, pins.splice(at, 1)[0]);
        Config.options.dock.pinnedApps = pins;
    }

    // ------------------------------------------------------------- the menu
    // A right click (a two-finger tap) on a program: what can be done with it, as words, in a slab over its pill
    // (SearchWidget draws it). It took the place of a right click that took a pinned app off the dock at once
    // (Discord 2026-11-03), and then of one that only pinned.
    property var menuEntry: null
    readonly property var menuPill: {
        for (let i = 0; i < programRow.children.length; i++) {
            const child = programRow.children[i];
            if (child.appId && root.menuEntry && child.appId === root.menuEntry.appId)
                return { "x": programRow.x + child.x, "width": child.width };
        }
        return { "x": root.width / 2 - 22, "width": 44 };
    }
    function openMenu(app) {
        root.reset();
        root.menuEntry = app;
    }
    function menuAct(act) {
        const app = root.menuEntry;
        root.menuEntry = null;
        if (!app)
            return;
        if (act === "new")
            root.launch(app.appId);
        else if (act === "quit")
            app.toplevels.slice().forEach(t => t.close());
        else if (act === "pin" || act === "unpin")
            TaskbarApps.togglePin(app.appId);
    }

    // ------------------------------------------------------------- the peek
    property var peekEntry: null
    property var peekCandidate: null
    property var shownEntry: null
    onPeekEntryChanged: {
        if (root.peekEntry !== null)
            root.shownEntry = root.peekEntry;
    }
    Timer {
        id: peekTimer
        interval: 300
        onTriggered: root.peekEntry = root.peekCandidate
    }
    // already peeking: another program is followed after a beat, so crossing one on the way up to
    // the peek does not take it over
    Timer {
        id: followTimer
        interval: 140
        onTriggered: root.peekEntry = root.peekCandidate
    }
    Timer {
        id: unpeekTimer
        interval: 260
        onTriggered: {
            root.peekEntry = null;
            root.peekCandidate = null;
        }
    }
    function rest(app) {
        unpeekTimer.stop();
        // a pill being carried (or settling) is arranging the row, not asking for a program's windows; an open menu stays
        // the one thing over the dock until it is put away
        if (root.draggingId !== "" || root.landing || root.menuEntry !== null)
            return;
        if (!app || app.toplevels.length === 0) {
            peekTimer.stop();
            followTimer.stop();
            root.peekCandidate = null;
            if (root.peekEntry !== null)
                unpeekTimer.restart();
            return;
        }
        root.peekCandidate = app;
        if (root.peekEntry === app)
            followTimer.stop();
        else if (root.peekEntry !== null)
            followTimer.restart();
        else
            peekTimer.restart();
    }
    function leave() {
        peekTimer.stop();
        followTimer.stop();
        unpeekTimer.restart();
    }
    function hold() {
        unpeekTimer.stop();
    }
    function reset() {
        peekTimer.stop();
        followTimer.stop();
        unpeekTimer.stop();
        root.peekEntry = null;
        root.peekCandidate = null;
        root.focusIndex = -1;
        root.menuEntry = null;
        root.cancelDrag();
    }

    readonly property color colWash: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
    // the program you are in, and the one whose windows the peek shows
    readonly property color colWashLit: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.82)
    readonly property color colSandWash: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)

    // Inks by contrast: each state's ink is solved for APCA Lc on the ground it stands on (the dock's frost, the
    // wash, the brighter wash, the sand wash), so the steps hold on any palette. The panel inks are set for a darker
    // ground; here they came out at Lc 85 closed and 84 open, one step. Closed 60 (a mark), open 80, lit 92 (the
    // main ink's level); a closed program's name 75, the floor for small text.
    readonly property color groundDock: Appearance.m3colors.m3surfaceContainerHigh
    readonly property color inkClosed: Appearance.inkFor(60, root.groundDock)
    readonly property color inkClosedName: Appearance.inkFor(75, root.groundDock)
    readonly property color inkOpen: Appearance.inkFor(80, ColorUtils.mix(Appearance.m3colors.m3onSurface, root.groundDock, 0.12))
    readonly property color inkLit: Appearance.inkFor(92, ColorUtils.mix(Appearance.m3colors.m3onSurface, root.groundDock, 0.18))
    readonly property color inkHot: Appearance.inkFor(92, ColorUtils.mix(Appearance.colors.colPrimary, root.groundDock, 0.22))

    // the keyboard's place: a soft sand wash that slides between the programs
    Rectangle {
        id: focusWash
        readonly property Item over: root.focusIndex >= 0 ? (programRow.children[root.focusIndex] ?? null) : null
        x: programRow.x + (focusWash.over?.x ?? 0)
        y: programRow.y
        width: focusWash.over?.width ?? root.tile
        height: root.tile
        radius: 16
        color: root.colSandWash
        opacity: focusWash.over ? 1 : 0
        Behavior on x {
            enabled: focusWash.opacity > 0
            Anim {
                type: Anim.EmphasizedSmall
            }
        }
        Behavior on width {
            Anim {
                type: Anim.EmphasizedSmall
            }
        }
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
    }

    // Where you are: Praxis's sand tick under the program, one mark that travels to the next program you go to. It
    // follows a dragged pill, fades where the disc has swept, and fades in place when you are in none of them.
    Rectangle {
        id: tick
        readonly property Item under: {
            for (let i = 0; i < programRow.children.length; i++)
                if (programRow.children[i].here)
                    return programRow.children[i];
            return null;
        }
        // set at its first place, then it travels (it does not fly in from the dock's edge)
        property bool placed: false
        onUnderChanged: if (tick.under) Qt.callLater(() => tick.placed = true)
        z: 1
        width: 24
        height: 4
        radius: 2
        color: Tacit.accent
        y: programRow.y + root.tile + 4
        opacity: tick.under ? tick.under.swept : 0
        Binding on x {
            when: tick.under !== null
            value: tick.under ? programRow.x + tick.under.x + tick.under.width / 2 + (tick.under.dragging ? root.dragOffset : 0) - tick.width / 2 : 0
            restoreMode: Binding.RestoreNone
        }
        Behavior on x {
            enabled: tick.placed && !(tick.under?.dragging ?? false)
            Anim {
                type: Anim.Emphasized
            }
        }
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
    }

    // the row
    Row {
        id: programRow
        x: 18
        y: (root.rowHeight - root.tile) / 2 - 3
        spacing: 6
        move: Transition {
            Anim {
                properties: "x"
                type: Anim.Emphasized
            }
        }

        Repeater {
            model: root.programs
            Rectangle {
                id: pill
                required property var modelData
                required property int index
                // the first program that is running but not pinned: a hairline before it
                readonly property bool firstLoose: !pill.pinned && pill.index > 0 && root.programs[pill.index - 1].pinned
                readonly property bool here: pill.modelData.toplevels.some(t => t.activated && WindowBand.heldAs(t) === "")
                readonly property bool starting: root.launching === pill.appId && !pill.open
                readonly property bool hovered: pillArea.containsMouse
                onOpenChanged: if (pill.open && root.launching === pill.appId) root.launching = ""
                readonly property string appId: modelData.appId
                readonly property bool pinned: modelData.pinned
                // a window being closed by the window band is gone already; a hidden one still counts
                readonly property bool open: modelData.toplevels.some(t => WindowBand.heldAs(t) !== "closed")
                // a window of it hidden by the band: a hollow tick says it is there to come back (under the sand tick
                // when this is the program you are in)
                readonly property bool hasHidden: modelData.toplevels.some(t => WindowBand.heldAs(t) === "hidden")
                readonly property bool named: root.tier === 0 || (root.tier === 1 && pill.open)
                readonly property string symbol: root.known[pill.appId]?.symbol ?? ""
                readonly property bool dragging: root.draggingId === pill.appId
                // fades where the disc has passed over it
                readonly property real swept: Math.max(0, Math.min(1, (root.discX + 22 - (pill.x + pill.width / 2 - 30 + programRow.x)) / 60))

                // 12 a side and 8 between: at 15 and 10 a usual nine programs ran past 1100 with their names
                width: pill.named ? 24 + 8 + label.implicitWidth + 24 : root.tile
                height: root.tile
                radius: root.tile / 2
                // the program whose windows the peek shows is lit a step brighter: the pill and the tab read as one
                readonly property bool peeked: root.peeking && root.shownEntry?.appId === pill.appId
                // the window band's window is heading for this button: it opens as the slot that takes it
                readonly property bool bandTarget: WindowBand.dropInto.length > 0 && WindowBand.dropInto === pill.appId
                onBandTargetChanged: if (pill.bandTarget) pill.reportBand()
                Component.onCompleted: if (pill.bandTarget) pill.reportBand()
                // where it will rest, at once, and again once the dock has arrived
                function reportBand() {
                    const p = pill.mapToItem(null, 0, 0);
                    WindowBand.reportHide(p.x, p.y - root.restOffset, pill.width, pill.height);
                    bandReport.restart();
                }
                // the window has landed in it: the button takes it with a small swell, and settles
                property bool taking: false
                Connections {
                    target: WindowBand
                    function onLanded(appId) {
                        if (appId.length > 0 && appId === pill.appId) {
                            pill.taking = true;
                            takeEnd.restart();
                        }
                    }
                }
                Timer {
                    id: takeEnd
                    interval: 110
                    onTriggered: pill.taking = false
                }
                Timer {
                    id: bandReport
                    // once the dock has risen, so the place is where it will be
                    interval: 320
                    onTriggered: {
                        const p = pill.mapToItem(null, 0, 0);
                        WindowBand.reportHide(p.x, p.y, pill.width, pill.height);
                    }
                }
                readonly property bool hot: pill.dragging || pill.hovered && !pill.open || pill.bandTarget
                readonly property bool lit: pill.open && (pill.here || pill.peeked)
                readonly property color ink: pill.hot ? root.inkHot : pill.lit ? root.inkLit : pill.open ? root.inkOpen : root.inkClosed
                // closed programs bare, open ones on the wash ("on"), a step brighter where you are or peeked; pointed
                // at, a closed one in sand
                color: pill.hot ? root.colSandWash : pill.lit ? root.colWashLit : pill.open ? root.colWash : "transparent"
                opacity: pill.swept
                // sunk a little while pressed, a hair raised while carried
                scale: (0.92 + 0.08 * pill.swept) * (pill.dragging ? 1.06 : (pillArea.pressed ? 0.95 : 1)) * (pill.taking ? 1.08 : 1)
                Behavior on scale { Anim { type: Anim.FastSpatial } }
                z: pill.dragging ? 2 : 0
                // the row makes room: the pills the carried one has passed slide over by its width
                readonly property real reorderShift: {
                    if (root.draggingId === "" || pill.dragging || !pill.pinned || root.dragTo < 0)
                        return 0;
                    const step = root.dragWidth + programRow.spacing;
                    if (root.dragTo > root.dragFrom && pill.index > root.dragFrom && pill.index <= root.dragTo)
                        return -step;
                    if (root.dragTo < root.dragFrom && pill.index >= root.dragTo && pill.index < root.dragFrom)
                        return step;
                    return 0;
                }
                transform: Translate {
                    x: pill.dragging ? root.dragOffset : pill.reorderShift
                    // carried, it follows the pointer with nothing in between; otherwise the room it made arrives
                    Behavior on x {
                        enabled: !pill.dragging
                        NumberAnimation {
                            duration: Appearance.animationCurves.smallDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
                        }
                    }
                    y: pill.dragging ? -Tacit.space.xs : 0
                    Behavior on y {
                        NumberAnimation {
                            duration: Appearance.animationCurves.smallDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
                        }
                    }
                }
                Behavior on width {
                    Anim {
                        type: Anim.Emphasized
                    }
                }
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }

                // hidden by the window band: the tick's outline where it would be, so the window has a way back
                Rectangle {
                    visible: pill.hasHidden && !pill.here
                    x: (pill.width - width) / 2
                    y: root.tile + 4
                    width: 24
                    height: 4
                    radius: 2
                    color: "transparent"
                    border.width: 1
                    border.color: Tacit.accent
                }

                // the hairline that parts the pinned programs from the others running
                Rectangle {
                    visible: pill.firstLoose
                    x: -5
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: 24
                    color: Tacit.hairline
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    // a program starting breathes until its window is there
                    opacity: pill.starting ? breath : 1
                    property real breath: 1
                    SequentialAnimation on breath {
                        running: pill.starting
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.45; duration: 650; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
                    }
                    Item {
                        id: mark
                        width: 24
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter
                        readonly property string iconPath: pill.symbol.length === 0 ? Quickshell.iconPath(AppSearch.guessIcon(pill.appId), true) : ""
                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: pill.symbol.length > 0
                            text: pill.symbol
                            iconSize: 21
                            color: pill.ink
                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }
                        }
                        IconImage {
                            id: appIcon
                            anchors.centerIn: parent
                            visible: pill.symbol.length === 0 && mark.iconPath.length > 0
                            source: visible ? mark.iconPath : ""
                            implicitSize: 24
                        }
                        // no icon to be found: the program's initial, not an empty tile
                        StyledText {
                            anchors.centerIn: parent
                            visible: pill.symbol.length === 0 && mark.iconPath.length === 0
                            text: root.nameFor(pill.appId).charAt(0).toUpperCase()
                            font.pixelSize: Tacit.size.row
                            font.weight: Font.DemiBold
                            color: pill.ink
                        }
                    }
                    StyledText {
                        id: label
                        visible: pill.named
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.nameFor(pill.appId)
                        font.pixelSize: Appearance.font.pixelSize.smallish
                        // the weight says open, not where you are: a weight that changed with focus would change the
                        // pill's width and shift the row
                        font.weight: pill.open ? Font.Medium : Font.Normal
                        color: pill.open || pill.hot ? pill.ink : root.inkClosedName
                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                }

                // a closed program's name, above it while pointed at (an open one shows its windows instead)
                Rectangle {
                    id: nameTag
                    readonly property bool wanted: (pill.hovered || root.focusIndex === pill.index) && !pill.open && !pill.named && !pill.dragging
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 12
                    width: tagText.implicitWidth + 22
                    height: 28
                    radius: Tacit.radius.panel
                    color: Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1
                    border.color: Tacit.hairline
                    opacity: 0
                    visible: opacity > 0
                    states: State { when: nameTag.wanted; PropertyChanges { nameTag.opacity: 1 } }
                    transitions: Transition {
                        SequentialAnimation {
                            PauseAnimation { duration: nameTag.wanted ? 250 : 0 }
                            Anim { property: "opacity"; type: Anim.FastEffects }
                        }
                    }
                    StyledText {
                        id: tagText
                        anchors.centerIn: parent
                        text: root.nameFor(pill.appId)
                        font.pixelSize: Tacit.size.fileText
                        color: Tacit.inkMain
                    }
                }

                MouseArea {
                    id: pillArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: pill.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    property real pressX: 0
                    property bool moved: false
                    onEntered: root.rest(pill.modelData)
                    onExited: root.leave()
                    onPressed: mouse => {
                        // the last one put down is still settling: let it land, and this press does nothing
                        if (root.landing) {
                            pillArea.moved = true;
                            root.finishDrag();
                            return;
                        }
                        // the pointer's place in the dock, not in the pill: once the pill is being dragged
                        // it is moved under the pointer, and its own coordinates subtract that move
                        pillArea.pressX = pillArea.mapToItem(root, mouse.x, mouse.y).x;
                        pillArea.moved = false;
                    }
                    onPositionChanged: mouse => {
                        if (!(pillArea.pressedButtons & Qt.LeftButton) || !pill.pinned)
                            return;
                        // measured in the pill's coordinates, the far end of the drag took the drag itself
                        // off and the sign flipped on every event: the pill ran left and right and left the
                        // dock. Mapped into the dock, the pointer's move is the move.
                        const dx = pillArea.mapToItem(root, mouse.x, mouse.y).x - pillArea.pressX;
                        if (!pillArea.moved && Math.abs(dx) > 6) {
                            pillArea.moved = true;
                            root.beginDrag(pill.appId, pill.x + pill.width / 2, pill.width);
                        }
                        if (!pillArea.moved)
                            return;
                        root.dragOffset = dx;
                        // the row opens the place the pill's centre has reached, while it is still carried
                        root.dragTo = root.slotFor(pill.x + pill.width / 2 + dx);
                    }
                    onReleased: mouse => {
                        if (!pill.dragging)
                            return;
                        // let go: it goes into that place first, then the order is written
                        root.landing = true;
                        land.to = root.landingOffset();
                        land.start();
                    }
                    onCanceled: root.cancelDrag()
                    onClicked: mouse => {
                        if (pillArea.moved)
                            return;
                        // a right click (a two-finger tap on a touchpad) opens the program's menu; it no longer pins or
                        // unpins on its own (it took a pinned app off the dock at once, Discord 2026-11-03)
                        if (mouse.button === Qt.RightButton) {
                            root.openMenu(pill.modelData);
                            return;
                        }
                        root.menuEntry = null;
                        if (mouse.button === Qt.MiddleButton)
                            root.launch(pill.appId);
                        else
                            root.activate(pill.modelData);
                    }
                }
            }
        }
    }
}
