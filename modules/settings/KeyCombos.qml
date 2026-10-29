import QtQuick
import qs.modules.common
import qs.modules.common.widgets

/** The key combinations of a shortcut, "or" between them; "No shortcut" when it has none. */
Row {
    id: combos
    property var list: []
    spacing: Tacit.space.m
    Repeater {
        model: combos.list
        Row {
            required property string modelData
            required property int index
            spacing: Tacit.space.m
            StyledText {
                visible: index > 0
                anchors.verticalCenter: parent.verticalCenter
                text: "or"
                font.pixelSize: Tacit.size.meta
                color: Tacit.inkFaint
            }
            KeyCaps { anchors.verticalCenter: parent.verticalCenter; combo: parent.modelData }
        }
    }
    StyledText {
        visible: combos.list.length === 0
        anchors.verticalCenter: parent.verticalCenter
        text: "No shortcut"
        font.pixelSize: Tacit.size.row
        color: Tacit.inkMeta
    }
}
