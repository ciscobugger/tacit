import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import org.kde.syntaxhighlighting
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * One file in the side panel, read-only: Code's look (gutter, diff marks against the file's own
 * repository, the Martida highlighter), following the file on disk. When it changes (Claude
 * editing it), only the changed lines are replaced, the view goes to them and they flash.
 * Images are shown as images; Markdown as rendered text with a Source switch.
 *
 * The code view is made anew for each file and its text is never swapped whole: replacing a
 * highlighted document while the highlighter still had queued work crashed the app
 * (QSyntaxHighlighter::rehighlightBlock on a block that no longer existed).
 */
Item {
    id: viewer

    property string path: ""
    signal openInCode(int line)

    readonly property string ext: viewer.path.includes(".") ? viewer.path.split(".").pop().toLowerCase() : ""
    readonly property bool isImage: ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif"].includes(viewer.ext)
    readonly property bool isMarkdown: viewer.ext === "md" || viewer.ext === "markdown"
    property bool showSource: false
    property string text: ""
    property string problem: ""        // too large, binary, gone
    property bool loaded: false
    readonly property int lineCount: viewer.loaded ? viewer.text.split("\n").length : 0

    // the line to show once the text is in: a number, or the first line holding `find`
    property int wantLine: 0
    property string wantFind: ""
    function goTo(line, find) {
        viewer.wantLine = line || 0;
        viewer.wantFind = find || "";
        if (codeLoader.item) viewer.applyGoTo();
    }
    function applyGoTo() {
        let n = viewer.wantLine;
        if (viewer.wantFind.length) {
            const i = viewer.text.split("\n").findIndex(l => l.includes(viewer.wantFind));
            if (i >= 0) n = i + 1;
        }
        viewer.wantLine = 0; viewer.wantFind = "";
        if (n > 0 && codeLoader.item) { codeLoader.item.scrollTo(n); codeLoader.item.flash(n, 1); }
    }

    // ── the file on disk ────────────────────────────────────────────────────
    onPathChanged: {
        codeLoader.active = false;
        viewer.loaded = false; viewer.text = ""; viewer.problem = ""; viewer.marks = {}; viewer.showSource = false;
    }
    // An image is read by the Image below, not here, but it is still watched: Image caches by URL,
    // so a re-render at the same path needs a URL that changes with the file.
    property int rev: 0
    FileView {
        id: imageWatch
        path: viewer.isImage && viewer.path.length ? viewer.path : ""
        watchChanges: true
        printErrors: false
        onFileChanged: viewer.rev++
    }
    FileView {
        id: disk
        path: viewer.isImage || !viewer.path.length ? "" : viewer.path
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: viewer.take(disk.text())
        onLoadFailed: { viewer.problem = "This file is gone."; viewer.loaded = true; }
    }
    function take(t) {
        if (t.length > 2000000) { viewer.problem = "Too large to show here."; viewer.loaded = true; return; }
        if (t.substring(0, 8000).includes("\u0000")) { viewer.problem = "A binary file."; viewer.loaded = true; return; }
        const before = viewer.text;
        if (codeLoader.item && t === before) return;
        viewer.text = t;
        viewer.problem = "";
        viewer.loaded = true;
        viewer.refreshMarks();
        if (!codeLoader.item) { codeLoader.active = true; return; }   // the view takes the text as it is made
        // what changed: the lines between the common start and the common end
        const a = before.split("\n"), b = t.split("\n");
        let p = 0;
        while (p < a.length && p < b.length && a[p] === b[p]) p++;
        let q = 0;
        while (q < a.length - p && q < b.length - p && a[a.length - 1 - q] === b[b.length - 1 - q]) q++;
        codeLoader.item.patch(before, t);
        codeLoader.item.scrollTo(p + 1);
        codeLoader.item.flash(p + 1, Math.max(1, b.length - p - q));
    }

    // ── the diff gutter: the file against the last commit of its own repository ─
    property var marks: ({})
    function refreshMarks() { marksLater.restart(); }
    Timer {
        id: marksLater
        interval: 300
        onTriggered: {
            diffProc.running = false;
            diffProc.command = ["git", "-C", viewer.path.substring(0, viewer.path.lastIndexOf("/")) || "/", "diff", "--no-color", "-U0", "HEAD", "--", viewer.path];
            diffProc.running = true;
        }
    }
    Process {
        id: diffProc
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                for (const l of this.text.split("\n")) {
                    const h = /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(l);
                    if (!h) continue;
                    const oldN = h[1] === undefined ? 1 : Number(h[1]);
                    const start = Number(h[2]);
                    const newN = h[3] === undefined ? 1 : Number(h[3]);
                    if (newN === 0) m[Math.max(1, start)] = "d";
                    else for (let i = start; i < start + newN; i++) m[i] = oldN === 0 ? "a" : "m";
                }
                viewer.marks = m;
            }
        }
    }

    // ── the code view, one per file ─────────────────────────────────────────
    Loader {
        id: codeLoader
        anchors.fill: parent
        active: false
        visible: !viewer.problem.length && !viewer.isImage && !(viewer.isMarkdown && !viewer.showSource)
        sourceComponent: codeView
        onLoaded: viewer.applyGoTo()
    }
    Component {
        id: codeView
        Item {
            id: cv
            readonly property real lineHeight: area.lineCount > 0 ? area.contentHeight / area.lineCount : 18
            readonly property int gutter: Math.max(3, String(area.lineCount).length) * fm.averageCharacterWidth + 36

            function scrollTo(n) {
                flick.contentY = Math.max(0, Math.min((n - 1) * cv.lineHeight - flick.height / 3, flick.contentHeight - flick.height + flick.bottomMargin));
            }
            function flash(line, count) {
                band.y = (line - 1) * cv.lineHeight;
                band.height = count * cv.lineHeight;
                bandFade.restart();
            }
            // the old text becomes the new one by a single edit, as typing would make it: what lies
            // between their common start and their common end is replaced
            function patch(oldT, newT) {
                const m = Math.min(oldT.length, newT.length);
                let s = 0;
                while (s < m && oldT.charCodeAt(s) === newT.charCodeAt(s)) s++;
                let e = 0;
                while (e < m - s && oldT.charCodeAt(oldT.length - 1 - e) === newT.charCodeAt(newT.length - 1 - e)) e++;
                area.readOnly = false;
                if (oldT.length - e > s) area.remove(s, oldT.length - e);
                const ins = newT.substring(s, newT.length - e);
                if (ins.length) area.insert(s, ins);
                area.readOnly = true;
            }

            FontMetrics { id: fm; font: area.font }

            ListView {
                id: numbers
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: cv.gutter
                interactive: false
                clip: true
                model: area.lineCount
                contentY: flick.contentY - flick.topMargin
                delegate: Text {
                    required property int index
                    width: numbers.width - 14
                    height: cv.lineHeight
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: index + 1
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: 13
                    color: Appearance.colors.colInkSecondary
                    opacity: 0.5
                    Rectangle {
                        readonly property string kind: viewer.marks[index + 1] ?? ""
                        visible: kind.length > 0
                        x: numbers.width - 14 + 6
                        width: 3
                        height: kind === "d" ? 4 : parent.height
                        y: kind === "d" ? parent.height - 2 : 0
                        radius: 1.5
                        color: kind === "a" ? Appearance.m3colors.m3primary : kind === "m" ? Appearance.m3colors.m3tertiary : Appearance.colors.colError
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: viewer.openInCode(index + 1)
                    }
                }
            }

            Flickable {
                id: flick
                anchors { left: numbers.right; right: parent.right; top: parent.top; bottom: parent.bottom }
                clip: true
                topMargin: 4
                bottomMargin: height / 2
                contentWidth: Math.max(width, area.contentWidth + 40)
                contentHeight: area.contentHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar {}
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                FastWheel { view: flick }

                Rectangle {
                    id: band
                    width: flick.contentWidth
                    radius: 4
                    color: Appearance.m3colors.m3primary
                    opacity: 0
                    SequentialAnimation {
                        id: bandFade
                        NumberAnimation { target: band; property: "opacity"; to: 0.22; duration: 120 }
                        PauseAnimation { duration: 500 }
                        NumberAnimation { target: band; property: "opacity"; to: 0; duration: 900; easing.type: Easing.OutCubic }
                    }
                }

                TextEdit {

                    // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)

                    font.hintingPreference: Font.PreferNoHinting
                    id: area
                    width: Math.max(flick.width, contentWidth)
                    readOnly: true
                    textFormat: TextEdit.PlainText
                    wrapMode: TextEdit.NoWrap
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: 14
                    color: Appearance.colors.colInkMain
                    selectionColor: Appearance.colors.colSecondaryContainer
                    selectedTextColor: Appearance.colors.colOnSecondaryContainer
                    selectByMouse: true
                    persistentSelection: true
                    tabStopDistance: fm.averageCharacterWidth * 4
                }
            }

            SyntaxHighlighter {
                id: hl
                textEdit: area
                theme: {
                    const t = Repository.theme("Martida");
                    return t.name === "Martida" ? t : Repository.theme(Appearance.m3colors.darkmode ? "Material You Dark" : "Material You Light");
                }
            }
            // the text and the language once, as the view is made; a long file stays uncoloured
            Component.onCompleted: {
                area.text = viewer.text;
                hl.definition = viewer.text.length < 400000 ? Repository.definitionForFileName(viewer.path) : Repository.definitionForName("None");
            }
        }
    }

    // Markdown, rendered the way the conversation renders it
    Flickable {
        id: mdFlick
        visible: viewer.loaded && !viewer.problem.length && viewer.isMarkdown && !viewer.showSource
        anchors.fill: parent
        clip: true
        contentHeight: md.implicitHeight + 40
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: StyledScrollBar {}
        FastWheel { view: mdFlick }
        ClaudeText {
            id: md
            x: 20
            y: 8
            width: mdFlick.width - 40
            readOnly: true
            markdown: viewer.isMarkdown ? viewer.text : ""
        }
    }

    // an image, fitted
    Image {
        visible: viewer.isImage
        anchors { fill: parent; margins: 16 }
        source: viewer.isImage && viewer.path.length ? `file://${viewer.path}?${viewer.rev}` : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
    }

    StyledText {
        visible: viewer.problem.length > 0
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 20 }
        text: viewer.problem
        wrapMode: Text.Wrap
        font.pixelSize: 14
        color: Appearance.colors.colInkSecondary
    }
}
