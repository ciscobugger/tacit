//@ pragma UseQApplication
//@ pragma AppId store
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

// Apps: find an app by what you want to do, get it, open it, remove it. Its own process (`qs -p store.qml`), like
// Activity and Viewer. Third pass, on Apple's design principles (~/book4-edge/tacit-store-apple-principles.md), not its
// layout: content first with the controls floating over it; concentric shapes and capsules; one app lockup everywhere;
// hierarchy by weight; spring motion that can be interrupted; editorial cards that lead with what you can do; an app
// page with the essentials first. Kept from Tacit: inks measured on this window's ground, tonal surfaces, sentence-case
// labels, the installer's soft-well search, the accent only for the way forward.
// Data: scripts/store/stored.py (Arch's signed app catalogue; the store's words in assets/store/editorial.json). Apps are
// got as Tacit bundles (scripts/store/bundle.py: own folder, sandboxed, no password); pacman only for apps that need
// parts of the system. Not here yet: closed apps, asking for permissions, the notch.
// Discover is an issue (owner's pick, 2026-10-16, mock ~/dev/tacit-site/mocks/store-editorial): one spread a window tall per
// pick, each its own composition (cover, split, words, object, cinema), the window lit by the spread in front, the header
// floating over it with a big frosted search whose glass thickens over bright pictures.

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Shapes
import Qt5Compat.GraphicalEffects as GE
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.tacit
import qs.services

