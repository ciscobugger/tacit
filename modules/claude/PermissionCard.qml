import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The agent asks before running something: what and on what, then Allow once / Always / Deny.
 * Drawn in the composer's tones: the overlay surface and outline, neutral pills (the "yes" a
 * step stronger), no accent fill.
 * "Always" hands back Claude Code's own suggestion, so the rule lands where the CLI puts it.
 */
Rectangle {
    id: card
    property var pending: ({})    // { request, tool, input, suggestions }
    signal answered(bool allow, var permissions)

    readonly property string label: {
        switch (card.pending.tool) {
        case "Bash": return "Run this command?";
        case "Edit": case "MultiEdit": return "Edit this file?";
        case "Write": return "Write this file?";
        case "WebFetch": return "Fetch this page?";
        }
        return `Use ${card.pending.tool ?? "this tool"}?`;
    }
    readonly property string detail: {
        const i = card.pending.input ?? {};
        return i.command ?? i.file_path ?? i.url ?? i.pattern ?? i.query ?? JSON.stringify(i);
    }
    readonly property bool canAlways: (card.pending.suggestions ?? []).length > 0
    // what an edit will change, drawn as a finished one is (DiffView): the path alone asked for a yes to an edit
    // you could not see. Clipped as the transcript clips them.
    readonly property var change: {
        const i = card.pending.input ?? {};
        const clip = t => String(t ?? "").substring(0, 3000);
        const all = k => (i.edits ?? []).map(e => e[k] ?? "").join("\n");
        switch (card.pending.tool) {
        case "Edit": return { old: clip(i.old_string), new: clip(i.new_string) };
        case "MultiEdit": return { old: clip(all("old_string")), new: clip(all("new_string")) };
        case "Write": return { new: clip(i.content) };
        }
        return null;
    }
    // answered: the card stays until the host takes the request away; a second click answered a closed
    // request and put up "That request had already closed"
    property bool sent: false
    opacity: card.sent ? 0.6 : 1
    // still here well after the answer (it did not reach the host): it can be answered again
    Timer { running: card.sent; interval: 5000; onTriggered: card.sent = false }

    implicitHeight: column.implicitHeight + 28
    radius: 14
    // as the composer: on the window's frost with a hairline, where the inks keep their contrast (2026-10-11)
    color: "transparent"
    border.width: 1
    border.color: Appearance.colors.colInkDivider

    ColumnLayout {
        id: column
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
        spacing: 10
        RowLayout {
            spacing: 8
            MaterialSymbol { text: "back_hand"; iconSize: 17; color: Appearance.colors.colInkSecondary }
            StyledText {
                Layout.fillWidth: true
                text: card.label
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: Appearance.colors.colInkMain
            }
        }
        StyledText {
            Layout.fillWidth: true
            text: card.detail
            wrapMode: Text.WrapAnywhere
            maximumLineCount: 6
            elide: Text.ElideRight
            font.family: Appearance.font.family.monospace
            font.pixelSize: 14
            color: Appearance.colors.colInkSecondary
        }
        DiffView {
            visible: card.change !== null
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? Math.min(implicitHeight, 220) : 0
            item: card.change ?? ({})
        }
        Row {
            spacing: 8
            Repeater {
                model: [
                    { label: "Allow once", accent: true, allow: true, always: false },
                    { label: "Always allow", accent: false, allow: true, always: true },
                    { label: "Deny", accent: false, allow: false, always: false }
                ].filter(b => !b.always || card.canAlways)
                delegate: Rectangle {
                    required property var modelData
                    // Allow once on sand, Always allow on the soft fill, Deny an outline: three
                    // buttons that look like buttons, the likely one first
                    readonly property real tone: modelData.allow ? 0.9 : 1
                    width: btnText.implicitWidth + 28
                    height: 32
                    radius: Appearance.rounding.full
                    color: modelData.accent ? (btnArea.pressed ? Qt.darker(Appearance.colors.colPrimary, 1.1) : btnArea.containsMouse ? Qt.lighter(Appearance.colors.colPrimary, 1.08) : Appearance.colors.colPrimary)
                         : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, btnArea.pressed ? tone - 0.1 : btnArea.containsMouse ? tone - 0.05 : tone)
                    Behavior on color { enabled: !btnArea.pressed; ColorAnimation { duration: 110 } }
                    border.width: modelData.allow ? 0 : 1
                    border.color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.82)
                    StyledText {
                        id: btnText
                        anchors.centerIn: parent
                        text: modelData.label
                        font.pixelSize: 14
                        font.weight: modelData.accent ? Font.DemiBold : Font.Medium
                        color: modelData.accent ? Appearance.m3colors.m3onPrimary : Appearance.colors.colInkMain
                    }
                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: !card.sent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { card.sent = true; card.answered(modelData.allow, modelData.always ? card.pending.suggestions : null); }
                    }
                }
            }
        }
    }
}
