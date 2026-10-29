import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * A run of settings under a name: the name as a heading above, the rows on the window's own ground
 * with a hairline between rows from the labels' edge (no card behind them: the owner found the wash
 * less clean). A note, when there is one, sits under the rows.
 */
ColumnLayout {
    id: group
    property string title: ""
    property string note: ""
    property string aside: ""          // a short state on the heading's line, at the right
    property bool asideAttention: false   // it needs you: sand, as Praxis marks what waits on you
    property string asideTip: ""       // more about it on hover (a version)
    default property alias rows: holder.data

    Layout.fillWidth: true
    // a group starts well apart from the one above, its heading close over its rows: the page
    // reads in chunks
    Layout.topMargin: group.title.length > 0 ? 48 : 12
    spacing: 0

    RowLayout {
        visible: group.title.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: 20
        Layout.rightMargin: 20
        Layout.bottomMargin: 8
        StyledText {
            id: heading
            Layout.fillWidth: true
            text: group.title
            font.pixelSize: 22
            font.weight: Font.DemiBold
            color: Appearance.colors.colInkMain
            elide: Text.ElideRight
        }
        StyledText {
            visible: group.aside.length > 0
            Layout.alignment: Qt.AlignBaseline
            text: group.aside
            font.pixelSize: 15
            font.weight: group.asideAttention ? Font.Medium : Font.Normal
            color: group.asideAttention ? Appearance.colors.colPrimary : Tacit.inkMeta
            HoverHandler { id: asideHover }
            StyledToolTip { text: group.asideTip; extraVisibleCondition: asideHover.hovered && group.asideTip.length > 0 }
        }
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: holder.implicitHeight + 8
        color: "transparent"
        ColumnLayout {
            id: holder
            // whether any row here has a glyph: rows without one then keep the glyphs' edge
            readonly property bool hasLeadRows: {
                for (const c of holder.children) if (c.hasLead) return true;
                return false;
            }
            // the first row shown (the topmost: a Repeater moves its rows into place without a
            // children change, so the order of `children` can be stale): every row after it has a
            // hairline above
            readonly property Item firstRow: {
                let top = null;
                for (const c of holder.children)
                    if (c.visible && c.implicitHeight > 0 && (top === null || c.y < top.y)) top = c;
                return top;
            }
            y: 4
            width: parent.width
            spacing: 0
        }
    }

    StyledText {
        visible: group.note.length > 0
        Layout.fillWidth: true
        Layout.leftMargin: holder.hasLeadRows ? 52 : 20
        Layout.rightMargin: 20
        Layout.topMargin: 8
        text: group.note
        font.pixelSize: 13
        color: Tacit.inkMeta
        wrapMode: Text.Wrap
        lineHeight: 1.2
    }
}
