import QtQuick
import QtQuick.Controls
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The agent asks you something (its AskUserQuestion tool), in the installer's language and Tacit's kit: one question
 * at a time; its choices as setup's rings (the chosen one with a dot of the accent), the words on one edge; your own
 * answer in a soft well; one ring, the way forward, on the right, and Back and Skip as words. Submit sends the answers
 * back the way Claude Code expects ({question: "label, label"}); Skip declines.
 * Every question stacked with Material radios, a box each and an outline filled the window and read as a stock Linux
 * form (2026-10-10, "too big", "not premium").
 */
Rectangle {
    id: card
    property var pending: ({})        // { request, tool: "AskUserQuestion", input: { questions } }
    property var picked: ({})         // question -> [labels]
    property var typed: ({})          // question -> free text for "Something else"
    // the most the card may take; past it the choices scroll and the actions stay in view
    property real maxHeight: 100000
    signal answered(var input)
    signal skipped()

    readonly property var questions: card.pending.input?.questions ?? []
    property int step: 0
    // the question on screen: it follows `step` through a fade, so the card does not swap in one frame
    property int shown: 0
    onStepChanged: swap.restart()
    SequentialAnimation {
        id: swap
        NumberAnimation { target: content; property: "opacity"; to: 0; duration: 90; easing.type: Easing.InCubic }
        ScriptAction { script: card.shown = card.step }
        NumberAnimation { target: content; property: "opacity"; to: 1; duration: 160; easing.type: Easing.OutCubic }
    }
    readonly property var current: card.questions[Math.min(card.shown, card.questions.length - 1)] ?? ({ question: "", options: [] })
    readonly property bool multi: card.current.multiSelect ?? false
    readonly property bool last: card.shown >= card.questions.length - 1
    function answeredQ(q) { return (card.picked[q.question] ?? []).length > 0 || (card.typed[q.question] ?? "").trim().length > 0; }
    readonly property bool complete: card.questions.every(q => card.answeredQ(q))
    readonly property bool ready: card.last ? card.complete : card.answeredQ(card.current)
    // answered or skipped: the card stays until the host takes the request away; a second click answered a
    // closed request and put up "That request had already closed"
    property bool sent: false
    opacity: card.sent ? 0.6 : 1
    // still here well after the answer (it did not reach the host): it can be answered again
    Timer { running: card.sent; interval: 5000; onTriggered: card.sent = false }
    enabled: !card.sent

    function toggle(q, label, multi) {
        const p = Object.assign({}, card.picked);
        const cur = p[q] ?? [];
        p[q] = multi ? (cur.includes(label) ? cur.filter(l => l !== label) : cur.concat([label])) : [label];
        card.picked = p;
        if (!multi) {
            const t = Object.assign({}, card.typed);
            delete t[q];
            card.typed = t;
            advance.restart();
        }
    }
    // a pick in a one-answer question moves on to the next one still open
    Timer {
        id: advance
        interval: 220
        onTriggered: {
            const i = card.questions.findIndex((q, k) => k > card.shown && !card.answeredQ(q));
            if (i >= 0) card.step = i;
        }
    }
    function next() {
        if (!card.ready) return;
        if (card.last) card.submit();
        else card.step = card.shown + 1;
    }
    function submit() {
        const answers = {};
        for (const q of card.questions) {
            const parts = (card.picked[q.question] ?? []).slice();
            const other = (card.typed[q.question] ?? "").trim();
            if (other.length) parts.push(other);
            answers[q.question] = parts.join(", ");
        }
        card.sent = true;
        card.answered(Object.assign({}, card.pending.input, { answers: answers }));
    }

    readonly property int pad: 24
    implicitHeight: card.pad + top.height + 16 + body.height + 24 + footer.height + card.pad
    Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    radius: Appearance.rounding.card
    // as the composer: on the window's frost with a hairline, where the inks keep their contrast (2026-10-11)
    color: "transparent"
    border.width: 1
    border.color: Appearance.colors.colInkDivider

    // where you are: the question's name, and how many there are
    Item {
        id: top
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: card.pad }
        height: 20
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: card.current.header || "A question"
            font.pixelSize: Tacit.size.row
            font.weight: Font.Medium
            color: Tacit.inkSec
        }
        StyledText {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            visible: card.questions.length > 1
            text: `${card.shown + 1} of ${card.questions.length}`
            font.pixelSize: Tacit.size.meta
            color: Tacit.inkMeta
        }
    }

    Flickable {
        id: body
        anchors { left: parent.left; right: parent.right; top: top.bottom; topMargin: 16 }
        height: Math.min(content.implicitHeight, Math.max(120, card.maxHeight - top.height - footer.height - 2 * card.pad - 36))
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: StyledScrollBar {}
        Column {
            id: content
            x: card.pad
            width: body.width - 2 * card.pad
            StyledText {
                width: parent.width
                text: card.current.question
                wrapMode: Text.Wrap
                font.pixelSize: Tacit.size.section
                font.weight: Font.Medium
                color: Tacit.inkMain
            }
            StyledText {
                visible: card.multi
                topPadding: 4
                text: "Choose any"
                font.pixelSize: Tacit.size.meta
                color: Tacit.inkMeta
            }
            Item { width: 1; height: 24 }
            Column {
                width: parent.width
                spacing: 16
                Repeater {
                    model: card.current.options ?? []
                    // setup's Choice at the app's sizes: a ring, the chosen one with a dot of the accent
                    delegate: Item {
                        id: opt
                        required property var modelData
                        readonly property bool on: (card.picked[card.current.question] ?? []).includes(opt.modelData.label)
                        readonly property bool suggested: /\s*\(recommended\)\s*$/i.test(opt.modelData.label)
                        width: content.width
                        height: optText.height
                        Rectangle {
                            y: 2
                            width: 20; height: 20
                            radius: card.multi ? 6 : 10
                            color: "transparent"
                            border.width: 1
                            border.color: opt.on ? ColorUtils.transparentize(Tacit.accent, 0.15) : ColorUtils.transparentize(Tacit.inkMain, optArea.containsMouse ? 0.35 : 0.55)
                            Behavior on border.color { ColorAnimation { duration: 140 } }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 10; height: 10
                                radius: card.multi ? 3 : 5
                                color: Tacit.accent
                                scale: opt.on ? 1 : 0
                                Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            }
                        }
                        Column {
                            id: optText
                            x: 36
                            width: parent.width - 36
                            spacing: 3
                            Row {
                                spacing: 10
                                StyledText {
                                    id: name
                                    width: Math.min(implicitWidth, optText.width - (opt.suggested ? hint.implicitWidth + 10 : 0))
                                    text: opt.modelData.label.replace(/\s*\(recommended\)\s*$/i, "")
                                    wrapMode: Text.Wrap
                                    font.pixelSize: Tacit.size.body
                                    color: Tacit.inkMain
                                }
                                StyledText {
                                    id: hint
                                    visible: opt.suggested
                                    anchors.baseline: name.baseline
                                    text: "Recommended"
                                    font.pixelSize: Tacit.size.meta
                                    color: Tacit.inkMeta
                                }
                            }
                            StyledText {
                                width: parent.width
                                visible: text.length > 0
                                text: opt.modelData.description ?? ""
                                wrapMode: Text.Wrap
                                lineHeight: 1.2
                                font.pixelSize: Tacit.size.row
                                color: Tacit.inkSec
                            }
                        }
                        MouseArea {
                            id: optArea
                            anchors { fill: parent; margins: -6 }
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: card.toggle(card.current.question, opt.modelData.label, card.multi)
                        }
                    }
                }
            }
            Item { width: 1; height: 24 }
            // your own answer: a field on the choices' edge
            Rectangle {
                x: 36
                width: parent.width - 36
                height: 44
                radius: Tacit.radius.slab
                // a hairline like the card's own, brighter while typing: a light fill greyed it
                color: "transparent"
                border.width: 1
                border.color: other.activeFocus ? ColorUtils.mix(Appearance.colors.colInkDivider, Appearance.colors.colInkFaint, 0.3)
                    : otherArea.containsMouse ? ColorUtils.mix(Appearance.colors.colInkDivider, Appearance.colors.colInkFaint, 0.12) : Appearance.colors.colInkDivider
                Behavior on border.color { ColorAnimation { duration: 160 } }
                TextInput {
                    // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)
                    font.hintingPreference: Font.PreferNoHinting
                    id: other
                    anchors { left: parent.left; right: parent.right; leftMargin: 16; rightMargin: 16; verticalCenter: parent.verticalCenter }
                    font.family: Appearance.font.family.main
                    font.pixelSize: Tacit.size.row
                    color: Tacit.inkMain
                    selectionColor: ColorUtils.transparentize(Tacit.accent, 0.6)
                    clip: true
                    onTextChanged: {
                        const q = card.current.question;
                        if ((card.typed[q] ?? "") === text) return;
                        const t = Object.assign({}, card.typed);
                        t[q] = text;
                        card.typed = t;
                        if (text.length && !card.multi) { const p = Object.assign({}, card.picked); delete p[q]; card.picked = p; }
                    }
                    Keys.onReturnPressed: card.next()
                    // each question keeps its own text
                    Connections {
                        target: card
                        function onShownChanged() { other.text = card.typed[card.current.question] ?? ""; }
                        // one answer only: a choice picked after typing here takes its place, so the well
                        // empties too (the typed text stayed on screen and was not sent)
                        function onPickedChanged() {
                            if (!card.multi && other.text.length && (card.picked[card.current.question] ?? []).length) other.text = "";
                        }
                    }
                }
                StyledText {
                    anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
                    visible: other.text.length === 0
                    text: "Something else…"
                    font.pixelSize: Tacit.size.row
                    color: Tacit.inkMeta
                }
                MouseArea {
                    id: otherArea
                    anchors.fill: parent
                    visible: !other.activeFocus
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                    onClicked: other.forceActiveFocus()
                }
            }
        }
    }

    // Back and Skip as words; the way forward, the one ring, on the right
    Item {
        id: footer
        anchors { left: parent.left; right: parent.right; top: body.bottom; topMargin: 24; leftMargin: card.pad; rightMargin: card.pad }
        height: forward.implicitHeight
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: card.shown > 0
            text: "Back"
            font.pixelSize: Tacit.size.row
            color: backArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
            MouseArea { id: backArea; anchors { fill: parent; margins: -8 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: card.step = card.shown - 1 }
        }
        Row {
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            spacing: 24
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Skip"
                font.pixelSize: Tacit.size.row
                color: skipArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                MouseArea { id: skipArea; anchors { fill: parent; margins: -8 } hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { card.sent = true; card.skipped(); } }
            }
            Slab {
                id: forward
                // the width of the forward ring either way: it lighting up does not move Skip
                width: Math.max(104, implicitWidth)
                text: card.last ? "Submit" : "Next"
                tone: card.ready ? "default" : ""
                onPicked: card.next()
            }
        }
    }
}
