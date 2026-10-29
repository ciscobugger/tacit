import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * One of a few. Up to four choices sit side by side as words, the chosen one on the raised wash,
 * so the alternatives read at a glance. More than that is the current choice in quiet words, which
 * opens the list - a row of seven small buttons is a puzzle.
 */
SettingRow {
    id: root
    property var options: []          // [{ value, label, glyph }]
    property var current: ""
    signal picked(var value)
    clickable: !root.inline

    // a choice of apps or places reads as a list whatever its length
    property bool asList: false
    // Side by side only when the choices fit in about half the row: three long device names
    // ran out over the row's own label ("Listen with" on Sound).
    FontMetrics {
        id: optionMetrics
        font.pixelSize: 15
        font.family: Appearance.font.family.main
    }
    readonly property real inlineWidth: root.options.reduce((w, o) => w + optionMetrics.advanceWidth(String(o.label)) + 24 + ((o.glyph ?? "").length > 0 ? 21 : 0), 0)
    readonly property bool inline: !root.asList && root.options.length > 0 && root.options.length <= 4
        && root.inlineWidth <= root.width - 72
    // the words under the question, the first on the labels' edge
    stacked: root.inline
    readonly property var currentOption: root.options.find(o => o.value === root.current) ?? null

    // the whole row opens the list when it is a list, the way the button alone would
    onActivated: if (!root.inline) menu.open()
    // side-by-side choices step with the arrow keys
    function step(by) {
        const i = root.options.findIndex(o => o.value === root.current);
        const j = Math.max(0, Math.min(root.options.length - 1, i < 0 ? 0 : i + by));
        if (j !== i)
            root.picked(root.options[j].value);
    }
    Keys.onLeftPressed: if (root.inline) root.step(-1)
    Keys.onRightPressed: if (root.inline) root.step(1)

    control: Item {
        x: root.inline ? -12 : 0
        implicitWidth: root.inline ? inlineRow.implicitWidth : dropButton.implicitWidth
        implicitHeight: root.inline ? inlineRow.implicitHeight : dropButton.implicitHeight

        RowLayout {
            id: inlineRow
            visible: root.inline
            spacing: 0
            Repeater {
                model: root.inline ? root.options : []
                Rectangle {
                    id: opt
                    required property var modelData
                    readonly property bool isCurrent: root.current === modelData.value
                    // Praxis's panel tabs: the chosen word in full ink and weight over a sand line
                    implicitHeight: 32
                    implicitWidth: optRow.implicitWidth + 24
                    radius: 8
                    color: "transparent"
                    Rectangle {
                        visible: opt.isCurrent
                        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 1 }
                        width: optRow.implicitWidth
                        height: 2
                        radius: 1
                        color: Appearance.colors.colPrimary
                    }

                    RowLayout {
                        id: optRow
                        anchors.centerIn: parent
                        spacing: 5
                        MaterialSymbol {
                            visible: (opt.modelData.glyph ?? "").length > 0
                            text: opt.modelData.glyph ?? ""
                            iconSize: 16
                            color: opt.isCurrent || optArea.containsMouse ? Appearance.colors.colInkMain : Tacit.inkSec
                        }
                        StyledText {
                            text: opt.modelData.label
                            font.pixelSize: 15
                            font.weight: opt.isCurrent ? Font.DemiBold : Font.Normal
                            color: opt.isCurrent || optArea.containsMouse ? Appearance.colors.colInkMain : Tacit.inkSec
                        }
                    }
                    MouseArea {
                        id: optArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.picked(opt.modelData.value)
                    }
                }
            }
        }

        // the current choice, and a chevron that says there are others
        Rectangle {
            id: dropButton
            visible: !root.inline
            implicitHeight: 32
            implicitWidth: Math.min(260, dropRow.implicitWidth + 20)
            radius: 8
            color: dropArea.containsMouse || menu.opened
                ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95)
                : "transparent"
            Behavior on color { ColorAnimation { duration: 80 } }

            RowLayout {
                id: dropRow
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 4
                spacing: 2
                StyledText {
                    Layout.fillWidth: true
                    Layout.maximumWidth: 210
                    // a value not in the list (a font since removed) is still named, not hidden
                    text: root.currentOption?.label ?? (String(root.current ?? "").length > 0 ? String(root.current) : "Choose")
                    font.pixelSize: 15
                    color: Tacit.inkSec
                    elide: Text.ElideRight
                }
                MaterialSymbol {
                    text: "expand_more"
                    iconSize: 17
                    color: Tacit.inkMeta
                }
            }
            MouseArea {
                id: dropArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: menu.opened ? menu.close() : menu.open()
            }

            Popup {
                id: menu
                y: dropButton.height + 4
                x: dropButton.width - width
                width: Math.max(dropButton.width, 240)
                padding: 6
                modal: false
                focus: true
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                background: Rectangle {
                    radius: 14
                    color: Appearance.m3colors.m3surfaceContainerHigh
                    border.width: 1
                    border.color: ColorUtils.transparentize(Appearance.m3colors.m3outlineVariant, 0.5)
                }

                // A long list (fonts, keyboard layouts) gets a filter at its top, and every list
                // opens at the current choice rather than at the first entry.
                readonly property bool isLong: root.options.length > 12
                property string filter: ""
                onOpened: {
                    filterInput.text = "";
                    const at = Math.max(0, root.options.findIndex(o => o.value === root.current));
                    list.currentIndex = at;
                    // a long list starts in its filter, a short one on the current choice
                    if (menu.isLong)
                        filterInput.forceActiveFocus();
                    else
                        list.forceActiveFocus();
                    Qt.callLater(() => list.positionViewAtIndex(at, ListView.Center));
                }
                onClosed: root.forceActiveFocus()

                contentItem: Column {
                    spacing: 4

                    Rectangle {
                        visible: menu.isLong
                        width: parent.width
                        height: 32
                        radius: 8
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95)
                        MaterialSymbol {
                            id: filterGlyph
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: "search"
                            iconSize: 16
                            color: Tacit.inkMeta
                        }
                        TextInput {
                            id: filterInput
                            anchors.left: filterGlyph.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            font.pixelSize: 15
                            font.family: Appearance.font.family.main
                            color: Appearance.colors.colInkMain
                            selectionColor: Appearance.colors.colPrimary
                            clip: true
                            onTextChanged: {
                                menu.filter = text.trim().toLowerCase();
                                list.currentIndex = 0;
                            }
                            Keys.onDownPressed: list.forceActiveFocus()
                            // Enter takes the first match
                            Keys.onReturnPressed: {
                                const first = list.model[0];
                                if (first) {
                                    root.picked(first.value);
                                    menu.close();
                                }
                            }
                        }
                        StyledText {
                            anchors.left: filterInput.left
                            anchors.verticalCenter: parent.verticalCenter
                            visible: filterInput.text.length === 0
                            text: "Filter"
                            font.pixelSize: 15
                            color: Tacit.inkMeta
                        }
                    }

                    ListView {
                        id: list
                        width: parent.width
                        height: Math.min(contentHeight, 320)
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: menu.filter.length === 0 ? root.options
                            : root.options.filter(o => String(o.label).toLowerCase().includes(menu.filter))
                        keyNavigationEnabled: true
                        function pickCurrent() {
                            const o = list.model[list.currentIndex];
                            if (o) {
                                root.picked(o.value);
                                menu.close();
                            }
                        }
                        Keys.onReturnPressed: list.pickCurrent()
                        Keys.onEnterPressed: list.pickCurrent()
                        // Up from the first row goes back to the filter
                        Keys.onUpPressed: event => {
                            if (list.currentIndex === 0 && menu.isLong)
                                filterInput.forceActiveFocus();
                            else
                                event.accepted = false;
                        }
                        delegate: Item {
                            id: item
                            required property var modelData
                            readonly property bool isCurrent: root.current === item.modelData.value
                            width: ListView.view.width
                            height: 36

                            Rectangle {
                                anchors.fill: parent
                                radius: 8
                                color: item.isCurrent ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                                    : ((itemArea.containsMouse || (item.ListView.isCurrentItem && list.activeFocus))
                                        ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent")
                                Behavior on color { ColorAnimation { duration: 80 } }
                            }
                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.right: tick.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: item.modelData.label
                                font.pixelSize: 15
                                color: Appearance.colors.colInkMain
                                elide: Text.ElideRight
                            }
                            MaterialSymbol {
                                id: tick
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                visible: item.isCurrent
                                text: "check"
                                iconSize: 18
                                color: Appearance.colors.colPrimary
                            }
                            MouseArea {
                                id: itemArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.picked(item.modelData.value);
                                    menu.close();
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
