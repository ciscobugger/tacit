//@ pragma UseQApplication
//@ pragma AppId activity
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

// Activity: what is slowing the computer down, what the battery is going to, what fills the disk -
// in a sentence and one plain list, biggest first. Its own process (`qs -p activity.qml`), like Settings and
// Viewer. Brief: ~/book4-edge/tacit-activity-brief.md; mock: tacit-activity-mocks act-a6.qml (v7).

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import qs.modules.activity

ApplicationWindow {
    id: root

    visible: true
    Binding { target: Quickshell; property: "watchFiles"; value: false }
    title: "Activity"
    readonly property Item openPage: [nowPage, appPage, agentsPage, allPage, stuckPage, tacitPage, batteryPage, sharesPage, diskPage, dirsPage]
                                     .find(p => p.visible) ?? null
    readonly property real contentHeight: (openPage ? openPage.y + openPage.height : 240) + 44
    // Opens at 840 x 680 (the window rule), then takes the open page's height: never under 600 (a short
    // list in a 320 px window was "too small"), never over most of the screen (past that it scrolls).
    // Hyprland sizes floating windows, so the app asks it once the page has settled.
    minimumWidth: 640
    minimumHeight: 480
    width: 840
    height: 680
    readonly property int wantHeight: Math.round(Math.max(600, Math.min(contentHeight, (screen?.height ?? 1080) * 0.88)))
    onWantHeightChanged: fitTimer.restart()
    // short: the window follows a page switch with it, not a beat after; scripts/activity/fit-window keeps
    // the top edge (and the tabs under the pointer) where it is
    Timer {
        id: fitTimer
        interval: 60
        onTriggered: {
            if (root.renderDir === "" && root.visible && Math.abs(root.height - root.wantHeight) > 8)
                Quickshell.execDetached(["python3", "-I", Quickshell.shellPath("scripts/activity/fit-window"), String(root.wantHeight)]);
        }
    }
    color: "transparent"
    onClosing: Qt.quit()

    // the window's ground is Praxis's: the terminal background, 15 % see-through
    FileView {
        id: termColors
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/generated/terminal/sequences.txt`)
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property color termBase: {
        const m = /\]11;(#[0-9a-fA-F]{6})/.exec(termColors.text() || "");
        return m ? m[1] : Appearance.m3colors.m3surfaceContainerLow;
    }
    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        root.show(Quickshell.env("ACTIVITY_PAGE") ?? "");
    }

    // not `data`: inside an Item that name is the Item's own children list
    Data {
        id: facts
        // the layout holds still while the pointer is on a row; it moves on once the pointer leaves
        frozen: Ink.pointerRow !== ""
        onStuck: key => {
            if (root.drill === null && root.tab === "Now")
                root.drill = { kind: "stuck", key: key };
        }
    }

    // where we are: a tab, and maybe a page opened from Now
    property string tab: "Now"
    property var drill: null
    onTabChanged: root.reveal()
    onDrillChanged: root.reveal()
    function back() {
        if (root.drill !== null)
            root.drill = null;
        else
            root.close();
    }
    function show(page) {
        const p = page ?? "";
        if (p === "battery") { root.drill = null; root.tab = "Battery"; }
        else if (p === "disk") { root.drill = null; root.tab = "Disk"; }
        else if (p.startsWith("stuck:")) {
            const [, pid, secs] = p.split(":");
            root.pendingStuck = { pid: parseInt(pid), secs: parseInt(secs || "0"), at: Date.now() };
            root.tab = "Now";
            root.tryStuck();
        } else { root.drill = null; root.tab = "Now"; }
    }
    // the notch's Details can arrive before the first sample
    property var pendingStuck: null
    function tryStuck() {
        const s = root.pendingStuck;
        if (!s || !facts.raw)
            return;
        root.pendingStuck = null;
        const key = facts.stuckFromPid(s.pid, s.secs + (Date.now() - s.at) / 1000);
        if (key !== "")
            root.drill = { kind: "stuck", key: key };
    }
    Connections {
        target: facts
        function onRawChanged() { root.tryStuck(); }
    }
    function opened(item) {
        // a fold opens the whole list it stands for
        if (item.fold)
            root.drill = { kind: item.key === "fold:dirs" ? "dirs" : item.key === "fold:battery" ? "shares" : "all" };
        else if (item.kind === "agents")
            root.drill = { kind: "agents", tool: item.tool };
        else if (item.kind === "tacit")
            root.drill = { kind: "tacit" };
        else if (item.kind === "app")
            root.drill = { kind: "app", key: item.key };
        else if (item.path)
            facts.act(item, "openFolder");
    }
    function act(item, what) {
        if (what === "open")
            root.opened(item);
        else if (what === "all")
            root.drill = { kind: "all" };
        else {
            facts.act(item, what);
            if (what === "quit" && root.drill?.kind === "app")
                root.drill = null;
        }
    }

    IpcHandler {
        target: "activity"
        function page(name: string): void { root.show(name); root.visible = true; root.raise(); root.requestActivate(); }
        function present(): void { root.visible = true; }
        function state(): string {
            return JSON.stringify({ tab: root.tab, drill: root.drill, mode: facts.now?.mode ?? "", frozen: facts.frozen,
                                    height: root.height, want: root.wantHeight });
        }
    }

    // a page switch comes in from the top, rising 6 px as it fades in (Settings' page switch)
    function reveal() {
        pageIn.stop();
        pages.opacity = 0;
        pages.y = 6;
        flick.contentY = 0;
        pageIn.restart();
    }
    ParallelAnimation {
        id: pageIn
        Anim { target: pages; property: "opacity"; to: 1; type: Anim.DefaultEffects }
        Anim { target: pages; property: "y"; to: 0; type: Anim.FastSpatial }
    }

    // ── the page frame. Every page is one column that flows top to bottom: a sentence that wraps pushes the
    // buttons down instead of running into them. The window is as tall as the open page (Window below).
    readonly property real side: 56
    component Gap: Item { width: 1; property real h: 0; height: h }
    component Headline: T {
        property bool alarm: false
        width: parent.width
        // one line: a long name shrinks the headline rather than cutting it
        fontSizeMode: Text.HorizontalFit
        minimumPixelSize: 24
        font.pixelSize: alarm ? 40 : 30
        font.weight: alarm ? Font.DemiBold : Font.Normal
        // a new state: the old words fade out and the new ones in, not a hard swap
        Behavior on text {
            SequentialAnimation {
                Anim { property: "opacity"; to: 0; type: Anim.FastEffects }
                PropertyAction {}
                Anim { property: "opacity"; to: 1; type: Anim.DefaultEffects }
            }
        }
    }
    // the sentence; its cause phrase in sand
    component Sentence: T {
        property string cause: ""
        property string rest: ""
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.RichText
        font.pixelSize: 17
        lineHeight: 1.15
        color: Ink.sec
        function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
        text: (cause !== "" ? `<span style="color:${Ink.sand}; font-weight:600">${esc(cause)}</span>` : "") + esc(rest)
    }
    component Verbs: Flow {
        property var list: []
        width: parent.width
        spacing: 12
        Repeater {
            model: parent.list
            Verb {
                required property var modelData
                text: modelData.text
                primary: modelData.primary ?? false
                later: modelData.later ?? false
                onClicked: modelData.go ? modelData.go() : root.act(modelData.item ?? {}, modelData.act)
            }
        }
    }
    // the head every page shares: headline, sentence, then the bar or the buttons
    component Head: Column {
        property string headline: ""
        property bool alarm: false
        property string cause: ""
        property string rest: ""
        property var gauge: null
        property var verbs: []
        width: parent.width
        Headline { text: parent.headline; alarm: parent.alarm }
        Gap { h: 10 }
        Sentence { visible: text !== ""; cause: parent.cause; rest: parent.rest }
        Gap { h: 22 }
        Gauge {
            visible: !!parent.gauge && parent.verbs.length === 0
            width: parent.width
            value: parent.gauge?.value ?? 0
            word: parent.gauge?.word ?? ""
            warn: parent.gauge?.warn ?? false
        }
        Verbs { visible: parent.verbs.length > 0; list: parent.verbs }
    }

    Item {
        id: shot
        anchors.fill: parent
        focus: true
        // the render harness only: a blurred wallpaper standing in for Hyprland's blur
        Image {
            visible: root.renderDir !== ""
            anchors.fill: parent
            source: visible ? `file://${facts.home}/.cache/tacit-activity-mocks/assets/bgblur.png` : ""
            fillMode: Image.PreserveAspectCrop
        }
        Rectangle {
            anchors.fill: parent
            color: ColorUtils.transparentize(root.termBase, Tacit.windowSeeThrough)
        }
        Keys.onEscapePressed: root.back()
        Shortcut { sequences: ["Ctrl+W", "Ctrl+Q"]; onActivated: root.close() }
        Keys.onLeftPressed: shot.step(false)
        Keys.onUpPressed: shot.step(false)
        Keys.onRightPressed: shot.step(true)
        Keys.onDownPressed: shot.step(true)
        function step(forward) {
            const from = root.activeFocusItem ?? shot;
            const next = from.nextItemInFocusChain(forward);
            if (next)
                next.forceActiveFocus(forward ? Qt.TabFocusReason : Qt.BacktabFocusReason);
        }

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: root.contentHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Item {
                id: pages
                width: flick.width
                height: root.contentHeight

                Tabs {
                    x: root.side
                    y: 28
                    at: root.tab
                    crumb: root.drill !== null ? root.tab : ""
                    onPicked: t => { root.drill = null; root.tab = t; }
                    onBack: root.drill = null
                }

                // ── Now
                Column {
                    id: nowPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.tab === "Now" && root.drill === null
                    readonly property var p: facts.now
                    Head {
                        visible: !!nowPage.p
                        headline: nowPage.p?.headline ?? ""
                        alarm: nowPage.p?.alarm ?? false
                        cause: nowPage.p?.cause ?? ""
                        rest: nowPage.p?.rest ?? ""
                        gauge: nowPage.p?.gauge ?? null
                        verbs: nowPage.p?.verbs ?? []
                    }
                    T {
                        visible: !nowPage.p
                        text: facts.readerFailed ? "Activity can't read the system right now." : "Looking…"
                        font.pixelSize: 30
                        color: Ink.sec
                    }
                    Gap { h: 26 }
                    // what the amounts are: memory, or each one's share of the processor (switchable when calm)
                    Item {
                        width: parent.width
                        height: unitSwitch.visible ? 30 : 0
                        Row {
                            id: unitSwitch
                            visible: nowPage.p?.canSwitch ?? false
                            anchors.right: parent.right
                            spacing: 20
                            Repeater {
                                model: [{ t: "Memory", cpu: false }, { t: "Processor", cpu: true }]
                                Item {
                                    id: unit
                                    required property var modelData
                                    readonly property bool on: facts.byProcessor === modelData.cpu
                                    width: ut.width
                                    height: 24
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: facts.byProcessor = modelData.cpu
                                    T {
                                        id: ut
                                        text: unit.modelData.t
                                        font.pixelSize: 14
                                        font.weight: unit.on ? Font.DemiBold : Font.Normal
                                        color: unit.on || ua.containsMouse || unit.activeFocus ? Ink.main : Ink.meta
                                    }
                                    Rectangle {
                                        visible: unit.on || unit.activeFocus
                                        y: 21
                                        width: ut.width
                                        height: 2
                                        radius: 1
                                        color: unit.on ? Ink.sand : Ink.sec
                                    }
                                    MouseArea {
                                        id: ua
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: facts.byProcessor = unit.modelData.cpu
                                    }
                                }
                            }
                        }
                    }
                    Band {
                        width: parent.width
                        items: nowPage.p?.apps ?? []
                        foldKey: "fold:apps"
                        foldOpens: true
                        foldHot: nowPage.p?.foldHot ?? false
                        foldWord: rest => facts.foldWord(rest, nowPage.p?.cpuView ?? false)
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24; visible: (nowPage.p?.agents ?? []).length > 0 }
                    Band {
                        visible: (nowPage.p?.agents ?? []).length > 0
                        width: parent.width
                        label: "Agents"
                        maxRows: 3
                        items: nowPage.p?.agents ?? []
                        foldKey: "fold:agents"
                        foldOpens: true
                        foldWord: rest => facts.foldWord(rest, nowPage.p?.cpuView ?? false)
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24; visible: (nowPage.p?.background ?? []).length > 0 }
                    Band {
                        visible: (nowPage.p?.background ?? []).length > 0
                        width: parent.width
                        label: "In the background"
                        wrap: true
                        items: nowPage.p?.background ?? []
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24 }
                    Band {
                        width: parent.width
                        items: nowPage.p?.tacit ?? []
                        onOpened: it => root.opened(it)
                    }
                }

                // ── an app opened
                Column {
                    id: appPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "app"
                    readonly property var p: visible ? facts.appPage(root.drill.key) : null
                    Head {
                        alarm: true
                        headline: appPage.p?.headline ?? "It has closed."
                        rest: appPage.p?.rest ?? ""
                        verbs: !appPage.p ? [] : (appPage.p.item.windows.length > 0 ? [{ text: `Show ${appPage.p.item.n}`, act: "focus", item: appPage.p.item }] : [])
                               .concat([{ text: `Quit ${appPage.p.item.n}`, act: "quit", item: appPage.p.item }])
                    }
                    Gap { h: 26 }
                    Band {
                        visible: (appPage.p?.windows ?? []).length > 0
                        width: parent.width
                        label: "Windows"
                        wrap: true
                        items: appPage.p?.windows ?? []
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24; visible: (appPage.p?.windows ?? []).length > 0 && (appPage.p?.parts ?? []).length > 0 }
                    Band {
                        visible: (appPage.p?.parts ?? []).length > 0
                        width: parent.width
                        label: "What it holds"
                        wrap: true
                        items: appPage.p?.parts ?? []
                    }
                }

                // ── agents opened
                Column {
                    id: agentsPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "agents"
                    readonly property var p: visible ? facts.agentsPage(root.drill.tool) : null
                    Head {
                        alarm: (agentsPage.p?.cause ?? "") !== ""
                        headline: agentsPage.p?.headline ?? "No sessions are running."
                        cause: agentsPage.p?.cause ?? ""
                        rest: agentsPage.p?.rest ?? ""
                    }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        wrap: true
                        items: agentsPage.p?.sessions ?? []
                        onAct: (it, what) => root.act(it, what)
                    }
                }

                // ── everything (the fold opened)
                Column {
                    id: allPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "all"
                    readonly property var p: facts.now
                    Head {
                        headline: `${allPage.p?.appsTotal ?? 0} apps are open.`
                        rest: `They hold ${facts.gb((allPage.p?.apps ?? []).reduce((n, i) => n + i.mem, 0))} together.`
                        verbs: (allPage.p?.windowless ?? 0) > 0
                               ? [{ text: `Quit the ${allPage.p?.windowless ?? 0} apps with no window`, primary: true, act: "quitWindowless", item: {} }] : []
                    }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        wrap: true
                        items: allPage.p?.apps ?? []
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24; visible: (allPage.p?.agents ?? []).length > 0 }
                    Band {
                        visible: (allPage.p?.agents ?? []).length > 0
                        width: parent.width
                        label: "Agents"
                        wrap: true
                        items: allPage.p?.agents ?? []
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                }

                // ── not answering
                Column {
                    id: stuckPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "stuck"
                    readonly property var p: visible ? facts.stuckPage() : null
                    Head {
                        alarm: true
                        headline: stuckPage.p?.headline ?? "It has closed."
                        rest: stuckPage.p?.rest ?? ""
                        verbs: !stuckPage.p ? [] : [{ text: "Wait", primary: true, go: () => { facts.waitMore(); root.drill = null; } },
                                                    { text: "Close it now", later: !(stuckPage.p?.canClose ?? false),
                                                      go: () => { facts.forceQuit(stuckPage.p.key); root.drill = null; } }]
                    }
                    Gap { h: 26 }
                    Band {
                        visible: (stuckPage.p?.parts ?? []).length > 0
                        width: parent.width
                        label: "Still holding"
                        wrap: true
                        items: stuckPage.p?.parts ?? []
                    }
                }

                // ── Tacit itself opened
                Column {
                    id: tacitPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "tacit"
                    readonly property var p: visible ? facts.tacitPage() : null
                    Head { headline: tacitPage.p?.headline ?? ""; rest: tacitPage.p?.rest ?? "" }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        wrap: true
                        items: tacitPage.p?.parts ?? []
                    }
                }

                // ── battery
                Column {
                    id: batteryPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.tab === "Battery" && root.drill === null
                    readonly property var p: visible ? facts.batteryPage() : null
                    Head {
                        headline: batteryPage.p?.headline ?? "No battery."
                        rest: batteryPage.p?.rest ?? ""
                        gauge: batteryPage.p ? { value: batteryPage.p.pct / 100, word: "", warn: batteryPage.p.pct <= 15 } : null
                    }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        items: batteryPage.p?.top ?? []
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24 }
                    Band {
                        visible: (batteryPage.p?.apps ?? []).length > 0
                        width: parent.width
                        label: "Apps"
                        items: batteryPage.p?.apps ?? []
                        foldKey: "fold:battery"
                        foldOpens: true
                        foldWord: rest => facts.pct(rest.reduce((n, i) => n + (i.f ?? 0), 0))
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                }

                // ── every app's share of the battery (the Battery fold opened)
                Column {
                    id: sharesPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "shares"
                    readonly property var p: visible ? facts.batteryPage() : null
                    Head { headline: "Every app's share."; rest: "Of what the battery is going to now, from the processor time each one used." }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        wrap: true
                        items: sharesPage.p?.apps ?? []
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                }

                // ── disk
                Column {
                    id: diskPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.tab === "Disk" && root.drill === null
                    readonly property var p: visible ? facts.diskPage() : null
                    Head {
                        headline: diskPage.p?.headline ?? "Measuring the disk…"
                        rest: diskPage.p?.rest ?? ""
                        gauge: diskPage.p?.gauge ?? null
                    }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        items: diskPage.p?.folders ?? []
                        foldKey: "fold:dirs"
                        foldOpens: true
                        foldWord: rest => facts.diskGb(rest.reduce((n, i) => n + (i.size ?? 0), 0))
                        onOpened: it => root.opened(it)
                        onAct: (it, what) => root.act(it, what)
                    }
                    Gap { h: 24; visible: (diskPage.p?.can ?? []).length > 0 }
                    Band {
                        visible: (diskPage.p?.can ?? []).length > 0
                        width: parent.width
                        label: "Can go"
                        items: diskPage.p?.can ?? []
                        onAct: (it, what) => root.act(it, what)
                    }
                }

                // ── every folder (the Disk fold opened)
                Column {
                    id: dirsPage
                    x: root.side
                    y: 84
                    width: parent.width - 2 * root.side
                    visible: root.drill?.kind === "dirs"
                    readonly property var p: visible ? facts.diskPage() : null
                    readonly property int mine: (dirsPage.p?.folders ?? []).filter(f => f.mine).length
                    Head { headline: "Every folder, by size."; rest: `${dirsPage.mine} of your own, then what Tacit, the apps and their data take. A folder opens in Files.` }
                    Gap { h: 26 }
                    Band {
                        width: parent.width
                        wrap: true
                        items: dirsPage.p?.folders ?? []
                        onOpened: it => root.opened(it)
                    }
                }
            }
        }
    }

    // ── render harness: ACTIVITY_RENDER=<dir> with ACTIVITY_FIXTURE=<json>: each state drawn and saved
    readonly property string renderDir: Quickshell.env("ACTIVITY_RENDER") ?? ""
    FileView {
        id: fixture
        path: facts.fixture
        blockLoading: true
        printErrors: false
    }
    property var states: []
    property int si: 0
    Timer {
        id: renderStep
        interval: 900
        running: root.renderDir !== ""
        onTriggered: {
            if (root.states.length === 0) {
                root.states = JSON.parse(fixture.text());
                root.si = 0;
                root.load(root.states[0]);
                renderStep.restart();
                return;
            }
            shot.grabToImage(g => {
                g.saveToFile(`${root.renderDir}/activity-${root.states[root.si].name}.png`);
                root.si++;
                if (root.si >= root.states.length)
                    Qt.quit();
                else {
                    root.load(root.states[root.si]);
                    renderStep.restart();
                }
            });
        }
    }
    function load(st) {
        facts.quit = null;
        facts.memAlarm = false;
        facts.letFinish = ({});
        facts.snap = null;
        facts.raw = null;
        facts.watts = 0;
        facts.cpuShare = ({});
        if (st.disk)
            facts.disk = st.disk;
        facts.feed(st.lines.map(l => JSON.stringify(l)));
        if (st.quit) {
            const q = Object.assign({}, st.quit);
            q.at = Date.now() - (q.ago ?? 0) * 1000;
            facts.quit = q;
        }
        root.tab = st.tab ?? "Now";
        root.drill = st.drill ?? null;
        Ink.previewHover = st.hover ?? "";
        facts.byProcessor = st.byProcessor ?? false;
    }
}
