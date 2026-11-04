// Tacit Mail, a design mock: the whole mail app drawn in Tacit's design language, one screen per DUNE_SURFACE.
// It runs inside Tacit's shell tree (it imports the shell's modules and Tacit.Kit); see README.md.
// DUNE_SURFACE = read | draft | switch | plain | compose | search | empty | sent | setup | importing | settings | notify | offline.
// The sample people and messages are made up; the first sample content came from lorenz's mail prototype.
import QtQuick
import QtQuick.Effects
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import Tacit.Kit as K

ShellRoot {
    id: shell
    readonly property string surface: Quickshell.env("DUNE_SURFACE") ?? "read"
    readonly property string wall: Quickshell.env("DUNE_WALL") ?? ""
    Component.onCompleted: MaterialThemeLoader.reapplyTheme()
    readonly property int sw: parseInt(Quickshell.env("DUNE_W") ?? "1920")
    readonly property int sh: parseInt(Quickshell.env("DUNE_H") ?? "1080")
    // the agent's colour: the palette's third hue, quiet; it marks the agent's work and nothing else
    // one agent hue on every wallpaper; teal instead when a wallpaper's accent sits too close to it
    readonly property real agentHue: Math.abs(Appearance.m3colors.m3primary.hslHue - 0.70) < 0.10 ? 0.48 : 0.70
    readonly property color agentInk: Qt.hsla(agentHue, 0.42, 0.76, 1)
    readonly property bool replying: surface === "draft"
    readonly property bool switching: surface === "switch"
    readonly property bool composing: surface === "compose"
    readonly property bool searching: surface === "search"
    readonly property bool emptyBox: surface === "empty"
    readonly property bool plainMsg: surface === "plain"
    readonly property bool sentNow: surface === "sent"
    readonly property bool setupNow: surface === "setup"
    readonly property bool importing: surface === "importing"
    readonly property bool settingsNow: surface === "settings"
    readonly property bool notifyNow: surface === "notify"
    readonly property bool offlineNow: surface === "offline"
    readonly property bool fullPage: setupNow || settingsNow
    // the thread on screen: Mara's (with the agent's draft) unless this state shows another
    readonly property bool maraThread: surface === "read" || surface === "draft" || surface === "switch" || surface === "sent" || surface === "offline"

    FloatingWindow {
        implicitWidth: shell.sw
        implicitHeight: shell.sh
        color: "black"
        visible: true

        Item {
            id: scene
            anchors.fill: parent
            Image { id: wallImg; anchors.fill: parent; source: "file://" + shell.wall; fillMode: Image.PreserveAspectCrop }
            MultiEffect { id: blurred; anchors.fill: parent; source: wallImg; blurEnabled: true; blur: 1.0; blurMax: 64; visible: false }

            component T: Text {
                font.letterSpacing: 0.1
                property int size: Tacit.size.row
                property int w: Tacit.weight.regular
                property color ink: Tacit.inkMain
                color: ink
                font.family: Tacit.font.main; font.pixelSize: size; font.weight: w
            }
            component Meta: T { size: Tacit.size.meta; ink: Tacit.kitInkMeta }
            component Act: T { w: Tacit.weight.medium; ink: Tacit.inkSec }
            component Sym: K.Symbol { size: 18; color: Tacit.inkSec }
            component Pill: Rectangle {
                property string text
                height: 40; width: pillText.implicitWidth + 40; radius: 20; color: Tacit.accent
                T { id: pillText; anchors.centerIn: parent; text: parent.text; w: Tacit.weight.strong; ink: Tacit.inkOnAccent }
            }
            component Avatar: Rectangle {
                property string letter
                property int s: 40
                width: s; height: s; radius: s / 2; color: Qt.rgba(1, 1, 1, 0.09)
                T { anchors.centerIn: parent; text: parent.letter; w: Tacit.weight.strong; size: parent.s > 32 ? 16 : 13; ink: Tacit.inkSec }
            }
            // the agent has no icon: its mark is the thread's tick, in its own colour
            component Mark: Item {
                property int s: 32
                width: s; height: s
                Rectangle { x: 8; anchors.verticalCenter: parent.verticalCenter; width: 17; height: 2; radius: 1; color: shell.agentInk }
            }
            // the same mark in a line of text: the thread line and its tick, small
            component AgentStroke: Item { width: 9; height: 14
                Rectangle { width: 2; height: 14; color: shell.agentInk }
                Rectangle { y: 6; width: 9; height: 2; color: shell.agentInk } }
            component Frost: Item {
                id: fr
                property real bx; property real by; property real bw; property real bh
                anchors.fill: parent
                Item { id: m; anchors.fill: parent; visible: false; layer.enabled: true
                    DockedRect { x: fr.bx; y: fr.by; width: fr.bw; height: fr.bh; edge: "top"; cornerRadius: 17; fillet: 6; color: "white" } }
                MultiEffect { anchors.fill: parent; source: blurred; maskEnabled: true; maskSource: m }
                DockedRect { x: fr.bx; y: fr.by; width: fr.bw; height: fr.bh; edge: "top"; cornerRadius: 17; fillet: 6; color: Appearance.colors.colPanelFrost }
            }

            // the notch at rest
            Frost { visible: !shell.setupNow; bx: (shell.sw - (shell.sentNow ? 600 : 400)) / 2; by: 0; bw: shell.sentNow ? 600 : 400; bh: 40 }
            // adding an account: the provider's own page, held in the notch; the way back names Mail
            Frost { visible: shell.setupNow; z: 100; bx: (shell.sw - 640) / 2; by: 0; bw: 640; bh: 520 }
            Item {
                visible: shell.setupNow
                z: 101
                x: (shell.sw - 640) / 2; width: 640; height: 520
                Row { x: 22; y: 11; spacing: 8
                    K.Symbol { text: "lock"; size: 15; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter }
                    T { text: "accounts.google.com"; w: Tacit.weight.medium; anchors.verticalCenter: parent.verticalCenter } }
                T { anchors.right: parent.right; anchors.rightMargin: 24; y: 12; text: "Back to Mail"; w: Tacit.weight.medium; ink: Tacit.inkSec }
                Rectangle {
                    x: 20; y: 48; width: 600; height: 452; radius: 14; color: "#202124"
                    Column { x: 64; y: 56; width: 472; spacing: 10
                        Text { text: "Sign in"; color: "#e8eaed"; font.family: Tacit.font.main; font.pixelSize: 26; font.weight: Tacit.weight.medium }
                        Text { text: "to continue to Mail"; color: "#bdc1c6"; font.family: Tacit.font.main; font.pixelSize: 15 }
                        Item { width: 1; height: 26 }
                        Rectangle { width: parent.width; height: 52; radius: 6; color: "transparent"; border.width: 1; border.color: "#8e918f"
                            Text { x: 16; anchors.verticalCenter: parent.verticalCenter; text: "lorenz@example.com"; color: "#e8eaed"; font.family: Tacit.font.main; font.pixelSize: 16 } }
                        Text { text: "Forgot email?"; color: "#bdc1c6"; font.family: Tacit.font.main; font.pixelSize: 14 }
                        Item { width: 1; height: 60 }
                        Item { width: parent.width; height: 40
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Create account"; color: "#bdc1c6"; font.family: Tacit.font.main; font.pixelSize: 14 }
                            Rectangle { anchors.right: parent.right; width: 96; height: 40; radius: 20; color: "#e8eaed"
                                Text { anchors.centerIn: parent; text: "Next"; color: "#202124"; font.family: Tacit.font.main; font.pixelSize: 15; font.weight: Tacit.weight.medium } } } }
                }
            }
            Item {
                visible: shell.sentNow
                x: (shell.sw - 600) / 2; width: 600; height: 40
                Row { x: 20; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                    K.Symbol { text: "send"; size: 17; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter }
                    T { text: "Sending to Mara and 2 others"; w: Tacit.weight.medium; anchors.verticalCenter: parent.verticalCenter } }
                T { anchors.centerIn: parent; text: "09:52"; w: Tacit.weight.strong }
                T { anchors.right: parent.right; anchors.rightMargin: 24; anchors.verticalCenter: parent.verticalCenter; text: "Undo"; w: Tacit.weight.strong }
                Rectangle { x: 20; y: 36; width: 560; height: 2; radius: 1; color: Qt.rgba(1, 1, 1, 0.10)
                    Rectangle { width: parent.width * 0.7; height: 2; radius: 1; color: Tacit.inkSec } }
            }
            Item {
                visible: !shell.sentNow && !shell.setupNow
                x: (shell.sw - 400) / 2; width: 400; height: 40
                Row { x: 22; anchors.verticalCenter: parent.verticalCenter; spacing: 16
                    K.Symbol { text: "search"; size: 17; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter }
                    T { text: "1"; w: Tacit.weight.strong; ink: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter } }
                T { anchors.centerIn: parent; text: "09:51"; w: Tacit.weight.strong }
                Item { visible: shell.sentNow; anchors.fill: parent
                    Rectangle { anchors.fill: parent; color: "transparent" } }
                Row { anchors.right: parent.right; anchors.rightMargin: 24; anchors.verticalCenter: parent.verticalCenter; spacing: 12
                    K.Symbol { text: shell.offlineNow ? "wifi_off" : "wifi"; size: 17; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter }
                    Row { spacing: 4; anchors.verticalCenter: parent.verticalCenter
                        K.Symbol { text: "battery_full"; size: 17; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter }
                        T { text: "84 %"; w: Tacit.weight.medium; ink: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter } } }
            }

            // ------------------------------------------------ the window
            Item {
                id: win
                visible: !shell.notifyNow
                x: 100; y: 64; width: 1720; height: 972
                Item { id: wm; anchors.fill: parent; visible: false; layer.enabled: true
                    Rectangle { anchors.fill: parent; radius: Tacit.radius.window; color: "white" } }
                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect { maskEnabled: true; maskSource: wm }
                    ShaderEffectSource { width: parent.width; height: parent.height; sourceItem: blurred; sourceRect: Qt.rect(win.x, win.y, win.width, win.height) }
                    Rectangle { anchors.fill: parent; color: Tacit.windowGround; opacity: 1 - Tacit.windowSeeThrough }
                    // the mailboxes and the list sit a step back from the reading
                    Rectangle { visible: !shell.fullPage; width: shell.switching ? 720 : 460; height: parent.height; color: Qt.rgba(0, 0, 0, 0.14) }
                }
                // the window band: the line, with minimise and close beside it
                Item { anchors.horizontalCenter: parent.horizontalCenter; y: 6; width: 168; height: 30
                    Rectangle { anchors.centerIn: parent; width: 44; height: 4; radius: 2; color: Qt.rgba(1, 1, 1, 0.26) }
                    K.Symbol { x: 6; anchors.verticalCenter: parent.verticalCenter; text: "remove"; size: 18; color: Tacit.inkSec }
                    K.Symbol { anchors.right: parent.right; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter; text: "close"; size: 18; color: Tacit.inkSec } }

                readonly property color ink2: Qt.rgba(Tacit.inkMain.r, Tacit.inkMain.g, Tacit.inkMain.b, 0.72)
                readonly property color ink3: Qt.rgba(Tacit.inkMain.r, Tacit.inkMain.g, Tacit.inkMain.b, 0.70)
                readonly property int listX: shell.switching ? 260 : 0
                component CurLine: Rectangle { width: 2; radius: 1; color: Tacit.inkMain }
                component Caret: Rectangle { width: 2; height: 22; radius: 1; color: Tacit.accent }
                // the one why line, the same wherever the agent's draft appears
                component Why: Row {
                    spacing: 6
                    T { text: "Why:"; size: Tacit.size.meta; w: Tacit.weight.medium; ink: shell.agentInk }
                    T { text: "to answer both of Mara's questions, from your header notes."; size: Tacit.size.meta; ink: win.ink2 }
                    Item { width: 4; height: 1 }
                    Act { text: "Open notes"; size: Tacit.size.meta }
                }

                // ------------------------------------------------ the mailboxes: a column that opens beside the list
                Item {
                    visible: shell.switching
                    x: 0; y: 0; width: 260; height: parent.height
                    Rectangle { x: parent.width - 1; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.07) }
                    Column {
                        x: 12; y: 58; width: 236; spacing: 0
                        component Box: Item {
                            property string name; property string count: ""; property bool cur: false; property string agentLine: ""
                            width: 236; height: agentLine === "" ? 38 : 56
                            CurLine { visible: parent.cur; x: 2; y: 9; height: 20 }
                            T { x: 16; y: 9; text: parent.name; w: parent.cur ? Tacit.weight.strong : Tacit.weight.medium; ink: parent.cur ? Tacit.inkMain : win.ink2 }
                            Row { visible: parent.agentLine !== ""; x: 16; y: 32; spacing: 6
                                AgentStroke { anchors.verticalCenter: parent.verticalCenter }
                                T { text: parent.parent.agentLine; size: Tacit.size.meta; ink: shell.agentInk } }
                            T { visible: parent.count !== ""; anchors.right: parent.right; anchors.rightMargin: 12; y: 11; text: parent.count; size: Tacit.size.meta; ink: win.ink3; font.features: { "tnum": 1 } }
                        }
                        component Account: Item {
                            property string name; property string address
                            width: 236; height: 62
                            Rectangle { x: 16; y: 12; width: 208; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                            T { x: 16; y: 24; text: parent.name; size: Tacit.size.meta; w: Tacit.weight.strong; ink: win.ink2 }
                            T { x: 16; y: 41; text: parent.address; size: Tacit.size.meta; ink: win.ink3 }
                        }
                        T { leftPadding: 16; bottomPadding: 8; text: "All accounts"; size: Tacit.size.meta; w: Tacit.weight.medium; ink: win.ink3 }
                        Box { name: "Inbox"; count: "4"; cur: true }
                        Box { name: "Later"; count: "1" }
                        Box { name: "Starred" }
                        Box { name: "Drafts"; count: "2"; agentLine: "1 by your agent" }
                        Box { name: "Sent" }
                        Box { name: "Archive" }
                        Box { name: "Junk" }
                        Box { name: "Trash" }
                        Account { name: "Personal"; address: "lorenz@example.com" }
                        Box { name: "Inbox"; count: "3" }
                        Box { name: "Family" }
                        Box { name: "Receipts" }
                        Account { name: "Work"; address: "lorenz@moss.example" }
                        Box { name: "Inbox"; count: "1" }
                        Box { name: "Clients" }
                        Box { name: "Invoices"; count: "2" }
                    }
                    Row { x: 28; anchors.bottom: parent.bottom; anchors.bottomMargin: 30; spacing: 26
                        Act { text: "Add account" }
                        Act { text: "Settings" } }
                }

                // ------------------------------------------------ the list
                Item {
                    id: list
                    visible: !shell.fullPage
                    x: win.listX; y: 0; width: 460; height: parent.height
                    Rectangle { x: parent.width - 1; width: 1; height: parent.height; color: Tacit.hairline }
                    Row { x: 32; y: 52; spacing: 4
                        T { text: shell.searching ? "Search" : (shell.emptyBox ? "Later" : "Inbox"); size: Tacit.size.section; w: Tacit.weight.strong; font.family: Tacit.font.display; font.letterSpacing: 0.4 }
                        K.Symbol { visible: !shell.searching; text: shell.switching ? "expand_less" : "expand_more"; size: 20; color: Tacit.inkSec; anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 1 } }
                    T { x: 32; y: 84; text: shell.emptyBox ? "All accounts" : shell.importing ? "Personal  ·  lorenz@example.com" : (shell.searching ? "3 results in every account and mailbox" : (shell.plainMsg ? "All accounts  ·  3 unread" : "All accounts  ·  4 unread")); size: Tacit.size.meta; ink: win.ink3 }
                    T { anchors.right: parent.right; anchors.rightMargin: 32; y: 58; text: shell.searching ? "Close search" : "New message"; w: Tacit.weight.strong; ink: shell.composing ? win.ink3 : Tacit.inkMain }
                    Item { x: 32; y: 116; width: 396; height: 40
                        Row { anchors.verticalCenter: parent.verticalCenter; spacing: 10
                            K.Symbol { text: "search"; size: 17; color: shell.searching ? Tacit.inkMain : win.ink3; anchors.verticalCenter: parent.verticalCenter }
                            T { text: shell.searching ? "palettes" : "Search all mail"; ink: shell.searching ? Tacit.inkMain : win.ink3; anchors.verticalCenter: parent.verticalCenter }
                            Caret { visible: shell.searching; anchors.verticalCenter: parent.verticalCenter } }
                        Row { visible: !shell.emptyBox; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 4
                            T { visible: !shell.searching; text: "All mail, newest first"; size: Tacit.size.meta; w: Tacit.weight.medium; ink: win.ink2 }
                            K.Symbol { visible: !shell.searching; text: "expand_more"; size: 14; color: win.ink3; anchors.verticalCenter: parent.verticalCenter } }
                        Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: shell.searching ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.14) } }

                    component Msg: Item {
                        property string from; property string subject; property string preview; property string time
                        property bool unread: false; property bool cur: false; property bool files: false; property bool star: false; property int count: 0
                        property bool drafted: false; property bool showPreview: !drafted
                        property string account: "Personal"
                        width: 436; height: drafted && showPreview ? 108 : 86
                        CurLine { visible: parent.cur; x: 2; y: 14; height: parent.height - 28 }
                        // one unread signal: the sender in bold
                        T { x: 20; y: 12; width: 210; elide: Text.ElideRight; text: parent.from; w: parent.unread ? Tacit.weight.strong : Tacit.weight.medium; ink: parent.unread ? Tacit.inkMain : win.ink2 }
                        Row { anchors.right: parent.right; anchors.rightMargin: 20; y: 14; spacing: 0
                            T { visible: parent.parent.star; text: "Starred  ·  "; size: Tacit.size.meta; ink: win.ink2 }
                            T { text: parent.parent.account + "  ·  " + parent.parent.time; size: Tacit.size.meta; ink: win.ink3 } }
                        Row { x: 20; y: 36; spacing: 8
                            T { width: Math.min(implicitWidth, 290); elide: Text.ElideRight; text: parent.parent.subject; ink: parent.parent.unread ? Tacit.inkMain : win.ink3 }
                            T { visible: parent.parent.count > 1; text: parent.parent.count + " messages"; size: Tacit.size.meta; ink: win.ink3; anchors.baseline: parent.children[0].baseline }
                            T { visible: parent.parent.files; text: "1 file"; size: Tacit.size.meta; ink: win.ink3; anchors.baseline: parent.children[0].baseline } }
                        Row { visible: parent.drafted; x: 20; y: parent.showPreview ? 82 : 60; spacing: 6
                            AgentStroke { anchors.verticalCenter: parent.verticalCenter }
                            T { text: "Reply drafted: answers both of Mara's questions"; size: Tacit.size.meta; ink: shell.agentInk; anchors.verticalCenter: parent.verticalCenter } }
                        T { visible: parent.showPreview; x: 20; y: 60; width: 396; elide: Text.ElideRight; text: parent.preview; size: Tacit.size.meta; ink: win.ink3; textFormat: Text.StyledText }
                    }
                    component Day: T { leftPadding: 20; topPadding: 12; bottomPadding: 4; size: Tacit.size.meta; w: Tacit.weight.medium; ink: win.ink3 }

                    // the inbox
                    Column {
                        visible: !shell.searching && !shell.emptyBox && !shell.importing
                        x: 12; y: 166; width: 436; spacing: 0
                        Day { text: "Today" }
                        Msg { from: "Mara Klein"; subject: "The Dusk and Moss pass"; time: shell.sentNow ? "09:52" : "09:42"; cur: shell.maraThread; files: true; count: shell.sentNow || shell.offlineNow ? 4 : 3; account: "Work"; drafted: !shell.sentNow && !shell.offlineNow; preview: shell.offlineNow ? "You: waiting for a connection to send" : "You: Hi Mara, thanks, this reads well." }
                        Msg { from: "Tactical Studio"; subject: "Monday notes, prototype review"; preview: "The prototype is ready for a short review. We have updated the keyboard map."; time: "08:15"; unread: !shell.plainMsg; cur: shell.plainMsg; account: "Work" }
                        Day { text: "Yesterday" }
                        Msg { from: "Nils Berger"; subject: "Train details for Friday"; preview: "The train leaves at 08:34 from platform 7. Our seats are in carriage 24."; time: "18:20"; files: true; star: true; account: "Work" }
                        Msg { from: "Quiet Hours"; subject: "Your weekly summary"; preview: "You made room for three focused sessions and kept two evenings free."; time: "07:00" }
                        Day { text: "Monday" }
                        Msg { from: "Studio Newsletter"; subject: "A few things worth reading"; preview: "Quieter interfaces, thoughtful tools, and making software feel calm."; time: "16:02"; unread: true }
                        Msg { from: "Anna Richter"; subject: "A small question about Tuesday"; preview: "Would Tuesday still work for you? I can make either 11:00 or 14:30."; time: "11:47"; unread: true }
                        Msg { from: "Lea Hoffmann"; subject: "Feedback on the reading view"; preview: "The denser overview is much easier to scan. A little more room around the sender."; time: "09:30"; unread: true }
                        Msg { from: "Bookshop"; subject: "Your reservation is ready"; preview: "The book you asked us to set aside has arrived."; time: "Sunday" }
                    }
                    // search results: the matching words stand out in the preview
                    // mail arriving: only the account just added, newest first, as it comes in
                    Column {
                        visible: shell.importing
                        x: 12; y: 166; width: 436; spacing: 0
                        Day { text: "Today" }
                        Msg { from: "Quiet Hours"; subject: "Your weekly summary"; preview: "You made room for three focused sessions and kept two evenings free."; time: "07:00" }
                        Day { text: "Monday" }
                        Msg { from: "Studio Newsletter"; subject: "A few things worth reading"; preview: "Quieter interfaces, thoughtful tools, and making software feel calm."; time: "16:02"; unread: true }
                        Msg { from: "Anna Richter"; subject: "A small question about Tuesday"; preview: "Would Tuesday still work for you? I can make either 11:00 or 14:30."; time: "11:47"; unread: true }
                        Msg { from: "Lea Hoffmann"; subject: "Feedback on the reading view"; preview: "The denser overview is much easier to scan. A little more room around the sender."; time: "09:30"; unread: true }
                        Day { text: "Sunday" }
                        Msg { from: "Bookshop"; subject: "Your reservation is ready"; preview: "The book you asked us to set aside has arrived."; time: "18:40" }
                        Msg { from: "Felix Braun"; subject: "Photos from the weekend"; preview: "Here are a few pictures from our walk. The light by the lake was lovely."; time: "12:05" }
                    }
                    Column {
                        visible: shell.searching
                        x: 12; y: 166; width: 436; spacing: 0
                        Day { text: "Best matches" }
                        Msg { from: "Mara Klein"; subject: "The Dusk and Moss pass"; preview: "I have attached our notes on the Dusk and Moss <b>palettes</b>."; time: "09:42"; cur: true; files: true; account: "Work"; drafted: true; showPreview: true }
                        Msg { from: "Lena Fischer"; subject: "Re: The Dusk and Moss pass"; preview: "Here are the two <b>palettes</b> as we left them on Friday."; time: "Monday"; account: "Work" }
                        Msg { from: "Studio Newsletter"; subject: "Colour for calm software"; preview: "Three <b>palettes</b> that stay quiet on dark grounds."; time: "12 Oct" }
                    }
                }

                // ------------------------------------------------ the reading side
                Item {
                    id: pane
                    visible: !shell.fullPage
                    x: win.listX + 460; y: 0; width: parent.width - x; height: parent.height
                    readonly property int cw: 700
                    readonly property int cx: Math.max(40, (width - cw) / 2 - 24)
                    readonly property int tx: 48
                    readonly property int ex: cx + tx
                    readonly property int ew: cw - tx
                    // the thread's actions, answering first; while you review a draft only the way back stays
                    Item {
                        visible: !shell.replying && !shell.composing && !shell.emptyBox && !shell.importing
                        Row { x: pane.ex; y: 66; spacing: 26
                            Act { text: "Reply" }
                            Act { text: "Reply all" }
                            Act { text: "Forward" } }
                        Row { x: pane.ex + pane.ew - width; y: 66; spacing: 26
                            Act { text: "Archive" }
                            Act { text: "Later" }
                            Act { text: "More" } }
                    }
                    Act { visible: shell.replying; x: pane.ex + pane.ew - width; y: 66; text: "Close, keep the draft" }
                    Item { visible: shell.replying; x: pane.ex; y: pane.height - 48 - 44; width: pane.ew; height: 44
                        Rectangle { y: -14; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                        Act { anchors.verticalCenter: parent.verticalCenter; text: "Attach a file" }
                        Row { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 24
                            Act { text: "Move draft to Trash"; anchors.verticalCenter: parent.verticalCenter }
                            Pill { text: "Send"; anchors.verticalCenter: parent.verticalCenter } } }
                    Text { visible: shell.composing; x: pane.ex; y: 124; text: "New message"; color: Tacit.inkMain
                        font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                    Act { visible: shell.composing; x: pane.ex + pane.ew - width; y: 66; text: "Close, keep the draft" }
                    Rectangle { visible: !shell.emptyBox && !shell.importing; x: pane.ex; y: 104; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }

                    // ---- mail arriving: the progress said once, here, while what has come in can be read
                    Column {
                        visible: shell.importing
                        x: pane.ex; y: 124; width: pane.ew; spacing: 0
                        Text { text: "Getting your mail"; color: Tacit.inkMain
                            font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                        Item { width: 1; height: 18 }
                        T { text: "1,240 of 8,600 from Personal. Read what has arrived while the rest comes in."; ink: win.ink2 }
                        Item { width: 1; height: 24 }
                        Rectangle { width: parent.width; height: 2; radius: 1; color: Qt.rgba(1, 1, 1, 0.16)
                            Rectangle { width: parent.width * 0.14; height: 2; radius: 1; color: Tacit.inkMain } }
                    }
                    // ---- empty: the mailbox says what lives here, once, in the middle of the reader
                    Column {
                        visible: shell.emptyBox
                        anchors.centerIn: parent; anchors.verticalCenterOffset: -40; width: 560; spacing: 0
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Nothing in Later"; color: Tacit.inkMain
                            font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                        Item { width: 1; height: 18 }
                        T { width: 400; anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap; lineHeight: 1.4; text: "Mail you set aside with Later comes back to your inbox at the time you chose. It waits here until then."; ink: win.ink2 }
                        Item { width: 1; height: 28 }
                        Act { anchors.horizontalCenter: parent.horizontalCenter; text: "Back to Inbox" }
                    }

                    // ---- a message with no draft
                    Item {
                        visible: shell.plainMsg
                        anchors.fill: parent
                        Text { x: pane.ex; y: 124; width: pane.ew; wrapMode: Text.Wrap; text: "Monday notes, prototype review"; color: Tacit.inkMain
                            font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                        T { x: pane.ex; y: 168; text: "1 message  ·  Work"; size: Tacit.size.meta; ink: win.ink3 }
                        Item { x: pane.cx; y: 214; width: pane.cw; height: 52
                            Rectangle { x: 8; y: 10; width: 17; height: 1; color: Tacit.inkMain }
                            T { x: pane.tx; y: 0; text: "Tactical Studio"; w: Tacit.weight.strong }
                            T { x: pane.tx; y: 22; text: "To you"; size: Tacit.size.meta; ink: win.ink2 }
                            T { anchors.right: parent.right; y: 2; text: "Today 08:15"; size: Tacit.size.meta; ink: win.ink3 } }
                        Column {
                            x: pane.ex; y: 284; width: pane.ew; spacing: 14
                            Repeater { model: ["Good morning,", "The prototype is ready for a short review. We have updated the keyboard map and the spacing in the header, as discussed on Monday.",
                                               "Could you try it this week and tell us what still feels slow?", "Best,\nTactical Studio"]
                                T { width: parent.width; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3; text: modelData } }
                        }
                    }

                    // ---- a new message
                    Item {
                        visible: shell.composing
                        anchors.fill: parent
                        Column {
                            x: pane.ex; y: 124; width: pane.ew; spacing: 0
                            component Field: Item {
                                property string label; property string value; property string trail: ""; property bool hint: false; property bool caret: false
                                width: pane.ew; height: 40
                                T { anchors.verticalCenter: parent.verticalCenter; width: 64; text: parent.label; size: Tacit.size.meta; ink: win.ink3 }
                                Row { x: 64; anchors.verticalCenter: parent.verticalCenter; spacing: 2
                                    T { text: parent.parent.value; size: Tacit.size.meta; w: parent.parent.hint ? Tacit.weight.regular : Tacit.weight.medium; ink: parent.parent.hint ? win.ink3 : Tacit.inkMain }
                                    Caret { visible: parent.parent.caret; height: 18; anchors.verticalCenter: parent.verticalCenter } }
                                T { visible: parent.trail !== ""; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: parent.trail; size: Tacit.size.meta; w: Tacit.weight.medium; ink: win.ink2 }
                                Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                            }
                            Item { width: 1; height: 64 }
                            Field { label: "From"; value: "Personal, lorenz@example.com  ⌄" }
                            Field { label: "To"; value: "Anna Ri"; caret: true; trail: "Cc   Bcc" }
                            // the people who match, in words, opened under the field it fills
                            Column { x: 64; topPadding: 6; bottomPadding: 6; spacing: 0
                                Repeater { model: [["Anna Richter", "anna.richter@example.net", "Personal"], ["Anna Richter", "a.richter@moss.example", "Work"]]
                                    Item { width: pane.ew - 64; height: 32
                                        CurLine { visible: index === 0; x: -14; y: 7; height: 18 }
                                        Row { anchors.verticalCenter: parent.verticalCenter; spacing: 12
                                            T { text: modelData[0]; size: Tacit.size.meta; w: index === 0 ? Tacit.weight.strong : Tacit.weight.medium; ink: index === 0 ? Tacit.inkMain : win.ink2 }
                                            T { text: modelData[1]; size: Tacit.size.meta; ink: win.ink3 } }
                                        T { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: modelData[2]; size: Tacit.size.meta; ink: win.ink3 } } } }
                            Rectangle { width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                            Field { label: "Subject"; value: "Add a subject"; hint: true }
                        }
                        T { x: pane.ex; y: 430; text: "Write your message"; size: Tacit.size.body; ink: win.ink3 }
                        Item { x: pane.ex; y: 900 - 44; width: pane.ew; height: 44
                            Row { anchors.verticalCenter: parent.verticalCenter; spacing: 26
                                Act { text: "Attach a file" }
                                Row { spacing: 6
                                    AgentStroke { anchors.verticalCenter: parent.verticalCenter }
                                    Act { text: "Ask your agent to draft it"; ink: shell.agentInk } } }
                            Row { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 20
                                Act { text: "Move draft to Trash"; anchors.verticalCenter: parent.verticalCenter }
                                Pill { text: "Send"; opacity: 0.4; anchors.verticalCenter: parent.verticalCenter } } }
                    }

                    // ---- Mara's thread, in search too (the best match opens); while reviewing the draft it scrolls so her
                    //      message stays open right above the reply
                    Item {
                        visible: shell.maraThread || shell.searching
                        x: 0; y: 105; width: parent.width; height: (shell.replying ? parent.height - 48 - 44 - 22 : parent.height) - y; clip: true
                        Item { width: parent.width; height: pane.height; y: -105
                        Text { x: pane.ex; y: 124; width: pane.ew; wrapMode: Text.Wrap; text: "The Dusk and Moss pass"; color: Tacit.inkMain
                            font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                        T { x: pane.ex; y: 168; text: (shell.sentNow || shell.offlineNow ? "4" : "3") + " messages  ·  Work"; size: Tacit.size.meta; ink: win.ink3 }
                        // the thread's line, from its first message to the newest (or the agent's diamond)
                        Rectangle {
                            x: pane.cx + 16; width: 1; color: Qt.rgba(1, 1, 1, 0.14)
                            y: threadCol.y + lenaRow.y + 23
                            height: threadCol.y + (shell.replying ? draftBlk.y + 6 : maraCol.y + (shell.sentNow || shell.offlineNow ? sentBlk.y + 30 : agentBlk.y + 34)) - y
                        }
                        Column {
                            id: threadCol
                            x: pane.cx; y: 204; width: pane.cw; spacing: 0
                            component Earlier: Item {
                                property string who; property string letter; property string when; property string line
                                width: pane.cw; height: 48
                                Rectangle { x: pane.tx; y: parent.height - 1; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                Rectangle { x: 12; y: 23; width: 9; height: 1; color: Qt.rgba(1, 1, 1, 0.34) }
                                T { x: pane.tx; y: 14; width: 130; text: parent.who; w: Tacit.weight.medium; ink: win.ink2 }
                                T { x: pane.tx + 140; y: 14; width: pane.cw - pane.tx - 140 - 130; elide: Text.ElideRight; text: parent.line; ink: win.ink3; textFormat: Text.StyledText }
                                Row { anchors.right: parent.right; y: 15; spacing: 6
                                    T { text: parent.parent.when; size: Tacit.size.meta; ink: win.ink3 }
                                    K.Symbol { text: "expand_more"; size: 14; color: win.ink3; anchors.verticalCenter: parent.verticalCenter } }
                            }
                            Rectangle { x: pane.tx; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                            Earlier { id: lenaRow; who: "Lena Fischer"; letter: "L"; when: "Monday"; line: shell.searching ? "Here are the two <b>palettes</b> as we left them on Friday." : "Here are the two palettes as we left them on Friday." }
                            Earlier { who: "Nils Berger"; letter: "N"; when: "Yesterday"; line: "The moss reads well on dark. The header spacing still feels tight." }
                            // while you review the draft, Mara's message folds to the question the draft answers, in full
                            Earlier { visible: shell.offlineNow; who: "Mara Klein"; when: "Today 09:42"; line: "Could you take a look at the navigation and the message header before Thursday?" }
                            Item {
                                visible: shell.replying
                                width: pane.cw; height: askText.y + askText.height + 20
                                Rectangle { x: pane.tx; y: parent.height - 1; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                Rectangle { x: 12; y: 23; width: 9; height: 1; color: Qt.rgba(1, 1, 1, 0.34) }
                                T { x: pane.tx; y: 14; text: "Mara Klein"; w: Tacit.weight.medium; ink: win.ink2 }
                                Row { anchors.right: parent.right; y: 15; spacing: 6
                                    T { text: "Today 09:42"; size: Tacit.size.meta; ink: win.ink3 }
                                    K.Symbol { text: "expand_more"; size: 14; color: win.ink3; anchors.verticalCenter: parent.verticalCenter } }
                                T { id: askText; x: pane.tx; y: 44; width: pane.ew - 40; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3; ink: win.ink2
                                    text: "Could you take a look at the navigation and the message header before Thursday? The interface should stay quiet, with the content doing most of the talking." }
                            }
                            Item { width: 1; height: 26 }

                            Column {
                                id: maraCol
                                visible: !shell.replying
                                width: pane.cw; spacing: 0
                                Item {
                                    id: maraHead
                                    visible: !shell.offlineNow
                                    width: pane.cw; height: 52
                                    Rectangle { x: 8; y: 10; width: 17; height: 1; color: Tacit.inkMain }
                                    T { x: pane.tx; y: 0; text: "Mara Klein"; w: Tacit.weight.strong }
                                    T { x: pane.tx; y: 22; text: "To you, Nils Berger and Lena Fischer"; size: Tacit.size.meta; ink: win.ink2 }
                                    T { anchors.right: parent.right; y: 2; text: "Today 09:42"; size: Tacit.size.meta; ink: win.ink3 }
                                }
                                Item { visible: !shell.offlineNow; width: 1; height: 18 }
                                Column {
                                    visible: !shell.offlineNow
                                    x: pane.tx; width: pane.ew; spacing: 14
                                    Repeater { model: ["Hi Lorenz,", shell.searching ? "The final design review is ready. I have attached our notes on the Dusk and Moss <b>palettes</b>." : "The final design review is ready. I have attached our notes on the Dusk and Moss palettes.",
                                                       "Could you take a look at the navigation and the message header before Thursday? The interface should stay quiet, with the content doing most of the talking.",
                                                       "Thanks,\nMara"]
                                        T { width: parent.width; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3; text: modelData; textFormat: modelData.indexOf("<b>") >= 0 ? Text.StyledText : Text.PlainText } }
                                }
                                Item { visible: !shell.offlineNow; width: 1; height: 18 }
                                Row {
                                    visible: !shell.offlineNow
                                    x: pane.tx; spacing: 26
                                    Row { spacing: 12
                                        T { text: "Review summary.pdf"; w: Tacit.weight.medium }
                                        T { text: "6 pages, 180 kB"; size: Tacit.size.meta; ink: win.ink3; anchors.baseline: parent.children[0].baseline } }
                                    Act { text: "Open" }
                                    Act { text: "Save to Files" }
                                }
                                Item { visible: !shell.offlineNow; width: 1; height: 26 }
                                Item {
                                    id: sentBlk
                                    visible: shell.sentNow || shell.offlineNow
                                    width: pane.cw; height: (shell.offlineNow ? offCol.y + offCol.height : agentRow.y + 20) + 30
                                    Row { id: agentRow; x: pane.tx; y: sentBody.y + sentBody.height + 20; spacing: 8
                                        AgentStroke { anchors.verticalCenter: parent.verticalCenter }
                                        T { text: "Drafted by your agent, edited by you"; size: Tacit.size.meta; ink: shell.agentInk; anchors.verticalCenter: parent.verticalCenter } }
                                    Column { id: offCol; visible: shell.offlineNow; x: pane.tx; y: agentRow.y + 36; spacing: 10
                                        T { text: "No connection. Mail sends it as soon as you are back online; nothing was lost."; ink: win.ink2 }
                                        Row { spacing: 26
                                            Act { text: "Try now" }
                                            Act { text: "Edit" }
                                            Act { text: "Keep it in Drafts" } } }
                                    Rectangle { x: pane.tx; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                    Rectangle { x: 8; y: 30; width: 17; height: 1; color: Tacit.inkMain }
                                    T { x: pane.tx; y: 20; text: "You"; w: Tacit.weight.strong }
                                    T { x: pane.tx; y: 42; text: "To Mara Klein, Nils Berger and Lena Fischer"; size: Tacit.size.meta; ink: win.ink2 }
                                    T { anchors.right: parent.right; y: 22; text: shell.offlineNow ? "Not sent" : "Sending"; size: Tacit.size.meta; ink: win.ink3 }
                                    Column { id: sentBody; x: pane.tx; y: 76; width: pane.ew; spacing: 12
                                        T { width: parent.width; size: Tacit.size.body; text: "Hi Mara," }
                                        T { width: parent.width; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3
                                            text: "Thanks, this reads well. Two notes on the header: the sender and the date could share one line, and the attachment should sit right under the text it belongs to." }
                                        T { width: parent.width; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3; text: "I will send the rest by Wednesday, a day before your Thursday deadline." }
                                        T { width: parent.width; size: Tacit.size.body; lineHeight: 1.3; text: "Lorenz\nMoss Studio" } }
                                }
                                Item {
                                    id: agentBlk
                                    visible: !shell.replying && !shell.sentNow && !shell.offlineNow
                                    width: pane.cw; height: 130
                                    Rectangle { x: pane.tx; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                    Mark { y: 18 }
                                    T { x: pane.tx; y: 22; text: "Your agent drafted a reply"; w: Tacit.weight.strong; ink: shell.agentInk }
                                    T { anchors.right: parent.right; y: 24; text: "Not sent"; size: Tacit.size.meta; ink: win.ink3 }
                                    Why { x: pane.tx; y: 46 }
                                    Pill { x: pane.tx; y: 82; text: "Review reply" }
                                }
                            }

                            // draft: the state said once; the text is yours to change, here
                            Item {
                                id: draftBlk
                                visible: shell.replying
                                width: pane.cw; height: 600
                                Rectangle { x: pane.tx; y: -24; width: pane.ew; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                Mark { y: -4 }
                                T { x: pane.tx; y: 0; text: "Your agent drafted a reply"; w: Tacit.weight.strong; ink: shell.agentInk }
                                T { anchors.right: parent.right; y: 2; text: "Not sent"; size: Tacit.size.meta; ink: win.ink3 }
                                Why { x: pane.tx; y: 24 }
                                Column {
                                    x: pane.tx; y: 54; width: pane.ew; spacing: 0
                                    component DField: Item {
                                        property string label; property string value; property string trail: ""
                                        width: pane.ew; height: 32
                                        T { anchors.verticalCenter: parent.verticalCenter; width: 64; text: parent.label; size: Tacit.size.meta; ink: win.ink3 }
                                        T { x: 64; anchors.verticalCenter: parent.verticalCenter; text: parent.value; size: Tacit.size.meta; w: Tacit.weight.medium; ink: Tacit.inkMain }
                                        T { visible: parent.trail !== ""; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: parent.trail; size: Tacit.size.meta; w: Tacit.weight.medium; ink: win.ink2 }
                                        Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                                    }
                                    DField { label: "From"; value: "Work, lorenz@moss.example  ⌄"; trail: "Reply all  ⌄" }
                                    DField { label: "To"; value: "Mara Klein,  Nils Berger,  Lena Fischer"; trail: "Cc   Bcc" }
                                    DField { label: "Subject"; value: "Re: The Dusk and Moss pass" }
                                }
                                Rectangle { x: 16; y: 28; width: 1; height: draftBody.y + draftBody.height - 28; color: shell.agentInk }
                                Column {
                                    id: draftBody
                                    x: pane.tx; y: 164; width: pane.ew; spacing: 12
                                    T { width: parent.width; size: Tacit.size.body; text: "Hi Mara," }
                                    T { width: parent.width; wrapMode: Text.Wrap; size: Tacit.size.body; lineHeight: 1.3
                                        text: "Thanks, this reads well. Two notes on the header: the sender and the date could share one line, and the attachment should sit right under the text it belongs to." }
                                    Row { spacing: 1
                                        T { size: Tacit.size.body; text: "I will send the rest by Wednesday, a day before your Thursday deadline." }
                                        Caret { anchors.verticalCenter: parent.verticalCenter } }
                                    T { width: parent.width; size: Tacit.size.body; lineHeight: 1.3; text: "Lorenz\nMoss Studio" }
                                }

                            }
                        }
                    }
                    }
                }

                // ------------------------------------------------ adding your first account
                Item {
                    visible: shell.setupNow
                    anchors.fill: parent
                    Column {
                        x: (parent.width - 560) / 2; y: 560; width: 560; spacing: 0
                        Text { text: "Add your mail"; color: Tacit.inkMain; font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                        Item { width: 1; height: 10 }
                        T { width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.3; ink: win.ink2
                            text: "Every account in one place. You sign in on your provider's own page, in the notch, so Mail never sees your password." }
                        Item { width: 1; height: 26 }
                        Repeater { model: [["Google", ""], ["Microsoft", ""], ["iCloud", ""], ["Fastmail", ""], ["Another provider", "IMAP and SMTP"]]
                            Item { width: 560; height: 46
                                CurLine { visible: index === 0; x: -16; y: 13; height: 20 }
                                T { anchors.verticalCenter: parent.verticalCenter; text: modelData[0]; size: Tacit.size.body; w: index === 0 ? Tacit.weight.strong : Tacit.weight.medium; ink: index === 0 ? Tacit.inkMain : win.ink2 }
                                Row { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                                    T { visible: modelData[1] !== ""; text: modelData[1]; size: Tacit.size.meta; ink: win.ink3; anchors.verticalCenter: parent.verticalCenter }
                                    K.Symbol { text: "chevron_right"; size: 16; color: win.ink3; anchors.verticalCenter: parent.verticalCenter } }
                                Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) } } }
                    }
                }

                // ------------------------------------------------ settings
                Item {
                    visible: shell.settingsNow
                    anchors.fill: parent
                    readonly property int c1: 200
                    readonly property int c2: 200 + 600 + 120
                    Act { x: parent.c1; y: 66; text: "Back to Mail" }
                    Rectangle { x: parent.c1; y: 104; width: parent.width - 2 * parent.c1; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                    Text { x: parent.c1; y: 124; text: "Settings"; color: Tacit.inkMain; font.family: Tacit.font.display; font.pixelSize: Tacit.size.headline; font.weight: Tacit.weight.strong; font.letterSpacing: 0.6 }
                    component SetRow: Item {
                        property string label; property string value; property bool chevron: true; property bool quiet: false; property string note: ""
                        width: 600; height: note === "" ? 46 : 70
                        T { y: 13; text: parent.label; ink: win.ink2 }
                        Row { anchors.right: parent.right; y: 13; spacing: 6
                            T { text: parent.parent.value; w: Tacit.weight.medium; ink: parent.parent.quiet ? win.ink3 : Tacit.inkMain }
                            K.Symbol { visible: parent.parent.chevron; text: "expand_more"; size: 15; color: win.ink3; anchors.verticalCenter: parent.verticalCenter } }
                        T { visible: parent.note !== ""; y: 40; width: parent.width; text: parent.note; size: Tacit.size.meta; ink: win.ink3 }
                        Rectangle { y: parent.height - 1; width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.07) }
                    }
                    component SetHead: Row {
                        property string text; property bool agent: false
                        spacing: 8; height: 44
                        AgentStroke { visible: parent.agent; anchors.verticalCenter: parent.verticalCenter }
                        T { text: parent.text; size: Tacit.size.body; w: Tacit.weight.strong; ink: parent.agent ? shell.agentInk : Tacit.inkMain; anchors.verticalCenter: parent.verticalCenter }
                    }
                    Column {
                        x: parent.c1; y: 190; width: 600; spacing: 0
                        SetHead { text: "Accounts" }
                        SetRow { label: "Personal, lorenz@example.com"; value: "Signed in"; chevron: false; quiet: true }
                        SetRow { label: "Work, lorenz@moss.example"; value: "Signed in"; chevron: false; quiet: true }
                        Item { width: 1; height: 12 }
                        Row { spacing: 26
                            Act { text: "Add account" }
                            Act { text: "Remove an account" } }
                        Item { width: 1; height: 40 }
                        SetHead { text: "Your agent"; agent: true }
                        SetRow { label: "Draft replies for you to review"; value: "On" }
                        SetRow { label: "Sort new mail into mailboxes"; value: "Off" }
                        SetRow { label: "Mail it may read"; value: "Work only" }
                        SetRow { label: "Sending"; value: "Never on its own"; chevron: false; quiet: true; note: "Your agent can prepare mail. Only you send it." }
                    }
                    Column {
                        x: parent.c2; y: 190; width: 600; spacing: 0
                        SetHead { text: "Sending" }
                        SetRow { label: "Undo after sending"; value: "10 seconds" }
                        SetRow { label: "Signature for Work"; value: "Lorenz, Moss Studio" }
                        SetRow { label: "Signature for Personal"; value: "Lorenz" }
                        Item { width: 1; height: 40 }
                        SetHead { text: "Reading" }
                        SetRow { label: "Pictures from the web"; value: "Ask first"; note: "Pictures in mail can tell the sender when you opened it." }
                        Item { width: 1; height: 40 }
                        SetHead { text: "Notifications" }
                        SetRow { label: "New mail"; value: "From people only" }
                    }
                }

                // ------------------------------------------------ mail arriving: the reader says so, once

            }

            // ------------------------------------------------ new mail while you work in another app: a Tacit notification
            Item {
                visible: shell.notifyNow
                anchors.fill: parent
                Frost { bx: shell.sw - 520; by: 0; bw: 520; bh: 190 }
                Item {
                    x: shell.sw - 520; y: 0; width: 520; height: 250
                    T { x: 28; y: 28; text: "Anna Richter"; w: Tacit.weight.strong }
                    T { anchors.right: parent.right; anchors.rightMargin: 28; y: 30; text: "Mail  ·  now"; size: Tacit.size.meta; ink: Tacit.kitInkMeta }
                    T { x: 28; y: 52; text: "A small question about Tuesday"; w: Tacit.weight.medium }
                    T { x: 28; y: 76; width: 520 - 56; wrapMode: Text.Wrap; text: "Would Tuesday still work for you? I can make either 11:00 or 14:30."; ink: Tacit.inkSec }
                    Row { x: 28; y: 140; spacing: 24
                        Act { text: "Reply"; size: Tacit.size.meta; ink: Tacit.inkMain }
                        Act { text: "Open in Mail"; size: Tacit.size.meta }
                        Act { text: "Mark as read"; size: Tacit.size.meta }
                        Row { spacing: 6
                            AgentStroke { anchors.verticalCenter: parent.verticalCenter }
                            Act { text: "Ask your agent to reply"; size: Tacit.size.meta; ink: shell.agentInk } } }
                }
            }
        }

        Timer {
            interval: 4500; running: true
            onTriggered: scene.grabToImage(r => { r.saveToFile(Quickshell.env("DUNE_SHOT")); console.info("DUNE saved"); Qt.quit(); })
        }
    }
}