ApplicationWindow {
    id: root

    visible: true
    title: "Apps"
    width: 1528
    height: 928
    minimumWidth: 1120
    minimumHeight: 760
    color: "transparent"
    onClosing: Qt.quit()
    Binding { target: Quickshell; property: "watchFiles"; value: false }

    readonly property int m: gutter      // every page's margin is the header's
    readonly property int cw: width - 2 * m
    readonly property string backend: Quickshell.shellPath("scripts/store/stored.py")
    readonly property string renderDir: Quickshell.env("STORE_RENDER") ?? ""

    // ---- where the window is: discover | job | search | app | yours
    property string page: "discover"
    property var history: []
    property var home: null
    property var job: null
    property var found: null
    property var appInfo: null
    property var jobHero: ({})
    property var jobTone: ({})
    property var heroWork: ({})          // true when the picture is the work alone (cropped by the store), shown across
    property var heroAspect: ({})
    property var heroWant: []
    function wantHeroes(pkgs) {
        const need = pkgs.filter(p => jobHero[p] === undefined && !heroWant.includes(p) && heroProc.pkg !== p);
        heroWant = heroWant.concat(need); nextHero();
    }
    function nextHero() {
        if (heroProc.running || heroWant.length === 0) return;
        heroProc.pkg = heroWant[0]; heroWant = heroWant.slice(1); heroProc.running = true;
    }
    property string query: ""
    property var work: null               // { pkg, kind: "install"|"remove", progress, phase }
    property var outcome: ({})
    property string justGot: ""
    property var askUpdate: null          // { pkg, name, updates, updatesMB, appMB }: an app that needs the waiting updates with it
    readonly property var issue: (home?.issue ?? []).filter(sp => !sp.pkg || appOf(sp.pkg)?.available !== false)
    readonly property real gutter: width >= 1400 ? 96 : 64
    readonly property real k: Math.min(1, width / 1528, height / 928)        // type and pictures scale down with the window
    readonly property int spreadAt: Math.max(0, Math.min(issue.length - 1, Math.round(issueView.contentY / Math.max(1, height))))
    // the pointer across the window (0..1), followed softly: pictures and words drift apart a little, light follows it
    property real ptrX: 0.5
    property real ptrY: 0.4
    property real sunX: ptrX
    property real sunY: ptrY
    Behavior on sunX { SpringAnimation { spring: 2.4; damping: 0.9; epsilon: 0.0005 } }
    Behavior on sunY { SpringAnimation { spring: 2.4; damping: 0.9; epsilon: 0.0005 } }
    readonly property bool asking: field.activeFocus && field.text === ""
    // where a spread's picture lies, top and bottom, as fractions of the window's height (the header reads this too)
    function picBand(layout) {
        return layout === "cover" ? [0, 0.646] : layout === "split" ? [0.12, 1 - 72 / 928] : layout === "object" ? [0.125, 0.6]
             : layout === "cinema" ? [0.211, 0.814] : [0, 0];
    }

    onPageChanged: reveal()
    function go(p) { history = history.concat([{ page: page, job: job, appInfo: appInfo, found: found }]); if (p === page) reveal(); else page = p; }
    function back() {
        if (history.length === 0) { page = "discover"; return; }
        const h = history[history.length - 1];
        history = history.slice(0, -1);
        job = h.job; appInfo = h.appInfo; found = h.found; page = h.page;
    }
    function openApp(pkg) {
        const known = appOf(pkg) ?? (found?.apps ?? []).find(x => x.pkg === pkg) ?? null;
        appInfo = known ? Object.assign({ shots: [], description: [], whatsNew: [], loading: true }, known) : null;
        go("app");
        appProc.pkg = pkg; appProc.running = true;
    }
    function openJob(j) { job = j; go("job"); wantHeroes(j.pkgs); }
    function launch(a) {
        const id = (a?.desktop || "").replace(/\.desktop$/, "");
        const entry = id ? DesktopEntries.byId(id) : null;
        if (entry) entry.execute(); else if (id) Quickshell.execDetached(["gtk-launch", id]);
    }
    function get(pkg) {
        if (work) return;
        // known already (its page has its plan): ask about the updates at once, nothing is started yet
        if (appInfo?.pkg === pkg && appInfo?.plan?.why === "update" && appInfo.plan.updates !== undefined) {
            askUpdate = Object.assign({ pkg: pkg, name: appInfo.name }, appInfo.plan); return;
        }
        work = { pkg: pkg, kind: "install", progress: 0, phase: "Starting" };
        const o = Object.assign({}, outcome); delete o[pkg]; outcome = o;
        workProc.command = ["python3", "-I", backend, "install", pkg]; workProc.running = true;
    }
    // the system brought up to date and the app got in one step (pacman -Syu <app>): one password, never a partial update
    function getEverything(pkg) {
        if (work) return;
        work = { pkg: pkg, kind: "install", progress: 0, phase: "Starting", everything: true };
        const o = Object.assign({}, outcome); delete o[pkg]; outcome = o;
        workProc.command = ["python3", "-I", backend, "install", pkg, "--everything"]; workProc.running = true;
    }
    function removeApp(pkg) {
        if (work) return;
        work = { pkg: pkg, kind: "remove", progress: 0.5, phase: "Removing" };
        workProc.command = ["python3", "-I", backend, "remove", pkg]; workProc.running = true;
    }
    function act(a) { const st = stateOf(a); if (st === "installed") launch(a); else if (st === "get") get(a.pkg); }
    function refresh() { homeProc.running = true; if (page === "app" && appInfo) { appProc.pkg = appInfo.pkg; appProc.running = true; } }
    function runSearch(q) {
        query = q;
        const s = q.trim().toLowerCase();
        if (s.length < 2) return;
        const j = (home?.jobs ?? []).find(j => j.name.toLowerCase() === s || j.words.some(w => w === s || (s.length > 3 && w.startsWith(s))));
        found = { query: s, apps: [], job: j ?? null, done: false };
        if (j) wantHeroes(j.pkgs);
        if (page !== "search") go("search");
        if (!searchProc.running) searchProc.running = true;
        searchProc.write(JSON.stringify({ op: "search", q: s }) + "\n");
    }
    function appOf(pkg) { return home?.apps?.[pkg] ?? null; }
    function jobOf(pkg) { return (home?.jobs ?? []).find(j => j.pkgs.includes(pkg)) ?? null; }
    function stateOf(a) {
        if (!a) return "none";
        if (work && work.pkg === a.pkg) return work.kind === "install" ? "getting" : "removing";
        if (a.installed) return "installed";
        if (!a.available) return "unavailable";
        return "get";
    }
    function costWords(a) {
        if (!a) return "";
        if (a.installed) return "On this computer";
        return [a.free === false ? "Free to use" : "Free", a.download ? `${a.download} MB` : ""].filter(x => x).join(" · ");
    }
    readonly property var outcomeWords: ({
        "cancelled": ["Not installed", "The password was not given, so nothing changed."],
        "busy": ["Another update is running", "Try again when it has finished."],
        "offline": ["No internet connection", "Connect to the internet, then try again."],
        "space": ["Not enough space", "Free up some space, then try again."],
        "update": ["Needs a system update first", "This computer's list of apps is out of date, so this version is no longer on the server. Update everything, and it is got in the same step."],
        "failed": ["Couldn't install it", "Nothing was changed. Try again, or look again later."],
        "needed": ["Other apps use it", "It can't be removed while they need it."],
        "unavailable": ["Not made for this computer", "There is no version of it for this computer's processor."]
    })

    // ---- the backend
    Process { id: homeProc; running: true; command: ["python3", "-I", root.backend, "home"]
        stdout: StdioCollector { onStreamFinished: { try { root.home = JSON.parse(text); } catch (e) { console.warn("store: home", e); } } } }
    Process { id: appProc; property string pkg: ""; command: ["python3", "-I", root.backend, "app", pkg]
        stdout: StdioCollector { onStreamFinished: { try { const j = JSON.parse(text); if (root.appInfo && j.pkg === root.appInfo.pkg) root.appInfo = j; } catch (e) { console.warn("store: app", e); } } } }
    Process { id: heroProc; property string pkg: ""; command: ["python3", "-I", root.backend, "app", pkg]
        stdout: StdioCollector { onStreamFinished: { try {
            const a = JSON.parse(text);
            const h = Object.assign({}, root.jobHero); h[a.pkg] = a.hero || (a.shots?.[0]?.path ?? ""); root.jobHero = h;
            const t = Object.assign({}, root.jobTone); t[a.pkg] = a.tone ?? ""; root.jobTone = t;
            const w = Object.assign({}, root.heroWork); w[a.pkg] = !!a.heroWork; root.heroWork = w;
            const r = Object.assign({}, root.heroAspect); r[a.pkg] = a.heroAspect ?? 1.6; root.heroAspect = r;
        } catch (e) {} } }
        onExited: root.nextHero() }
    // one search backend for as long as the window lives: answers come from memory, icons follow in a second answer
    Process { id: searchProc; running: true; command: ["python3", "-I", root.backend, "serve"]; stdinEnabled: true
        stdout: SplitParser { onRead: line => { try {
            const r = JSON.parse(line);
            if (root.found && r.query === root.found.query) root.found = Object.assign({}, root.found, { apps: r.apps, done: true });
        } catch (e) {} } } }
    Process { id: workProc
        stdout: SplitParser { onRead: line => {
            let msg = null; try { msg = JSON.parse(line); } catch (e) { return; }
            if (msg.progress !== undefined && root.work) root.work = Object.assign({}, root.work, { progress: msg.progress, phase: msg.phase });
            if (msg.result !== undefined && root.work) {
                if (msg.result === "update" && msg.plan) {
                    // nothing went wrong: the app needs the waiting updates with it, so ask, here, where Get was pressed
                    root.askUpdate = Object.assign({ pkg: root.work.pkg, name: root.appOf(root.work.pkg)?.name ?? root.appInfo?.name ?? "" }, msg.plan);
                } else {
                    const o = Object.assign({}, root.outcome); o[root.work.pkg] = msg.result; root.outcome = o;
                    if (msg.result !== "ok" && root.work.kind === "install" && !(root.page === "app" && root.appInfo?.pkg === root.work.pkg)) root.openApp(root.work.pkg);
                }
                if (msg.result === "ok" && root.work.kind === "install") { root.justGot = root.work.pkg; tickTimer.restart(); }
            }
        } }
        onExited: { root.work = null; root.refresh(); } }
    Timer { id: tickTimer; interval: 2600; onTriggered: root.justGot = "" }

    // ---- colour: the ground, the inks measured on it (APCA, as Appearance.inkFor), the raised tones, the page's own colour
    // the front page as it was last time, drawn at once; the backend's fresh one replaces it a moment later
    FileView { id: homeKept; path: `${Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache"}/tacit-store/home.json`; blockLoading: true; printErrors: false }
    FileView { id: termColors; path: FileUtils.trimFileProtocol(`${Directories.state}/user/generated/terminal/sequences.txt`); blockLoading: true; printErrors: false }
    readonly property color ground: { const mm = /\]11;(#[0-9a-fA-F]{6})/.exec(termColors.text() || ""); return mm ? mm[1] : Appearance.m3colors.m3surfaceContainerLow; }
    function inkAt(lc) {
        const g = root.ground, ink = Appearance.m3colors.m3onBackground;
        const far = g.hslLightness < 0.5 ? "#ffffff" : "#000000";
        const at = t => t <= 1 ? ColorUtils.mix(ink, g, t) : ColorUtils.mix(far, ink, t - 1);
        let lo = 0, hi = 2;
        for (let i = 0; i < 18; i++) { const mid = (lo + hi) / 2; if (Math.abs(ColorUtils.apcaLc(at(mid), g)) < lc) lo = mid; else hi = mid; }
        return at(hi);
    }
    readonly property color inkMain: inkAt(92)
    readonly property color inkSec: inkAt(78)
    readonly property color raised: ColorUtils.mix(inkMain, ground, 0.07)
    readonly property color raisedHot: ColorUtils.mix(inkMain, ground, 0.12)
    readonly property color card: ColorUtils.mix(inkMain, ground, 0.045)
    readonly property string toneHex: ""   // every page is lit by its own picture instead (the glow under the content)
    property color tint: toneHex ? toneHex : ground
    Behavior on tint { ColorAnimation { duration: 480; easing.type: Easing.OutCubic } }

    Rectangle { id: canvas; anchors.fill: parent; color: ColorUtils.transparentize(root.ground, Tacit.windowSeeThrough) }
    Rectangle {   // the page's colour, from its picture: a wash from the top
        parent: canvas; z: -1; width: parent.width; height: parent.height * 0.8
        gradient: Gradient {
            GradientStop { position: 0; color: ColorUtils.transparentize(root.tint, root.toneHex ? 0.78 : 1) }
            GradientStop { position: 1; color: ColorUtils.transparentize(root.tint, 1) } }
    }
    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        if (!root.home) { try { const kept = JSON.parse(homeKept.text()); if (kept && kept.apps) root.home = kept; } catch (e) {} }
    }

    // ---- type: hierarchy by weight and size; large type tighter, small type a touch looser
    component Body: StyledText { color: root.inkMain; font.pixelSize: 17 }
    component Small: StyledText { color: root.inkSec; font.pixelSize: 15; font.letterSpacing: 0.15 }
    component Caption: Small { font.weight: Font.Medium }
    component Name: Body { font.weight: Font.DemiBold; font.letterSpacing: -0.1 }
    component Section: Body { font.pixelSize: 24; font.weight: Font.DemiBold; font.letterSpacing: -0.35 }
    component PageTitle: Body { font.pixelSize: 40; font.weight: Font.DemiBold; font.letterSpacing: -0.8 }
    component Headline: Body { font.pixelSize: 48; font.weight: Font.DemiBold; font.letterSpacing: -1.1; color: "white" }

    // ---- motion: springs, so a press, a lift and a growing capsule start from where they are and can turn back
    component Spring: SpringAnimation { spring: 5.5; damping: 0.42; mass: 1; epsilon: 0.004 }

    // ---- touch: anything that can be pressed takes a raised tone under the pointer and sinks a little when pressed
    component Press: Item {
        id: press
        signal picked()
        property int inset: 12
        property real rounding: 18
        property bool lit: true
        property bool lifts: false
        readonly property bool hovered: pressArea.containsMouse
        readonly property bool down: pressArea.pressed
        scale: down ? 0.975 : 1
        Behavior on scale { Spring {} }
        transform: Translate { y: press.lifts && press.hovered && !press.down ? -3 : 0; Behavior on y { Spring {} } }
        Rectangle {
            x: -press.inset; y: -press.inset; width: press.width + 2 * press.inset; height: press.height + 2 * press.inset; radius: press.rounding
            color: !press.lit ? "transparent" : press.down ? root.raisedHot : press.hovered ? root.raised : ColorUtils.transparentize(root.raised, 1)
            Behavior on color { ColorAnimation { duration: 160; easing.type: Easing.OutCubic } }
        }
        MouseArea { id: pressArea; x: -press.inset; y: -press.inset; width: press.width + 2 * press.inset; height: press.height + 2 * press.inset
            hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: press.picked() }
    }
    component Word: Item {
        id: wd
        property string text; property string glyph: ""; property color ink: root.inkSec
        signal picked()
        implicitWidth: wr.implicitWidth; implicitHeight: 28
        scale: wa.pressed ? 0.94 : 1
        Behavior on scale { Spring {} }
        Row { id: wr; anchors.verticalCenter: parent.verticalCenter; spacing: 8
            MaterialSymbol { visible: wd.glyph !== ""; text: wd.glyph; iconSize: 18; anchors.verticalCenter: parent.verticalCenter
                color: wa.containsMouse ? root.inkMain : wd.ink; Behavior on color { ColorAnimation { duration: 120 } } }
            Body { text: wd.text; anchors.verticalCenter: parent.verticalCenter; font.weight: Font.Medium
                color: wa.containsMouse && wd.ink === root.inkSec ? root.inkMain : wd.ink; Behavior on color { ColorAnimation { duration: 120 } } } }
        MouseArea { id: wa; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: wd.picked() }
    }
    // the one action of an app, as a capsule: Get in the accent, Open in the main ink; while getting it, it fills
    component Capsule: Item {
        id: cap
        property var a
        property bool large: false
        property bool onPicture: false
        property bool solid: false            // on the issue: Get in sand, the way forward
        readonly property string st: root.stateOf(a)
        readonly property bool got: root.justGot !== "" && root.justGot === a?.pkg
        readonly property real prog: st === "getting" ? Math.max(0, Math.min(1, root.work?.progress ?? 0)) : 0
        // the sand moves on smoothly between the steps the installer reports, never backwards
        property real fill: prog
        Behavior on fill { SmoothedAnimation { velocity: 0.35 } }
        readonly property string word: st === "getting" ? (prog < 0.04 ? "Waiting" : `${Math.round(prog * 100)} %`) : st === "removing" ? "Removing"
                                        : st === "installed" ? "Open" : st === "unavailable" ? "Not here" : "Get"
        visible: st !== "none"
        height: solid ? (large ? 48 : 40) : large ? 44 : 32
        // one width through the whole install, so nothing jumps while the numbers change
        width: Math.max(solid ? (large ? 128 : 84) : large ? 120 : 76, st === "getting" ? 0 : ct.implicitWidth + (got ? 30 : 0) + (large ? 52 : 36),
                        st === "getting" ? (large ? 132 : 96) : 0)
        Behavior on width { Spring {} }
        scale: ca.pressed ? 0.94 : 1
        Behavior on scale { Spring {} }
        Rectangle { anchors.fill: parent; radius: height / 2
            color: cap.solid && cap.st === "get" ? (ca.containsMouse ? ColorUtils.mix("#ffffff", Tacit.accent, 0.14) : Tacit.accent)
                 : cap.solid ? Qt.rgba(1, 1, 1, ca.containsMouse ? 0.17 : 0.12)
                 : cap.onPicture ? Qt.rgba(1, 1, 1, ca.pressed ? 0.34 : ca.containsMouse ? 0.28 : 0.2) : ca.pressed ? root.raisedHot : ca.containsMouse ? ColorUtils.mix(root.inkMain, root.ground, 0.1) : root.raised
            Behavior on color { ColorAnimation { duration: 140 } } }
        Rectangle {    // the track, a quiet sand
            visible: cap.st === "getting"; anchors.fill: parent; radius: height / 2; color: ColorUtils.mix(Tacit.accent, "#14100f", 0.2)
        }
        Rectangle {    // the sand, filling
            id: capFill
            z: 1; visible: cap.st === "getting"; height: parent.height; radius: height / 2; clip: true
            width: Math.max(height, parent.width * cap.fill); color: Tacit.accent
            Rectangle {    // light at its leading edge
                anchors.right: parent.right; width: Math.min(parent.width, 28); height: parent.height
                gradient: Gradient { orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) } GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0.18) } }
            }
            Body {    // the same words, dark where the sand is under them
                x: cap.width / 2 - width / 2; anchors.verticalCenter: parent.verticalCenter
                text: cap.word; font.pixelSize: cap.large ? 17 : 15; font.weight: Font.DemiBold; font.letterSpacing: 0.2; color: Tacit.inkOnAccent
            }
        }
        Row { anchors.centerIn: parent; spacing: 6
            MaterialSymbol { visible: cap.got; text: "check"; iconSize: cap.large ? 20 : 17; color: cap.onPicture ? "white" : Tacit.accent; anchors.verticalCenter: parent.verticalCenter }
            Body { id: ct; anchors.verticalCenter: parent.verticalCenter; text: cap.word; font.pixelSize: cap.large ? 17 : 15; font.weight: Font.DemiBold; font.letterSpacing: 0.2
                color: cap.st === "getting" ? Tacit.accent : cap.solid && cap.st === "get" ? Tacit.inkOnAccent : cap.onPicture ? "white" : cap.st === "get" ? Tacit.accent : cap.st === "unavailable" ? root.inkSec : root.inkMain } }
        MouseArea { id: ca; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; enabled: cap.st === "get" || cap.st === "installed"
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: root.act(cap.a) }
    }
    component AppIcon: Image {
        property string src
        source: src ? "file://" + src : ""
        sourceSize: Qt.size(256, 256); smooth: true; mipmap: true
    }
    // ---- the issue's pieces
    // a picture as a lit surface: a faint highlight on its top edge, a sheen that follows the pointer across it, and the
    // pointer's sun along its lower edge (the landing page's light)
    component EdgePic: Item {
        id: ep
        property string src
        property real r: 20
        property real lx: 0.5          // the light's place on it, 0..1
        property real ly: 0.3
        property bool edgeLight: true
        property string pkg: ""               // the app it shows: while it is being got, its lower edge carries the progress
        readonly property real progress: !pkg ? -1 : root.work?.pkg === pkg && root.work?.kind === "install" ? Math.max(0.02, root.work.progress ?? 0)
                                         : root.justGot === pkg ? 1 : -1
        property real shownProgress: Math.max(0, progress)
        Behavior on shownProgress { SmoothedAnimation { velocity: 0.35 } }
        EdgeProgress { ep: ep; anchors.fill: parent; z: 3 }
        ClippingRectangle {
            anchors.fill: parent; radius: ep.r; color: root.card
            Image {
                anchors.fill: parent; source: ep.src ? "file://" + ep.src : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; smooth: true
                sourceSize: Qt.size(Math.ceil(ep.width * Screen.devicePixelRatio), Math.ceil(ep.height * Screen.devicePixelRatio))
                opacity: status === Image.Ready ? 1 : 0; Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            }
            Shape {
                anchors.fill: parent
                ShapePath {
                    strokeWidth: -1; strokeColor: "transparent"
                    fillGradient: RadialGradient {
                        centerX: ep.width * ep.lx; centerY: ep.height * ep.ly; focalX: centerX; focalY: centerY
                        centerRadius: Math.max(ep.width, ep.height) * 0.42
                        GradientStop { position: 0; color: Qt.rgba(1, 0.93, 0.86, 0.10) }
                        GradientStop { position: 1; color: Qt.rgba(1, 0.93, 0.86, 0) }
                    }
                    startX: 0; startY: 0
                    PathLine { x: ep.width; y: 0 }
                    PathLine { x: ep.width; y: ep.height }
                    PathLine { x: 0; y: ep.height }
                    PathLine { x: 0; y: 0 }
                }
            }
            Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }
            Rectangle {
                visible: ep.edgeLight && ep.progress < 0
                anchors.bottom: parent.bottom; width: parent.width; height: 2
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: Math.max(0, Math.min(0.98, ep.lx - 0.3)); color: Qt.rgba(1, 0.886, 0.784, 0) }
                    GradientStop { position: Math.max(0.01, Math.min(0.99, ep.lx)); color: Qt.rgba(1, 0.886, 0.784, 0.7) }
                    GradientStop { position: Math.max(0.02, Math.min(1, ep.lx + 0.3)); color: Qt.rgba(1, 0.886, 0.784, 0) }
                }
            }
        }
    }
    // an app being got: the light along its picture's lower edge becomes the progress, sand running across with a glow
    // rising off it, held full a moment when it is done
    component EdgeProgress: Item {
        id: epr
        property Item ep
        readonly property real inset: ep ? ep.r * 0.55 : 0      // clear of the rounded corners
        opacity: ep && ep.progress >= 0 ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
        Rectangle {    // the glow rising off the edge
            x: epr.inset; anchors.bottom: parent.bottom; height: 64; width: (parent.width - 2 * epr.inset) * (epr.ep?.shownProgress ?? 0)
            gradient: Gradient { GradientStop { position: 0; color: ColorUtils.transparentize(Tacit.accent, 1) } GradientStop { position: 1; color: ColorUtils.transparentize(Tacit.accent, 0.62) } }
        }
        Rectangle {    // the edge itself, brightest where the sand is arriving
            x: epr.inset; anchors.bottom: parent.bottom; height: 3; radius: 1.5; color: Tacit.accent
            width: (parent.width - 2 * epr.inset) * (epr.ep?.shownProgress ?? 0)
            Rectangle { anchors.right: parent.right; width: Math.min(parent.width, 40); height: 3
                gradient: Gradient { orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: ColorUtils.transparentize("#ffffff", 1) } GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0.8) } } }
        }
    }
    // a headline lit from below by the same sun, brightest under the pointer
    component Lit: Item {
        id: lt
        property alias text: ltText.text
        property real size: 62
        property int align: Text.AlignLeft
        property real originX: 0       // its left edge in the window, so the light stands where the pointer is
        readonly property real lx: Math.max(0, Math.min(1, (root.sunX * root.width - lt.originX) / Math.max(1, lt.width)))
        implicitHeight: ltText.implicitHeight
        Text {
            id: ltText
            width: lt.width; visible: false; wrapMode: Text.Wrap; horizontalAlignment: lt.align
            font.family: Appearance.font.family.display; font.pixelSize: lt.size; font.weight: Font.DemiBold
            font.letterSpacing: -lt.size * 0.02; lineHeight: 1.04; color: "white"; renderType: Text.QtRendering
        }
        Rectangle {
            id: ltLight
            anchors.fill: ltText; visible: false
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "#e4ddd7" }
                GradientStop { position: Math.max(0.01, Math.min(0.97, lt.lx - 0.28)); color: "#f6efe8" }
                GradientStop { position: Math.max(0.02, Math.min(0.98, lt.lx)); color: "#ffe6cf" }
                GradientStop { position: Math.max(0.03, Math.min(0.99, lt.lx + 0.28)); color: "#f6efe8" }
                GradientStop { position: 1; color: "#e4ddd7" }
            }
        }
        GE.OpacityMask { anchors.fill: ltText; source: ltLight; maskSource: ltText }
    }
    // the app's credit: its icon, its name, the facts
    component Credit: Row {
        id: cr
        property var a
        property bool version: true
        spacing: 12
        AppIcon { src: cr.a?.icon ?? ""; width: 30; height: 30; anchors.verticalCenter: parent.verticalCenter }
        Column {
            anchors.verticalCenter: parent.verticalCenter; spacing: 1
            Body { text: cr.a?.name ?? ""; font.pixelSize: 16; font.weight: Font.DemiBold }
            Small { text: [root.costWords(cr.a), cr.version && cr.a?.version ? `version ${cr.a.version}` : ""].filter(x => x).join(" · ") }
        }
    }
    component Kicker: Small { font.pixelSize: 15; font.weight: Font.Medium; color: ColorUtils.mix(root.inkMain, root.inkSec, 0.35) }
    component Quote: Body {
        property string from: ""
        font.pixelSize: 18; lineHeight: 1.3; color: root.inkSec; wrapMode: Text.Wrap
    }

    // ---- the issue's spreads: each is loaded with its spread (sp), how far it is from the top of the window in windows
    // (off) and in pixels (top). Pictures lie a little deeper than words: they drift against the pointer and lag the page
    component SpreadBase: Item {
        anchors.fill: parent
        readonly property var sp: parent ? parent.sp : ({})
        readonly property real off: parent ? parent.off : 0
        readonly property real spreadTop: off * root.height
        readonly property var a: root.appOf(sp.pkg ?? "")
        readonly property real pdx: -(root.sunX - 0.5) * 10
        readonly property real pdy: -(root.sunY - 0.5) * 6 + off * 46
        readonly property real wdx: (root.sunX - 0.5) * 4
        readonly property real wdy: (root.sunY - 0.5) * 2 + off * 10
    }
    component CoverSpread: SpreadBase {
        id: cs
        EdgePic {
            id: cpic
            x: -12; width: root.width + 24; height: root.height * 0.646; r: 0
            src: cs.sp.picture ?? ""; pkg: cs.sp.pkg ?? ""
            lx: (root.sunX * root.width + 12) / width; ly: (root.sunY * root.height - cs.spreadTop) / height
            transform: Translate { x: cs.pdx; y: cs.pdy }
            Rectangle { anchors.fill: parent
                gradient: Gradient { GradientStop { position: 0.7; color: "transparent" } GradientStop { position: 1; color: ColorUtils.transparentize(root.ground, 0.45) } } }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(cs.sp.pkg) }
        }
        Item {
            x: root.gutter; y: root.height * 0.698; width: root.width - 2 * root.gutter; height: root.height * 0.302 - 56
            transform: Translate { x: cs.wdx; y: cs.wdy }
            Column {
                anchors.bottom: parent.bottom; width: parent.width - 360 - 96; spacing: 16
                Kicker { text: cs.sp.kicker ?? "" }
                Lit { width: parent.width; text: cs.sp.line ?? ""; size: Math.round(62 * root.k); originX: root.gutter }
            }
            Column {
                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.bottomMargin: 6; width: 360; spacing: 22
                Column { width: parent.width; spacing: 8; visible: !!cs.sp.quote
                    Quote { width: parent.width; text: `“${cs.sp.quote ?? ""}”` }
                    Small { visible: !!cs.sp.from; text: `from ${cs.sp.from ?? ""}`; font.pixelSize: 14 } }
                Rectangle { width: parent.width; height: 1; color: root.inkMain; opacity: 0.12 }
                Item { width: parent.width; height: 48
                    Credit { a: cs.a; version: false; anchors.verticalCenter: parent.verticalCenter }
                    Capsule { a: cs.a; solid: true; large: true; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter } }
            }
        }
    }
    component SplitSpread: SpreadBase {
        id: ss
        EdgePic {
            x: root.width * 0.48; y: root.height * 0.12; width: root.width * 0.52 + 24; height: root.height - 72 - y
            src: ss.sp.picture ?? ""; pkg: ss.sp.pkg ?? ""
            lx: (root.sunX * root.width - x) / width; ly: (root.sunY * root.height - ss.spreadTop - y) / height
            transform: Translate { x: ss.pdx; y: ss.pdy }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(ss.sp.pkg) }
        }
        Column {
            x: root.gutter; width: root.width * 0.34; anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 16; spacing: 32
            transform: Translate { x: ss.wdx; y: ss.wdy }
            Column { width: parent.width; spacing: 16
                Kicker { text: ss.sp.kicker ?? "" }
                Lit { width: parent.width; text: ss.sp.line ?? ""; size: Math.round(54 * root.k); originX: root.gutter } }
            Column { width: parent.width; spacing: 8; visible: !!ss.sp.quote
                Quote { width: parent.width; text: `“${ss.sp.quote ?? ""}”` }
                Small { visible: !!ss.sp.from; text: `from ${ss.sp.from ?? ""}`; font.pixelSize: 14 } }
            Rectangle { width: parent.width; height: 1; color: root.inkMain; opacity: 0.12 }
            Row { spacing: 28
                Credit { a: ss.a; anchors.verticalCenter: parent.verticalCenter }
                Capsule { a: ss.a; solid: true; large: true; anchors.verticalCenter: parent.verticalCenter } }
        }
    }
    component WordsSpread: SpreadBase {
        id: ws
        readonly property var parts: ws.sp.say ?? []
        readonly property string html: parts.map(pt => {
            const t = (pt[0] ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");
            const app = pt[1] ? root.appOf(pt[1]) : null;
            return t + (app ? `<a href="${pt[1]}" style="text-decoration:none; color:#f6f1ea"><img src="file://${app.icon}" width="${Math.round(46 * root.k)}" height="${Math.round(46 * root.k)}" align="middle">&nbsp;${app.name}</a>` : "");
        }).join("")
        Column {
            anchors.centerIn: parent; anchors.verticalCenterOffset: 16; spacing: 0
            transform: Translate { x: ws.wdx; y: ws.wdy }
            Kicker { text: ws.sp.kicker ?? ""; anchors.horizontalCenter: parent.horizontalCenter }
            Item { width: 1; height: 26 }
            Text {
                width: Math.min(1180, root.width - 400); anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.RichText; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; text: ws.html
                font.family: Appearance.font.family.display; font.pixelSize: Math.round(50 * root.k); font.weight: Font.DemiBold
                font.letterSpacing: -0.6; lineHeight: 1.25; color: ColorUtils.mix(root.inkMain, root.inkSec, 0.5); linkColor: "#f6f1ea"
                onLinkActivated: link => root.openApp(link)
                HoverHandler { cursorShape: parent.hoveredLink ? Qt.PointingHandCursor : Qt.ArrowCursor }
            }
            Item { width: 1; height: 72 }
            Row {
                anchors.horizontalCenter: parent.horizontalCenter; spacing: 20
                Repeater {
                    model: ws.parts.filter(pt => pt[1]).map(pt => root.appOf(pt[1])).filter(x => x)
                    Rectangle {
                        required property var modelData
                        width: pillRow.implicitWidth + 36; height: 68; radius: 22; color: Qt.rgba(0.078, 0.067, 0.063, 0.5)
                        Row { id: pillRow; x: 22; anchors.verticalCenter: parent.verticalCenter; spacing: 16
                            AppIcon { src: modelData.icon; width: 32; height: 32; anchors.verticalCenter: parent.verticalCenter }
                            Column { anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                Body { text: modelData.name; font.pixelSize: 16; font.weight: Font.DemiBold }
                                Small { text: root.costWords(modelData); font.pixelSize: 14 } }
                            Capsule { a: modelData; solid: true; anchors.verticalCenter: parent.verticalCenter } }
                    }
                }
            }
        }
    }
    component ObjectSpread: SpreadBase {
        id: os
        EdgePic {
            height: root.height * 0.474; width: Math.min(root.width - 2 * root.gutter, height * (os.sp.aspect ?? 1.4))
            x: (root.width - width) / 2; y: root.height * 0.125
            src: os.sp.picture ?? ""; pkg: os.sp.pkg ?? ""
            lx: (root.sunX * root.width - x) / width; ly: (root.sunY * root.height - os.spreadTop - y) / height
            transform: Translate { x: os.pdx; y: os.pdy }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(os.sp.pkg) }
        }
        Column {
            y: root.height * 0.655; width: root.width; spacing: 0
            transform: Translate { x: os.wdx; y: os.wdy }
            Kicker { text: os.sp.kicker ?? ""; anchors.horizontalCenter: parent.horizontalCenter }
            Item { width: 1; height: 14 }
            Lit { width: root.width - 2 * root.gutter; anchors.horizontalCenter: parent.horizontalCenter; text: os.sp.line ?? ""
                size: Math.round(50 * root.k); align: Text.AlignHCenter; originX: root.gutter }
            Item { width: 1; height: 22 }
            Quote { visible: !!os.sp.quote; width: Math.min(900, root.width - 2 * root.gutter); anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter; font.pixelSize: 17; text: `“${os.sp.quote ?? ""}”` }
            Item { width: 1; height: 24 }
            Row { anchors.horizontalCenter: parent.horizontalCenter; spacing: 28
                Credit { a: os.a; anchors.verticalCenter: parent.verticalCenter }
                Capsule { a: os.a; solid: true; large: true; anchors.verticalCenter: parent.verticalCenter } }
        }
    }
    component CinemaSpread: SpreadBase {
        id: cn
        Rectangle { anchors.fill: parent; color: "#000000" }
        Item {
            x: root.gutter; y: root.height * 0.142; width: root.width - 2 * root.gutter; height: 48
            Kicker { anchors.verticalCenter: parent.verticalCenter; text: cn.sp.kicker ?? "" }
            Row { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 20
                Credit { a: cn.a; anchors.verticalCenter: parent.verticalCenter }
                Capsule { a: cn.a; solid: true; anchors.verticalCenter: parent.verticalCenter } }
        }
        EdgePic {
            // never stretched far past its own pixels: a small frame stays sharp, centred on the black
            readonly property real full: root.width + 24
            width: cn.sp.px ? Math.min(full, cn.sp.px * 1.2) : full; x: (root.width - width) / 2
            y: root.height * 0.211; height: Math.min(root.height * 0.603, width / (cn.sp.aspect ?? 1.85)); r: width < full ? 14 : 0
            src: cn.sp.picture ?? ""; pkg: cn.sp.pkg ?? ""
            lx: (root.sunX * root.width + 12) / width; ly: (root.sunY * root.height - cn.spreadTop - y) / height
            transform: Translate { x: cn.pdx; y: cn.pdy * 0.5 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(cn.sp.pkg) }
        }
        Text { y: root.height * 0.855; width: root.width; horizontalAlignment: Text.AlignHCenter; text: cn.sp.line ?? ""
            font.family: Appearance.font.family.main; font.pixelSize: Math.round(24 * root.k); color: "#f1ece4" }
    }
    // the window's light, from a picture: drawn tiny, blurred, spread over the whole window
    component GlowPic: Item {
        id: gp
        property string src
        property bool on: false
        property real level: 0.42
        anchors.fill: parent
        opacity: on ? level : 0
        Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
        Image { id: gpImg; anchors.centerIn: parent; width: parent.width * 1.2; height: parent.height * 1.2; visible: false
            source: gp.src ? "file://" + gp.src : ""; fillMode: Image.PreserveAspectCrop; sourceSize: Qt.size(48, 30); smooth: true; asynchronous: true }
        MultiEffect { anchors.fill: gpImg; source: gpImg; blurEnabled: true; blurMax: 64; blur: 1; saturation: 0.25 }
    }

    // ---- the other pages in the issue's language
    // a page's head: what it is, its title lit like the issue's headlines, one plain line
    component PageHead: Column {
        id: ph
        property string kicker: ""
        property string title: ""
        property string line: ""
        width: root.cw; spacing: 0
        Kicker { visible: ph.kicker !== ""; text: ph.kicker }
        Item { visible: ph.kicker !== ""; width: 1; height: 14 }
        Lit { width: Math.min(root.cw, 1100); text: ph.title; size: Math.round(62 * root.k); originX: root.m }
        Item { visible: ph.line !== ""; width: 1; height: 18 }
        Quote { visible: ph.line !== ""; width: Math.min(root.cw, 900); text: ph.line; font.pixelSize: 19 }
    }
    // an app as an entry: its picture (the work, or its window framed) beside its name, what it is, the facts and Get
    component Entry: Item {
        id: en
        property var a
        property bool flip: false
        readonly property string pkg: a?.pkg ?? ""
        readonly property string pic: root.jobHero[pkg] ?? ""
        readonly property real ar: root.heroAspect[pkg] ?? 1.6
        readonly property real picW: Math.round(root.cw * 0.54)
        readonly property real picH: pic ? Math.min(460, Math.round(picW / ar)) : 0
        visible: !!a
        width: root.cw; height: Math.max(picH, words.implicitHeight, 200)
        EdgePic {
            visible: en.pic !== ""
            x: en.flip ? root.cw - width : 0; width: en.picW; height: en.picH; r: 18
            anchors.verticalCenter: parent.verticalCenter
            src: en.pic; pkg: en.pkg; lx: 0.5; ly: 0.35
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(en.pkg) }
        }
        Item {    // no picture yet, or none at all: the icon stands where it would be
            visible: en.pic === ""
            x: en.flip ? root.cw - width : 0; width: en.picW; height: 200
            AppIcon { anchors.centerIn: parent; src: en.a?.icon ?? ""; width: 120; height: 120 }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(en.pkg) }
        }
        Column {
            id: words
            x: en.flip ? 0 : en.picW + 72; width: root.cw - en.picW - 72; anchors.verticalCenter: parent.verticalCenter; spacing: 0
            Kicker { visible: !!en.a?.like; text: en.a?.like ?? "" }
            Item { width: 1; height: 10 }
            Text { width: parent.width; text: en.a?.name ?? ""; font.family: Appearance.font.family.display; font.pixelSize: Math.round(40 * root.k)
                font.weight: Font.DemiBold; font.letterSpacing: -0.6; color: "#f3f0ea"; elide: Text.ElideRight
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(en.pkg) } }
            Item { width: 1; height: 12 }
            Quote { width: parent.width; text: en.a?.line ?? "" }
            Item { width: 1; height: 26 }
            Row { spacing: 24
                Capsule { a: en.a; solid: true; large: true; anchors.verticalCenter: parent.verticalCenter }
                Small { anchors.verticalCenter: parent.verticalCenter
                    text: [root.costWords(en.a), en.a?.version ? `version ${en.a.version}` : ""].filter(x => x).join(" · ") } }
        }
    }
    // an app as a row of a list: icon, name, what it is, what it costs, its capsule
    component ListRow: Item {
        id: lr
        property var a
        property bool removable: false
        readonly property string said: a ? (root.outcome[a.pkg] ?? "") : ""
        visible: !!a
        height: 84
        Rectangle { x: -14; y: 4; width: lr.width + 28; height: lr.height - 8; radius: 16
            color: rowArea.containsMouse ? Qt.rgba(1, 1, 1, 0.045) : "transparent"; Behavior on color { ColorAnimation { duration: 140 } } }
        MouseArea { id: rowArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openApp(lr.a.pkg) }
        AppIcon { src: lr.a?.icon ?? ""; width: 48; height: 48; anchors.verticalCenter: parent.verticalCenter }
        Column {
            x: 68; anchors.verticalCenter: parent.verticalCenter; spacing: 3; width: lr.width - 68 - rowEnd.width - 24
            Body { text: lr.a?.name ?? ""; font.pixelSize: 17; font.weight: Font.DemiBold; width: parent.width; elide: Text.ElideRight }
            Small { text: [lr.a?.like, lr.a?.line].filter(x => x).join(" · "); width: parent.width; elide: Text.ElideRight }
            Small { visible: lr.said !== "" && lr.said !== "ok"; text: (root.outcomeWords[lr.said] ?? ["", ""]).join(". "); color: Tacit.risk }
        }
        Row {
            id: rowEnd
            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 18
            Small { anchors.verticalCenter: parent.verticalCenter; text: lr.removable ? "" : root.costWords(lr.a); visible: text !== "" }
            Capsule { a: lr.a; anchors.verticalCenter: parent.verticalCenter }
            Word { visible: lr.removable; anchors.verticalCenter: parent.verticalCenter
                text: root.work?.pkg === lr.a?.pkg && root.work?.kind === "remove" ? "Removing…" : "Remove"; glyph: "delete"; ink: Tacit.risk
                onPicked: root.removeApp(lr.a.pkg) }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.inkMain; opacity: 0.07 }
    }

    // ---- the header: the store's name (or Back), a big search in the middle, your apps. It floats over the page with no
    // edge of its own; its glass thickens with how bright the picture passing under it is, so it stays readable
    readonly property real underBright: {
        if (page !== "discover") return 0.25;
        let b = 0;
        const H = height, band = 96;
        for (let i = Math.max(0, spreadAt - 1); i <= Math.min(issue.length - 1, spreadAt + 1); i++) {
            const sp = issue[i], pb = picBand(sp.layout), top = i * H - issueView.contentY;
            const over = Math.max(0, Math.min(top + pb[1] * H, band) - Math.max(top + pb[0] * H, 0));
            if (over > 0) b = Math.max(b, (sp.bright ?? 0.5) * Math.min(1, over / band));
        }
        return b;
    }
    property real scrim: 0.22 + 0.5 * Math.max(0, Math.min(1, (underBright - 0.2) / 0.5))
    Behavior on scrim { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    Item {
        id: topRow
        parent: canvas; z: 3
        width: root.width; height: 96
        Item {
            width: parent.width; height: 150
            ShaderEffectSource { id: bandSrc; anchors.fill: parent; sourceItem: contentLayer; live: true; hideSource: false; visible: false
                sourceRect: Qt.rect(0, 0, width, height) }
            MultiEffect { id: bandBlur; anchors.fill: parent; source: bandSrc; blurEnabled: true; blurMax: 40; blur: 1; saturation: 0.15; visible: false }
            Rectangle { id: bandMask; anchors.fill: parent; visible: false
                gradient: Gradient { GradientStop { position: 0; color: "white" } GradientStop { position: 0.42; color: "white" } GradientStop { position: 1; color: "transparent" } } }
            GE.OpacityMask { anchors.fill: parent; source: bandBlur; maskSource: bandMask }
        }
        Rectangle {    // the glass's tint, fading out downward: no line where it ends
            width: parent.width; height: 150
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.rgba(0.086, 0.07, 0.067, Math.min(0.9, root.scrim + 0.15)) }
                GradientStop { position: 0.5; color: Qt.rgba(0.086, 0.07, 0.067, root.scrim) }
                GradientStop { position: 1; color: Qt.rgba(0.086, 0.07, 0.067, 0) }
            }
        }
        // left: the store's name, which is the way back to the issue; on an app's page, Back
        Press {
            visible: root.page !== "app"
            x: root.gutter; anchors.verticalCenter: parent.verticalCenter; width: nameText.implicitWidth; height: 30
            inset: 8; rounding: 12; lit: false
            onPicked: { field.text = ""; field.focus = false; root.history = []; root.page = "discover"; }
            Body { id: nameText; anchors.verticalCenter: parent.verticalCenter; text: "Apps"; font.family: Appearance.font.family.display
                font.pixelSize: 21; font.weight: Font.DemiBold; color: "#f6f1ea" }
        }
        Word { visible: root.page === "app"; x: root.gutter - 4; anchors.verticalCenter: parent.verticalCenter; text: "Back"; glyph: "arrow_back"; ink: root.inkMain; onPicked: root.back() }
        // right: your apps, with the sand tick when it is the page
        Item {
            anchors.right: parent.right; anchors.rightMargin: root.gutter; anchors.verticalCenter: parent.verticalCenter
            width: yoursText.implicitWidth; height: 30
            Body { id: yoursText; anchors.verticalCenter: parent.verticalCenter; text: "Your apps"; font.pixelSize: 16; font.weight: Font.Medium
                color: yoursArea.containsMouse || root.page === "yours" ? "#f6f1ea" : root.inkMain }
            Rectangle { y: 28; height: 3; radius: 1.5; color: Tacit.accent; width: root.page === "yours" ? 22 : 0; Behavior on width { Spring {} } }
            MouseArea { id: yoursArea; anchors.fill: parent; anchors.margins: -8; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: { field.text = ""; field.focus = false; if (root.page !== "yours") root.go("yours"); } }
        }
        // the search: frosted from what passes under it, darker over bright pictures
        Item {
            id: searchBox
            anchors.centerIn: parent
            width: Math.min(720, root.width - 2 * root.gutter - 360); height: 60
            ClippingRectangle {
                anchors.fill: parent; radius: 30; color: "transparent"
                ShaderEffectSource {
                    id: frostSrc
                    anchors.fill: parent; sourceItem: contentLayer; live: true; hideSource: false; visible: false
                    sourceRect: Qt.rect(searchBox.x, searchBox.y, searchBox.width, searchBox.height)
                }
                MultiEffect { anchors.fill: parent; source: frostSrc; blurEnabled: true; blurMax: 48; blur: 1; saturation: 0.2 }
                Rectangle { anchors.fill: parent; color: field.activeFocus ? Qt.rgba(0.102, 0.086, 0.082, 0.78)
                                                         : Qt.rgba(0.102, 0.086, 0.082, 0.32 + root.scrim * 0.5)
                    Behavior on color { ColorAnimation { duration: 260 } } }
            }
            Rectangle { anchors.fill: parent; radius: 30; color: "transparent"; border.width: 1
                border.color: field.activeFocus ? ColorUtils.transparentize(Tacit.accent, 0.62) : Qt.rgba(1, 1, 1, 0.07) }
            MaterialSymbol { x: 24; anchors.verticalCenter: parent.verticalCenter; text: "search"; iconSize: 24; color: field.activeFocus ? root.inkMain : root.inkSec }
            TextInput {
                id: field
                x: 62; width: parent.width - 86; anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 20; font.family: Appearance.font.family.main; color: root.inkMain
                selectionColor: ColorUtils.transparentize(Tacit.accent, 0.6); clip: true
                cursorDelegate: Rectangle { width: 2; color: Tacit.accent; visible: field.activeFocus }
                onTextChanged: searchDelay.restart()
                Keys.onReturnPressed: { searchDelay.stop(); root.runSearch(text); }
                Keys.onEscapePressed: { if (text) text = ""; else { focus = false; if (root.page !== "discover") root.back(); } }
            }
            Body { x: 62; anchors.verticalCenter: parent.verticalCenter; visible: !field.text; text: "What do you want to do?"; color: root.inkSec; font.pixelSize: 20 }
            MouseArea { anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton; cursorShape: Qt.IBeamCursor }
            Timer { id: searchDelay; interval: 90; onTriggered: if (field.text.trim().length >= 2) root.runSearch(field.text) }
        }
    }

    // ---- an app that needs the waiting updates with it: a sheet grows down from the window's top edge and says what Get
    // brings, in plain words; one press does both, the password is asked once
    MouseArea {    // the page behind it rests, dimmed; a click there is "Not now"
        parent: canvas; z: 4; anchors.fill: parent
        visible: sheet.shown > 0.01
        Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.35 * sheet.shown }
        onClicked: root.askUpdate = null
    }
    Item {
        id: sheet
        parent: canvas; z: 5
        readonly property var u: root.askUpdate
        property var last: null
        onUChanged: if (u) last = u
        property real shown: u ? 1 : 0
        Behavior on shown { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
        visible: shown > 0.01
        width: 640; x: (root.width - width) / 2
        height: sheetBody.implicitHeight + 72
        y: -height * (1 - shown)
        DockedRect {
            anchors.fill: parent; edge: "top"; cornerRadius: 28; fillet: 18
            color: ColorUtils.mix("#ffffff", root.ground, 0.07)
        }
        Column {
            id: sheetBody
            x: 44; y: 40; width: parent.width - 88; spacing: 0
            Row { spacing: 16
                AppIcon { src: root.appOf(sheet.last?.pkg ?? "")?.icon ?? ""; width: 44; height: 44; anchors.verticalCenter: parent.verticalCenter }
                Text { anchors.verticalCenter: parent.verticalCenter; width: sheetBody.width - 60; wrapMode: Text.Wrap
                    text: `${sheet.last?.name ?? ""} comes with Tacit's latest updates`
                    font.family: Appearance.font.family.display; font.pixelSize: 26; font.weight: Font.DemiBold; font.letterSpacing: -0.3; color: "#f3f0ea" } }
            Item { width: 1; height: 18 }
            Quote {
                width: parent.width; font.pixelSize: 17
                readonly property real leftMB: sheet.last?.toDownloadMB ?? ((sheet.last?.updatesMB ?? 0) + (sheet.last?.appMB ?? 0))
                readonly property string leftWords: leftMB >= 1000 ? (leftMB / 1000).toFixed(1) + " GB" : Math.max(1, Math.round(leftMB)) + " MB"
                text: `There are ${sheet.last?.updates ?? 0} updates waiting for Tacit and your apps. They come first, then ${sheet.last?.name ?? "it"}. `
                      + (leftMB < 50 ? "They're already downloaded, so it takes about a minute." : `${leftWords} to download, a few minutes, and you can keep working.`)
            }
            Item { width: 1; height: 30 }
            Row {
                spacing: 28
                Rectangle {
                    height: 48; radius: 24; width: goText.implicitWidth + 52
                    color: goArea.containsMouse ? ColorUtils.mix("#ffffff", Tacit.accent, 0.14) : Tacit.accent
                    scale: goArea.pressed ? 0.96 : 1; Behavior on scale { Spring {} }
                    Body { id: goText; anchors.centerIn: parent; text: `Get ${sheet.last?.name ?? ""} and the updates`; font.pixelSize: 16; font.weight: Font.DemiBold; color: Tacit.inkOnAccent }
                    MouseArea { id: goArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { const pk = root.askUpdate?.pkg; root.askUpdate = null; if (pk) root.getEverything(pk); } }
                }
                Word { anchors.verticalCenter: parent.verticalCenter; text: "Not now"; ink: root.inkMain; onPicked: root.askUpdate = null }
            }
        }
        Keys.onEscapePressed: root.askUpdate = null
    }

    // ---- what you can do: when the search opens with nothing typed, the page steps back and these stand in its light
    MouseArea {    // a click anywhere else closes it
        parent: canvas; z: 2; anchors.fill: parent; visible: root.asking; onClicked: field.focus = false
    }
    Item {
        id: jobsLayer
        parent: canvas; z: 2
        width: Math.min(900, root.width - 2 * root.gutter); x: (root.width - width) / 2; y: 150
        opacity: root.asking ? 1 : 0; visible: opacity > 0.01
        transform: Translate { y: root.asking ? 0 : 14; Behavior on y { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } } }
        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        Grid {
            columns: 2; columnSpacing: 72
            Repeater {
                model: root.home?.jobs ?? []
                Item {
                    required property var modelData
                    width: (jobsLayer.width - 72) / 2; height: 92
                    Column {
                        anchors.verticalCenter: parent.verticalCenter; spacing: 6
                        Text { text: modelData.name; font.family: Appearance.font.family.display; font.pixelSize: 32; font.weight: Font.DemiBold
                            font.letterSpacing: -0.3; color: jobArea.containsMouse ? "#f3f0ea" : root.inkSec; Behavior on color { ColorAnimation { duration: 160 } } }
                        Small { text: modelData.pkgs.map(p => root.appOf(p)?.name).filter(x => x).join(", ") }
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.inkMain; opacity: 0.07 }
                    MouseArea { id: jobArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { field.focus = false; root.openJob(modelData); } }
                }
            }
        }
    }
    Shortcut { sequences: ["Ctrl+F", "Ctrl+K"]; onActivated: field.forceActiveFocus() }
    Shortcut { sequence: "Escape"; enabled: !field.activeFocus; onActivated: root.back() }

    Component { id: coverC; CoverSpread {} }
    Component { id: splitC; SplitSpread {} }
    Component { id: wordsC; WordsSpread {} }
    Component { id: objectC; ObjectSpread {} }
    Component { id: cinemaC; CinemaSpread {} }
    function turnTo(i) { snapAnim.to = Math.max(0, Math.min(issue.length - 1, i)) * height; snapAnim.restart(); }
    Shortcut { sequences: ["Down", "PgDown", "Space"]; enabled: root.page === "discover" && !field.activeFocus; onActivated: root.turnTo(root.spreadAt + 1) }
    Shortcut { sequences: ["Up", "PgUp"]; enabled: root.page === "discover" && !field.activeFocus; onActivated: root.turnTo(root.spreadAt - 1) }
    function reveal() { pageIn.stop(); pages.opacity = 0; pages.y = 10; scroller.contentY = page === "app" ? 0 : -116; pageIn.restart(); }
    ParallelAnimation { id: pageIn
        Anim { target: pages; property: "opacity"; to: 1; type: Anim.DefaultEffects }
        SpringAnimation { target: pages; property: "y"; to: 0; spring: 4.5; damping: 0.5; epsilon: 0.05 } }

    // ---- the content layer: the window's light, the issue, the other pages; it all passes under the header
    Item {
        id: contentLayer
        parent: canvas
        anchors.fill: parent

        Item {
            id: glow
            anchors.fill: parent
            opacity: want ? (root.asking ? 0.6 : 1) : 0
            Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            readonly property var sp: root.issue[root.spreadAt] ?? null
            readonly property string firstPkg: ((root.page === "job" ? root.job?.pkgs : root.page === "search" ? root.found?.job?.pkgs : null) ?? []).find(p => !!root.jobHero[p]) ?? ""
            readonly property string want: root.page === "discover" ? (!sp ? "" : sp.picture ? sp.picture : (root.appOf(((sp.say ?? []).find(x => x[1]) ?? [])[1] ?? "")?.icon ?? ""))
                                         : root.page === "app" ? (root.appInfo?.hero || "")
                                         : firstPkg ? root.jobHero[firstPkg] : ""
            readonly property real level: root.page === "discover" ? ((sp?.layout ?? "") === "words" ? 0.1 : 0.42)
                                         : root.page === "app" ? (root.appInfo?.heroWork ? 0.42 : 0.3) : 0.3
            property int front: 0
            onWantChanged: { if (front === 0) glowB.src = want; else glowA.src = want; front = 1 - front; }
            GlowPic { id: glowA; on: glow.front === 0; level: glow.level }
            GlowPic { id: glowB; on: glow.front === 1; level: glow.level }
            Shape {    // the light gathers in the middle; the window's own ground at its edges
                anchors.fill: parent
                ShapePath {
                    strokeWidth: -1; strokeColor: "transparent"
                    fillGradient: RadialGradient {
                        centerX: glow.width / 2; centerY: glow.height * 0.45; focalX: centerX; focalY: centerY
                        centerRadius: Math.max(glow.width, glow.height) * 0.72
                        GradientStop { position: 0.35; color: ColorUtils.transparentize(root.ground, 1) }
                        GradientStop { position: 1; color: ColorUtils.transparentize(root.ground, 0.12) }
                    }
                    startX: 0; startY: 0
                    PathLine { x: glow.width; y: 0 }
                    PathLine { x: glow.width; y: glow.height }
                    PathLine { x: 0; y: glow.height }
                    PathLine { x: 0; y: 0 }
                }
            }
        }

        // ---- Discover: the issue, a spread a window tall per pick; scrolling turns the pages and settles on the nearest
        Flickable {
            id: issueView
            anchors.fill: parent
            visible: root.page === "discover"
            opacity: root.asking ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
            contentWidth: width; contentHeight: root.issue.length * root.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            GlideWheel { id: issueGlide; view: issueView; gain: 1.6; gainPerSpeed: 3; gainMax: 6 }
            HoverHandler { onPointChanged: { root.ptrX = point.position.x / Math.max(1, issueView.width); root.ptrY = point.position.y / Math.max(1, issueView.height); } }
            onContentYChanged: if (!snapAnim.running) settle.restart()
            Column {
                Repeater {
                    model: root.issue
                    Item {
                        id: spreadItem
                        required property var modelData
                        required property int index
                        width: root.width; height: root.height
                        Loader {
                            anchors.fill: parent
                            readonly property var sp: spreadItem.modelData
                            readonly property real off: (spreadItem.index * root.height - issueView.contentY) / Math.max(1, root.height)
                            active: Math.abs(off) < 1.6
                            sourceComponent: ({ cover: coverC, split: splitC, words: wordsC, object: objectC, cinema: cinemaC })[spreadItem.modelData.layout] ?? null
                        }
                    }
                }
            }
        }
        Timer {
            id: settle; interval: 200
            onTriggered: {
                if (issueGlide.active || issueView.moving || issueView.dragging) { restart(); return; }
                const H = root.height, n = Math.round(issueView.contentY / H), d = issueView.contentY - n * H;
                if (Math.abs(d) > 1 && Math.abs(d) < 0.3 * H) { snapAnim.to = n * H; snapAnim.restart(); }
            }
        }
        NumberAnimation { id: snapAnim; target: issueView; property: "contentY"; duration: 520; easing.type: Easing.OutCubic }
        // where you are in the issue
        Column {
            visible: root.page === "discover" && !root.asking
            anchors.right: parent.right; anchors.rightMargin: 36; anchors.verticalCenter: parent.verticalCenter; spacing: 8
            Repeater {
                model: root.issue.length
                Rectangle {
                    required property int index
                    width: 3; height: 16; radius: 1.5
                    color: index === root.spreadAt ? Tacit.accent : Qt.rgba(1, 1, 1, 0.18)
                    Behavior on color { ColorAnimation { duration: 300 } }
                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: root.turnTo(parent.index) }
                }
            }
        }

    Flickable {
        id: scroller
        parent: contentLayer
        anchors.fill: parent
        visible: root.page !== "discover"
        opacity: root.asking ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
        topMargin: root.page === "app" ? 0 : 116
        contentWidth: width
        contentHeight: pages.childrenRect.height + 96
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: StyledScrollBar { topPadding: 120 }
        GlideWheel { view: scroller; gain: 1.6; gainPerSpeed: 3; gainMax: 6 }

        Item {
            id: pages
            width: root.width

            // ---- a job: its head, then every app for it as an entry, pictures alternating sides
            Column {
                visible: root.page === "job" && root.job !== null
                x: root.m; width: root.cw
                PageHead { kicker: "What you can do"; title: root.job?.name ?? ""; line: root.job?.advice ?? "" }
                Item { width: 1; height: 72 }
                Repeater {
                    model: (root.job?.pkgs ?? []).filter(p => root.appOf(p)?.available !== false)
                    Column {
                        required property string modelData
                        required property int index
                        Entry { a: root.appOf(modelData); flip: index % 2 === 1 }
                        Item { width: 1; height: 88 }
                    }
                }
            }

            // ---- search: the matching job's apps as entries, then everything else that matches as a list
            Column {
                visible: root.page === "search" && root.found !== null
                x: root.m; width: root.cw
                readonly property var others: (root.found?.apps ?? []).filter(x => !(root.found?.job?.pkgs ?? []).includes(x.pkg)).slice(0, 16)
                PageHead {
                    kicker: root.found?.job ? "What you can do" : "Search"
                    title: root.found?.job ? root.found.job.name : `“${root.query.trim()}”`
                    line: root.found?.job ? root.found.job.advice : (root.found?.apps?.length ?? 0) ? `${root.found.apps.length} apps match.`
                        : root.found?.done ? "Nothing matches that. Try saying what you want to do, like edit photos." : "Looking…"
                }
                Item { width: 1; height: 72 }
                Repeater {
                    model: (root.found?.job ? root.found.job.pkgs : []).filter(p => root.appOf(p)?.available !== false)
                    Column {
                        required property string modelData
                        required property int index
                        Entry { a: root.appOf(modelData); flip: index % 2 === 1 }
                        Item { width: 1; height: 88 }
                    }
                }
                Kicker { visible: !!root.found?.job && parent.others.length > 0; text: "Other apps that match" }
                Item { visible: !!root.found?.job && parent.others.length > 0; width: 1; height: 18 }
                Grid {
                    columns: 2; columnSpacing: 72
                    Repeater { model: parent.parent.others
                        ListRow { required property var modelData; a: modelData; width: (root.cw - 72) / 2 } }
                }
            }

            // ---- an app: its picture across the window (the work) or framed (its window), its name lit, the facts, then the rest
            Column {
                id: appPage
                visible: root.page === "app"
                x: root.m; width: root.cw
                readonly property var a: root.appInfo
                readonly property string st: root.stateOf(a)
                readonly property string said: a ? (root.outcome[a.pkg] ?? "") : ""
                readonly property string w: said && said !== "ok" ? said : (st === "unavailable" ? "unavailable"
                                            : (a?.plan?.can === false && !["installed", "update"].includes(a?.plan?.why) ? (a?.plan?.why ?? "") : ""))
                readonly property bool work: !!a?.heroWork && !!a?.hero
                readonly property real framedH: Math.min(root.height * 0.44, root.cw * 0.72 / (a?.heroAspect ?? 1.6))
                Item {
                    x: -root.m; width: root.width
                    height: appPage.work ? Math.round(root.height * 0.58) : (appPage.a?.hero ? 116 + appPage.framedH : 116)
                    EdgePic {
                        visible: appPage.work
                        x: -12; width: root.width + 24; height: parent.height; r: 0
                        src: appPage.work ? appPage.a.hero : ""; pkg: appPage.a?.pkg ?? ""; lx: root.sunX; ly: 0.4
                        Rectangle { anchors.fill: parent
                            gradient: Gradient { GradientStop { position: 0.68; color: "transparent" } GradientStop { position: 1; color: ColorUtils.transparentize(root.ground, 0.4) } } }
                    }
                    EdgePic {
                        visible: !appPage.work && !!appPage.a?.hero
                        y: 116; height: appPage.framedH; width: height * (appPage.a?.heroAspect ?? 1.6); x: (root.width - width) / 2; r: 16
                        src: !appPage.work ? (appPage.a?.hero ?? "") : ""; pkg: appPage.a?.pkg ?? ""; lx: 0.5; ly: 0.35
                    }
                }
                Item { width: 1; height: 44 }
                Item {
                    width: root.cw; height: Math.max(titleCol.height, getCol.height)
                    Column {
                        id: titleCol
                        width: root.cw - 420; spacing: 0
                        Row { spacing: 14
                            AppIcon { src: appPage.a?.icon ?? ""; width: 30; height: 30; anchors.verticalCenter: parent.verticalCenter }
                            Kicker { anchors.verticalCenter: parent.verticalCenter
                                text: [root.jobOf(appPage.a?.pkg ?? "")?.name, appPage.a?.like].filter(x => x).join(" · ") || (appPage.a?.developer ?? "") } }
                        Item { width: 1; height: 14 }
                        Lit { width: parent.width; text: appPage.a?.name ?? "…"; size: Math.round(62 * root.k); originX: root.m }
                        Item { width: 1; height: 14 }
                        Quote { width: parent.width; text: appPage.a?.line ?? ""; font.pixelSize: 20 }
                    }
                    Column {
                        id: getCol
                        anchors.right: parent.right; anchors.bottom: parent.bottom; spacing: 10
                        Capsule { a: appPage.a; solid: true; large: true; anchors.right: parent.right }
                        Small { anchors.right: parent.right; horizontalAlignment: Text.AlignRight
                            text: appPage.st === "getting" ? (root.work?.phase ?? "") : root.justGot === appPage.a?.pkg ? "It's in your apps now."
                                  : appPage.st === "installed" ? "On this computer"
                                  : [appPage.a?.plan?.download ? `${appPage.a.plan.download} MB` : appPage.a?.plan?.appMB ? `${appPage.a.plan.appMB} MB` : "",
                                     appPage.a?.free === false ? "Free to use" : "Free"].filter(x => x).join(" · ") }
                    }
                }
                Column {
                    visible: appPage.w !== "" && !["getting", "removing"].includes(appPage.st)
                    width: root.cw; spacing: 4
                    Item { width: 1; height: 20 }
                    Body { text: (root.outcomeWords[appPage.w] ?? ["", ""])[0]; font.weight: Font.DemiBold }
                    Small { text: (root.outcomeWords[appPage.w] ?? ["", ""])[1]; font.pixelSize: 16 }
                    Item { width: 1; height: 8 }
                    Word { visible: ["cancelled", "busy", "offline", "failed"].includes(appPage.w); text: "Try again"; glyph: "refresh"; ink: root.inkMain; onPicked: root.get(appPage.a.pkg) }
                }
                Item { width: 1; height: 44 }
                Rectangle { width: root.cw; height: 1; color: root.inkMain; opacity: 0.1 }
                Row {
                    Repeater {
                        model: [["Size", appPage.a?.plan?.need ? `${appPage.a.plan.need} MB` : appPage.a?.size ? `${appPage.a.size} MB` : "–"],
                                ["Licence", appPage.a ? (appPage.a.free ? "Open source" : "Closed source") : "–"],
                                ["Version", appPage.a?.version || "–"],
                                ["Made by", appPage.a?.developer || "–"],
                                ["Kind", root.jobOf(appPage.a?.pkg ?? "")?.name ?? "App"]]
                        Item {
                            required property var modelData; required property int index
                            width: root.cw / 5; height: 84
                            Rectangle { visible: index > 0; width: 1; height: 44; anchors.verticalCenter: parent.verticalCenter; color: root.inkMain; opacity: 0.1 }
                            Column { x: index > 0 ? 24 : 0; anchors.verticalCenter: parent.verticalCenter; spacing: 5; width: parent.width - 32
                                Small { text: modelData[0]; font.pixelSize: 14 }
                                Body { text: modelData[1]; font.pixelSize: 17; font.weight: Font.DemiBold; width: parent.width; elide: Text.ElideRight } }
                        }
                    }
                }
                Rectangle { width: root.cw; height: 1; color: root.inkMain; opacity: 0.1 }
                Item { width: 1; height: 48 }
                Item {
                    width: root.cw + root.m; height: (appPage.a?.shots?.length ?? 0) > 0 ? 380 : 0
                    visible: height > 0; clip: true
                    Flickable {
                        anchors.fill: parent; contentWidth: shotRow.width + root.m; contentHeight: height
                        flickableDirection: Flickable.HorizontalFlick; boundsBehavior: Flickable.StopAtBounds
                        Row { id: shotRow; spacing: 20
                            Repeater { model: appPage.a?.shots ?? []
                                EdgePic { required property var modelData; width: 600; height: 376; r: 16; src: modelData.path; lx: 0.5; ly: 0.3; edgeLight: false } } }
                    }
                }
                Item { width: 1; height: 56 }
                Row {
                    spacing: 72
                    Column { width: (root.cw - 72) * 0.58; spacing: 14
                        Kicker { visible: (appPage.a?.description?.length ?? 0) > 0; text: "About" }
                        Body { width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.35; font.pixelSize: 18; color: root.inkSec; text: (appPage.a?.description ?? []).join("\n\n") } }
                    Column { width: (root.cw - 72) * 0.42; spacing: 14; visible: (appPage.a?.whatsNew?.length ?? 0) > 0
                        Kicker { text: `What's new in ${appPage.a?.version ?? ""}` }
                        Body { width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.35; font.pixelSize: 16; color: root.inkSec; maximumLineCount: 9; elide: Text.ElideRight; text: (appPage.a?.whatsNew ?? []).join(" ") } }
                }
                Item { width: 1; height: 28 }
                Word { visible: !!appPage.a?.homepage; text: "Its website"; glyph: "open_in_new"; onPicked: Qt.openUrlExternally(appPage.a.homepage) }
            }

            // ---- Your apps: every app from here on this computer, as a list, with Remove beside each
            Column {
                id: yoursPage
                visible: root.page === "yours"
                x: root.m; width: root.cw
                readonly property var list: (root.home?.installed ?? []).map(p => root.appOf(p)).filter(x => x)
                PageHead { kicker: "On this computer"; title: "Your apps"
                    line: yoursPage.list.length ? "Apps from here that are on this computer. They update with Tacit's system updates." : "None yet. Apps you get here are listed here." }
                Item { width: 1; height: 56 }
                Repeater {
                    model: yoursPage.list
                    ListRow { required property var modelData; a: modelData; removable: true; width: Math.min(root.cw, 1100) }
                }
            }
        }
    }
    }   // contentLayer

    IpcHandler {
        target: "store"
        function present(): void { root.visible = true; root.raise(); root.requestActivate(); }
        function page(name: string): void { if (name === "yours") root.go("yours"); else { root.history = []; root.page = "discover"; } present(); }
        function search(words: string): void { field.text = words; root.runSearch(words); present(); }
        function state(): string { return JSON.stringify({ page: root.page, loaded: !!root.home, work: root.work, outcome: root.outcome }); }
    }

    // ---- STORE_RENDER=<dir>: the pages with real data, saved as pictures, then quit (for checking the look)
    property int renderStep: 0
    Timer {
        running: root.renderDir !== "" && !!root.home
        interval: 6000; repeat: true
        onTriggered: {
            const steps = [
                () => { root.page = "discover"; issueView.contentY = 0; },
                () => { issueView.contentY = root.height; },
                () => { issueView.contentY = 2 * root.height; },
                () => { issueView.contentY = 3 * root.height; },
                () => { issueView.contentY = 4 * root.height; },
                () => { issueView.contentY = 0; field.forceActiveFocus(); },
                () => { field.focus = false; root.openJob(root.home.jobs[0]); },
                () => { field.text = "call family"; root.runSearch("call family"); },
                () => root.openApp("krita"),
                () => root.get("krita"),
                () => { root.askUpdate = null; root.work = { pkg: "krita", kind: "install", progress: 0.43, phase: "Downloading updates 61 of 158" }; },
                () => { root.work = null; root.openApp("pinta"); },
                () => { field.text = ""; root.history = []; root.go("yours"); }
            ];
            const next = () => { if (root.renderStep >= steps.length) { Qt.quit(); return; } steps[root.renderStep](); root.renderStep++; };
            if (root.renderStep === 0) { next(); return; }
            const n = String(root.renderStep).padStart(2, "0");
            canvas.grabToImage(g => { g.saveToFile(`${root.renderDir}/${n}.png`); next(); });
        }
    }
}
