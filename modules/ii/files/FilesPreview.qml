import QtQuick
import Qt5Compat.GraphicalEffects
import Qt.labs.folderlistmodel
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import Tacit.Kit as K

/**
 * The docked panel's face for the selection (kit v0, "Docked panel"): its content, one Slab, actions as words, the
 * trash last in the risk ink. A picture shows itself; a song its cover and what its tags say; a video its poster, its
 * size and length; a text its first lines; a folder how much is in it; several files their count and size. Each fact
 * once: the row already says name, source, size and time, so the face says what the row cannot. Tags, EXIF and posters
 * come from the Viewer's probe (scripts/viewer/probe.py), asked a beat after the selection settles.
 */
Item {
    id: face

    property string path: ""            // the file the keyboard is on
    property bool isDir: false
    property double size: 0
    property bool showHidden: false
    property int many: 0                // more than one selected: a sum, not a file
    property int manyDirs: 0
    property double manyBytes: 0
    property var actions: []
    property bool showLook: true        // the Gallery shows the picture itself: here only what it is
    property bool sizeSaid: true        // a list row says the size; a grid cell does not
    signal open()
    signal more(Item at)

    readonly property var thing: Things.describe(face.path + (face.isDir ? "/" : ""))
    readonly property string kind: face.path.length > 0 ? face.thing.kind : ""
    readonly property bool looks: face.many === 0 && (face.kind === "image" || face.kind === "audio" || face.kind === "video")
    readonly property bool reads: face.many === 0 && (face.kind === "text" || face.kind === "code")
    readonly property var facts: face.probed[face.path] ?? null
    readonly property real side: width - 2 * K.Kit.tokens.space.xl

    // ---- what the probe and the first bytes say, per path
    property var probed: ({})
    property string headPath: ""
    property var head: []
    readonly property string probeScript: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/viewer/probe.py`
    function ask() {
        if (!face.visible || face.many > 0 || face.path.length === 0)
            return;
        if (face.looks && face.probed[face.path] === undefined && !probe.running) {
            probe.target = face.path;
            probe.running = true;
        }
        if (face.reads && face.headPath !== face.path && !headProc.running) {
            headProc.target = face.path;
            headProc.running = true;
        }
    }
    Timer { id: settle; interval: 120; onTriggered: face.ask() }
    onPathChanged: settle.restart()
    onVisibleChanged: settle.restart()
    Process {
        id: probe
        property string target: ""
        command: ["nice", "-n", "10", "python3", face.probeScript, "facts", probe.target]
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try { r = JSON.parse(text); } catch (e) {}
                face.probed = Object.assign({}, face.probed, { [probe.target]: r ?? {} });
            }
        }
        onExited: face.ask()   // the selection may have moved on meanwhile
    }
    Process {
        id: headProc
        property string target: ""
        command: ["head", "-c", "4096", "--", headProc.target]
        stdout: StdioCollector {
            onStreamFinished: {
                face.headPath = headProc.target;
                face.head = text.indexOf("\u0000") >= 0 ? [] : text.replace(/\r/g, "").replace(/\t/g, "    ").split("\n");
            }
        }
        onExited: face.ask()
    }
    // a folder: how much is in it
    FolderListModel {
        id: inside
        folder: face.isDir && face.many === 0 && face.visible ? "file://" + face.path : ""
        showHidden: face.showHidden
        showDotAndDotDot: false
    }

    function clock(sec) {
        const s = Math.round(sec), h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = String(s % 60).padStart(2, "0");
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${r}` : `${m}:${r}`;
    }
    function dims(f) {
        return f && f.w > 0 && f.h > 0 ? `${f.w} × ${f.h}` : "";
    }
    // EXIF's "2026:10:22 18:04:12" as "22 October 2026 at 18:04"
    function taken(s) {
        const m = /^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2})/.exec(s ?? "");
        if (!m)
            return "";
        const month = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                       "November", "December"][Number(m[2]) - 1] ?? "";
        return `${Number(m[3])} ${month} ${m[1]} at ${m[4]}:${m[5]}`;
    }
    // the one line under the name: what the row cannot say
    readonly property string line: {
        const f = face.facts;
        const sz = face.sizeSaid || face.isDir ? "" : Voice.size(face.size);
        switch (face.kind) {
        case "folder":
            return inside.status === FolderListModel.Ready ? Voice.count(inside.count, "item") : "";
        case "image": {
            const ex = f?.exif ?? {};
            const when = face.taken(ex.taken);
            const on = (ex.model ?? "").length > 0 ? ex.model : (ex.make ?? "");
            const first = when.length > 0 ? `Taken ${when}${on.length > 0 ? " on " + on : ""}` : "";
            const rest = [face.dims(f), sz].filter(x => x.length > 0).join(", ");
            return first.length > 0 && rest.length > 0 ? `${first}. ${rest}.` : first + rest;
        }
        case "audio": {
            const t = f?.tags ?? {};
            const year = /\d{4}/.exec(t.date ?? t.year ?? "")?.[0] ?? "";
            const album = (t.album ?? "").length > 0 ? t.album + (year ? ` (${year})` : "") : year;
            return [t.artist ?? t.album_artist ?? "", album, f?.duration > 0 ? face.clock(f.duration) : "", sz].filter(x => x.length > 0).join(", ");
        }
        case "video":
            return [face.dims(f), f?.duration > 0 ? face.clock(f.duration) : "", sz].filter(x => x.length > 0).join(", ");
        }
        return sz;
    }
    // "3 files, 2.9 GB"; folders' sizes are not summed, so with a folder in it the size is not said
    readonly property string sum: {
        const files = face.many - face.manyDirs;
        return [files > 0 ? Voice.count(files, "file") : "", face.manyDirs > 0 ? Voice.count(face.manyDirs, "folder") : "",
                face.manyDirs === 0 && face.manyBytes > 0 ? Voice.size(face.manyBytes) : ""].filter(x => x.length > 0).join(", ");
    }

    // ---- the actions: what Enter does as the Slab, a few as words, the rest behind More…, the trash last
    readonly property var slabAction: face.actions.find(a => a.id === "open" || a.id === "restore")
        ?? (face.many > 0 ? face.actions.find(a => a.id === "park") : null) ?? null
    readonly property var riskAction: face.actions.find(a => a.id === "trash") ?? face.actions.find(a => a.id === "delete") ?? null
    readonly property var wordIds: face.many > 0 ? ["renamemany", "compress", "hand"]
        : face.kind === "folder" ? ["terminal", "pin", "unpin", "park", "rename"]
        : face.reads ? ["openwith", "hand", "path"]
        : face.looks ? ["openwith", "park", "phone", "rename"]
        : ["openwith", "extract", "park", "phone", "rename"]
    readonly property var words: face.wordIds.map(id => face.actions.find(a => a.id === id)).filter(a => !!a).slice(0, 4)
    readonly property bool moreThere: face.actions.length > face.words.length + (face.slabAction ? 1 : 0) + (face.riskAction ? 1 : 0)

    // the content changing with the selection fades in (kit: Fade, fast)
    readonly property string subject: face.many > 0 ? "many" : face.path
    onSubjectChanged: fadeIn.restart()
    NumberAnimation {
        id: fadeIn
        target: content; property: "opacity"; from: 0; to: 1
        duration: K.Kit.tokens.motion.fadeFast.ms
        easing.type: Easing.BezierSpline; easing.bezierCurve: K.Kit.tokens.motion.fadeFast.curve
    }

    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: content.height + 2 * K.Kit.tokens.space.xl
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        clip: true

        Column {
            id: content
            x: K.Kit.tokens.space.xl
            y: K.Kit.tokens.space.xl
            width: face.side

            // the look: a picture itself, a song's cover, a video's poster; whole, at its own shape
            Item {
                id: art
                readonly property string source: face.many > 0 || !face.showLook ? ""
                    : face.kind === "image" ? "file://" + face.path
                    : face.looks && (face.facts?.thumb ?? "").length > 0 ? "file://" + face.facts.thumb : ""
                readonly property real ratio: look.implicitHeight > 0 ? look.implicitWidth / look.implicitHeight : 1
                // what the panel's height leaves after the words under it, so the actions stay in view
                readonly property real cap: Math.max(160, Math.min(face.side, face.height - 2 * K.Kit.tokens.space.xl - 20 - info.height))
                width: Math.min(face.side, art.cap * art.ratio)
                height: look.status === Image.Ready ? Math.min(art.cap, art.width / art.ratio) : 0
                visible: height > 0
                Image {
                    id: look
                    anchors.fill: parent
                    source: art.source
                    asynchronous: true
                    cache: false
                    autoTransform: true
                    sourceSize.width: 720
                    sourceSize.height: 720
                    fillMode: Image.PreserveAspectCrop
                    visible: false
                }
                OpacityMask {
                    anchors.fill: parent
                    source: look
                    maskSource: Rectangle { width: art.width; height: art.height; radius: K.Kit.tokens.radius.slab }
                }
            }
            Item { width: 1; height: art.visible ? 20 : 0 }

            Column {
                id: info
                width: parent.width

                // several: how many, how much
                K.TacitText {
                    visible: face.many > 0
                    width: parent.width
                    text: face.sum
                    size: "section"; weight: "strong"
                    wrapMode: Text.Wrap
                }
                // a text: the text itself (no name: the row says it)
                Column {
                    id: lines
                    visible: face.reads
                    width: parent.width
                    readonly property int fits: Math.max(4, Math.floor((face.height - 2 * K.Kit.tokens.space.xl - actionsBlock.height) / 22))
                    Repeater {
                        model: face.reads && face.headPath === face.path ? face.head.slice(0, lines.fits) : []
                        K.TacitText {
                            required property string modelData
                            readonly property bool heading: face.path.toLowerCase().endsWith(".md") && /^#{1,6}\s/.test(modelData)
                            width: lines.width
                            height: 22
                            verticalAlignment: Text.AlignVCenter
                            text: modelData.length > 0 ? modelData : " "
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            size: "fileText"; cut: "code"
                            ink: heading ? "main" : "sec"
                            weight: heading ? "medium" : "regular"
                        }
                    }
                }
                // anything else: its name, then the line the row cannot say
                K.TacitText {
                    visible: face.many === 0 && !face.reads
                    width: parent.width
                    text: face.thing.name
                    size: "body"; weight: "medium"
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                Item { width: 1; height: face.many === 0 && !face.reads && face.line.length > 0 ? 6 : 0 }
                K.TacitText {
                    visible: face.many === 0 && !face.reads && face.line.length > 0
                    width: parent.width
                    text: face.line
                    ink: "sec"
                    wrapMode: Text.Wrap
                }

                Column {
                    id: actionsBlock
                    width: parent.width
                    Item { width: 1; height: face.slabAction ? 22 : 6 }
                    K.Slab {
                        visible: !!face.slabAction
                        text: face.slabAction?.label ?? ""
                        tone: "default"
                        // Open goes through the window, as Enter does: a folder opens here, a pick is a choice
                        onPicked: face.slabAction.id === "open" ? face.open() : face.slabAction.run()
                    }
                    Item { width: 1; height: face.slabAction ? 16 : 0 }
                    Repeater {
                        model: face.words
                        K.WordAction {
                            required property var modelData
                            width: face.side
                            text: modelData.label
                            onPicked: modelData.run()
                        }
                    }
                    K.WordAction {
                        id: moreWord
                        visible: face.moreThere
                        width: face.side
                        text: "More…"
                        onPicked: face.more(moreWord)
                    }
                    Item { width: 1; height: face.riskAction && (face.words.length > 0 || face.moreThere) ? 10 : 0 }
                    K.WordAction {
                        visible: !!face.riskAction
                        width: face.side
                        text: face.riskAction?.label ?? ""
                        risk: true
                        onPicked: face.riskAction.run()
                    }
                }
            }
        }
    }
    K.Glide { view: flick }
}
