//@ pragma UseQApplication
//@ pragma AppId tacit-setup
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic

// Tacit's setup: from the USB stick to the first desktop. Design: ~/Pictures/Martida/tacit-setup-mocks-2026-10-08
// (v8, after five reviews and a final round). Every screen keeps the same lines - headline top 200, controls top
// 360, the main action's top 720 and centred - so a step changes in place; the horizon (a render from the
// trailer's renderer) is the progress, one step brighter per screen.
//
// PRACTICE ONLY for now (scripts/setup/setupd.py): the computer is read - Wi-Fi, disks, power, keyboards - and the
// install is played, but nothing is written to a disk, no network is joined and no account is made. The real install
// needs a Tacit system image to copy (release plan steps 1-2).
//
//   qs -p setup.qml                          full screen, as on the stick
//   TACIT_SETUP_WINDOWED=1 qs -p setup.qml   in a window, to look at it on the desktop
//   TACIT_SETUP_SCENARIO=windows|bitlocker|full|empty|linux, TACIT_SETUP_FAIL=1   cases this computer does not have

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import qs.modules.setup

ApplicationWindow {
    id: root
    visible: true
    title: "Tacit setup"
    color: "black"
    readonly property bool windowed: (Quickshell.env("TACIT_SETUP_WINDOWED") ?? "") === "1"
    width: windowed ? 1440 : (screen?.width ?? 1920)
    height: windowed ? 810 : (screen?.height ?? 1080)
    visibility: windowed ? Window.Windowed : Window.FullScreen
    // a window opened over it on the stick (a key that starts the terminal) takes the full screen away (Hyprland's
    // on_focus_under_fullscreen), and the practice run's rule then made Setup a card: it takes it back when in front again
    onActiveChanged: if (active && !windowed && visibility !== Window.FullScreen) visibility = Window.FullScreen
    Binding { target: Quickshell; property: "watchFiles"; value: false }
    Binding { target: Look; property: "u"; value: Math.min(root.width / 1920, root.height / 1080) }
    Component.onCompleted: MaterialThemeLoader.reapplyTheme()
    // ask until it answers: a request written before the service has started is lost
    Timer { interval: 300; repeat: true; running: !backend.ready; triggeredOnStart: true; onTriggered: if (proc.running) backend.send({ op: "hello" }) }

    // ── what the computer says (scripts/setup/setupd.py)
    QtObject {
        id: backend
        property var languages: []
        property var layouts: []
        property bool wired: false      // a cable connects this computer (no Wi-Fi needed)
        property var wifi: []
        property var disk: ({})
        property var plan: null
        property var disks: []          // every disk inside, when there is more than one to choose from
        property var power: ({ ac: true })
        property string scenario: ""
        property bool ready: false
        property bool practice: true        // false on Tacit's live system: the install is real
        function send(o) { proc.write(JSON.stringify(o) + "\n"); }
    }
    Process {
        id: proc
        running: true
        command: ["python3", "-I", Quickshell.shellPath("scripts/setup/setupd.py")]
        stdinEnabled: true
        stdout: SplitParser { onRead: line => root.receive(line) }
    }
    function receive(line) {
        let m;
        try { m = JSON.parse(line); } catch (e) { return; }
        if (m.ev === "hello") {
            backend.languages = m.languages; backend.layouts = m.layouts; backend.wifi = m.wifi; backend.wired = m.wired === true;
            backend.disk = m.disk; backend.plan = m.plan; backend.power = m.power; backend.scenario = m.scenario;
            backend.disks = m.disks ?? [];
            backend.practice = m.practice !== false;
            backend.ready = true;
            if (setup.language === "") { setup.language = m.languages[0].code; setup.layout = m.languages[0].layout; }
            const here = m.wifi.find(w => w.inUse);
            if (here) setup.network = here.ssid;
        } else if (m.ev === "wifi") { backend.wifi = m.wifi; backend.wired = m.wired === true; }
        else if (m.ev === "disk") { backend.disk = m.disk; backend.plan = m.plan; setup.place = "next"; }
        else if (m.ev === "power") backend.power = m.power;
        else if (m.ev === "join") {
            setup.joining = false;
            if (m.ok) { setup.joined = m.ssid; setup.joinError = ""; setup.go("where"); }
            else setup.joinError = "That password didn't work. Check it and try again.";
        } else if (m.ev === "install") {
            setup.installDone = m.done; setup.installLeft = m.left ?? -1; setup.installState = m.state;
            if (m.other) setup.otherSystem = m.other;
            if (m.state === "failed") setup.installUntouched = m.untouched !== false;
            if (m.state === "failed") setup.installReason = m.reason ?? "";
            if (m.state === "failed") setup.go("failed");
            else if (m.state === "done" && setup.page === "almost") setup.go("ready");
        }
    }
    Timer { interval: 10000; repeat: true; running: setup.page === "wifi"; onTriggered: backend.send({ op: "wifi" }) }

    // ── where we are, and what has been chosen
    QtObject {
        id: setup
        property string page: "welcome"
        property var trail: []
        property string language: ""
        property string layout: ""
        // the live system types in the layout chosen, so a password made here is typed the same at the installed
        // system's lock (which reads the layout tacit-install writes); not in the practice run, which runs on this desktop
        onLayoutChanged: if (!backend.practice && /^[a-z]{2,8}$/.test(layout))
            Quickshell.execDetached(["hyprctl", "eval", `hl.config({ input = { kb_layout = "${layout}" } })`])
        property string installReason: ""   // what stopped an install, in the installer's words
        property string network: ""
        property string joined: ""
        property bool joining: false
        property string joinError: ""
        property string place: "next"          // next | instead
        property string otherSystem: ""        // Windows on another disk, still chosen with Space (tacit-install)
        property string picture: "dune"
        property bool reports: false
        property real installDone: 0
        property int installLeft: -1
        property bool installUntouched: true
        property string installState: ""
        readonly property bool installing: installState === "running" || installState === "done"
        function go(p) { trail = trail.concat([page]); page = p; }
        function back() {
            if (installing || trail.length === 0) return;
            const t = trail.slice(); page = t.pop(); trail = t;
        }
        function startInstall() { backend.send({ op: "install", place: place }); installState = "running"; trail = []; go("you"); }
        readonly property var lang: backend.languages.find(l => l.code === language) ?? null
        readonly property var layoutName: (backend.layouts.find(l => l.code === layout) ?? { name: layout }).name
    }
    readonly property int step: ({ welcome: 1, languages: 1, keyboards: 1, wifi: 2, where: 3, disks: 3, erase: 3, you: 4, privacy: 5, almost: 6, ready: 7, failed: 3 })[setup.page] ?? 1

    // a page switch: the new words come in where the old ones were, rising a little
    property string shownPage: "welcome"
    Connections {
        target: setup
        function onPageChanged() { swapOut.restart(); }
    }
    SequentialAnimation {
        id: swapOut
        NumberAnimation { target: content; property: "opacity"; to: 0; duration: Look.lessMotion ? 80 : 140; easing.type: Easing.InCubic }
        ScriptAction { script: { root.shownPage = setup.page; content.y = Look.lessMotion ? 0 : Look.px(10); root.focusFirst(); } }
        ParallelAnimation {
            NumberAnimation { target: content; property: "opacity"; to: 1; duration: Look.lessMotion ? 120 : 320; easing.type: Easing.OutCubic }
            NumberAnimation { target: content; property: "y"; to: 0; duration: Look.lessMotion ? 0 : 420; easing.type: Easing.OutCubic }
        }
    }
    function focusFirst() {
        Qt.callLater(() => {
            if (root.shownPage === "you") nameField.focusIn();
            else if (root.shownPage === "wifi" && root.pwFieldRef) root.pwFieldRef.focusIn();
            else primary.forceActiveFocus();
        });
    }

    Item {
        id: shot
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: { if (a11y.open) a11y.open = false; else setup.back(); }

        Ground { anchors.fill: parent; step: root.step; lessMotion: Look.lessMotion }

        // the design is 1920 x 1080; everything inside scales with Look.u, centred on any screen
        Item {
            id: stage
            width: Look.px(1920); height: Look.px(1080)
            anchors.centerIn: parent

            // practice: said where a tester sees it, never in the way
            T { visible: backend.practice; x: Look.px(48); y: Look.px(58); text: "Practice run · nothing is installed"; font.pixelSize: Look.fs(14); color: Look.meta }

            // while it installs: one quiet line at the top, on the dark sky
            T {
                visible: setup.installing && ["you", "privacy", "almost"].includes(root.shownPage)
                x: (stage.width - width) / 2; y: Look.px(62)
                text: setup.installLeft < 0 ? "Installing" : `Installing · about ${Math.max(1, Math.round(setup.installLeft / 60))} ${Math.round(setup.installLeft / 60) <= 1 ? "minute" : "minutes"} left`
                font.pixelSize: Look.fs(17); color: Look.sec
            }

            Item {
                id: content
                width: stage.width; height: stage.height

                // ── welcome
                Item {
                    visible: root.shownPage === "welcome"
                    anchors.fill: parent
                    T { x: (parent.width - width) / 2 + Look.px(14); y: Look.px(196); text: "TACIT"; font.family: Look.display; font.pixelSize: Look.fs(60); font.weight: Font.Light; font.variableAxes: { "wght": 300 }; font.letterSpacing: Look.px(28) }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(330); width: Look.px(600)
                        Repeater {
                            model: backend.languages.slice(0, 5)
                            Item {
                                id: langRow
                                required property var modelData
                                readonly property bool on: modelData.code === setup.language
                                width: Look.px(600); height: Look.px(50)
                                activeFocusOnTab: true
                                Keys.onReturnPressed: root.pickLanguage(modelData)
                                Keys.onSpacePressed: root.pickLanguage(modelData)
                                T {
                                    anchors.centerIn: parent
                                    text: langRow.modelData.name
                                    font.pixelSize: langRow.on ? Look.fs(30) : Look.fs(24)
                                    font.weight: langRow.on || langRow.activeFocus ? Font.Medium : Font.Normal
                                    color: langRow.on || langRow.activeFocus || lma.containsMouse ? Look.main : Look.meta
                                }
                                MouseArea { id: lma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickLanguage(langRow.modelData) }
                            }
                        }
                        Item { width: 1; height: Look.px(10) }
                        Link { anchors.horizontalCenter: parent.horizontalCenter; glyph: "language"; text: "More languages ›"; onClicked: setup.go("languages") }
                    }
                    Link { x: (parent.width - width) / 2; y: Look.px(646); text: `Keyboard: ${setup.layoutName}  ›`; bright: true; onClicked: setup.go("keyboards") }
                }

                // ── a long list to pick from: every language, or every keyboard
                Item {
                    visible: root.shownPage === "languages" || root.shownPage === "keyboards"
                    anchors.fill: parent
                    readonly property bool langs: root.shownPage === "languages"
                    Headline { text: parent.langs ? "Choose a language." : "Choose a keyboard." }
                    Sentence { text: parent.langs ? "Everything after this is in it." : "Type a few letters to find yours." }
                    Rectangle {
                        visible: !parent.langs
                        x: (parent.width - width) / 2; y: Look.px(340); width: Look.px(600); height: Look.px(56); radius: Look.px(18)
                        color: Qt.rgba(1, 1, 1, filter.activeFocus ? 0.10 : 0.06)
                        TextInput { id: filter; x: Look.px(26); anchors.verticalCenter: parent.verticalCenter; width: parent.width - Look.px(52)
                            color: Look.main; font.family: Appearance.font.family.main; font.pixelSize: Look.fs(21); activeFocusOnTab: true
                            cursorDelegate: Rectangle { width: 2; color: Look.light; visible: filter.activeFocus }
                            // the page says "Type a few letters": the keys go here as it opens (they went nowhere)
                            Connections { target: root; function onShownPageChanged() { if (root.shownPage === "keyboards") filter.forceActiveFocus() } } }
                        T { visible: filter.text === ""; x: Look.px(26); anchors.verticalCenter: parent.verticalCenter; text: "Search"; font.pixelSize: Look.fs(20); color: Look.meta }
                    }
                    ListView {
                        id: pick
                        x: (parent.width - width) / 2; y: parent.langs ? Look.px(352) : Look.px(410)
                        width: Look.px(600); height: Look.px(680) - y
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: parent.langs ? backend.languages
                             : backend.layouts.filter(l => filter.text === "" || l.name.toLowerCase().includes(filter.text.toLowerCase()) || l.code.startsWith(filter.text.toLowerCase()))
                        delegate: Item {
                            id: pr
                            required property var modelData
                            readonly property bool on: root.shownPage === "languages" ? modelData.code === setup.language : modelData.code === setup.layout
                            width: pick.width; height: Look.px(48)
                            activeFocusOnTab: true
                            Keys.onReturnPressed: root.pickFrom(modelData)
                            T { x: Look.px(44); anchors.verticalCenter: parent.verticalCenter; text: pr.modelData.name; font.pixelSize: Look.fs(21)
                                font.weight: pr.on || pr.activeFocus ? Font.Medium : Font.Normal; color: pr.on || pr.activeFocus || pma.containsMouse ? Look.main : Look.meta }
                            Rectangle { visible: pr.on; anchors.verticalCenter: parent.verticalCenter; x: Look.px(6); width: Look.px(10); height: width; radius: width / 2; color: Look.light }
                            MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickFrom(pr.modelData) }
                        }
                    }
                }

                // ── the internet
                Item {
                    visible: root.shownPage === "wifi"
                    anchors.fill: parent
                    Headline { text: "Connect to the internet." }
                    Sentence { text: "Tacit uses it to set the clock and look for updates. You can connect later." }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(360); width: Look.px(600)
                        Repeater {
                            // four, so an open password field never reaches the buttons
                            model: backend.wifi.slice(0, 4)
                            Column {
                                id: net
                                required property var modelData
                                readonly property bool on: modelData.ssid === setup.network
                                width: Look.px(600)
                                Item {
                                    width: Look.px(600); height: Look.px(52)
                                    activeFocusOnTab: true
                                    Keys.onReturnPressed: root.pickNetwork(net.modelData)
                                    MaterialSymbol { anchors.verticalCenter: parent.verticalCenter; iconSize: Look.fs(24)
                                        text: net.modelData.signal > 66 ? "wifi" : net.modelData.signal > 33 ? "wifi_2_bar" : "wifi_1_bar"; color: net.on ? Look.main : Look.meta }
                                    T { x: Look.px(44); anchors.verticalCenter: parent.verticalCenter; text: net.modelData.ssid; font.pixelSize: Look.fs(22)
                                        font.weight: net.on || parent.activeFocus ? Font.DemiBold : Font.Normal; color: net.on || parent.activeFocus || nma.containsMouse ? Look.main : Look.meta }
                                    T { visible: net.modelData.inUse; anchors.right: parent.right; anchors.rightMargin: Look.px(20); anchors.verticalCenter: parent.verticalCenter
                                        text: "Connected"; font.pixelSize: Look.fs(16); color: Look.sec }
                                    MaterialSymbol { visible: net.modelData.secure && !net.modelData.inUse; anchors.right: parent.right; anchors.rightMargin: Look.px(20); anchors.verticalCenter: parent.verticalCenter
                                        text: "lock"; iconSize: Look.fs(18); color: Look.meta }
                                    MouseArea { id: nma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickNetwork(net.modelData) }
                                }
                                Loader {
                                    active: net.on && net.modelData.secure && !net.modelData.inUse
                                    visible: active
                                    sourceComponent: Column {
                                        width: Look.px(600)
                                        Field {
                                            id: pwField
                                            width: Look.px(600)
                                            label: `Password for ${net.modelData.ssid}`
                                            secret: true
                                            layout: setup.layout
                                            error: setup.joinError
                                            onAccepted: root.forward()
                                            Component.onCompleted: { root.pwFieldRef = pwField; pwField.focusIn(); }
                                        }
                                        Item { width: 1; height: Look.px(14) }
                                    }
                                }
                            }
                        }
                        T { visible: backend.wifi.length === 0; text: backend.wired ? "Connected by cable." : "No networks found. You can connect later."; font.pixelSize: Look.fs(19); color: Look.sec }
                    }
                }

                // ── where Tacit goes
                Item {
                    visible: root.shownPage === "where"
                    anchors.fill: parent
                    readonly property string c: backend.disk.case ?? "none"
                    readonly property bool room: backend.plan?.room ?? false
                    readonly property bool locked: c === "bitlocker" || c === "asleep"
                    readonly property string size: `${Math.round((backend.disk.size ?? 0) / 1e9)} GB`
                    Headline {
                        text: parent.c === "bitlocker" ? "Windows is locked."
                            : parent.c === "asleep" && backend.disk.why === "check" ? "Windows has a disk check waiting."
                            : parent.c === "asleep" && backend.disk.why === "other" ? "Tacit can't read the Windows disk yet."
                            : parent.c === "asleep" ? "Windows didn't shut down fully."
                            : parent.c === "windows" && !parent.room && backend.plan ? "There is no room next to Windows."
                            : parent.c === "none" ? "There is no disk to install on."
                            : parent.c === "empty" ? "Tacit will use the whole disk."
                            : "Where should Tacit go?"
                    }
                    Sentence {
                        text: parent.c === "bitlocker" ? "This disk is locked with BitLocker, so Tacit can't make room next to Windows. Start Windows, turn BitLocker off in Settings, then start from this USB stick again."
                            : parent.c === "asleep" && backend.disk.why === "check" ? "Windows marked its disk to be checked, so Tacit can't make room next to it yet. Start Windows and restart it twice so the check runs, then shut it down and start from this USB stick again."
                            : parent.c === "asleep" && backend.disk.why === "other" ? `Tacit can't make room next to Windows until it can read the disk safely. Start Windows, restart it, shut it down, then start from this USB stick again. The disk said: “${backend.disk.says}”`
                            : parent.c === "asleep" ? "Windows is paused rather than shut down, so Tacit can't make room next to it yet. Start Windows, hold Shift while you choose Shut down, then start from this USB stick again."
                            : parent.c === "windows" && backend.plan && !parent.room ? `Windows and your files use ${Math.round(backend.disk.used / 1e9)} GB of the ${parent.size} disk. Free up space in Windows, or install instead of Windows.`
                            : parent.c === "windows" && backend.plan ? `This computer has Windows on its ${parent.size} disk, with ${Math.round(backend.disk.used / 1e9)} GB in use.`
                            : parent.c === "windows" ? `This computer has Windows on its ${parent.size} disk.`
                            : parent.c === "linux" ? `This computer has Linux on its ${parent.size} disk.`
                            : parent.c === "empty" && root.windowsElsewhere ? `This ${parent.size} disk is empty. Windows, on the other disk, stays as it is.`
                            : parent.c === "empty" ? `This computer's ${parent.size} disk is empty.`
                            : parent.c === "none" ? "Tacit found no disk inside this computer. The USB stick it runs from can't be used."
                            : `This computer's disk is ${parent.size}.`
                    }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(360); width: Look.px(600)
                        spacing: Look.px(30)
                        Choice {
                            visible: parent.parent.room
                            width: Look.px(600)
                            name: root.other === "it" ? "Next to what is on it" : `Next to ${root.other}`; on: setup.place === "next"
                            detail: (root.other === "Windows" ? "Your Windows files stay as they are. " : "Everything on this disk stays as it is. ")
                                    + (backend.plan?.windowsKeeps ? `Windows keeps ${Math.round(backend.plan.windowsKeeps / 1e9)} GB, Tacit gets ${Math.round(backend.plan.tacitGets / 1e9)} GB.`
                                                                  : `Tacit uses the ${Math.round((backend.plan?.tacitGets ?? 0) / 1e9)} GB of free space.`)
                                    + (root.other === "it" ? "" : ` To use ${root.other}, hold the Space bar while the computer starts.`)
                            onPicked: setup.place = "next"
                        }
                        // one way only (an empty disk) is no choice: the headline says it
                        Choice {
                            visible: parent.parent.c !== "none" && !parent.parent.locked && parent.parent.c !== "empty"
                            width: Look.px(600)
                            name: parent.parent.c === "windows" ? "Instead of Windows" : parent.parent.c === "empty" ? "Use the whole disk" : "Instead of what is on it"
                            on: setup.place === "instead" || !parent.parent.room
                            detail: parent.parent.c === "empty" ? "" : parent.parent.c === "windows" ? "Windows and every file on this disk will be erased." : "Everything on this disk will be erased."
                            onPicked: setup.place = "instead"
                        }
                        T {
                            visible: !(backend.power.ac ?? true) && parent.parent.c !== "none" && !parent.parent.locked
                            width: Look.px(600); wrapMode: Text.Wrap
                            horizontalAlignment: parent.parent.c === "empty" ? Text.AlignHCenter : Text.AlignLeft
                            text: "Plug in the charger. Installing takes about 10 minutes."
                            font.pixelSize: Look.fs(17); color: Look.sec
                        }
                    }

                    // with more than one disk inside: which one, as the first page names the keyboard
                    Link { visible: backend.disks.length > 1; x: (parent.width - width) / 2; y: Look.px(646); bright: true
                        text: `Disk: ${root.diskName(backend.disk)}  ›`; onClicked: setup.go("disks") }
                }

                // ── the disks inside, to choose from (Setup took the biggest until 2026-10-18)
                Item {
                    visible: root.shownPage === "disks"
                    anchors.fill: parent
                    Headline { text: "Choose a disk." }
                    Sentence { text: "Tacit goes on the one you choose. Nothing changes until you install." }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(352); width: Look.px(600)
                        Repeater {
                            model: backend.disks
                            delegate: Item {
                                id: dr
                                required property var modelData
                                readonly property bool on: modelData.name === backend.disk.name
                                width: Look.px(600); height: Look.px(56)
                                activeFocusOnTab: true
                                Keys.onReturnPressed: root.pickDisk(modelData)
                                T { x: Look.px(44); anchors.verticalCenter: parent.verticalCenter; text: root.diskName(dr.modelData); font.pixelSize: Look.fs(21)
                                    font.weight: dr.on || dr.activeFocus ? Font.Medium : Font.Normal; color: dr.on || dr.activeFocus || dma.containsMouse ? Look.main : Look.meta }
                                T { anchors.right: parent.right; anchors.rightMargin: Look.px(20); anchors.verticalCenter: parent.verticalCenter
                                    text: root.diskHolds(dr.modelData); font.pixelSize: Look.fs(16); color: Look.sec }
                                Rectangle { visible: dr.on; anchors.verticalCenter: parent.verticalCenter; x: Look.px(6); width: Look.px(10); height: width; radius: width / 2; color: Look.light }
                                MouseArea { id: dma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickDisk(dr.modelData) }
                            }
                        }
                    }
                }

                // ── erase, said once more
                Item {
                    visible: root.shownPage === "erase"
                    anchors.fill: parent
                    Headline { text: "Erase this disk?" }
                    Sentence { text: (backend.disk.case === "windows" ? "Windows and every file" : "Everything") + " on this disk will be erased. This can't be undone." }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(360); width: Look.px(600); spacing: Look.px(10)
                        T { anchors.horizontalCenter: parent.horizontalCenter; text: `${backend.disk.model ?? "This disk"} · ${Math.round((backend.disk.size ?? 0) / 1e9)} GB`; font.pixelSize: Look.fs(22) }
                        T { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; font.pixelSize: Look.fs(18); color: Look.sec
                            text: backend.disk.case === "windows" ? "To keep any files, restart into Windows and copy them to a USB drive first." : "To keep any files, copy them somewhere else first." }
                    }
                }

                // ── you
                Item {
                    visible: root.shownPage === "you"
                    anchors.fill: parent
                    Headline { text: "Who will use this computer?" }
                    Sentence { text: "You can add other people later." }
                    Column {
                        x: (parent.width - width) / 2; y: Look.px(360); width: Look.px(600)
                        Row {
                            spacing: (Look.px(600) - 6 * Look.px(58)) / 5
                            Repeater {
                                model: ["dune", "terracotta", "moss", "copper", "basalt", "marble"]
                                Planet { required property string modelData; name: modelData; on: setup.picture === modelData; onPicked: setup.picture = modelData }
                            }
                        }
                        Item { width: 1; height: Look.px(12) }
                        T { anchors.horizontalCenter: parent.horizontalCenter; text: "Your picture, shown when the computer starts"; font.pixelSize: Look.fs(16); color: Look.meta }
                        Item { width: 1; height: Look.px(22) }
                        Field { id: nameField; width: Look.px(600); label: "Your name"; onAccepted: passField.focusIn() }
                        Item { width: 1; height: Look.px(8) }
                        Field { id: passField; width: Look.px(600); label: "Password for this computer"; secret: true; layout: setup.layout; onAccepted: againField.focusIn() }
                        Item { width: 1; height: Look.px(8) }
                        Field {
                            id: againField; width: Look.px(600); label: "Type it again"; secret: true; layout: setup.layout
                            error: text !== "" && passField.text !== "" && text !== passField.text && text.length >= passField.text.length ? "The two passwords are different." : ""
                            onAccepted: root.forward()
                        }
                    }
                }

                // ── reports
                Item {
                    visible: root.shownPage === "privacy"
                    anchors.fill: parent
                    Headline { text: "Send a report when something breaks?" }
                    Sentence { text: "If an update fails or an app closes by itself, Tacit can send the Tacit team a short report: what went wrong, the Tacit version and the computer model. It never includes your files, what you type or what you open." }
                    T { x: (parent.width - width) / 2; y: Look.px(792); text: "You can change this in Settings."; font.pixelSize: Look.fs(16); color: Look.meta }
                }

                // ── almost, ready, stopped
                Item {
                    visible: ["almost", "ready", "failed"].includes(root.shownPage)
                    anchors.fill: parent
                    Headline { text: root.shownPage === "almost" ? "Almost done." : root.shownPage === "ready" ? "Tacit is ready." : "Tacit didn't finish installing." }
                    // what stopped it, in the installer's words (all of it in /tmp/tacit-install.log on the live system)
                    T {
                        visible: root.shownPage === "failed" && setup.installReason !== ""
                        x: (parent.width - width) / 2; y: Look.px(430); width: Look.px(780)
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                        text: `What stopped it: ${setup.installReason}.`
                        font.pixelSize: Look.fs(16); color: Look.meta
                    }
                    Sentence {
                        text: root.shownPage === "almost" ? "Tacit is finishing on its own. Keep the computer on and the USB stick in."
                            : root.shownPage === "ready" ? ("Restart now. When the screen goes dark, take out the USB stick." + (setup.place === "next" && root.other !== "it" ? ` To use ${root.other}, hold the Space bar while the computer starts.`
                                                                                                                                : setup.otherSystem !== "" ? ` To use ${setup.otherSystem}, hold the Space bar while the computer starts.` : ""))
                            : setup.installUntouched ? "Nothing on the disk was changed, so the computer starts as before. You can try again."
                            : setup.place === "next" ? `Tacit stopped partway. ${root.other === "it" ? "What was on the disk" : root.other} should start as before${root.other === "Windows" ? ", after it checks its disk" : ""}. You can try again.`
                            : "Tacit stopped partway, after the disk was erased. You can try again."
                    }
                }
            }

            // ── the way forward: the main action's top at 720; the other way to its left, the two centred as a pair (the
            // main action alone at the centre left the pair off it, 2026-10-17)
            Act {
                id: primary
                visible: root.shownPage !== "almost" && root.shownPage !== "privacy" && root.shownPage !== "languages" && root.shownPage !== "keyboards" && root.shownPage !== "disks"
                x: (stage.width - width + (otherWay.visible ? otherWay.width + Look.px(18) : 0)) / 2; y: Look.px(720)
                text: root.primaryText
                later: root.primaryLater
                onClicked: root.forward()
            }
            Quiet {
                id: otherWay
                // on the stick's first screen: Tacit as it is, without installing it (Discord 2026-10-24: people did not
                // know they could, and Setup covered the desktop)
                readonly property bool tryFirst: root.shownPage === "welcome" && !backend.practice && !root.windowed
                visible: tryFirst || ["wifi", "where", "erase"].includes(root.shownPage)
                x: primary.x - width - Look.px(18); y: Look.px(724)
                text: tryFirst ? "Try Tacit first" : root.shownPage === "wifi" ? "Not now" : "Back"
                onClicked: tryFirst ? root.tryTacitFirst() : root.shownPage === "wifi" ? setup.go("where") : setup.back()
            }
            Quiet {
                visible: root.shownPage === "languages" || root.shownPage === "keyboards" || root.shownPage === "disks"
                x: (stage.width - width) / 2; y: Look.px(724)
                text: "Back"
                onClicked: setup.back()
            }
            // a real choice: two equal rings either side of the centre
            Row {
                visible: root.shownPage === "privacy"
                x: (stage.width - width) / 2; y: Look.px(720)
                spacing: Look.px(18)
                Act { width: Look.px(240); text: "Don't send"; onClicked: { setup.reports = false; root.afterQuestions(); } }
                Act { width: Look.px(240); text: "Send reports"; onClicked: { setup.reports = true; root.afterQuestions(); } }
            }

            // accessibility, before any language is chosen
            Item {
                id: a11y
                property bool open: false
                x: stage.width - Look.px(100); y: Look.px(48); width: Look.px(52); height: width
                activeFocusOnTab: true
                Keys.onReturnPressed: open = !open
                Rectangle { anchors.fill: parent; radius: width / 2; color: Qt.rgba(1, 1, 1, a11y.activeFocus || a11y.open ? 0.09 : ama.containsMouse ? 0.05 : 0); border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.42) }
                Text { anchors.centerIn: parent; text: "accessibility_new"; font.family: "Material Symbols Rounded"; font.pixelSize: Look.fs(28); color: Look.sec }
                MouseArea { id: ama; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: a11y.open = !a11y.open }
            }
            Column {
                visible: a11y.open
                x: stage.width - Look.px(48) - width; y: Look.px(116); width: Look.px(300)
                spacing: Look.px(4)
                Repeater {
                    model: [{ t: "Larger text", on: Look.text > 1, f: () => Look.text = Look.text > 1 ? 1 : 1.25 },
                            { t: "Less motion", on: Look.lessMotion, f: () => Look.lessMotion = !Look.lessMotion }]
                    Item {
                        id: opt
                        required property var modelData
                        width: Look.px(300); height: Look.px(48)
                        activeFocusOnTab: true
                        Keys.onReturnPressed: modelData.f()
                        T { anchors.verticalCenter: parent.verticalCenter; text: opt.modelData.t; font.pixelSize: Look.fs(19); color: opt.activeFocus || oma.containsMouse ? Look.main : Look.sec }
                        Rectangle {
                            anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            width: Look.px(44); height: Look.px(26); radius: height / 2; color: "transparent"; border.width: 1
                            border.color: opt.modelData.on ? Qt.rgba(0.95, 0.77, 0.60, 0.85) : Qt.rgba(1, 1, 1, 0.42)
                            Rectangle { x: opt.modelData.on ? parent.width - width - Look.px(4) : Look.px(4); anchors.verticalCenter: parent.verticalCenter
                                width: Look.px(18); height: width; radius: width / 2; color: opt.modelData.on ? Look.light : Look.meta
                                Behavior on x { Anim { type: Anim.FastSpatial } } }
                        }
                        MouseArea { id: oma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: opt.modelData.f() }
                    }
                }
            }
        }
    }

    // ── small parts used by the pages above
    component Headline: T {
        x: (parent.width - width) / 2; y: Look.px(200)
        font.family: Look.display; font.pixelSize: Look.fs(52); font.weight: Font.Light; font.variableAxes: { "wght": 300 }; font.letterSpacing: 0.5
    }
    component Sentence: T {
        x: (parent.width - width) / 2; y: Look.px(282); width: Look.px(780)
        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; lineHeight: 1.3
        color: Look.sec
    }
    component Link: Item {
        id: lk
        property string text
        property string glyph: ""
        property bool bright: false
        signal clicked()
        width: lrow.width; height: Look.px(32)
        activeFocusOnTab: true
        Keys.onReturnPressed: clicked()
        Row {
            id: lrow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Look.px(8)
            MaterialSymbol { visible: lk.glyph !== ""; anchors.verticalCenter: parent.verticalCenter; text: lk.glyph; iconSize: Look.fs(20); color: lt.color }
            T { id: lt; anchors.verticalCenter: parent.verticalCenter; text: lk.text; font.pixelSize: Look.fs(17)
                font.weight: lk.activeFocus ? Font.Medium : Font.Normal; color: lk.activeFocus || lkma.containsMouse ? Look.main : lk.bright ? Look.sec : Look.meta }
        }
        MouseArea { id: lkma; anchors.fill: parent; anchors.margins: -Look.px(6); hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: lk.clicked() }
    }

    // ── what the buttons do
    property Item pwFieldRef: null
    // the system Tacit goes next to
    readonly property string other: backend.disk.case === "windows" ? "Windows" : backend.disk.case === "linux" ? "Linux" : "it"
    readonly property string primaryText: ({
        welcome: "Continue", wifi: "Continue", erase: "Erase and install", you: "Continue", ready: "Restart", failed: "Try again"
    })[shownPage] ?? (shownPage === "where" ? (["bitlocker", "asleep"].includes(backend.disk.case) ? "Restart into Windows"
                                                : backend.disk.case === "none" ? "Turn off"
                                                : (backend.plan?.room ?? false) && setup.place === "next" ? (root.other === "it" ? "Install" : `Install next to ${root.other}`)
                                                : backend.disk.case === "empty" ? "Install" : "Continue") : "Continue")
    readonly property bool primaryLater: shownPage === "you" ? (nameField.text.trim() === "" || passField.text === "" || againField.text !== passField.text)
                                       : shownPage === "wifi" ? setup.joining : false
    function pickLanguage(l) { setup.language = l.code; setup.layout = l.layout; }
    function pickFrom(item) {
        if (shownPage === "languages") { setup.language = item.code; setup.layout = item.layout; }
        else setup.layout = item.code;
        setup.back();
    }
    function pickNetwork(n) { setup.network = n.ssid; setup.joinError = ""; }
    // a disk in words: its name and size, and what is on it
    function diskName(d) { return `${d.model ?? "Disk"} · ${Math.round((d.size ?? 0) / 1e9)} GB`; }
    function diskHolds(d) {
        return ({ windows: "Windows", asleep: "Windows", bitlocker: "Windows, with BitLocker", linux: "Linux", empty: "Empty" })[d.case] ?? "Other files";
    }
    readonly property bool windowsElsewhere: backend.disks.some(d => d.name !== backend.disk.name && ["windows", "asleep", "bitlocker"].includes(d.case))
    function pickDisk(d) {
        backend.disk = d; backend.plan = d.plan; setup.place = "next";
        backend.send({ op: "disk", name: d.name });
        setup.back();
    }
    function forward() {
        switch (shownPage) {
        case "welcome": setup.go("wifi"); break;
        case "wifi": {
            const n = backend.wifi.find(w => w.ssid === setup.network);
            if (!n || n.inUse || setup.joined === n.ssid) { setup.go("where"); break; }
            setup.joining = true; setup.joinError = "";
            backend.send({ op: "join", ssid: n.ssid, secure: n.secure, password: root.pwFieldRef?.text ?? "" });
            break;
        }
        case "where": {
            const c = backend.disk.case ?? "none";
            // "Restart into Windows" and "Turn off" do that on the stick (they only closed Setup there)
            if (c === "bitlocker" || c === "asleep" || c === "none") {
                if (backend.practice) root.endPractice();
                else backend.send({ op: c === "none" ? "off" : "restart" });
                break;
            }
            if ((backend.plan?.room ?? false) && setup.place === "next") setup.startInstall();
            else if (c === "empty") { setup.place = "instead"; setup.startInstall(); }
            else { setup.place = "instead"; setup.go("erase"); }
            break;
        }
        case "erase": setup.startInstall(); break;
        case "you": if (!root.primaryLater) setup.go("privacy"); break;
        case "ready": if (backend.practice) root.endPractice(); else backend.send({ op: "restart" }); break;
        case "failed": setup.installState = ""; setup.trail = []; setup.page = "where"; break;
        }
    }
    function afterQuestions() {
        backend.send({ op: "answers", language: setup.language, layout: setup.layout, network: setup.joined || setup.network,
                       place: setup.place, name: nameField.text.trim(), password: passField.text, picture: setup.picture, reports: setup.reports });
        setup.go(setup.installState === "done" ? "ready" : "almost");
    }
    // Setup steps aside on the stick and says once how to come back: the launcher's Install Tacit (the ISO's
    // tacit-setup.desktop) opens it again
    function tryTacitFirst() {
        Quickshell.execDetached(["notify-send", "-a", "Tacit", "Trying Tacit",
                                 "Nothing is installed. To install it, press Super and open Install Tacit."]);
        Qt.quit();
    }
    function endPractice() { if (root.walk) console.info("WALK end"); Qt.quit(); }

    // ── a scripted walk through the flow (TACIT_SETUP_WALK=1): each step's page, printed, for a quick check
    readonly property bool walk: (Quickshell.env("TACIT_SETUP_WALK") ?? "") === "1"
    property int wi: 0
    Timer {
        interval: 700
        repeat: true
        running: root.walk && backend.ready
        onTriggered: {
            const steps = [
                () => root.forward(),                                                        // welcome -> wifi
                () => { setup.network = (backend.wifi.find(w => w.inUse) ?? backend.wifi[0] ?? {}).ssid ?? ""; root.forward(); },
                () => { setup.place = "instead"; root.forward(); },                         // where -> erase
                () => setup.back(),                                                         // erase -> where (back works)
                () => { setup.place = "next"; root.forward(); },                            // where -> you (install starts)
                () => { setup.back(); },                                                    // no way back once installing
                () => { nameField.text = "Abdul"; passField.text = "abc12345"; againField.text = "abc1234"; console.info("WALK later", root.primaryLater); againField.text = "abc12345"; root.forward(); },
                () => { setup.reports = false; root.afterQuestions(); },                    // privacy -> almost
            ];
            console.info("WALK page", setup.page, "install", setup.installState, Math.round(setup.installDone * 100) + "%");
            if (root.wi < steps.length) { steps[root.wi](); root.wi++; }
            else if (setup.page === "ready") { console.info("WALK page ready"); root.forward(); }
        }
    }

    // ── render harness: TACIT_SETUP_RENDER=<dir> draws each page once and saves it
    readonly property string renderDir: Quickshell.env("TACIT_SETUP_RENDER") ?? ""
    property var shots: [["1-welcome", "welcome"], ["1b-languages", "languages"], ["1c-keyboards", "keyboards"], ["2-internet", "wifi"],
                         ["3-where", "where"], ["3c-disks", "disks"], ["3b-erase", "erase"], ["4-you", "you"], ["5-privacy", "privacy"], ["6-almost", "almost"],
                         ["7-ready", "ready"], ["8-failed", "failed"]]
    property int si: -1
    Timer { id: quitLater; interval: 1500; onTriggered: Qt.quit() }
    Timer {
        id: renderStep
        interval: 2200
        running: root.renderDir !== ""
        onTriggered: {
            if (root.si >= 0) {
                const name = root.shots[root.si][0];     // the grab finishes after si has moved on
                shot.grabToImage(g => g.saveToFile(`${root.renderDir}/setup-${name}.png`));
            }
            root.si++;
            if (root.si >= root.shots.length) { quitLater.start(); return; }
            const pg = root.shots[root.si][1];
            if (pg === "wifi" && backend.wifi.length > 0) { setup.network = backend.wifi.find(w => w.secure && !w.inUse)?.ssid ?? setup.network; }
            if (["you", "privacy", "almost"].includes(pg)) { setup.installState = "running"; setup.installLeft = 360; }
            if (pg === "you") { nameField.text = "Abdul"; passField.text = "correct horse"; againField.text = "correct hors"; }
            setup.page = pg;
            renderStep.restart();
        }
    }
}
