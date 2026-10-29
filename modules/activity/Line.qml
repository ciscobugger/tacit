import QtQuick
import Quickshell
import qs.modules.common
import qs.modules.common.widgets

// One row of a list: icon, name (and a few words after it), the amount on the right. Every row the same
// size, kept apart by space alone (no lines between them); the cause by brightness (full ink, amount in
// sand), the rest faint. Hover or keyboard focus lifts a row to full ink and shows Quit beside the amount.
Item {
    id: r
    property var item: ({})
    signal opened(var item)
    signal act(var item, string what)

    readonly property bool canOpen: item.open ?? false
    readonly property string quitText: item.quit ?? ""
    readonly property var verbs: item.verbs ?? []
    readonly property bool verbsOnHover: item.verbsOnHover ?? false     // the row's own buttons come with Quit, on hover
    readonly property bool hot: item.hot ?? false
    readonly property bool dim: item.dim ?? false
    readonly property bool more: item.fold ?? false
    readonly property bool hovered: hov.hovered || (Ink.previewHover !== "" && Ink.previewHover === (item.key ?? ""))
    property bool confirming: false
    readonly property bool lit: (hovered && (canOpen || quitText !== "" || verbs.length > 0)) || activeFocus || confirming
    readonly property bool showQuit: quitText !== "" && (verbs.length === 0 || verbsOnHover) && (hovered || activeFocus || confirming)
    readonly property bool showVerbs: !verbsOnHover || hovered || activeFocus || confirming
    readonly property color ink: lit ? Ink.main : more ? (hot ? Ink.main : Ink.sec) : dim ? Ink.faint : Ink.main

    height: 46
    // a closing app fades to a third; a pressed row gives a little; `appear` is the list's fade-in (its
    // own property, so the transition does not overwrite this binding)
    property real appear: 1
    opacity: appear * (item.fade ?? 1) * (press.pressed ? 0.8 : 1)
    Behavior on opacity { Anim { type: Anim.FastEffects } }
    activeFocusOnTab: canOpen || quitText !== ""
    onActiveFocusChanged: if (!activeFocus && !quitVerb.activeFocus) confirming = false
    Keys.onReturnPressed: if (canOpen) r.opened(r.item)
    Keys.onDeletePressed: if (quitText !== "") { r.confirming = true; quitVerb.forceActiveFocus(); }
    Keys.onEscapePressed: event => { if (r.confirming) { r.confirming = false; r.forceActiveFocus(); } else event.accepted = false; }

    HoverHandler {
        id: hov
        cursorShape: r.canOpen ? Qt.PointingHandCursor : Qt.ArrowCursor
        // the list holds still while the pointer is on a row (Data.frozen)
        onHoveredChanged: {
            if (hovered)
                Ink.pointerRow = r.item.key ?? "";
            else if (Ink.pointerRow === (r.item.key ?? ""))
                Ink.pointerRow = "";
        }
    }
    MouseArea {
        id: press
        anchors.fill: parent
        enabled: r.canOpen
        onClicked: r.opened(r.item)
    }

    Item {
        id: icon
        visible: !r.more
        x: 0
        anchors.verticalCenter: parent.verticalCenter
        width: 28
        height: 28
        opacity: r.dim && !r.lit ? 0.45 : 1
        Behavior on opacity { Anim { type: Anim.FastEffects } }
        readonly property bool drawn: (r.item.icon ?? "") !== "" && img.status !== Image.Error
        Image {
            id: img
            visible: icon.drawn
            anchors.fill: parent
            source: r.item.icon ?? ""
            sourceSize: Qt.size(64, 64)
            smooth: true
            mipmap: true
        }
        Rectangle {
            visible: !icon.drawn
            anchors.fill: parent
            radius: 8
            color: "#2b2826"
            MaterialSymbol {
                anchors.centerIn: parent
                text: r.item.sym ?? "apps"
                iconSize: 18
                color: "#d9c9bf"
            }
        }
    }
    // the name, and after it what it is doing ("4 sessions", "waiting for you")
    Row {
        x: r.more ? 0 : 44
        anchors.verticalCenter: parent.verticalCenter
        width: amountRow.x - x - 16
        spacing: 0
        T {
            id: nameText
            text: r.item.n ?? ""
            width: Math.min(implicitWidth, parent.width)
            elide: Text.ElideRight
            font.pixelSize: 17
            font.weight: Font.Medium
            color: r.ink
            Behavior on color { Ease {} }
            // keyboard focus: a row that is already at full ink shows it under its name
            Rectangle {
                opacity: r.activeFocus ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { Anim { type: Anim.FastEffects } }
                anchors.top: parent.bottom
                anchors.topMargin: 2
                width: parent.width
                height: 2
                radius: 1
                color: Ink.sec
            }
        }
        T {
            visible: (r.item.detail ?? "") !== ""
            text: "  ·  " + (r.item.detail ?? "")
            width: Math.min(implicitWidth, Math.max(0, parent.width - nameText.width))
            elide: Text.ElideRight
            font.pixelSize: 17
            color: (r.item.detailHot ?? false) ? Ink.sand : r.dim && !r.lit ? Ink.faint : Ink.sec
            Behavior on color { Ease {} }
        }
    }
    // the right edge: actions, then the amount
    Row {
        id: amountRow
        x: r.width - width
        anchors.verticalCenter: parent.verticalCenter
        spacing: 16
        Repeater {
            model: r.verbs
            Verb {
                required property var modelData
                anchors.verticalCenter: parent.verticalCenter
                opacity: r.showVerbs ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { Anim { type: Anim.FastEffects } }
                text: modelData.text
                primary: modelData.primary ?? false
                later: modelData.later ?? false
                px: 14
                padV: 12
                padH: 28
                onClicked: r.act(r.item, modelData.act)
            }
        }
        // Quit comes in from the amount's side as it fades up, and goes the same way
        Verb {
            id: quitVerb
            opacity: r.showQuit ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { Anim { type: Anim.FastEffects } }
            transform: Translate {
                x: r.showQuit ? 0 : 10
                Behavior on x { Anim { type: Anim.FastSpatial } }
            }
            anchors.verticalCenter: parent.verticalCenter
            text: r.quitText
            px: 14
            padV: 12
            padH: 28
            primary: r.confirming
            onClicked: { r.confirming = false; r.act(r.item, "quit"); }
            Keys.onEscapePressed: { r.confirming = false; r.forceActiveFocus(); }
            onActiveFocusChanged: if (!activeFocus && !r.activeFocus) r.confirming = false
        }
        T {
            anchors.verticalCenter: parent.verticalCenter
            text: (r.item.c1 ?? "") + (r.more && r.canOpen ? "  ›" : "")
            font.pixelSize: 16
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
            color: r.hot && !r.more ? Ink.sand : r.ink
            Behavior on color { Ease {} }
        }
    }
}
