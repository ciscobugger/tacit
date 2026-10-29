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
 * one; right-click pins or unpins; drag a pinned program to move it. The peek itself is drawn by
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
    Timer { id: launchTimer; interval: 8000; onTriggered: root.launching = "" }
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
        // a window the window band hid comes back first (the last one hidden); held windows are never cycled through
        const hidden = app.toplevels.filter(t => WindowBand.heldAs(t) === "hidden");
        if (hidden.length > 0) {
            WindowBand.command("reopen", WindowBand.addressOf(hidden[hidden.length - 1]));
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

    // ------------------------------------------------------------- reordering
    property string draggingId: ""
    property real dragOffset: 0
    function moveTo(appId, x) {
        const pins = (Config.options.dock.pinnedApps ?? []).slice();
        const from = pins.findIndex(id => id.toLowerCase() === appId.toLowerCase());
        if (from < 0)
            return;
        // the slot whose centre the dragged pill passed
        let to = 0;
        for (let i = 0; i < programRow.children.length; i++) {
            const child = programRow.children[i];
            if (!child.appId || !child.pinned || child.appId === appId)
                continue;
            if (x > child.x + child.width / 2)
                to++;
        }
        pins.splice(from, 1);
        pins.splice(Math.min(to, pins.length), 0, Config.options.dock.pinnedApps[from]);
        Config.options.dock.pinnedApps = pins;
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
        root.draggingId = "";
        root.focusIndex = -1;
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
                onBandTargetChanged: if (pill.bandTarget) bandReport.restart()
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
                // sunk a little while pressed
                scale: (0.92 + 0.08 * pill.swept) * (pillArea.pressed ? 0.95 : 1)
                Behavior on scale { Anim { type: Anim.FastSpatial } }
                z: pill.dragging ? 2 : 0
                transform: Translate {
                    x: pill.dragging ? root.dragOffset : 0
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
                            font.pixelSize: 15
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
                    readonly property bool wanted: pill.hovered && !pill.open && !pill.named && !pill.dragging
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.top
                    anchors.bottomMargin: 12
                    width: tagText.implicitWidth + 22
                    height: 28
                    radius: 14
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
                        font.pixelSize: 14
                        color: Tacit.inkMain
                    }
                }

                MouseArea {
                    id: pillArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                    property real pressX: 0
                    property bool moved: false
                    onEntered: root.rest(pill.modelData)
                    onExited: root.leave()
                    onPressed: mouse => {
                        pillArea.pressX = mouse.x;
                        pillArea.moved = false;
                    }
                    onPositionChanged: mouse => {
                        if (!(pillArea.pressedButtons & Qt.LeftButton) || !pill.pinned)
                            return;
                        const dx = mouse.x - pillArea.pressX;
                        if (!pillArea.moved && Math.abs(dx) > 6) {
                            pillArea.moved = true;
                            root.draggingId = pill.appId;
                            root.reset();
                            root.draggingId = pill.appId;
                        }
                        if (pillArea.moved)
                            root.dragOffset = dx;
                    }
                    onReleased: mouse => {
                        if (!pillArea.moved)
                            return;
                        root.moveTo(pill.appId, pill.x + pill.width / 2 + root.dragOffset);
                        root.draggingId = "";
                        root.dragOffset = 0;
                    }
                    onClicked: mouse => {
                        if (pillArea.moved)
                            return;
                        if (mouse.button === Qt.RightButton)
                            TaskbarApps.togglePin(pill.appId);
                        else if (mouse.button === Qt.MiddleButton)
                            root.launch(pill.appId);
                        else
                            root.activate(pill.modelData);
                    }
                }
            }
        }
    }
}
