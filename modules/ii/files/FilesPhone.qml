import QtQuick
import QtQuick.Controls
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import Tacit.Kit as K

/**
 * The phone's page in Files (the rail's "Your phone" under Devices): where a phone is connected the first time, and
 * afterwards where what was sent to it is listed. Not a folder: Files shows it in the list's place, under the header.
 *
 * Not connected: "Connect your phone" (the sentence, three steps, the code to scan on a paper tile, the waiting line).
 * The phone asked: its name, the code both screens must show, Connect and Not now. Connected: the files sent, each
 * with its state (bar, Sent, or Not sent with Try again) and Forget this phone. Files waiting for a phone are listed
 * on the connect page and go when it is connected. A drop on the page sends. Without the part that talks to phones the
 * page says what it is for and has one action that gets it (PhoneLink.setupPhone), with progress and a plain failure;
 * a part that is not running is said in one sentence. State and sending are services/PhoneLink.qml's.
 */
Item {
    id: page

    property real inset: 0             // where the list's names start, in this item
    property real outset: 0            // the same distance from the right edge of this item
    readonly property var t: K.Kit.tokens
    readonly property real side: 7 * page.t.space.xl      // the code's tile: seven of the big space

    // opened by the window: the page is being looked at, and the first answer is the thing to focus
    function focusFirst() {
        if (PhoneLink.asking)
            connectSlab.forceActiveFocus();
    }
    Connections {
        target: PhoneLink
        function onAskingChanged() { if (page.visible && PhoneLink.asking) connectSlab.forceActiveFocus(); }
    }
    // the page holds PhoneLink's quick looking up while it is seen
    property bool watched: false
    function watch(on) {
        if (on === page.watched)
            return;
        page.watched = on;
        PhoneLink.watching += on ? 1 : -1;
        if (on)
            PhoneLink.ensureCode();
    }
    onVisibleChanged: page.watch(visible)
    Component.onCompleted: page.watch(visible)
    Component.onDestruction: page.watch(false)

    readonly property var waitingFiles: PhoneLink.waiting
    readonly property string waitingWords: waitingFiles.length === 1 ? waitingFiles[0].name : Voice.count(waitingFiles.length, "file")

    // a file as it is listed: `s` is a PhoneLink send
    component SendRow: Item {
        id: sr
        required property var s
        x: -page.t.space.m
        width: parent.width + 2 * page.t.space.m
        height: row.height
        readonly property bool failed: s.state === "failed"
        K.ListRow {
            id: row
            width: parent.width
            focusable: false
            glyph: Things.describe(sr.s.path).glyph
            name: sr.s.name
            facts: [sr.failed ? "" : sr.s.state === "waiting" ? "Waits for your phone" : sr.s.state === "sent" ? "Sent"
                : sr.s.state === "sending" ? "Sending" : "Next"]
            factWidths: [sr.failed ? 0 : 96]
            accessory: [Row {
                spacing: page.t.space.l
                Row {
                    visible: sr.failed
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: page.t.space.s
                    K.Symbol { anchors.verticalCenter: parent.verticalCenter; text: "warning"; color: page.t.risk }
                    K.TacitText { text: `Not sent to ${PhoneLink.phoneName}`; ink: "risk" }
                }
                K.WordAction {
                    visible: sr.failed
                    anchors.verticalCenter: parent.verticalCenter
                    width: wordsWidth
                    text: "Try again"
                    onActivated: PhoneLink.retry(sr.s.n)
                }
                K.Progress {
                    visible: sr.s.state === "sending"
                    anchors.verticalCenter: parent.verticalCenter
                    width: 4 * page.t.space.xl
                    going: true
                }
            }]
        }
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: col.y + col.height + page.t.space.xxl
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: StyledScrollBar {}

        Column {
            id: col
            x: page.inset
            y: page.t.space.m
            width: Math.max(0, page.width - page.inset - page.outset)
            spacing: page.t.space.m

            // the part that talks to phones is not here: what it is for, and the one action that gets it
            Column {
                visible: PhoneLink.loaded && !PhoneLink.installed && PhoneLink.setup === ""
                width: col.width
                spacing: page.t.space.l
                K.SectionHeading { x: -page.t.space.l; text: "Your phone" }
                K.TacitText {
                    width: Math.min(560, parent.width)
                    wrapMode: Text.WordWrap
                    ink: "sec"
                    text: "Send files from this computer to your phone over Wi-Fi. This computer needs one more part for that. Setting it up asks for your password and brings the whole system up to date, so it can take a few minutes."
                }
                K.Slab { text: "Set up your phone"; tone: "default"; onPicked: PhoneLink.setupPhone() }
            }
            // getting it
            Column {
                visible: PhoneLink.setup === "working"
                width: Math.min(440, col.width)
                spacing: page.t.space.s
                K.SectionHeading { x: -page.t.space.l; text: "Setting up your phone" }
                K.Progress { width: parent.width; value: PhoneLink.setupProgress }
                K.TacitText { text: PhoneLink.setupPhase; ink: "meta" }
            }
            // it did not happen: nothing was changed, and the way to try again
            K.PageState {
                visible: PhoneLink.setup !== "" && PhoneLink.setup !== "working"
                failure: PhoneLink.setup !== "cancelled"
                text: PhoneLink.setupWords
                action: "Try again"
                onActed: PhoneLink.setupPhone()
            }
            // the part is here but not running
            K.PageState {
                visible: PhoneLink.loaded && PhoneLink.installed && !PhoneLink.running && PhoneLink.setup === ""
                failure: true
                text: "The part that talks to phones is not running. It starts when you sign in."
            }

            // ---- not connected, nobody asking: the way in
            K.SectionHeading { visible: PhoneLink.usable && !PhoneLink.paired && !PhoneLink.asking; x: -page.t.space.l; text: "Connect your phone" }
            Item {
                visible: PhoneLink.usable && !PhoneLink.paired && !PhoneLink.asking
                width: col.width
                height: way.height
                Column {
                    id: way
                    width: col.width - page.side - 2 * page.t.space.xl
                    spacing: page.t.space.l
                    K.TacitText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        ink: "sec"
                        text: (page.waitingFiles.length > 0 ? `${page.waitingWords} goes as soon as your phone is connected. ` : "Send files to your phone from here. ")
                            + "Your phone and this computer need the same Wi-Fi."
                    }
                    Column {
                        width: parent.width
                        spacing: page.t.space.m
                        Repeater {
                            model: ["Scan this code with your phone's camera. The page it opens has the free app for your phone.",
                                    `Open the app and choose “${PhoneLink.computerName}”.`, "Check that both screens show the same code."]
                            Row {
                                id: step
                                required property string modelData
                                required property int index
                                spacing: page.t.space.m
                                K.TacitText { width: page.t.space.l; text: String(step.index + 1); ink: "meta"; cut: "numbers" }
                                K.TacitText { width: way.width - page.t.space.l - page.t.space.m; text: step.modelData; ink: "sec"; wrapMode: Text.WordWrap }
                            }
                        }
                    }
                    Item { width: 1; height: page.t.space.s }
                    Column {
                        spacing: page.t.space.s
                        K.Progress { width: way.width; going: true }
                        K.TacitText { text: "Looking for your phone"; ink: "meta" }
                    }
                }
                // the code, dark dots on the paper tile
                Rectangle {
                    x: parent.width - page.side
                    width: page.side; height: page.side
                    radius: page.t.radius.slab
                    color: page.t.inkMain   // the paper: the main ink as a tile (the kit's paper roles are this)
                    visible: PhoneLink.qrRows.length > 0
                    Accessible.role: Accessible.Graphic
                    Accessible.name: "Code for your phone's camera"
                    Canvas {
                        id: dots
                        anchors.fill: parent
                        readonly property var rows: PhoneLink.qrRows
                        onRowsChanged: requestPaint()
                        onPaint: {
                            const c = getContext("2d");
                            c.reset();
                            const n = rows.length;
                            if (n === 0)
                                return;
                            const m = Math.floor(width / (n + 2))   // one dot of quiet zone;   // whole pixels per dot: crisp edges
                            const x0 = Math.round((width - m * n) / 2), y0 = Math.round((height - m * n) / 2);
                            c.fillStyle = page.t.ground;
                            for (let y = 0; y < n; y++)
                                for (let x = 0; x < n; x++)
                                    if (rows[y][x] === "1")
                                        c.fillRect(x0 + x * m, y0 + y * m, m, m);
                        }
                    }
                }
            }

            // ---- the phone asked to connect
            K.SectionHeading { visible: PhoneLink.usable && !PhoneLink.paired && PhoneLink.asking !== null; x: -page.t.space.l; text: `${PhoneLink.asking?.name ?? ""} wants to connect` }
            Column {
                visible: PhoneLink.usable && !PhoneLink.paired && PhoneLink.asking !== null
                width: Math.min(440, col.width)
                spacing: page.t.space.l
                K.TacitText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    ink: "sec"
                    text: "Connect only if your phone shows the same code." + (page.waitingFiles.length > 0 ? ` ${page.waitingWords} goes right after.` : "")
                }
                K.TacitText { text: PhoneLink.codeOf(PhoneLink.asking?.key); size: "headline"; cut: "numbers"; weight: "medium" }
                Row {
                    spacing: page.t.space.xl
                    K.Slab {
                        id: connectSlab
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.waitingFiles.length > 0 ? "Connect and send" : "Connect"
                        tone: "default"
                        onActivated: PhoneLink.connect()
                    }
                    K.WordAction {
                        anchors.verticalCenter: parent.verticalCenter
                        width: wordsWidth
                        text: "Not now"
                        onActivated: PhoneLink.notNow()
                    }
                }
            }

            // ---- files waiting for a phone
            K.SectionHeading { visible: PhoneLink.usable && !PhoneLink.paired && page.waitingFiles.length > 0; x: -page.t.space.l; text: "Waiting to send" }
            Repeater {
                model: PhoneLink.usable && !PhoneLink.paired ? page.waitingFiles : []
                SendRow { required property var modelData; s: modelData }
            }

            // ---- connected
            K.TacitText {
                visible: PhoneLink.usable && PhoneLink.paired
                width: col.width
                wrapMode: Text.WordWrap
                ink: "sec"
                text: `Drop a file here, or choose Send to ${PhoneLink.phoneName} on any file.`
            }
            K.TacitText {
                visible: PhoneLink.usable && PhoneLink.paired && !PhoneLink.phoneReachable
                width: col.width
                wrapMode: Text.WordWrap
                ink: "meta"
                text: `${PhoneLink.phoneName} is not in reach. Your phone and this computer need the same Wi-Fi.`
            }
            K.SectionHeading { visible: PhoneLink.usable && PhoneLink.paired && PhoneLink.sends.length > 0; x: -page.t.space.l; text: `Files for ${PhoneLink.phoneName}` }
            Repeater {
                model: PhoneLink.usable && PhoneLink.paired ? PhoneLink.sends : []
                SendRow { required property var modelData; s: modelData }
            }
            K.WordAction {
                visible: PhoneLink.usable && PhoneLink.paired
                width: wordsWidth
                text: "Forget this phone"
                onActivated: PhoneLink.forget()
            }
        }
    }

    // a file dropped on the page goes to the phone
    DropArea {
        id: drop
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: d => {
            d.accept();
            PhoneLink.send((d.urls ?? []).map(u => decodeURIComponent(u.toString().replace(/^file:\/\//, ""))));
        }
    }
    Rectangle {
        anchors { fill: parent; margins: 1 }
        visible: drop.containsDrag
        radius: page.t.radius.row
        color: "transparent"
        border.width: 1.5
        border.color: page.t.accent
    }
}
