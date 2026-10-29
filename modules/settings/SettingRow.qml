import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The line every setting is made of: what it is, what it means underneath when that is not
 * obvious, and the control at the right edge. One height when it is a label alone, taller when
 * it carries a sentence, so a page of settings keeps a rhythm instead of a ragged stack.
 * Inks are Tacit's levels (main / meta), never opacity; a disabled row drops to the faint ink.
 */
Item {
    id: row

    property string label: ""
    property string description: ""
    property string glyph: ""
    property alias leading: leadSlot.data   // a drawn mark in the glyph's place (Signal)
    readonly property bool hasLead: glyphItem.visible || leadSlot.children.length > 0
    property alias control: slot.data
    property bool clickable: true           // the row selects; the control acts
    property bool selected: false
    property bool muted: false              // something hidden or unused: the label in the faint ink
    property bool topRule: false            // a hairline above the row, for rows that form a list
    // the control under the label on the labels' edge, the row's width (an amount, a choice of words):
    // read as part of its row instead of a thing far off at the right
    property bool stacked: false
    // the labels' edge: past the glyphs when the group has any, else on the heading's own edge
    readonly property real edge: row.hasLead || (row.parent?.hasLeadRows ?? true) ? 52 : 20
    // a glyph and a small control sit on the title's line, not the middle of a two-line row
    readonly property real titleMid: labels.y + 10
    signal activated()

    Layout.fillWidth: true
    implicitHeight: row.stacked ? labels.implicitHeight + 12 + 8 + slot.implicitHeight + 14
        : Math.max(row.description.length > 0 ? 62 : 48, slot.implicitHeight + 18)

    // Tab reaches every row; Enter or Space does what a click on it does. A row whose control is a
    // stepper or a set of choices takes the arrow keys as well (StepperRow, ChoiceRow).
    activeFocusOnTab: row.enabled
    // RippleButton's rule: only focus that came from the keyboard draws the ring
    readonly property bool hovered: area.containsMouse   // for a control that shows its word on hover
    readonly property bool keyboardFocus: row.activeFocus
        && (row.focusReason === Qt.TabFocusReason || row.focusReason === Qt.BacktabFocusReason)
    Keys.onReturnPressed: if (row.clickable) row.activated()
    Keys.onEnterPressed: if (row.clickable) row.activated()
    Keys.onSpacePressed: if (row.clickable) row.activated()
    // An inset wash on hover, a deeper one on press, inside the group's surface
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 4
        anchors.rightMargin: 4
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: 10
        // (the chosen row is told by its check and the label's weight, not a bar)
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface,
            row.clickable && area.pressed && row.enabled ? 0.88
            : row.clickable && area.containsMouse && row.enabled ? 0.95 : 1)
        Behavior on color { enabled: !area.pressed; ColorAnimation { duration: 110 } }
    }
    // keyboard focus: a soft 2 px ring of the accent around the same inset
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        radius: 12
        color: "transparent"
        visible: row.keyboardFocus
        border.width: 2
        border.color: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.15)
    }
    // a hairline from the labels' edge between rows of a group (Group.firstRow), or where asked
    readonly property bool ruled: row.topRule || (!!row.parent && row.parent.firstRow !== undefined && row.parent.firstRow !== null && row.parent.firstRow !== row)
    Rectangle {
        visible: row.ruled
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: row.edge
        anchors.rightMargin: 20
        height: 1
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.955)   // receding: the words lead
    }

    MouseArea {
        id: area
        anchors.fill: parent
        enabled: row.clickable && row.enabled
        hoverEnabled: row.clickable
        cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: row.activated()
    }

    MaterialSymbol {
        id: glyphItem
        visible: row.glyph.length > 0
        // placed by x/y, not anchors: an anchor taken away leaves an item where it was
        x: 20
        y: row.titleMid - height / 2
        text: row.glyph
        iconSize: 18
        color: row.enabled && !row.muted ? Tacit.inkMeta : Appearance.colors.colInkFaint
    }

    Item {
        id: leadSlot
        x: 20
        y: row.titleMid - height / 2
        width: 18
        height: 18
    }

    // one edge for every label, with or without a glyph (Praxis's rail: the mark hangs left of it)
    ColumnLayout {
        id: labels
        x: row.edge
        width: row.stacked ? row.width - row.edge - 20 : Math.max(0, slot.x - 16 - row.edge)
        y: row.stacked ? 12 : (row.height - height) / 2
        spacing: 3

        StyledText {
            Layout.fillWidth: true
            text: row.label
            font.pixelSize: 15
            font.weight: row.selected ? Font.Medium : Font.Normal
            color: row.enabled && !row.muted ? Appearance.colors.colInkMain : Appearance.colors.colInkFaint
            elide: Text.ElideRight
        }
        StyledText {
            Layout.fillWidth: true
            visible: row.description.length > 0
            text: row.description
            font.pixelSize: 13
            color: row.enabled ? Tacit.inkMeta : Appearance.colors.colInkFaint
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }

    Item {
        id: slot
        x: row.stacked ? row.edge : row.width - 20 - width
        y: row.stacked ? labels.y + labels.height + 8 : height <= 28 ? row.titleMid - height / 2 : (row.height - height) / 2
        implicitWidth: childrenRect.width
        implicitHeight: childrenRect.height
        width: row.stacked ? row.width - row.edge - 20 : implicitWidth
        height: implicitHeight
        enabled: row.enabled
        opacity: row.enabled ? 1 : 0.4
    }
}
