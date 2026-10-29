import QtQuick
import QtQuick.Controls
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.tacit

// One tool call as a single quiet line (OpenChamber's tool row: icon, name, muted detail).
// A call with something to show turns its icon into a chevron on hover; a click opens it under
// a thin rail: the diff for an edit, the start of the output otherwise. Edits carry their line
// counts in the palette's success/error tones and, on hover, a button to open the file in Code.
Item {
    id: line
    property var item: ({})
    // Whether the output is open is the conversation's to keep (by call id): this line is rebuilt
    // whenever the group updates and dropped when it scrolls far out of view.
    property var openIds: null
    property bool selfOpen: false      // a call the transcript gave no id to
    readonly property string callId: line.openIds ? (line.item.id ?? "") : ""
    readonly property bool open: line.callId.length ? line.openIds[line.callId] === true : line.selfOpen
    signal toggled(string key)
    property bool running: false       // the step the agent is on right now
    property var viewer: null          // MediaViewer for images
    property var files: null           // the side panel, where a file opens (Ctrl: in Code)
    property bool calm: false          // true: sand for added, meta for removed; the owner's choice is green and red
    readonly property bool asked: line.item.tool === "AskUserQuestion"
    readonly property string headline: line.asked ? (line.item.summary ?? "") : (line.item.desc ?? "")
    // a question's answer, from the tool result: "…"="Blue"
    readonly property string answer: {
        if (!line.asked) return "";
        const out = [];
        const re = /"[^"]*"="([^"]*)"/g;
        let m;
        while ((m = re.exec(line.item.result ?? "")) !== null) out.push(m[1]);
        return out.join(" · ");
    }
    readonly property var pictures: line.item.images ?? []
    readonly property bool hasDiff: (line.item.old ?? "").length > 0 || (line.item.new ?? "").length > 0 || (line.item.patch ?? "").length > 0
    readonly property bool hasResult: (line.item.result ?? "").length > 0
    readonly property bool opens: line.hasDiff || line.hasResult
    readonly property string file: line.item.files && line.item.files.length === 1 ? line.item.files[0].path
        : line.item.tool === "Read" && (line.item.summary ?? "").length ? line.item.summary.replace(/^~(?=\/)/, Quickshell.env("HOME")) : ""
    readonly property int added: (line.item.files ?? []).reduce((n, f) => n + (f.add ?? 0), 0)
    readonly property int removed: (line.item.files ?? []).reduce((n, f) => n + (f.del ?? 0), 0)
    // Opening and closing run on this one value: the body's height, its clip and its fade all follow
    // it, so the lines below move with the content. It changes only on a click; a body that grows
    // while open (a result coming in) grows at once.
    property real progress: line.open ? 1 : 0
    Behavior on progress { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    readonly property bool shown: line.progress > 0
    implicitHeight: row.height + (line.pictures.length ? thumbs.height + 8 : 0) + (body.height + 4) * line.progress

    function glyph(t) {
        switch (t) {
        case "Bash": case "shell": case "shell_command": case "exec_command": return "terminal";
        case "Edit": case "MultiEdit": case "NotebookEdit": case "apply_patch": return "edit_note";
        case "Write": return "note_add";
        case "Read": case "view_image": return "description";
        case "Grep": case "Glob": return "manage_search";
        case "WebSearch": case "WebFetch": return "language";
        case "Agent": case "Task": return "smart_toy";
        case "Skill": return "bolt";
        case "TodoWrite": case "update_plan": return "checklist";
        case "AskUserQuestion": return "help";
        }
        return "build";
    }
    // Names as OpenChamber shows them: Shell, Read, Edit, Search, Fetch.
    function label(t) {
        switch (t) {
        case "Bash": case "shell": case "shell_command": case "exec_command": return "Shell";
        case "Grep": case "Glob": case "WebSearch": return "Search";
        case "WebFetch": return "Fetch";
        case "apply_patch": case "MultiEdit": return "Edit";
        case "TodoWrite": case "update_plan": return "Plan";
        case "Agent": case "Task": return "Agent";
        case "AskUserQuestion": return "Asked";
        }
        return t ?? "";
    }

    Item {
        id: row
        width: parent.width
        height: 34
        HoverHandler { id: hover }
        Rectangle {
            anchors { fill: parent; leftMargin: -6; rightMargin: -6 }
            radius: Appearance.rounding.small
            color: hover.hovered && line.opens ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
        }
        MaterialSymbol {
            id: icon
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            visible: !line.running
            text: line.item.error ? "error" : (line.opens && (hover.hovered || line.open) ? (line.open ? "expand_more" : "chevron_right") : line.glyph(line.item.tool))
            iconSize: 17
            color: line.item.error ? Appearance.colors.colClay : Appearance.colors.colInkSecondary
        }
        LiveDot {
            visible: line.running
            anchors { horizontalCenter: icon.horizontalCenter; verticalCenter: parent.verticalCenter }
        }
        ShineText {
            id: name
            anchors { left: icon.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
            width: Math.min(implicitWidth, row.width * (line.headline.length ? 0.62 : 0.3))
            text: line.headline.length ? line.headline : line.label(line.item.tool)
            pixelSize: 15
            weight: Font.Medium
            active: line.running
            rests: true
            opacity: line.running ? 1 : 0.85
        }
        StyledText {
            anchors { left: name.right; leftMargin: 8; right: trailing.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
            text: line.asked ? (line.answer.length ? `→ ${line.answer}` : "") : (line.item.summary ?? "")
            // a command, never markup: as rich text a "<h1>" in a grep became a heading and the lines spilled over the rows around
            textFormat: Text.PlainText
            maximumLineCount: 1
            elide: Text.ElideRight
            font.family: line.headline.length && !line.asked ? Appearance.font.family.monospace : Appearance.font.family.main
            font.pixelSize: line.headline.length ? 14 : 15
            color: Appearance.colors.colInkMeta
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: line.opens ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                if (!line.opens) return;
                if (line.callId.length) line.toggled(line.callId);
                else line.selfOpen = !line.selfOpen;
            }
        }
        Row {
            id: trailing
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 6
            StyledText {
                visible: line.added > 0
                anchors.verticalCenter: parent.verticalCenter
                text: `+${line.added}`
                font.family: Appearance.font.family.numbers
                font.pixelSize: 14
                color: line.calm ? Appearance.colors.colPrimary : Appearance.m3colors.m3success
            }
            StyledText {
                visible: line.removed > 0
                anchors.verticalCenter: parent.verticalCenter
                text: `−${line.removed}`
                font.family: Appearance.font.family.numbers
                font.pixelSize: 14
                color: line.calm ? Appearance.colors.colInkMeta : Appearance.m3colors.m3error
            }
            MaterialSymbol {
                visible: line.file.length > 0 && hover.hovered
                anchors.verticalCenter: parent.verticalCenter
                text: "open_in_new"
                iconSize: 15
                color: openArea.containsMouse ? Appearance.colors.colInkMain : Appearance.colors.colInkSecondary
                MouseArea {
                    id: openArea
                    anchors { fill: parent; margins: -6 }
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // at the edit: the first line of what was written is found in the file
                    onClicked: m => {
                        const find = ((line.item.new ?? "").split("\n").find(l => l.trim().length) ?? "").trim();
                        if (line.files && !(m.modifiers & Qt.ControlModifier)) line.files.openFile(line.file, 0, find);
                        else Quickshell.execDetached([`${Directories.tacitBin}/code-file`, line.file, "0", find]);
                    }
                }
                StyledToolTip { text: line.files ? "Open (Ctrl: in Graphis)" : "Open in Graphis"; extraVisibleCondition: openArea.containsMouse }
            }
        }
    }

    Thumbs {
        id: thumbs
        visible: line.pictures.length > 0
        anchors { top: row.bottom; topMargin: 4; left: parent.left; leftMargin: 23; right: parent.right }
        paths: line.pictures
        viewer: line.viewer
    }

    Item {
        id: reveal
        visible: line.shown
        clip: line.progress < 1
        anchors { top: line.pictures.length ? thumbs.bottom : row.bottom; topMargin: line.pictures.length ? 6 : 2; left: parent.left; right: parent.right }
        height: body.height * line.progress
        Item {
            id: body
            opacity: line.progress
            anchors { top: parent.top; left: parent.left; leftMargin: 7; right: parent.right }
            height: (line.hasDiff ? diffView.implicitHeight : Math.min(resultText.implicitHeight, 320)) + 8
            Rectangle {
                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                width: 1
                color: Appearance.m3colors.m3outlineVariant
            }
            DiffView {
                id: diffView
                visible: line.hasDiff
                anchors { left: parent.left; leftMargin: 12; right: parent.right; top: parent.top }
                height: implicitHeight
                item: line.shown && line.hasDiff ? line.item : ({})
                calm: line.calm
            }
            Flickable {
                id: resultFlick
                visible: !line.hasDiff
                anchors { fill: parent; leftMargin: 12; bottomMargin: 8 }
                clip: true
                contentHeight: resultText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                GlideWheel { view: resultFlick; chain: true; gain: 1.6; gainPerSpeed: 3; gainMax: 6 }
                StyledText {
                    id: resultText
                    width: parent.width
                    text: line.shown ? (line.item.result ?? "") : ""
                    textFormat: Text.PlainText   // what the tool printed, as printed (a fetched page is not rendered)
                    wrapMode: Text.Wrap
                    font.family: Appearance.font.family.monospace
                    font.pixelSize: 14
                    color: Appearance.colors.colInkSecondary
                }
            }
        }
    }
}
