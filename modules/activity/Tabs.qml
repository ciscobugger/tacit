import QtQuick
import qs.modules.common.widgets

// Now · Battery · Disk, or on a page opened from Now the way back ("‹ Now").
Item {
    id: nav
    property string at: "Now"
    property string crumb: ""
    signal picked(string tab)
    signal back()
    width: 600
    height: 40
    // the sand line slides to the tab that is open
    readonly property Item onTab: tabs.children.find(c => c.on === true) ?? null
    Rectangle {
        visible: nav.crumb === "" && nav.onTab !== null
        x: nav.onTab?.x ?? 0
        y: 28
        width: nav.onTab?.width ?? 0
        height: 2
        radius: 1
        color: Ink.sand
        Behavior on x { Anim { type: Anim.FastSpatial } }
        Behavior on width { Anim { type: Anim.FastSpatial } }
    }
    Row {
        id: tabs
        spacing: 44
        visible: nav.crumb === ""
        Repeater {
            model: ["Now", "Battery", "Disk"]
            Item {
                id: tab
                required property string modelData
                readonly property bool on: modelData === nav.at
                width: tl.width
                height: 30
                activeFocusOnTab: true
                Keys.onReturnPressed: nav.picked(modelData)
                T {
                    id: tl
                    text: tab.modelData
                    font.pixelSize: 18
                    font.weight: tab.on ? Font.DemiBold : Font.Normal
                    color: tab.on || ta.containsMouse || tab.activeFocus ? Ink.main : Ink.sec
                    Behavior on color { Ease {} }
                }
                // keyboard focus on a tab that is not open
                Rectangle {
                    visible: tab.activeFocus && !tab.on
                    y: 28
                    width: tl.width
                    height: 2
                    radius: 1
                    color: Ink.sec
                }
                MouseArea {
                    id: ta
                    anchors.fill: parent
                    anchors.margins: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: nav.picked(tab.modelData)
                }
            }
        }
    }
    Item {
        id: bk
        visible: nav.crumb !== ""
        x: -12
        y: -6
        width: bt.width + 24
        height: 36
        activeFocusOnTab: visible
        Keys.onReturnPressed: nav.back()
        T {
            id: bt
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            text: "‹  " + nav.crumb
            font.pixelSize: 17
            font.weight: Font.Medium
            // brightness, not a grey fill
            color: ba.containsMouse || bk.activeFocus ? Ink.main : Ink.sec
            Behavior on color { Ease {} }
        }
        MouseArea {
            id: ba
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: nav.back()
        }
    }
}
