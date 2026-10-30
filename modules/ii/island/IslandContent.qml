pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.activity
import QtQuick.Effects
import Quickshell
import Quickshell.Widgets
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The quiet notch, after boring.notch (ContentView.swift). One 34px header docked into the
 * top edge, the time always in its centre; a sheet opens under it.
 *
 *   rest    [art]  time · glyph  [spectrum]      wings only while playing
 *   peek    [icon + name]  time  [bar + %]       width only, 1.5-4s, then back
 *   hover   the sheet opens (0.3s dwell) and closes 100ms after the pointer leaves
 *   click   opens too; a click on a peek dismisses it
 *
 * The sheet OVERLAYS windows like a menu (no reflow, nothing moves under the pointer); the
 * reserve is the header alone. Shape first, content after.
 */
Item {
    id: root

    // boring.notch: minimumHoverDuration 0.3s opens (Constants.swift:79, openNotchOnHover
    // default true); leaving closes after 100ms (ContentView.swift handleHover). While open,
    // peeks do not touch the header (their sneak peek is suppressed when open).
    property bool open: false
    // No tabs: the notch decides. A drag over it, or files already parked, and the sheet IS the
    // shelf; empty the shelf and the next open is the player. The choice is made when the sheet
    // opens and stays until it closes, so clearing the shelf or a drag leaving never swaps the
    // content under the pointer.
    property bool dragOver: false
    property bool droppedThisDrag: false
    property string view: "home"
    // the recording's sheet (states/IslandRecord.qml): "choose" from Super+Shift+R, "saved" when one has just ended
    property string recordMode: "choose"
    property bool recordActed: false
    // A tile being dragged OUT of the shelf keeps the sheet open until the drag ends, and a
    // sheet opened for a drop on the desktop stays until the pointer has visited it.
    property bool rowDragging: false  // a recents row being dragged out

    // Keyboard: the selected row while the sheet was opened from a key. Up/Down move over
    // sessions then arrivals, Enter does what a click does, Esc closes. Focus is released
    // the moment the sheet closes, however it closes.
    property int selected: -1
    readonly property int rowCount: IslandController.openSessions.length + IslandController.openRecents.length
    // Which screen this notch is on, and whether the keyboard belongs to it: a key-driven open
    // is one sheet on one monitor, and only that one may take the keyboard or give it back.
    property ShellScreen screenData: null
    readonly property bool keyScreen: root.screenData === null
        || IslandController.keyboardScreen === ""
        || IslandController.keyboardScreen === root.screenData.name
    // The Claude service reads the context again only when the sheet is not already up. One
    // Binding per screen would fight over the singleton - the last one installed wins and the
    // others could never report at all - so the screen the keyboard belongs to writes it.
    readonly property bool askOpen: root.open && root.view === "ask"
    onAskOpenChanged: if (root.keyScreen) Claude.sheetOpen = root.askOpen;
    // Another screen just took the keyboard: this notch's key-driven sheet is not the one being
    // typed into any more, so it does not stay open behind it.
    onKeyScreenChanged: if (!root.keyScreen && root.open && (root.view === "ask" || root.view === "address" || root.view === "record")) root.open = false;
    // Locking destroys this window with the sheet still up, and the flag would stay set with
    // nothing left to clear it - Claude would never read its context again.
    Component.onDestruction: if (root.askOpen && root.keyScreen) Claude.sheetOpen = false;
    onOpenChanged: {
        root.askUnfollow();
        root.addressFollow();
        if (!root.open && root.signinWaiting)
            signinBack.restart();
        if (!root.open) {
            root.selected = -1;
            if (root.keyScreen)
                IslandController.keyboard = false;
            // the card went unused: it folds away into a line
            if (root.view === "record" && root.recordMode === "saved" && !root.recordActed && root.keyScreen) {
                const dir = Persistent.states.record.file.replace(/\/[^\/]*$/, "").replace(/^.*\//, "");
                IslandController.request("recordSaved", { "text": `Recording saved · in ${dir}`, "icon": "movie" }, 60);
            }
        } else if (IslandController.keyboard && root.view !== "ask" && root.view !== "address" && root.view !== "signin") {
            root.selected = root.rowCount > 0 ? 0 : -1;
            root.forceActiveFocus();
        }
    }
    focus: IslandController.keyboard && root.open
    Keys.onPressed: event => {
        if (!IslandController.keyboard || !root.open)
            return;
        // Ask owns its own navigation keys, so the row handling below must stay out of its
        // way - but Escape has to work wherever focus sits inside the sheet (a question
        // card's own text field, for one), or the sheet cannot be closed at all. So does the
        // browser's address.
        if (root.view === "ask" || root.view === "address" || root.view === "record") {
            if (event.key === Qt.Key_Escape) {
                root.pinnedUntilVisit = false;
                root.open = false;
                event.accepted = true;
            } else if (root.view === "record" && sheetLoader.item?.keyPressed) {
                sheetLoader.item.keyPressed(event);
            }
            return;
        }
        // the sign-in's ask field had the keys: Esc gives them back to the page
        if (root.view === "signin") {
            if (event.key === Qt.Key_Escape) {
                IslandController.keyboard = false;
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
            if (root.rowCount > 0)
                root.selected = (root.selected + 1) % root.rowCount;
            event.accepted = true;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
            if (root.rowCount > 0)
                root.selected = (root.selected - 1 + root.rowCount) % root.rowCount;
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activateSelected();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            root.pinnedUntilVisit = false;
            root.open = false;
            event.accepted = true;
        }
    }
    function activateSelected() {
        const n = IslandController.openSessions.length;
        if (root.selected < 0)
            return;
        if (root.selected < n) {
            // the session may have ended while the sheet was up: its row is greyed out and
            // there is no window left to focus
            const s = AgentSessions.sessions.find(x => x.id === IslandController.openSessions[root.selected].id);
            if (!s)
                return;
            AgentSessions.focus(s);
        } else {
            Recents.activate(IslandController.openRecents[root.selected - n]);
        }
        root.pinnedUntilVisit = false;
        root.open = false;
    }
    readonly property bool draggingOut: (sheetLoader.item?.draggingOut ?? false) || root.rowDragging
    property bool pinnedUntilVisit: false
    onDraggingOutChanged: {
        if (!root.draggingOut && !islandHover.hovered)
            leaveTimer.restart();
    }
    // One line per transition in ~/.cache/qs-startup.log; cheap, and the only way to tell a
    // stuck sheet from a spurious hover after the fact.

    readonly property bool peekShowing: IslandController.transientShowing && !root.open
    // A peek does not open the notch, so the dwell timer is not armed while one is up - and the
    // pointer arriving during one is an edge that never comes again. Watch the condition: when
    // the peek resolves and the pointer is still here, the dwell starts then.
    onPeekShowingChanged: {
        if (root.peekShowing)
            hoverTimer.stop();
        else if (islandHover.hovered && Config.options.island.hoverExpand && !IslandController.recording)
            hoverTimer.restart();
    }
    readonly property string headerState: root.open
        ? (root.view === "address" ? "address" : root.view === "signin" ? "signin" : root.view === "record" ? "recordSheet" : "open")
        : root.signinStage === "breath" ? "signinPeek"
        : (root.peekShowing ? IslandController.transientState : (root.signinWaiting ? "signinWait" : "idle"))

    readonly property var headerGeometry: IslandController.geometryFor(root.headerState)
    readonly property var openGeometry: IslandController.geometryFor("open")
    property real radius: root.open ? root.openGeometry.r : root.headerGeometry.r
    // The cove stays 6 open and closed (theirs grows to 19; see IslandController.geometryFor).
    // The browser's address sheet is the exception: r 24 with 19 px coves, as its render has it.
    property real fillet: root.open ? (root.view === "address" ? 19 : root.openGeometry.f) : root.headerGeometry.f

    // boring.notch: open = spring(response 0.42, damping 0.8) - a touch of overshoot; close =
    // spring(0.45, damping 1.0) - none (ContentView.swift:123-124). Peeks morph on the fast
    // spatial curve like every other width change in the shell.
    // Once the address sheet is open, its rows changing per keystroke move only its height,
    // on the browser card's StandardSmall.
    readonly property bool sheetSettled: root.addressSettled || (root.view === "signin" && root.signinStage === "settled")
    readonly property int geometryDuration: root.open
        ? (root.sheetSettled ? Appearance.animationCurves.smallDuration : Appearance.animationCurves.expressiveDefaultSpatialDuration)
        : (root.peekShowing || root.signinStage === "breath" ? Appearance.animationCurves.expressiveFastSpatialDuration : 450)
    readonly property list<real> geometryCurve: root.open
        ? (root.sheetSettled ? Appearance.animationCurves.standard : Appearance.animationCurves.expressiveDefaultSpatial)
        : (root.peekShowing || root.signinStage === "breath" ? Appearance.animationCurves.expressiveFastSpatial : Appearance.animationCurves.emphasizedDecel)

    implicitWidth: root.open ? (root.view === "ask" ? 600 : root.view === "address" ? 680 : root.view === "signin" ? IslandController.signinSheetWidth : root.view === "record" ? (root.recordMode === "saved" ? 520 : 660) : root.openGeometry.w) : root.headerGeometry.w
    // Ask's height follows its content (a field, suggestions, then a conversation), up to the
    // sheets' 440. It opens on the springs below; once open, a streaming answer changes it every
    // line, and a NumberAnimation restarts from rest at each new target (the notch stalled and
    // bounced per line), so from then on it follows a spring that keeps its velocity instead.
    // The room the sheet has: the sheets' 440 (Island.qml) less the 34 header. The sheet
    // keeps its own copy in IslandAsk.room.
    readonly property real askRoom: 406
    readonly property real askHeight: Math.min(root.askRoom, Math.max(96, sheetLoader.item && root.view === "ask" ? sheetLoader.item.implicitHeight : 150))
    property bool askFollowing: false
    property real askSmooth: root.askHeight
    Behavior on askSmooth {
        enabled: root.askFollowing
        SpringAnimation { spring: 0.9; damping: 0.2; epsilon: 0.25 }
    }
    Timer {
        id: askSettle
        interval: root.geometryDuration
        onTriggered: if (root.open && root.view === "ask") { heightBehavior.enabled = false; root.askFollowing = true; }
    }
    // The behaviour is switched here, before the height moves, so an open or close is never
    // written with it off (a binding for `enabled` could update after the height's).
    function askUnfollow() {
        heightBehavior.enabled = true;
        root.askFollowing = false;
        if (root.open && root.view === "ask") askSettle.restart();
        else askSettle.stop();
    }
    onViewChanged: { root.askUnfollow(); root.addressFollow(); }
    // The browser's address (states/IslandAddress.qml): its height is its item's; it stays opaque
    // (IslandController.addressOut) until the shape has folded back.
    readonly property real addressHeight: sheetLoader.item && root.view === "address" ? sheetLoader.item.implicitHeight : 312
    property bool addressSettled: false
    Timer {
        id: addressSettle
        interval: Appearance.animationCurves.expressiveDefaultSpatialDuration
        onTriggered: root.addressSettled = root.open && root.view === "address"
    }
    Timer {
        id: addressFold
        interval: 450
        onTriggered: if (!(root.open && root.view === "address")) IslandController.addressOut = false
    }
    function addressFollow() {
        root.addressSettled = false;
        if (root.open && root.view === "address") {
            addressSettle.restart();
            addressFold.stop();
        } else if (root.keyScreen) {
            addressFold.restart();
        }
    }
    // The browser's sign-in (states/IslandSignin.qml, IslandController's sign-in): the header breathes in at the
    // sheet's width, the sheet drops, and once it has settled the browser shows the page under the hole; on folding the
    // hole closes and the page goes first, then the sheet. Only the notch of the screen it asked for shows it.
    readonly property bool signinHere: root.screenData === null || IslandController.signinScreen === ""
        || IslandController.signinScreen === root.screenData.name
    readonly property bool signinShown: root.open && root.view === "signin"
    readonly property bool signinWaiting: root.signinHere && IslandController.signinPhase === "waiting"
    // "breath" (the header widens), "drop" (the sheet opening), "settled" (the page asked for), "fold" (the page going)
    property string signinStage: ""
    property bool holeOpen: false
    property var afterFold: null
    // the page in this item, flush under the header; the hole is 1 px inside it, so the page's square corners and edge
    // stay under the frost
    readonly property rect pageRect: Qt.rect(10, 36, IslandController.signinPageWidth, IslandController.signinPageHeight)
    readonly property rect holeRect: root.holeOpen && root.signinShown
        ? Qt.rect(root.pageRect.x + 1, root.pageRect.y + 1, root.pageRect.width - 2, root.pageRect.height - 2) : Qt.rect(0, 0, 0, 0)
    // for Island.qml's input mask: clicks and keys there reach the page window
    readonly property Item holeItem: hole
    Item {
        id: hole
        x: root.holeRect.x
        y: root.holeRect.y
        width: root.holeRect.width
        height: root.holeRect.height
    }
    function signinBegin() {
        if (!root.signinHere || IslandController.signinPhase === "" || root.signinStage !== "")
            return;
        // Ask, the shelf or the address in use: it waits as a wing; the home or media sheet from a hover: it takes it
        if (root.open && ["ask", "address", "shelf", "record"].includes(root.view)) {
            IslandController.signinWait("busy");
            return;
        }
        hoverTimer.stop();
        leaveTimer.stop();
        pinTimer.stop();
        root.pinnedUntilVisit = false;
        // the page takes the keys: a sheet opened from a key (Super+Space) gives up the island's hold on them
        if (root.keyScreen)
            IslandController.keyboard = false;
        IslandController.signinHold();
        root.view = "signin";
        if (root.open) {
            root.signinStage = "drop";
            signinSettle.restart();
        } else {
            root.signinStage = "breath";
            signinBreath.restart();
        }
    }
    // the width's spring, and the wings' crossfade (IslandHeader: 100 out, 80 held, 140 in) done, before the drop
    Timer {
        id: signinBreath
        interval: Appearance.animationCurves.expressiveFastSpatialDuration + 150
        onTriggered: {
            if (root.signinStage !== "breath")
                return;
            root.signinStage = "drop";
            root.open = true;
            signinSettle.restart();
        }
    }
    Timer {
        id: signinSettle
        interval: Appearance.animationCurves.expressiveDefaultSpatialDuration
        onTriggered: {
            if (root.signinStage !== "drop" || !root.signinShown)
                return;
            root.signinStage = "settled";
            root.signinMap();
        }
    }
    function signinMap() {
        IslandController.signinSend({ "op": "map", "width": root.pageRect.width, "height": root.pageRect.height });
    }
    // an ask under the page took room from it: the page again, at its new size
    onPageRectChanged: if (root.signinStage === "settled" && IslandController.signinPhase === "open") root.signinMap()
    // The page first: the hole closes (the frost covers the page), the browser hides it, then `then` folds or swaps
    // the sheet. The browser answers unmapped; 150 ms without it is as good.
    function signinFold(then) {
        root.afterFold = then;
        if (root.signinStage === "breath" || !root.signinShown) {
            root.signinStage = "";
            root.holeOpen = false;
            root.signinFolded();
            return;
        }
        root.signinStage = "fold";
        holeCover.opacity = 0;
        holeCoverIn.restart();
    }
    // covered: the hole closes under the cover (nothing changes on the screen) and the page goes
    function signinCovered() {
        if (root.signinStage !== "fold")
            return;
        root.holeOpen = false;
        IslandController.signinSend({ "op": "unmap" });
        signinUnmapLimit.restart();
    }
    Timer {
        id: signinUnmapLimit
        interval: 150
        onTriggered: root.signinFolded()
    }
    function signinFolded() {
        signinUnmapLimit.stop();
        holeCoverIn.stop();
        holeCover.opacity = 0;
        if (root.signinStage === "fold")
            root.signinStage = "";
        const then = root.afterFold;
        root.afterFold = null;
        if (then)
            then();
    }
    // the sheet goes to what you called up (Ask, the address) once the page has gone
    function signinYield(view) {
        root.view = view;
        root.open = true;
        if (sheetLoader.item && sheetLoader.item.focusInput)
            sheetLoader.item.focusInput();
    }
    function signinToWing(reason) {
        root.signinFold(() => {
            IslandController.signinWait(reason);
            if (root.view === "signin")
                root.open = false;
        });
    }
    // what was in the way of it has gone: it comes back (Ask closed, the shelf put away)
    Timer {
        id: signinBack
        interval: 450
        onTriggered: if (!root.open && root.signinWaiting && ["ask", "busy"].includes(IslandController.signinAside)) root.signinBegin()
    }
    Connections {
        target: IslandController
        function onSigninOpen() {
            root.signinBegin();
        }
        function onSigninDone(signed) {
            if (!root.signinHere)
                return;
            root.signinFold(() => {
                if (root.view === "signin")
                    root.open = false;
                IslandController.signinEnd(signed);
            });
        }
        function onSigninAsideRequested(reason) {
            if (root.signinHere && root.view === "signin" && (root.open || root.signinStage !== ""))
                root.signinToWing(reason);
        }
        function onSigninMapped() {
            if (root.signinShown && root.signinStage === "settled")
                root.holeOpen = true;
        }
        function onSigninUnmapped() {
            if (root.signinStage === "fold")
                root.signinFolded();
        }
    }

    readonly property bool timerRunning: IslandController.focusRunning
    // For the session rows' "since" column; ticks only while the sheet is up.
    property real now: Date.now()
    Timer {
        running: root.open
        interval: 30000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }
    function elapsed(since) {
        const m = Math.max(0, Math.round((root.now - since) / 60000));
        return m < 1 ? "now" : m < 60 ? `${m}m` : `${Math.floor(m / 60)}h ${m % 60}m`;
    }
    // The shelf keeps its 150 whole: the session and arrival rows under it (the loader
    // reserves openRowsHeight) add to the sheet, they do not cut into the tiles.
    // The spring overshoots its target by design, and the target is already the ceiling: the
    // animated value is clamped here or the compositor slices the bottom of a streaming answer.
    // an app not answering: the prompt's body under the header
    readonly property real promptHeight: root.peekShowing && root.headerState === "notAnswering" ? 108 : 0
    implicitHeight: root.askFollowing ? 34 + Math.min(root.askRoom, root.askSmooth) : 34 + root.promptHeight + (root.open ? (root.view === "shelf" ? 150 + IslandController.openRowsHeight + (root.timerRunning ? 36 : 0) : root.view === "ask" ? root.askHeight : root.view === "address" ? root.addressHeight : root.view === "signin" ? IslandController.signinSheetHeight - 34 : root.view === "record" ? (root.recordMode === "saved" ? 94 : 82) : root.openGeometry.h) : 0)

    Behavior on implicitWidth {
        NumberAnimation {
            duration: root.geometryDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.geometryCurve
        }
    }
    Behavior on implicitHeight {
        id: heightBehavior
        NumberAnimation {
            duration: root.geometryDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.geometryCurve
        }
    }
    Behavior on radius {
        NumberAnimation {
            duration: root.geometryDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.geometryCurve
        }
    }
    Behavior on fillet {
        NumberAnimation {
            duration: root.geometryDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.geometryCurve
        }
    }

    // Compile the sheets once at startup so the first open is never cold.
    property var warmStates: []
    Component.onCompleted: {
        const c = Qt.createComponent(Qt.resolvedUrl("states/IslandSheet.qml"), Component.Asynchronous);
        root.warmStates.push(c);
        const a = Qt.createComponent(Qt.resolvedUrl("states/IslandAsk.qml"), Component.Asynchronous);
        a.statusChanged.connect(() => { if (a.status === Component.Error) console.warn("[Island] Ask:", a.errorString()); });
        root.warmStates.push(a);
        // The shelf is the heaviest of the three and the one a drag always loads.
        root.warmStates.push(Qt.createComponent(Qt.resolvedUrl("states/IslandShelf.qml"), Component.Asynchronous));
        const d = Qt.createComponent(Qt.resolvedUrl("states/IslandAddress.qml"), Component.Asynchronous);
        d.statusChanged.connect(() => { if (d.status === Component.Error) console.warn("[Island] Address:", d.errorString()); });
        root.warmStates.push(d);
        const g = Qt.createComponent(Qt.resolvedUrl("states/IslandSignin.qml"), Component.Asynchronous);
        g.statusChanged.connect(() => { if (g.status === Component.Error) console.warn("[Island] Sign-in:", g.errorString()); });
        root.warmStates.push(g);
        const r = Qt.createComponent(Qt.resolvedUrl("states/IslandRecord.qml"), Component.Asynchronous);
        r.statusChanged.connect(() => { if (r.status === Component.Error) console.warn("[Island] Record:", r.errorString()); });
        root.warmStates.push(r);
    }

    // The browser's address floats over the page (its render): a soft shadow under the sheet.
    RectangularShadow {
        x: 12
        y: 30
        width: Math.max(0, root.width - 24)
        height: Math.max(0, root.height - 30)
        radius: 24
        blur: 34
        offset: Qt.vector2d(0, 14)
        color: ColorUtils.transparentize("black", 0.64)
        visible: opacity > 0
        opacity: root.open && root.view === "address" ? 1 : 0
        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }

    // Docked into the top edge as ONE silhouette (body + coves, one fill, one outline that
    // follows the coves) -- see DockedRect.qml. Closed, the 6px cove is a seam you feel rather
    // than see; open, the 19px cove is the curve you asked for from caelestia.
    DockedRect {
        id: background
        anchors.fill: parent
        visible: !GlobalStates.gridOver
        cornerRadius: root.radius
        fillet: root.fillet
        // the sign-in's page window shows through here
        hole: root.holeRect
        holeRadius: 15
        // the browser's address is opaque over the page: the frost's own colour, solid
        color: IslandController.addressOut && root.view === "address" ? Appearance.m3colors.m3surfaceContainerHigh : IslandController.bodyColor
        Behavior on color {
            ColorAnimation {
                duration: Appearance.animationCurves.expressiveDefaultEffectsDuration
            }
        }
        // No outline. Neither reference has one (boring.notch is a black cut-out, caelestia's
        // panels are unstroked), and ours was darker than a light window behind the sheet, so
        // it read as a black fringe down the right wall and around the bottom-right curve.
        // The frost over the compositor blur is the separation.
        borderWidth: 0
    }
    // The fold's first step: the body's colour fades in over the page through the hole, so the page leaves without a
    // cut, and the fold follows as soon as it has gone (closed in one frame, then the empty sheet waited for the page:
    // the owner, 2026-10-02, "when it's dismissing it's not smooth")
    Rectangle {
        id: holeCover
        x: root.pageRect.x + 1
        y: root.pageRect.y + 1
        width: root.pageRect.width - 2
        height: root.pageRect.height - 2
        radius: 15
        color: background.color
        visible: opacity > 0 && root.signinShown
        opacity: 0
    }
    NumberAnimation {
        id: holeCoverIn
        target: holeCover
        property: "opacity"
        to: 1
        duration: Appearance.animationCurves.expressiveFastEffectsDuration
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Appearance.animationCurves.expressiveFastEffects
        onFinished: root.signinCovered()
    }

    // Hover lives on a handler, not on the MouseArea below: buttons in the strip and the sheet
    // would otherwise steal the hover and fold the notch as the pointer reaches them.
    HoverHandler {
        id: islandHover
        onHoveredChanged: {
            if (islandHover.hovered) {
                leaveTimer.stop();
                if (root.pinnedUntilVisit) {
                    root.pinnedUntilVisit = false;
                    pinTimer.stop();
                }
                // boring.notch: hovering a sneak peek does not open the notch. Nor does hovering a recording: the
                // resting notch is its Stop.
                if (Config.options.island.hoverExpand && !root.peekShowing && !IslandController.recording)
                    hoverTimer.restart();
            } else {
                hoverTimer.stop();
                leaveTimer.restart();
            }
        }
    }

    Timer {
        id: hoverTimer
        interval: 300
        repeat: false
        // a window held by its band on the way to the notch must not meet the sheet opening over it
        onTriggered: if (!IslandController.recording && !IslandController.recordArming && WindowBand.dragAddress === "") root.openSheet()
    }

    function openSheet() {
        // the sign-in is on its way into the sheet, or holds it
        if (root.signinStage !== "" || root.signinShown)
            return;
        if (!root.open) {
            root.view = (root.dragOver || DropShelf.items.length > 0) ? "shelf" : "home";
            IslandController.snapshotRows(!root.dragOver, root.view === "shelf");
        }
        root.open = true;
    }

    Timer {
        id: leaveTimer
        interval: 100
        repeat: false
        onTriggered: root.fold()
    }

    function fold() {
        hoverTimer.stop();
        leaveTimer.stop();
        if (root.draggingOut || root.pinnedUntilVisit)
            return;
        if ((root.view === "ask" || root.view === "address" || root.view === "signin") && root.open)   // Ask, the address and the sign-in close when you say so (Esc, ↗, the shortcut, the way back), not on leave
            return;
        if (root.view === "record" && root.recordMode === "choose" && root.open)   // so does the recording's choice
            return;
        root.open = false;
    }

    // Files dropped on the desktop used to open a floating shelf window at the drop point; the
    // notch is the shelf now. Open here, pinned until the pointer comes and goes, or 6s.
    // The flag is a pulse, not a state: it is cleared here the moment it arrives. The old window
    // (dropover/DropShelfPanel) binds its visibility to the same flag, so the panel family loads
    // it only when the notch is off.
    Connections {
        target: GlobalStates

        function onDropShelfOpenChanged() {
            if (!GlobalStates.dropShelfOpen)
                return;
            GlobalStates.dropShelfOpen = false;
            // the files are on the shelf; the sign-in keeps the sheet
            if (root.signinShown || root.signinStage !== "")
                return;
            root.view = "shelf";
            if (!root.open)
                IslandController.snapshotRows(false, true);
            root.open = true;
            root.pinnedUntilVisit = true;
            pinTimer.restart();
        }
    }

    Connections {
        id: requests
        target: IslandController

        function onOpenRequested() {
            if (!root.keyScreen)
                return;
            if (root.signinShown) {
                root.signinFold(() => {
                    IslandController.signinWait("ask");
                    root.view = "home";
                    root.open = false;
                    root.openSheet();
                    root.pinnedUntilVisit = true;
                    pinTimer.restart();
                });
                return;
            }
            root.openSheet();
            root.pinnedUntilVisit = true;
            pinTimer.restart();
        }

        function onCloseRequested() {
            pinTimer.stop();
            root.pinnedUntilVisit = false;
            root.open = false;
        }

        // the browser's Ctrl+L: the sheet as its address, with the keyboard
        function onAddressRequested() {
            if (!root.keyScreen)
                return;
            if (root.signinShown) {
                root.signinFold(() => { IslandController.signinWait("ask"); root.signinYield("address"); });
                return;
            }
            pinTimer.stop();
            root.pinnedUntilVisit = false;
            root.view = "address";
            root.open = true;
            if (sheetLoader.item && sheetLoader.item.focusInput)
                sheetLoader.item.focusInput();
        }

        // Super+Shift+R: the recording's choice, with the keyboard; the key again puts it away
        function onRecordRequested() {
            if (!root.keyScreen)
                return;
            pinTimer.stop();
            root.pinnedUntilVisit = false;
            if (root.signinShown || root.signinStage === "breath") {
                root.signinFold(() => { IslandController.signinWait("ask"); root.recordMode = "choose"; root.signinYield("record"); });
                return;
            }
            if (root.open && root.view === "record" && root.recordMode === "choose") {
                root.open = false;
                return;
            }
            root.recordMode = "choose";
            root.view = "record";
            root.open = true;
            root.forceActiveFocus();
        }

        // a recording ended: its card, until the pointer has come and gone (or 6 s); over another open sheet only the line
        function onRecordSaved() {
            if (!root.keyScreen)
                return;
            if (root.open || root.signinShown || root.signinStage !== "") {
                IslandController.request("recordSaved", { "text": "Recording saved", "icon": "movie" }, 60);
                return;
            }
            root.recordActed = false;
            root.recordMode = "saved";
            root.view = "record";
            root.open = true;
            root.pinnedUntilVisit = true;
            pinTimer.restart();
        }

        // the shortcut again, with nothing new to attach, puts Ask away
        function onAskRequested(fresh) {
            if (!root.keyScreen)
                return;
            // Ask is never pinned, and the pin's only expiry is pinTimer: leaving the flag set
            // with the timer stopped makes fold() refuse to close the notch until a pointer
            // visit clears it.
            pinTimer.stop();
            root.pinnedUntilVisit = false;
            // you win: the sign-in folds to its wing, and comes back when Ask closes
            if (root.signinShown || root.signinStage === "breath") {
                root.signinFold(() => { IslandController.signinWait("ask"); root.signinYield("ask"); });
                return;
            }
            if (root.open && root.view === "ask" && !fresh) {
                root.open = false;
                return;
            }
            root.view = "ask";
            root.open = true;
            if (sheetLoader.item && sheetLoader.item.focusInput)
                sheetLoader.item.focusInput();
        }
    }

    Timer {
        id: pinTimer
        interval: 6000
        repeat: false
        onTriggered: {
            root.pinnedUntilVisit = false;
            if (!islandHover.hovered)
                root.fold();
        }
    }

    // Interactions sit under the content, so buttons inside the strip and the sheet win the click.
    MouseArea {
        id: islandMouseArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onWheel: event => {
            if (event.angleDelta.y > 0)
                Audio.incrementVolume();
            else if (event.angleDelta.y < 0)
                Audio.decrementVolume();
        }
        onClicked: event => {
            if (event.button === Qt.MiddleButton) {
                MprisController.togglePlaying();
                return;
            }
            root.activate();
        }
    }

    function activate() {
        // A click on a peek dismisses it (a running job is told "not now" and keeps going in
        // the glyph slot). Otherwise a click opens without waiting for the dwell, or closes.
        if (root.peekShowing) {
            // A file that just arrived: the click opens it. Everything else: "not now".
            const path = IslandController.transientState === "download" ? (IslandController.payload?.path ?? "") : "";
            if (path.length > 0)
                Quickshell.execDetached(["xdg-open", path]);
            if (IslandController.transientState === "activity")
                IslandController.demoteActivity();
            // the not-answering prompt is answered with its buttons, never by a click beside them
            if (IslandController.transientState === "notAnswering")
                return;
            // memory full: Activity, on what holds it
            if (IslandController.transientState === "memory") {
                Quickshell.execDetached(["activity-open", "now"]);
                IslandController.dismiss();
                return;
            }
            if (IslandController.transientState === "wallpaper") {
                IslandController.wallpaperUndo();
                return;
            }
            // Flow listening or writing: a click cancels it
            if (IslandController.transientState === "flow") {
                Dictation.cancel();
                IslandController.dismiss();
                return;
            }
            // Claude asking, done or failed: open that conversation (the notch or the app)
            const claudeId = IslandController.payload?.claudeId ?? "";
            if (claudeId.length > 0 && ["claudeAsk", "activityDone", "activityFail"].includes(IslandController.transientState)) {
                IslandController.dismiss();
                Claude.openSession(claudeId);
                return;
            }
            IslandController.dismiss();
            return;
        }
        // the sign-in waiting as a wing: a click brings it back
        if (!root.open && root.signinWaiting) {
            hoverTimer.stop();
            root.signinBegin();
            return;
        }
        // boring.notch: a tap only ever opens (ContentView.swift onTapGesture -> doOpen); an
        // open notch closes by leaving or Esc, never by a click that might have been aimed at
        // a control.
        hoverTimer.stop();
        root.openSheet();
    }

    // Files dragged over the notch: open on the shelf (boring.notch onChange(anyDropZoneTargeting)
    // -> currentView = .shelf; doOpen()). A drag that leaves without dropping closes the notch
    // 500ms later; a drop keeps it open until the pointer leaves as usual.
    // Files dropped here park on the shelf. TEXT dropped here (a sentence, a paragraph, a
    // link dragged out of Zen) becomes the task of a new Claude session: the notch is where
    // work is handed to an agent, not a place to store text.
    property bool textDragOver: false
    // the sheet's height is the controller's: it needs to know to keep the hint's band
    onTextDragOverChanged: IslandController.textDragOver = root.textDragOver
    function isOwn(item) {
        for (let p = item; p; p = p.parent)
            if (p === root)
                return true;
        return false;
    }
    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list", "text/plain"]

        onEntered: drag => {
            // the sign-in holds the sheet: a file dragged onto the notch is ignored
            if (root.signinShown || root.signinStage !== "") {
                drag.accepted = false;
                return;
            }
            const text = !drag.hasUrls && drag.hasText;
            drag.accepted = drag.hasUrls || text;
            if (!drag.accepted)
                return;
            leaveTimer.stop();
            hoverTimer.stop();
            root.dragOver = drag.hasUrls;
            root.textDragOver = text;
            root.droppedThisDrag = false;
            root.view = drag.hasUrls ? "shelf" : "home";
            // Every other opening path snapshots the rows; without it the drag opens on the
            // rows the last open left behind - sessions that have ended, files that are gone.
            if (!root.open)
                IslandController.snapshotRows(false, drag.hasUrls);
            root.open = true;
        }
        onExited: {
            root.dragOver = false;
            root.textDragOver = false;
            dragLeaveTimer.restart();
        }
        onDropped: drop => {
            // A tile dragged off the shelf and let go on the notch itself: nothing to do, and
            // touching the list here would destroy the tile mid-drop.
            if (root.isOwn(drop.source)) {
                drop.accepted = false;
                return;
            }
            if (drop.hasUrls) {
                // a WireGuard .conf or an .ovpn is a VPN to add, not a file to park
                const vpnFiles = drop.urls.filter(u => Vpn.isVpnFile(u));
                for (const u of vpnFiles)
                    Vpn.importFile(u);
                const rest = drop.urls.filter(u => !Vpn.isVpnFile(u));
                if (rest.length > 0)
                    DropShelf.addItems(rest);
            } else if (drop.hasText && (drop.text + "").trim().length > 0) {
                Recents.handText(drop.text);
                root.pinnedUntilVisit = false;
                root.open = false;
            } else {
                drop.accepted = false;
                return;
            }
            drop.accept();
            root.droppedThisDrag = true;
            root.dragOver = false;
            root.textDragOver = false;
        }
    }

    Timer {
        id: dragLeaveTimer
        interval: 500
        repeat: false
        onTriggered: {
            if (root.droppedThisDrag) {
                root.droppedThisDrag = false;
                return;
            }
            if (!islandHover.hovered)
                root.fold();
        }
    }

    // quickshell:islandCollapse (Esc). The island never takes keyboard focus, so Esc reaches it
    // through a compositor global shortcut owned by IslandController.
    Connections {
        target: IslandController

        function onCollapseExpansion() {
            // fold() refuses to close Ask on purpose, so that leaving with the pointer does
            // not throw away a half-typed question. Escape is an explicit ask to close, and
            // it is the only way out while the sheet holds the keyboard: close it here.
            if ((root.view === "ask" || root.view === "address" || root.view === "record") && root.open) {
                root.pinnedUntilVisit = false;
                root.open = false;
                return;
            }
            // the sign-in's page has the keys: Esc is the page's, and the browser's when the page leaves it
            if (root.view === "signin" && (root.open || root.signinStage !== ""))
                return;
            root.fold();
        }
    }

    // Stencil/shader rounded clipping from Quickshell.Widgets. color must stay transparent -
    // ClippingRectangle paints its own background under the content and defaults to opaque white.
    ClippingRectangle {
        id: contentHolder
        anchors.fill: parent
        color: "transparent"
        radius: root.radius
        topLeftRadius: 0
        topRightRadius: 0

        // Flow listening: the voice as sand behind the time (SandLayer.qml). Without the component (an older shell
        // start), the load fails and the notch keeps Flow's level bars.
        Loader {
            id: sandLayer
            anchors.fill: parent
            active: Dictation.active
            source: "SandLayer.qml"
            onStatusChanged: IslandController.sandReady = status === Loader.Ready
        }

        // The header: the time in the centre, wings for the state. Always the top 34px.
        IslandHeader {
            id: header
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 34
            notchState: root.headerState
        }

        // An app stopped answering (Hyprland's detection, brought here by scripts/activity/hyprland-dialog):
        // which, for how long, Wait or Close it, and Details in Activity. Activity v7 mock, state 09.
        Item {
            id: promptBody
            anchors.top: header.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 108
            readonly property var n: IslandController.notAnswering
            readonly property int secs: IslandController.notAnsweringFor
            visible: opacity > 0
            opacity: root.promptHeight > 0 ? 1 : 0
            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
            Column {
                x: 28
                y: 6
                spacing: 4
                StyledText {
                    text: `${promptBody.n?.name ?? ""} isn't answering`
                    font.pixelSize: 17
                    font.weight: Font.DemiBold
                    color: IslandController.contentColor
                }
                StyledText {
                    text: {
                        const s = Math.max(1, promptBody.secs);
                        if (s < 60)
                            return s === 1 ? "It stopped 1 second ago." : `It stopped ${s} seconds ago.`;
                        const m = Math.round(s / 60);
                        return m === 1 ? "It stopped 1 minute ago." : `It stopped ${m} minutes ago.`;
                    }
                    font.pixelSize: 14
                    color: IslandController.subtextColor
                }
            }
            Row {
                x: 28
                y: 58
                spacing: 10
                Verb {
                    text: "Wait"
                    px: 15
                    onClicked: IslandController.answerNotAnswering("wait")
                }
                Verb {
                    text: "Close it"
                    px: 15
                    onClicked: IslandController.answerNotAnswering("close")
                }
            }
            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: 28
                y: 68
                text: "Details ›"
                font.pixelSize: 14
                color: detailsArea.containsMouse ? IslandController.contentColor : IslandController.subtextColor
                MouseArea {
                    id: detailsArea
                    anchors.fill: parent
                    anchors.margins: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: IslandController.notAnsweringDetails()
                }
            }
        }

        // The sheet, under the header. boring.notch: scale 0.8 from the top + opacity, 350ms.
        Item {
            id: sheetHolder
            anchors.top: header.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            opacity: root.open ? 1 : 0
            // the address's contents rise into place instead (states/IslandAddress.qml)
            scale: root.open || root.view === "address" ? 1 : 0.8
            transformOrigin: Item.Top
            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
            Behavior on scale {
                Anim {}
            }

            // One drag source for everything the notch hands out. The sheet is destroyed the
            // moment the notch folds, and Qt reads the source's mime data when the target asks
            // for the file: a tile whose sheet had gone took the shell down in
            // QWaylandDataSource::data_source_send. This item stays as long as the notch does.
            Item {
                id: dragProxy
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction
            }

            Loader {
                id: sheetLoader
                anchors.fill: parent
                anchors.bottomMargin: root.view === "ask" || root.view === "address" || root.view === "signin" || root.view === "record" ? 0 : (root.timerRunning ? 38 : 0) + IslandController.openRowsHeight
                active: root.open || sheetHolder.opacity > 0
                // Ask's height follows its item, so an asynchronous load opens the sheet to the
                // 150px placeholder and re-animates when the item lands. Its component is
                // pre-compiled above, so loading it in place costs nothing visible. The address
                // takes keys from the first frame, so it loads in place too.
                asynchronous: root.view !== "ask" && root.view !== "address" && root.view !== "signin" && root.view !== "record"
                source: root.view === "shelf" ? "states/IslandShelf.qml" : root.view === "ask" ? "states/IslandAsk.qml" : root.view === "address" ? "states/IslandAddress.qml" : root.view === "signin" ? "states/IslandSignin.qml" : root.view === "record" ? "states/IslandRecord.qml" : "states/IslandSheet.qml"
                onLoaded: {
                    if (root.view === "ask" || root.view === "address") {
                        item.close.connect(() => { root.pinnedUntilVisit = false; root.open = false; });
                        item.focusInput();
                    }
                    if (root.view === "record") {
                        item.mode = Qt.binding(() => root.recordMode);
                        item.screenName = root.screenData?.name ?? "";
                        item.dragProxy = dragProxy;
                        item.close.connect(() => { root.pinnedUntilVisit = false; root.open = false; });
                        item.acted.connect(() => root.recordActed = true);
                    }
                    if (root.view === "home") {
                        item.raise.connect(() => root.fold());
                        item.textDragOver = Qt.binding(() => root.textDragOver);
                    }
                    if (root.view === "shelf") {
                        item.dragProxy = dragProxy;
                        item.dragOver = Qt.binding(() => root.dragOver);
                        item.openFile.connect(path => {
                            if (path.length > 0)
                                Quickshell.execDetached(["xdg-open", path]);
                            root.pinnedUntilVisit = false;
                            root.open = false;
                        });
                        DropShelf.prune();
                    }
                }
            }

            // Agent sessions (IslandController.sessionRows): state glyph, task, folder · since.
            // A click focuses the session's window and folds the notch.
            Column {
                id: sessionRows
                visible: root.view !== "ask" && root.view !== "address" && root.view !== "signin" && root.view !== "record"
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 8 + (root.timerRunning ? 38 : 0)
                spacing: 0

                Repeater {
                    model: IslandController.openSessions
                    delegate: Item {
                        id: sessionRow
                        required property var modelData
                        required property int index
                        // The snapshot holds the session OBJECT, and AgentSessions mutates its
                        // sessions in place (see AgentSessions.qml), so nothing bound through
                        // modelData ever re-fires. Resolve this row's session out of the live
                        // list instead - as a fresh copy, or the identical object would not
                        // notify either. The sub-rows below stay on the snapshot: the list must
                        // not reflow under the pointer, and its height is the window's to spare.
                        readonly property var live: {
                            const s = AgentSessions.sessions.find(x => x.id === sessionRow.modelData.id);
                            return s ? Object.assign({}, s) : null;
                        }
                        readonly property var shown: sessionRow.live ?? sessionRow.modelData
                        readonly property bool gone: sessionRow.live === null
                        readonly property bool waiting: sessionRow.shown.state === "waiting"
                        readonly property var agents: (modelData.agents ?? []).slice(0, 3)
                        readonly property int agentsHidden: Math.max(0, (modelData.agents ?? []).length - 3)
                        width: sessionRows.width
                        height: 34 + agents.length * 26 + (agentsHidden > 0 ? 20 : 0)
                        // its terminal has gone: the row stays where it is, greyed and inert
                        opacity: sessionRow.gone ? 0.4 : 1

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: 34
                            radius: 8
                            color: sessionArea.containsMouse || root.selected === sessionRow.index ? Appearance.colors.colLayer1Hover : "transparent"
                        }
                        // the session's delegated agents, one line each, indented under it
                        Column {
                            id: agentColumn
                            anchors.left: parent.left
                            anchors.leftMargin: 26
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.topMargin: 34
                            Repeater {
                                model: sessionRow.agents
                                delegate: Item {
                                    required property var modelData
                                    width: agentColumn.width
                                    height: 26
                                    MaterialSymbol {
                                        id: agentGlyph
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "subdirectory_arrow_right"
                                        iconSize: 16
                                        color: IslandController.subtextColor
                                    }
                                    StyledText {
                                        anchors.left: agentGlyph.right
                                        anchors.leftMargin: 6
                                        anchors.right: agentAge.left
                                        anchors.rightMargin: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.desc
                                        elide: Text.ElideRight
                                        font.pixelSize: 14
                                        color: IslandController.subtextColor
                                    }
                                    StyledText {
                                        id: agentAge
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.elapsed(modelData.since)
                                        font.family: Appearance.font.family.numbers
                                        font.pixelSize: 13
                                        color: IslandController.subtextColor
                                    }
                                }
                            }
                            StyledText {
                                visible: sessionRow.agentsHidden > 0
                                height: visible ? 20 : 0
                                leftPadding: 22
                                verticalAlignment: Text.AlignVCenter
                                text: `and ${sessionRow.agentsHidden} more`
                                font.pixelSize: 13
                                color: IslandController.subtextColor
                            }
                        }
                        MaterialSymbol {
                            id: sessionGlyph
                            anchors.left: parent.left
                            y: 17 - height / 2
                            text: sessionRow.waiting ? "back_hand"
                                : sessionRow.shown.state === "working" ? "progress_activity"
                                : sessionRow.shown.state === "done" ? "check" : "radio_button_unchecked"
                            iconSize: 18
                            color: sessionRow.waiting ? Appearance.colors.colPrimary : IslandController.subtextColor
                        }
                        StyledText {
                            anchors.left: sessionGlyph.right
                            anchors.leftMargin: 8
                            anchors.right: sessionMeta.left
                            anchors.rightMargin: 12
                            y: 17 - height / 2
                            text: AgentSessions.label(sessionRow.shown)
                            elide: Text.ElideRight
                            font.pixelSize: 15
                            color: sessionRow.waiting ? Appearance.colors.colPrimary : IslandController.contentColor
                        }
                        StyledText {
                            id: sessionMeta
                            anchors.right: parent.right
                            y: 17 - height / 2
                            // the title keeps its room: the activity column is capped and elides
                            width: Math.min(implicitWidth, 230)
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignRight
                            // what it is doing now · since; "quiet Nm" when a working session has gone
                            // silent; folder · since when it is not working.
                            text: {
                                const s = sessionRow.shown;
                                const since = root.elapsed(s.since);
                                const quiet = AgentSessions.quietMinutes(s);
                                if (quiet > 0)
                                    return `quiet ${quiet}m`;
                                if (s.state === "working" && (s.activity ?? "").length > 0)
                                    return `${s.activity} · ${since}`;
                                const folder = (s.cwd + "").split("/").pop();
                                return folder === AgentSessions.label(s) ? since : `${folder} · ${since}`;
                            }
                            color: AgentSessions.quietMinutes(sessionRow.shown) > 0 ? Appearance.colors.colTertiary : IslandController.subtextColor
                            font.family: Appearance.font.family.numbers
                            font.pixelSize: 14
                        }
                        MouseArea {
                            id: sessionArea
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            height: 34
                            enabled: !sessionRow.gone
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                AgentSessions.focus(sessionRow.live);
                                root.fold();
                            }
                        }
                    }
                }

                // more sessions than rows: say so, once
                StyledText {
                    visible: IslandController.sessionsHidden > 0
                    height: visible ? 20 : 0
                    leftPadding: 26
                    verticalAlignment: Text.AlignVCenter
                    text: `and ${IslandController.sessionsHidden} more sessions`
                    font.pixelSize: 13
                    color: IslandController.subtextColor
                }

                // sessions above, arrivals below: one list, one hairline between the two
                Rectangle {
                    width: sessionRows.width
                    height: 9
                    visible: IslandController.openSessions.length > 0 && IslandController.openRecents.length > 0
                    color: "transparent"
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width - 8
                        height: 1
                        color: Appearance.colors.colOutlineVariant
                        opacity: 0.6
                    }
                }

                // Just happened (Recents): type glyph, label, source app, age, one side action.
                // Click does the obvious thing (open / back on the clipboard) and folds; middle
                // click goes back to the window it came from; right click drops the row. Every
                // row drags out (text or file), like a shelf tile.
                Repeater {
                    model: IslandController.openRecents
                    delegate: Item {
                        id: recentRow
                        required property var modelData
                        required property int index
                        readonly property var item: modelData
                        readonly property bool draggable: item.kind !== "image" && item.kind !== "secret" && item.kind !== "downloading"
                        width: sessionRows.width
                        height: 34

                        // unseen: a dot in the left margin, primary
                        Rectangle {
                            anchors.right: parent.left
                            anchors.rightMargin: 7
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6
                            height: 6
                            radius: 3
                            visible: !recentRow.item.seen
                            color: Appearance.colors.colPrimary
                        }

                        Rectangle {
                            id: recentCard
                            width: parent.width
                            height: parent.height
                            radius: 8
                            color: recentArea.containsMouse || root.selected === IslandController.openSessions.length + recentRow.index ? Appearance.colors.colLayer1Hover : "transparent"

                            Drag.active: recentRow.draggable && recentArea.drag.active
                            Drag.dragType: Drag.Automatic
                            // Rows come and go while a drag is out; a dead source segfaults Qt.
                            Component.onDestruction: if (recentCard.Drag.active) recentCard.Drag.cancel()
                            Drag.mimeData: recentRow.item.path.length > 0
                                ? { "text/uri-list": "file://" + recentRow.item.path }
                                : { "text/plain": recentRow.item.text }
                            Drag.supportedActions: Qt.CopyAction

                            // type: a swatch for a colour, a glyph for everything else
                            Rectangle {
                                id: swatch
                                anchors.left: parent.left
                                anchors.leftMargin: 1
                                anchors.verticalCenter: parent.verticalCenter
                                width: 16
                                height: 16
                                radius: 5
                                visible: recentRow.item.kind === "color"
                                color: visible ? recentRow.item.text.trim() : "transparent"
                                border.width: 1
                                border.color: Appearance.colors.colOutlineVariant
                            }
                            MaterialSymbol {
                                id: recentGlyph
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                visible: recentRow.item.kind !== "color"
                                text: Recents.glyphFor(recentRow.item.kind)
                                iconSize: 18
                                color: recentRow.item.kind === "error" ? Appearance.colors.colError
                                    : recentRow.item.kind === "secret" ? Appearance.colors.colTertiary : IslandController.subtextColor
                            }
                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 26
                                anchors.right: recentMeta.left
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: Recents.label(recentRow.item)
                                horizontalAlignment: Text.AlignLeft   // right-to-left text must not drift to the edge
                                elide: Text.ElideRight
                                font.family: recentRow.item.kind === "command" || recentRow.item.kind === "error"
                                    ? Appearance.font.family.monospace : Appearance.font.family.main
                                font.pixelSize: recentRow.item.kind === "command" || recentRow.item.kind === "error" ? 14 : 15
                                color: IslandController.contentColor
                            }
                            Row {
                                id: recentMeta
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                // where it came from
                                IconImage {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: recentRow.item.app.length > 0
                                    implicitSize: 16
                                    source: recentRow.item.app.length > 0
                                        ? Quickshell.iconPath(AppSearch.guessIcon(recentRow.item.app), "image-missing") : ""
                                }
                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Recents.age(recentRow.item)
                                    font.family: Appearance.font.family.numbers
                                    font.pixelSize: 14
                                    color: IslandController.subtextColor
                                }
                                // the one side action: a command goes to a terminal prompt,
                                // everything else can be handed to Claude
                                IslandControlButton {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: recentRow.item.kind === "command" || Recents.canHand(recentRow.item)
                                    implicitWidth: 26
                                    implicitHeight: 26
                                    glyph: recentRow.item.kind === "command" ? "play_arrow" : "smart_toy"
                                    iconSize: 16
                                    onActivated: {
                                        if (recentRow.item.kind === "command")
                                            Recents.run(recentRow.item);
                                        else
                                            Recents.hand(recentRow.item);
                                        root.pinnedUntilVisit = false;
                                        root.open = false;
                                    }
                                }
                            }
                            MouseArea {
                                id: recentArea
                                anchors.fill: parent
                                anchors.rightMargin: recentRow.item.kind === "command" || Recents.canHand(recentRow.item) ? 34 : 0
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                drag.target: recentRow.draggable ? parent : null
                                drag.threshold: 8
                                onPressed: event => {
                                    if (event.button === Qt.LeftButton && recentRow.draggable)
                                        parent.grabToImage(() => {});
                                }
                                onReleased: {
                                    if (parent.Drag.active)
                                        parent.Drag.drop();
                                    parent.x = 0;
                                    parent.y = 0;
                                }
                                onClicked: event => {
                                    if (event.button === Qt.LeftButton) {
                                        Recents.activate(recentRow.item);
                                        root.pinnedUntilVisit = false;
                                        root.open = false;
                                    } else if (event.button === Qt.MiddleButton) {
                                        Recents.back(recentRow.item);
                                        root.pinnedUntilVisit = false;
                                        root.open = false;
                                    } else {
                                        Recents.remove(recentRow.item);
                                    }
                                }
                                drag.onActiveChanged: root.rowDragging = recentArea.drag.active
                            }
                        }
                    }
                }
            }

            // A running timer gets its own row under whichever view is open: time left, pause, stop.
            Item {
                id: timerRow
                anchors.left: parent.left
                anchors.leftMargin: 20
                anchors.right: parent.right
                anchors.rightMargin: 20
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 8
                height: 30
                visible: root.timerRunning && root.view !== "ask" && root.view !== "address" && root.view !== "signin" && root.view !== "record"

                readonly property bool pomodoro: TimerService.pomodoroRunning
                readonly property int secondsLeft: pomodoro ? TimerService.pomodoroSecondsLeft : TimerService.countdownSecondsLeft

                MaterialSymbol {
                    id: timerGlyph
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: timerRow.pomodoro && TimerService.pomodoroBreak ? "coffee" : "timer"
                    iconSize: 18
                    color: Appearance.colors.colTertiary
                }
                StyledText {
                    anchors.left: timerGlyph.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: `${TimerService.formatSeconds(Math.max(0, timerRow.secondsLeft))} · ${timerRow.pomodoro ? (TimerService.pomodoroBreak ? "break" : "focus") : "countdown"}`
                    font.pixelSize: 14
                    color: IslandController.contentColor
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    IslandControlButton {
                        implicitWidth: 28
                        implicitHeight: 28
                        visible: timerRow.pomodoro
                        glyph: "pause"
                        iconSize: 16
                        onActivated: TimerService.togglePomodoro()
                    }
                    IslandControlButton {
                        implicitWidth: 28
                        implicitHeight: 28
                        glyph: "stop"
                        iconSize: 16
                        onActivated: timerRow.pomodoro ? TimerService.resetPomodoro() : TimerService.toggleCountdown()
                    }
                }
            }
        }
    }
}
