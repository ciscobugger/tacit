pragma ComponentBehavior: Bound

import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The 34px header: [left wing]  time · status glyph  [right wing].
 * The time is our camera - it never leaves the centre (boring.notch ContentView.swift
 * MusicLiveActivity / InlineHUD: album art left, spectrum right, HUD icon left, bar right).
 * Only the wings change with the state; they crossfade, the centre never moves.
 */
Item {
    id: root

    // "idle", "open", "address" (the browser's Ctrl+L sheet), "signin" (its sign-in holds the sheet), "signinPeek"
    // (the sign-in breathing in), "signinWait" (it waits as a wing), "recordSheet" (the recording's choice or card),
    // or a peek name.
    property string notchState: "idle"
    // the window's middle in the header's own place (IslandContent sets it); the notch's own middle when alone
    property real windowMid: width / 2
    property string loadedState: "idle"
    readonly property real wing: IslandController.wingFor(root.loadedState)
    readonly property string glyph: IslandController.ambientGlyph
    readonly property bool isDot: root.glyph === "circle"
    // a peek shows its point: the time and the status glyph step back to meta
    readonly property bool pointShown: !["idle", "open", "address", "signin", "signinPeek", "signinWait", "notAnswering", "recordSheet"].includes(root.loadedState)

    implicitHeight: 34

    // At rest the wings still change - music starts, a timer runs, a session begins working -
    // while notchState stays "idle". Those are a state change as far as the header is concerned,
    // so they crossfade too. Kept out of notchState itself: IslandController.geometryFor and
    // wingFor switch on that string and would not know the name.
    readonly property string idleSub: (IslandController.mediaVisible ? "m" : "")
        + (IslandController.focusRunning ? "t" : "")
        + (AgentSessions.active !== null ? "s" : "")
    property string loadedIdleSub: root.idleSub   // bound until the first crossfade hands it over

    onNotchStateChanged: root.swapWings()
    onIdleSubChanged: if (root.notchState === "idle") root.swapWings()

    function swapWings() {
        if (wingSwap.running)
            wingSwap.complete();
        wingSwap.restart();
    }

    // Contents finish 20ms before the shape does: 100 out, 80 hold, 140 in.
    SequentialAnimation {
        id: wingSwap
        NumberAnimation {
            targets: [leftWing, rightWing]
            property: "opacity"
            to: 0
            duration: 100
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.emphasizedAccel
        }
        PauseAnimation {
            duration: 80
        }
        ScriptAction {
            script: {
                root.loadedState = root.notchState;
                root.loadedIdleSub = root.idleSub;
            }
        }
        NumberAnimation {
            targets: [leftWing, rightWing]
            property: "opacity"
            to: 1
            duration: 140
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.animationCurves.expressiveEffects
        }
    }

    // ---------------------------------------------------------------- centre
    // The time alone at the notch's exact middle (the owner, 2026-10-15: centred as a pair with the status glyph it sat
    // 14 px off, and with the glyph hanging beside it the pair read right-heavy); the status glyph sits at the right edge.
    // While a screen recording runs, its time takes the clock's place: the red dot, the time, and Stop under the hand
    // (mock ~/dev/tacit-site/mocks/record/); a click on the notch at rest, or on the time, stops it (liveArea below).
    // The hand is the notch's own hover (IslandController.notchHovered), which also widens the notch for the word, so
    // at rest the time keeps the middle.
    Item {
        id: centre
        readonly property bool live: IslandController.recording
        // Kept on the window's middle, not the notch's: centred on the notch's own middle, the time moved with each width
        // the notch passed through, which at 125 % showed as a small shift when it opened (Discord 2026-11-03: "the time
        // just keeps small shifting when expand"). Measured on a test computer at 125 %: 0.8 px between closed and open
        // before, 0.4 px after, which is what the time's change of ink alone reads as at 100 %, where it does not move.
        x: Math.round(root.windowMid - width / 2)
        width: centre.live ? liveRow.width : clockFace.width
        height: parent.height
        // under the workspace sheet, which draws this same centre in the same place
        visible: !GlobalStates.gridOver

        StripClock {
            id: clockFace
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            back: root.pointShown
            opacity: centre.live ? 0 : 1
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation { duration: 160 }
            }
        }

        Row {
            id: liveRow
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            // No Row spacing: each gap is the padding of the item after it. A revealed Stop is a child whose width
            // goes to 0, and a Row's spacing before a zero-width child is still laid out (and dropped only when the
            // child finally hides), which shifted the dot and time by 4 px as the word went. With the gap inside the
            // animated width, the row's width is the dot and the time exactly whenever the hand leaves.
            spacing: 0
            opacity: centre.live ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation { duration: 160 }
            }
            Item {
                width: 9
                height: 9
                anchors.verticalCenter: parent.verticalCenter
                // the mock's glow: a wider, fainter disc under the dot
                Rectangle {
                    anchors.centerIn: parent
                    width: 15
                    height: 15
                    radius: 7.5
                    color: Qt.alpha(root.recordRed, 0.22)
                }
                Rectangle {
                    id: liveDot
                    anchors.fill: parent
                    radius: 4.5
                    color: root.recordRed
                    // three breaths as it starts, then still (an endless one repaints the notch every frame)
                    SequentialAnimation {
                        running: centre.live
                        loops: 3
                        NumberAnimation { target: liveDot; property: "opacity"; to: 0.55; duration: 1300; easing.type: Easing.InOutSine }
                        NumberAnimation { target: liveDot; property: "opacity"; to: 1; duration: 1300; easing.type: Easing.InOutSine }
                    }
                }
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: IslandController.recordElapsed
                // the gap after the dot (liveRow has no spacing: see there)
                leftPadding: 8
                font.family: Appearance.font.family.numbers
                font.pixelSize: 16
                font.variableAxes: ({ "wght": 500 })
                font.features: ({ "tnum": 1 })
                color: Tacit.inkMain
            }
            // "Stop" under the hand, as the mock has it, brought out by the notch's own hover (IslandController's
            // notchHovered, from IslandContent's HoverHandler) rather than the stop area's own: a MouseArea's
            // containsMouse missed the pointer arriving in the notch - the notch sits on the screen's edge, so arriving
            // is all a pointer does - and the one way out of a recording stayed hidden until the pointer was moved
            // around inside it (2026-11-01). The notch makes room for it while the hand is there, and sits at the
            // clock's box otherwise, so at rest the time keeps the middle.
            // Its width carries the gap before it and runs on the notch's own fold curve at the notch's own 450 ms
            // (IslandContent's geometry for a closed state): the expressive spatial curves overshoot, and on the way
            // out the box dipped below zero, was clamped and came back above it, so the row widened and narrowed again
            // after the word had gone - the recording's time bounced twice (2026-11-01).
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: IslandController.notchHovered ? stopWord.implicitWidth : 0
                height: stopWord.implicitHeight
                clip: true
                visible: width > 0
                Behavior on width {
                    NumberAnimation { duration: 450; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.emphasizedDecel }
                }
                StripWords {
                    id: stopWord
                    text: "Stop"
                    // the gap after the time (liveRow has no spacing: see there), inside the width this fades with
                    leftPadding: 8
                    point: true
                    color: Tacit.accent
                    opacity: IslandController.notchHovered ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 450; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.emphasizedDecel }
                    }
                }
            }
        }
    }
    readonly property color recordRed: "#e8705e"

    // Status slot: recording, mic, dnd, charging, timer, unread - in that order. At the right edge, the right side
    // ending 8 px before it; in the open sheet's header (and the address bar's, the sign-in's) that edge is the battery's
    // or the way back's, so the mark steps aside there.
    Loader {
        id: statusSlot
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        active: root.glyph !== ""
        visible: active && !GlobalStates.gridOver && !["open", "address", "signin", "signinPeek", "signinWait", "recordSheet"].includes(root.loadedState)

        sourceComponent: MaterialSymbol {
            id: statusGlyph
            text: root.glyph
            fill: root.isDot ? 1 : 0
            iconSize: root.isDot ? 8 : 18
            // the inks (2026-10-15): the sand dot for an agent at work (light means AI at work, nothing else), the main
            // ink for what asks for attention (meta while a peek shows its point), meta for the passive ones
            color: root.isDot ? Appearance.colors.colPrimary : statusGlyph.attention && !root.pointShown ? Tacit.inkMain : Tacit.inkMeta

            // Breathing: the glyph only, never the container - and only the glyphs that
            // ask for attention. Passive ones (night light, shelf, caffeine) stay still.
            // Three breaths when such a state starts or changes, then a steady glyph: an
            // endless animation repaints the notch every frame and the screen never rests.
            readonly property bool attention: ["fiber_manual_record", "mic", "battery_alert", "circle", "progress_activity", "back_hand", "rate_review"].includes(root.glyph)
            // a change during a breath joins it rather than restarting it (no jump)
            function breathe() {
                if (attention && !breath.running)
                    breath.start();
            }
            onAttentionChanged: attention ? breathe() : breath.stop()
            Connections {
                target: root
                function onGlyphChanged() { statusGlyph.breathe(); }
            }
            Component.onCompleted: breathe()
            SequentialAnimation {
                id: breath
                loops: 3
                // stopped mid-breath, it still finishes the breath and ends at rest; each half
                // starts where the glyph is, so a breath that starts again never jumps
                alwaysRunToEnd: true
                ParallelAnimation {
                    NumberAnimation { target: statusGlyph; property: "opacity"; to: 0.55; duration: 2600; easing.type: Easing.InOutSine }
                    NumberAnimation { target: statusGlyph; property: "scale"; to: 1.035; duration: 2600; easing.type: Easing.InOutSine }
                }
                ParallelAnimation {
                    NumberAnimation { target: statusGlyph; property: "opacity"; to: 1.0; duration: 2600; easing.type: Easing.InOutSine }
                    NumberAnimation { target: statusGlyph; property: "scale"; to: 1.0; duration: 2600; easing.type: Easing.InOutSine }
                }
            }
        }
    }

    // a recording's stop: the whole notch at rest, the time and its Stop when a peek or the sheet has wings beside it.
    // Under the wings, so their own controls keep their clicks.
    MouseArea {
        id: liveArea
        readonly property bool whole: root.loadedState === "idle"
        visible: centre.live && centre.visible
        x: liveArea.whole ? 0 : centre.x - 6
        width: liveArea.whole ? root.width : centre.width + 12
        height: root.height
        cursorShape: Qt.PointingHandCursor
        onClicked: IslandController.stopRecording()
    }

    // ---------------------------------------------------------------- wings
    Loader {
        id: leftWing
        // fades under the workspace sheet and back in once the sheet is gone into the notch
        opacity: GlobalStates.gridOver ? 0 : 1
        Behavior on opacity {
            NumberAnimation { duration: Appearance.animationCurves.expressiveFastEffectsDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveFastEffects }
        }
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.right: centre.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        height: 24
        sourceComponent: root.leftFor(root.loadedState)
    }

    Loader {
        id: rightWing
        // fades under the workspace sheet and back in once the sheet is gone into the notch
        opacity: GlobalStates.gridOver ? 0 : 1
        Behavior on opacity {
            NumberAnimation { duration: Appearance.animationCurves.expressiveFastEffectsDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveFastEffects }
        }
        anchors.left: centre.right
        anchors.leftMargin: 8
        anchors.right: parent.right
        anchors.rightMargin: statusSlot.visible ? 12 + statusSlot.width + 8 : 10
        anchors.verticalCenter: parent.verticalCenter
        height: 24
        sourceComponent: root.rightFor(root.loadedState)
    }

    function leftFor(state) {
        switch (state) {
        case "idle":
            if (root.loadedIdleSub.includes("m"))
                return artWing;
            if (root.loadedIdleSub.includes("t"))
                return timerGlyphWing;
            return root.loadedIdleSub.includes("s") ? sessionNameWing : null;
        case "open":
            return dateWing;
        case "address":
            return addressTaskWing;
        case "signin":
        case "signinPeek":
            return signinHostWing;
        case "signinWait":
            return signinWaitLeftWing;
        case "signedIn":
            return signedInLeftWing;
        case "volume":
        case "brightness":
            return meterLabelWing;
        case "track":
            return trackTitleWing;
        case "activity":
            return activityNameWing;
        case "greeting":
            return greetingWing;
        case "reload":
            return reloadMarkWing;
        case "brief":
            return briefLeftWing;
        case "workspace":
            return workspaceLabelWing;
        case "notification":
            return notificationTextWing;
        case "notAnswering":    // the prompt under the header says it all
        case "recordSheet":     // the time alone over the recording's choice or card
            return null;
        case "flow":            // with the sand, no words; without it, "Listening"
            return IslandController.sandReady ? null : messageTextWing;
        }
        return messageTextWing;
    }

    function rightFor(state) {
        switch (state) {
        case "idle":
            if (root.loadedIdleSub.includes("t"))
                return timerWing;
            if (root.loadedIdleSub.includes("m"))
                return spectrumWing;
            return root.loadedIdleSub.includes("s") ? sessionActivityWing : null;
        case "open":
            // boring.notch OpenNotchHUD: a volume/brightness change while open takes the right
            // side of the header (BoringHeader.swift:38-40); the sheet stays put. Every other
            // peek that lands while open shows here too, compactly - it must not be lost.
            if (!IslandController.transientShowing)
                return batteryWing;
            if (IslandController.transientState === "volume" || IslandController.transientState === "brightness")
                return meterBarWing;
            return openPeekWing;
        case "address":
            // a peek while it is open takes this side, as it does over the open sheet
            if (!IslandController.transientShowing)
                return addressPagesWing;
            if (IslandController.transientState === "volume" || IslandController.transientState === "brightness")
                return meterBarWing;
            return openPeekWing;
        case "signin":
            // volume, a copy, a download, the battery: this side for their hold, then the way back returns
            if (!IslandController.transientShowing)
                return signinBackWing;
            if (IslandController.transientState === "volume" || IslandController.transientState === "brightness")
                return meterBarWing;
            return openPeekWing;
        case "signinPeek":
            return signinForWing;
        case "signinWait":
            return signinWaitRightWing;
        case "signedIn":
            return signedInRightWing;
        case "volume":
        case "brightness":
            return meterBarWing;
        case "track":
            return trackArtistWing;
        case "activity":
            return activityBarWing;
        case "greeting":
            return greetingDateWing;
        case "reload":
            return reloadWordWing;
        case "brief":
            return briefRightWing;
        case "workspace":
            return workspaceNumeralWing;
        case "notification":
            return notificationAppWing;
        case "wallpaper":
            return undoPillWing;
        case "window":
            return IslandController.payload?.pill ? windowPillWing : messageGlyphWing;
        case "update":
            return updateAnswerWing;
        case "updated":
            return IslandController.payload?.notes ? updatedNotesWing : messageGlyphWing;
        case "claudeAsk":
            return IslandController.payload?.permission ? claudeAnswerWing : messageGlyphWing;
        case "flow":
            if (IslandController.sandReady)     // the sand says it
                return null;
            return IslandController.payload?.writing ? flowWritingWing : flowLevelWing;
        case "notAnswering":
        case "recordSheet":
            return null;
        }
        return messageGlyphWing;
    }

    // A peek's one line as its point (left) and the rest (right): "Merged · Wedding#361", "9%. Plug in.", a text and its
    // value, or "Buds Pro connected" as the thing and what happened. An agent's "Needs you · menu" turns round, the name
    // first; an ask and Flow keep their whole line.
    function parts(state, p) {
        let point = (p?.text ?? "").replace(/\s+/g, " ").trim();
        let rest = (p?.value ?? "") + "";
        const dot = point.indexOf(" · ");
        if (state === "claudeAsk" || state === "flow") {
            // whole
        } else if (dot > 0) {
            const after = point.slice(dot + 3);
            const before = point.slice(0, dot);
            if (state === "session") {
                point = after;
                rest = root.lower(before);
            } else {
                point = before;
                rest = rest.length > 0 ? `${after} · ${rest}` : after;
            }
        } else if (["battery", "charger", "chargerFault", "timerDone"].includes(state)) {
            const m = point.match(/^(.+?)\. (.+)$/);
            if (m) {
                point = m[1];
                rest = rest.length > 0 ? rest : root.lower(m[2]);
            }
        }
        if (rest.length === 0 && ["network", "timerDone", "activityDone", "activityFail"].includes(state)) {
            const m = point.replace(/\.$/, "").match(/^(.+) (connected|disconnected|on|off|dropped|done|failed)$/);
            if (m) {
                point = m[1];
                rest = m[2];
            } else if (state === "network" && (p?.icon ?? "").startsWith("wifi")) {
                rest = "Wi-Fi";
            }
        }
        if (state === "layout" && rest.length === 0)
            rest = "keyboard";
        return { "point": point.replace(/\.$/, ""), "rest": rest.replace(/\.$/, "") };
    }
    function lower(s) {
        return s.length > 0 ? s.charAt(0).toLowerCase() + s.slice(1) : s;
    }

    component WingText: StyledText {
        font.family: Appearance.font.family.condensed
        font.pixelSize: 15
        elide: Text.ElideRight
        maximumLineCount: 1   // a wing is one line; a text with line breaks (a script Claude asks to run) painted all of them over the pill
        color: IslandController.contentColor
    }

    // -- idle
    Component {
        id: artWing
        Item {
            StripArt {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                source: MprisController.activePlayer?.trackArtUrl ?? ""
                opacity: MprisController.isPlaying ? 1 : 0.5
                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }
    Component {
        id: spectrumWing
        Item {
            Visualizer {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                vertical: false
                isMaterial: false
                barCount: 5
                dotSize: 2
                dotSpacing: 2
                maxVisualizerValue: 1000
                maxBarHeight: 14
                implicitWidth: barCount * (dotSize + dotSpacing)
                implicitHeight: 16
                opacity: MprisController.isPlaying ? 1 : 0.4
                // the shared widget draws in the accent; here it takes the quiet ink (light means AI at work)
                layer.enabled: true
                layer.effect: ColorOverlay {
                    color: Tacit.inkMeta
                }
            }
        }
    }

    // A running timer at rest, symmetric around the clock: glyph in the left wing, time left
    // in the right. With media showing the art keeps the left wing and the glyph joins the
    // time on the right. Pomodoro break = coffee; numbers in the content colour like the clock.
    component TimerGlyph: MaterialSymbol {
        text: TimerService.pomodoroRunning && TimerService.pomodoroBreak ? "coffee" : "timer"
        iconSize: 17
        color: Tacit.inkMeta
    }
    Component {
        id: timerGlyphWing
        Item {
            TimerGlyph {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
    Component {
        id: timerWing
        Item {
            readonly property bool pomodoro: TimerService.pomodoroRunning
            readonly property int secondsLeft: pomodoro ? TimerService.pomodoroSecondsLeft : TimerService.countdownSecondsLeft
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                TimerGlyph {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: IslandController.mediaVisible
                    iconSize: 16
                }
                StripNum {
                    anchors.verticalCenter: parent.verticalCenter
                    text: TimerService.formatSeconds(Math.max(0, parent.parent.secondsLeft))
                }
            }
        }
    }

    // -- open (boring.notch BoringHeader: date where their tabs were, battery right)
    Component {
        id: dateWing
        Item {
            WingText {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(new Date(), "ddd d MMM")
                color: IslandController.subtextColor
            }
        }
    }
    Component {
        id: batteryWing
        Item {
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4
                MaterialSymbol {
                    visible: Battery.available
                    anchors.verticalCenter: parent.verticalCenter
                    text: Battery.isPluggedIn ? "bolt" : (Battery.percentage <= 0.2 ? "battery_alert" : "battery_full")
                    iconSize: 16
                    color: !Battery.isPluggedIn && Battery.percentage <= 0.2 ? Tacit.inkMain : IslandController.subtextColor
                }
                WingText {
                    visible: Battery.available
                    anchors.verticalCenter: parent.verticalCenter
                    // Time left, not just percent: a 4 AM session on battery wants to know
                    // when to plug in. Battery's measured estimate, shown only once it has one; plugged in
                    // while the pack still drains says so instead of a time to full.
                    text: {
                        const pct = `${Math.round(Battery.percentage * 100)}%`;
                        if (Battery.drainingOnAc)
                            return `${pct} · not charging`;
                        const secs = Battery.isCharging ? Battery.timeToFull : Battery.timeToEmpty;
                        if (!(secs > 60))
                            return pct;
                        const m = Math.round(secs / 60);
                        const span = m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
                        return Battery.isCharging ? `${pct} · ${span} to full` : `${pct} · ${span}`;
                    }
                    font.family: Appearance.font.family.numbers
                    color: IslandController.subtextColor
                }
            }
        }
    }

    // -- address (the browser's Ctrl+L): the task left, its pages right, at the sheet's 28 px edge
    Component {
        id: addressTaskWing
        Item {
            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: IslandController.addressTask
                elide: Text.ElideRight
                font.pixelSize: 13
                font.variableAxes: ({ "wght": 400 })
                color: Appearance.colors.colOnLayer0
            }
        }
    }
    Component {
        id: addressPagesWing
        Item {
            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: IslandController.addressPages > 0 ? `${IslandController.addressPages} ${IslandController.addressPages === 1 ? "page" : "pages"}` : ""
                font.pixelSize: 13
                font.variableAxes: ({ "wght": 400 })
                color: Appearance.colors.colSubtext
            }
        }
    }

    // A peek while open: glyph + one line, right-aligned, in place of the battery.
    Component {
        id: openPeekWing
        Item {
            id: wingItem
            readonly property var p: IslandController.payload
            readonly property string line: {
                const state = IslandController.transientState;
                if (state === "track")
                    return wingItem.p?.title ?? "";
                if (state === "workspace")
                    return `Workspace ${wingItem.p?.number ?? ""}`;
                if (state === "activity")
                    return wingItem.p?.name ?? "";
                if (state === "notification")
                    return wingItem.p?.summary ?? "";
                return wingItem.p?.text ?? "";
            }
            readonly property string icon: {
                const state = IslandController.transientState;
                if (state === "track")
                    return "music_note";
                if (state === "workspace")
                    return "grid_view";
                if (state === "activity")
                    return "progress_activity";
                if (state === "notification")
                    return "notifications";
                if (state === "greeting")
                    return "waving_hand";
                return wingItem.p?.icon ?? "info";
            }
            WingText {
                anchors.left: parent.left
                anchors.right: peekGlyph.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: parent.line
            }
            MaterialSymbol {
                id: peekGlyph
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: parent.icon
                iconSize: 18
                color: IslandController.contentColor
            }
        }
    }

    // -- volume / brightness (boring.notch InlineHUD: icon + name left, bar + % right)
    component Meter: QtObject {
        readonly property string kind: IslandController.payload?.kind ?? "volume"
        readonly property bool isGamma: kind === "gamma"
        readonly property bool isBrightness: kind === "brightness" || isGamma
        readonly property bool muted: !isBrightness && (Audio.sink?.audio.muted ?? false)
        readonly property real value: isGamma ? Hyprsunset.gamma / 100 : isBrightness ? IslandController.focusedBrightness : (Audio.sink?.audio.volume ?? 0)
        readonly property string glyph: {
            if (isGamma)
                return "contrast";
            if (isBrightness)
                return "brightness_6";
            if (muted)
                return "volume_off";
            if (value < 0.01)
                return "volume_mute";
            if (value < 0.5)
                return "volume_down";
            return "volume_up";
        }
    }
    Component {
        id: meterLabelWing
        Item {
            Meter { id: meter }
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: meter.isGamma ? "Gamma" : meter.isBrightness ? "Brightness" : (meter.muted ? "Muted" : "Volume")
            }
        }
    }
    Component {
        id: meterBarWing
        Item {
            Meter { id: meter }
            StripBar {
                anchors.left: parent.left
                anchors.right: numeral.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                value: meter.value
            }
            StripNum {
                id: numeral
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                horizontalAlignment: Text.AlignRight
                point: true
                text: `${Math.round(meter.value * 100)}%`
            }
        }
    }

    // -- new track (boring.notch inline sneak peek: art + title left, artist right)
    Component {
        id: trackTitleWing
        Item {
            StripArt {
                id: art
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                source: IslandController.payload?.art ?? ""
            }
            StripWords {
                anchors.left: art.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: IslandController.payload?.title ?? ""
            }
        }
    }
    Component {
        id: trackArtistWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: IslandController.payload?.artist ?? ""
            }
        }
    }

    // -- one-line messages (battery, charger, timerDone, network, activityDone/Fail...): the point left - a download or a
    // screenshot with the thing itself, an agent waiting with a dot - and the rest right, in place of a glyph
    Component {
        id: messageTextWing
        Item {
            id: messageItem
            readonly property string path: root.loadedState === "download" ? (IslandController.payload?.path ?? "") : ""
            readonly property bool showsThing: /\.(png|jpe?g|webp|bmp|gif|pdf)$/i.test(messageItem.path)
            readonly property bool waiting: root.loadedState === "session" && IslandController.payload?.icon === "back_hand"
            StripArt {
                id: thing
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: messageItem.showsThing
                source: messageItem.showsThing ? messageItem.path : ""
                wide: IslandController.screenshotDir.length > 0 && messageItem.path.startsWith(IslandController.screenshotDir + "/")
                veil: /\.pdf$/i.test(messageItem.path) ? 0.3 : 0.15
            }
            StripDot {
                id: waitDot
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                visible: messageItem.waiting
            }
            StripWords {
                anchors.left: parent.left
                anchors.leftMargin: messageItem.showsThing ? thing.width + 8 : messageItem.waiting ? waitDot.width + 8 : 0
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                // a file's name keeps its end (".pdf")
                elide: messageItem.path !== "" ? Text.ElideMiddle : Text.ElideRight
                text: root.parts(root.loadedState, IslandController.payload).point
            }
        }
    }
    Component {
        id: messageGlyphWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                // a question rather than a permission is answered in the sheet
                text: root.loadedState === "claudeAsk" ? "needs an answer" : root.parts(root.loadedState, IslandController.payload).rest
            }
        }
    }

    // -- wallpaper: the one peek with a control. A slip of the hand changed the whole desktop;
    // the way back is a pill, not a hint.
    Component {
        id: undoPillWing
        Item {
            StripPill {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Undo"
                ring: true
                action: () => IslandController.wallpaperUndo()
            }
        }
    }

    // -- the window band (WindowBand.qml): the way back from what a gesture did - Reopen, Show or Undo
    Component {
        id: windowPillWing
        Item {
            StripPill {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: IslandController.payload?.pill ?? ""
                ring: true
                action: () => {
                    const p = IslandController.payload;
                    IslandController.dismiss();
                    if (p?.run)
                        p.run();        // an app that didn't open: Try again (AppScope)
                    else
                        WindowBand.act(p?.verb ?? "", p?.address ?? "");
                }
            }
        }
    }

    // -- Claude asks to run something: answered from the pill, like the wallpaper's Undo.
    // "Always allow" is not here; it lives in the sheet and the app, next to the full request.
    Component {
        id: claudeAnswerWing
        Item {
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                StripPill {
                    text: "Deny"
                    action: () => { Claude.answer(IslandController.payload?.claudeId ?? "", IslandController.payload?.request ?? "", false); IslandController.dismiss(); }
                }
                StripPill {
                    text: "Allow"
                    ring: true
                    action: () => { Claude.answer(IslandController.payload?.claudeId ?? "", IslandController.payload?.request ?? "", true); IslandController.dismiss(); }
                }
            }
        }
    }

    // -- updates downloaded: installed while the computer restarts, now or tonight (Updates.qml)
    Component {
        id: updateAnswerWing
        Item {
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                StripPill {
                    text: "Tonight"
                    action: () => { IslandController.dismiss(); Updates.tonight(); }
                }
                StripPill {
                    text: "Restart"
                    ring: true
                    action: () => Updates.restartNow()
                }
            }
        }
    }

    // -- updated: what changed, in Settings
    Component {
        id: updatedNotesWing
        Item {
            StripPill {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "What's new"
                action: () => { IslandController.dismiss(); Updates.openNotes(); }
            }
        }
    }

    // -- Flow (dictation): five bars that move with your voice, then the turning shape
    Component {
        id: flowLevelWing
        Item {
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3
                Repeater {
                    // the middle bars reach highest, so a word reads as a swell
                    model: [0.55, 0.8, 1.0, 0.8, 0.55]
                    delegate: Rectangle {
                        required property real modelData
                        width: 3
                        radius: 1.5
                        height: Math.max(4, 18 * Math.min(1, Dictation.level * 1.6) * modelData)
                        anchors.verticalCenter: parent.verticalCenter
                        color: Tacit.inkMain
                        Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }
    Component {
        id: flowWritingWing
        Item {
            MaterialLoadingIndicator {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                implicitSize: 22
                colBg: "transparent"
                colShape: IslandController.contentColor
                loading: true
            }
        }
    }

    // -- workspace
    Component {
        id: workspaceLabelWing
        Item {
            MaterialSymbol {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "grid_view"
                iconSize: 16
                color: IslandController.subtextColor
            }
        }
    }
    Component {
        id: workspaceNumeralWing
        Item {
            StripNum {
                id: numeral
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: IslandController.payload?.number ?? 0
                onTextChanged: entry.restart()
                Component.onCompleted: entry.restart()
                SpringAnimation {
                    id: entry
                    target: numeral
                    property: "scale"
                    from: 0.7
                    to: 1.0
                    spring: 6.0
                    damping: 0.28
                    mass: 0.9
                    epsilon: 0.01
                }
            }
        }
    }

    // -- live activity
    Component {
        id: activityNameWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: {
                    const name = IslandController.payload?.name ?? "";
                    const detail = IslandController.payload?.text ?? "";
                    return detail.length > 0 ? `${name} · ${detail}` : name;
                }
            }
        }
    }
    Component {
        id: activityBarWing
        Item {
            id: activityWing
            readonly property int percent: Math.max(0, Math.min(100, IslandController.payload?.percent ?? 0))
            // no percent to tell (an agent working): the sand dot, still (light means AI at work)
            readonly property bool spinning: (IslandController.payload?.percent ?? 0) < 0
            StripDot {
                visible: activityWing.spinning
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                sand: true
            }
            StripBar {
                visible: !activityWing.spinning
                anchors.left: parent.left
                anchors.right: numeral.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                value: activityWing.percent / 100
            }
            StripNum {
                id: numeral
                visible: !activityWing.spinning
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                horizontalAlignment: Text.AlignRight
                text: `${activityWing.percent}%`
            }
        }
    }

    // -- after a reload: the Tacit mark, spaced caps (the wordmark's form), letters arriving left to
    // right; "updated" in light lowercase on the other side of the clock.
    Component {
        id: reloadMarkWing
        Item {
            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                Repeater {
                    model: ["T", "A", "C", "I", "T"]
                    StyledText {
                        id: letter
                        required property string modelData
                        required property int index
                        text: letter.modelData
                        font.family: Appearance.font.family.title
                        font.variableAxes: Appearance.font.variableAxes.title
                        font.pixelSize: 15
                        color: IslandController.contentColor
                        opacity: 0
                        transform: Translate { id: rise; y: 3 }
                        SequentialAnimation {
                            running: true
                            PauseAnimation { duration: 120 + letter.index * 40 }
                            ParallelAnimation {
                                NumberAnimation { target: letter; property: "opacity"; to: 1; duration: Appearance.animation.elementMoveFast.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve }
                                NumberAnimation { target: rise; property: "y"; to: 0; duration: Appearance.animation.elementMoveFast.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animation.elementMoveFast.bezierCurve }
                            }
                        }
                    }
                }
            }
        }
    }
    Component {
        id: reloadWordWing
        Item {
            StripWords {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "updated"
                opacity: 0
                NumberAnimation on opacity {
                    to: 1
                    // after the last letter
                    duration: Appearance.animation.elementMoveFast.duration
                    running: false
                    id: wordIn
                }
                Timer { interval: 120 + 5 * 40; running: true; onTriggered: wordIn.start() }
            }
        }
    }

    // -- greeting
    Component {
        id: greetingWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: (IslandController.payload?.text ?? "").replace(/\.$/, "")
            }
        }
    }
    // A working session at rest: its thread or name left, what it is doing right.
    Component {
        id: sessionNameWing
        Item {
            StripDot {
                id: workDot
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                sand: true
            }
            StripWords {
                anchors.left: workDot.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: AgentSessions.activeLabel
            }
        }
    }
    // what it is doing; the other agents at work as a count after it ("+2"), one wing for all of them
    Component {
        id: sessionActivityWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: others.visible ? others.left : parent.right
                anchors.rightMargin: others.visible ? 8 : 0
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: AgentSessions.activeLine
            }
            StripNum {
                id: others
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: AgentSessions.workingCount > 1
                text: `+${AgentSessions.workingCount - 1}`
            }
        }
    }

    // The restart brief: sessions left, uncommitted repos right, text only.
    Component {
        id: briefLeftWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: IslandController.payload?.left ?? ""
            }
        }
    }
    Component {
        id: briefRightWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: IslandController.payload?.right ?? ""
            }
        }
    }
    Component {
        id: greetingDateWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Qt.formatDate(new Date(), "ddd d MMM")
            }
        }
    }

    // -- the browser's sign-in (IslandController's sign-in, states/IslandSignin.qml). The host is the shell's to draw,
    // where no page can: lock (or a warning, plain http) and the popup's host left; at the right the way back, "for"
    // and the opener's own favicon and host, which lifts into "back to" when pointed at and closes the sign-in.
    // the opener's favicon (a letter tile without one), or for an app's sign-in that app's icon (a glyph without one)
    component SiteIcon: Item {
        id: siteIcon
        property string source: ""
        property string host: ""
        property bool app: false
        // the icon theme's, else hicolor's own (the theme here does not reach it: foot's foot.svg); a name with neither
        // fails to load, and the glyph shows
        readonly property string appName: siteIcon.app && siteIcon.host !== "" ? AppSearch.guessIcon(siteIcon.host) : ""
        readonly property string appIcon: siteIcon.appName === "" ? ""
            : Quickshell.iconPath(siteIcon.appName, true) || `file:///usr/share/icons/hicolor/scalable/apps/${siteIcon.appName}.svg`
        implicitWidth: 18
        implicitHeight: 18
        MaterialSymbol {
            anchors.centerIn: parent
            visible: siteIcon.app && iconImage.status !== Image.Ready
            text: "window"
            iconSize: 16
            color: IslandController.subtextColor
        }
        Rectangle {
            anchors.fill: parent
            radius: 5
            visible: !siteIcon.app && iconImage.status !== Image.Ready
            color: Appearance.colors.colLayer2
            StyledText {
                anchors.centerIn: parent
                text: (siteIcon.host.replace(/^www\./, "")[0] ?? "").toUpperCase()
                font.pixelSize: 11
                font.weight: Font.Bold
                color: Appearance.colors.colOnLayer2
            }
        }
        Image {
            id: iconImage
            anchors.fill: parent
            source: siteIcon.app ? siteIcon.appIcon : siteIcon.source
            visible: status === Image.Ready
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            sourceSize.width: 36
            sourceSize.height: 36
            // a favicon is rounded into a tile; an app's icon has its own shape
            layer.enabled: !siteIcon.app
            layer.effect: OpacityMask {
                maskSource: Rectangle {
                    width: siteIcon.width
                    height: siteIcon.height
                    radius: 5
                }
            }
        }
    }
    Component {
        id: signinHostWing
        Item {
            readonly property bool secure: IslandController.signin.secure !== false
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                // dictation or the mic on: always here, first
                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: IslandController.micLive || Dictation.active
                    text: "mic"
                    iconSize: 16
                    color: Appearance.colors.colPrimary
                }
                MaterialSymbol {
                    id: lockGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.parent.secure ? "lock" : "warning"
                    iconSize: 14
                    color: parent.parent.secure ? IslandController.subtextColor : Appearance.colors.colError
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, parent.width - lockGlyph.width - 6 - (IslandController.micLive || Dictation.active ? 22 : 0))
                    text: IslandController.signin.host ?? ""
                    elide: Text.ElideLeft
                    font.pixelSize: 15
                    font.weight: Font.Medium
                    color: parent.parent.secure ? IslandController.contentColor : Appearance.colors.colError
                }
            }
        }
    }
    Component {
        id: signinForWing
        Item {
            WingText {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.rightMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: `sign in for ${IslandController.signin.opener ?? ""}`
                font.family: Appearance.font.family.main
                font.pixelSize: 14
                color: IslandController.subtextColor
            }
        }
    }
    Component {
        id: signinBackWing
        Item {
            id: backWing
            Row {
                anchors.right: parent.right
                anchors.rightMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                // an agent asking waits behind the sign-in: one click opens it
                Item {
                    id: agentPill
                    anchors.verticalCenter: parent.verticalCenter
                    visible: IslandController.signinAgents > 0
                    width: visible ? agentRow.implicitWidth + 16 : 0
                    height: 24
                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        color: agentArea.containsMouse ? ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9) : "transparent"
                    }
                    Row {
                        id: agentRow
                        anchors.centerIn: parent
                        spacing: 4
                        MaterialSymbol {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "back_hand"
                            iconSize: 14
                            color: Appearance.colors.colPrimary
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: `${IslandController.signinAgents} waiting`
                            font.pixelSize: 14
                            color: Appearance.colors.colPrimary
                        }
                    }
                    MouseArea {
                        id: agentArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: IslandController.signinAsideRequested("agent")
                    }
                }
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: backRow.implicitWidth + 16
                    height: 24
                    Rectangle {
                        anchors.fill: parent
                        radius: 12
                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, backArea.pressed ? 0.84 : 0.9)
                        opacity: backArea.containsMouse ? 1 : 0
                        Behavior on opacity {
                            Anim {
                                type: Anim.DefaultEffects
                            }
                        }
                    }
                    Row {
                        id: backRow
                        anchors.centerIn: parent
                        spacing: 6
                        MaterialSymbol {
                            id: backGlyph
                            anchors.verticalCenter: parent.verticalCenter
                            visible: backArea.containsMouse
                            text: "undo"
                            iconSize: 14
                            color: IslandController.contentColor
                        }
                        StyledText {
                            id: backWord
                            anchors.verticalCenter: parent.verticalCenter
                            text: backArea.containsMouse ? "back to" : "for"
                            font.pixelSize: 14
                            color: backArea.containsMouse ? IslandController.contentColor : IslandController.subtextColor
                        }
                        SiteIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            source: IslandController.signin.icon ?? ""
                            host: IslandController.signin.opener ?? ""
                            app: IslandController.signin.app === true
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            // what the wing has left after the pill's padding, its words, the icon and the agent's pill
                            width: Math.max(0, Math.min(implicitWidth, backWing.width - 2 - 16 - backWord.implicitWidth - 18 - 12
                                - (backGlyph.visible ? backGlyph.implicitWidth + 6 : 0) - (agentPill.visible ? agentPill.width + 6 : 0)))
                            text: IslandController.signin.opener ?? ""
                            elide: Text.ElideLeft
                            font.pixelSize: 14
                            font.weight: backArea.containsMouse ? Font.Medium : Font.Normal
                            color: backArea.containsMouse ? IslandController.contentColor : IslandController.subtextColor
                        }
                    }
                    MouseArea {
                        id: backArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: IslandController.signinBack()
                    }
                }
            }
        }
    }
    // waiting: lock and "Sign in" left, for whom right (or how many wait)
    Component {
        id: signinWaitLeftWing
        Item {
            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                MaterialSymbol {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "lock"
                    iconSize: 15
                    color: Appearance.colors.colPrimary
                }
                WingText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Sign in"
                }
            }
        }
    }
    Component {
        id: signinWaitRightWing
        Item {
            readonly property int count: IslandController.signin.count ?? 1
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                WingText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.parent.count > 1 ? `${parent.parent.count} sign-ins` : "for"
                    color: IslandController.subtextColor
                }
                SiteIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.count <= 1
                    source: IslandController.signin.icon ?? ""
                    host: IslandController.signin.opener ?? ""
                    app: IslandController.signin.app === true
                }
                WingText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: parent.parent.count <= 1
                    width: Math.min(implicitWidth, parent.parent.width - 52)
                    text: IslandController.signin.opener ?? ""
                    elide: Text.ElideLeft
                    color: IslandController.subtextColor
                }
            }
        }
    }
    // the breath out: signed in, and where the keys went back to
    Component {
        id: signedInLeftWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: IslandController.payload?.text ?? "Signed in"
            }
        }
    }
    Component {
        id: signedInRightWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: `back to ${IslandController.payload?.opener ?? ""}`
                elide: Text.ElideLeft
            }
        }
    }

    // -- notification (off by default; popups live top-right)
    Component {
        id: notificationTextWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                point: true
                text: IslandController.payload?.summary ?? ""
            }
        }
    }
    Component {
        id: notificationAppWing
        Item {
            StripWords {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: IslandController.payload?.appName ?? ""
            }
        }
    }
}
