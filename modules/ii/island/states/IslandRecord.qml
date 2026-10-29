pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Screen recording in the sheet (IslandController's screen recording; mock ~/dev/tacit-site/mocks/record/).
 * "choose": Whole screen, An area, A window, and the sound; the last choice is outlined and Enter repeats it.
 * "saved": the recording just made on a card, a still, its name and length, Show; the still drags into a window.
 */
Item {
    id: root

    property string mode: "choose"
    property string screenName: ""
    property Item dragProxy: null
    property bool draggingOut: false
    signal close()
    signal acted()   // the card was used (Show, opened, dragged out): no "Recording saved" line after it

    implicitWidth: root.mode === "saved" ? 520 : 660
    implicitHeight: root.mode === "saved" ? 94 : 82

    readonly property var choices: [
        { "what": "screen", "glyph": "screenshot_monitor", "label": "Whole screen" },
        { "what": "area", "glyph": "screenshot_region", "label": "An area" },
        { "what": "window", "glyph": "select_window", "label": "A window" }
    ]
    readonly property var sounds: [
        { "what": "none", "glyph": "volume_off", "label": "No sound" },
        { "what": "system", "glyph": "volume_up", "label": "Computer sound" },
        { "what": "mic", "glyph": "mic", "label": "Microphone" }
    ]
    property string pick: Persistent.states.record.last
    readonly property var sound: root.sounds.find(s => s.what === Persistent.states.record.sound) ?? root.sounds[0]

    function choose(what) {
        IslandController.chooseRecord(what, root.screenName);
        root.close();
    }
    function nextSound() {
        const i = root.sounds.indexOf(root.sound);
        Persistent.states.record.sound = root.sounds[(i + 1) % root.sounds.length].what;
    }
    function focusInput() {
    }
    // IslandContent hands its keys here while this sheet is up
    function keyPressed(event) {
        if (root.mode !== "choose")
            return;
        const at = root.choices.findIndex(c => c.what === root.pick);
        if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            root.pick = root.choices[(at + 1) % 3].what;
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
            root.pick = root.choices[(at + 2) % 3].what;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.choose(root.pick);
        } else {
            return;
        }
        event.accepted = true;
    }

    // a choice: a 40 tall pill, its glyph and its words; the outlined one is what Enter does
    component Choice: Rectangle {
        id: choice
        property string glyph
        property string label
        property bool outlined: false
        property bool quiet: false   // the sound: a ring, no fill
        signal picked()
        implicitWidth: choiceRow.implicitWidth + 27
        implicitHeight: 40
        radius: 20
        color: choice.quiet ? "transparent" : ColorUtils.transparentize(Tacit.inkMain, choiceArea.containsMouse || choice.outlined ? 0.8 : 0.88)
        border.width: choice.outlined ? 1.2 : choice.quiet ? 1 : 0
        border.color: choice.outlined ? ColorUtils.transparentize(Tacit.accent, 0.45) : ColorUtils.transparentize(Tacit.inkMain, 0.82)
        Behavior on color {
            ColorAnimation { duration: 200 }
        }
        Row {
            id: choiceRow
            x: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: choice.glyph
                iconSize: 19
                color: choice.quiet ? Tacit.inkMeta : choiceArea.containsMouse || choice.outlined ? Tacit.inkMain : Tacit.inkSec
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: choice.label
                font.pixelSize: 15
                color: choice.quiet ? Tacit.inkMeta : choiceArea.containsMouse || choice.outlined ? Tacit.inkMain : Tacit.inkSec
            }
        }
        MouseArea {
            id: choiceArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: choice.picked()
        }
    }

    // ---------------------------------------------------------------- choose
    Row {
        visible: root.mode === "choose"
        anchors.horizontalCenter: parent.horizontalCenter
        y: 6
        spacing: 8
        Repeater {
            model: root.choices
            Choice {
                required property var modelData
                glyph: modelData.glyph
                label: modelData.label
                outlined: root.pick === modelData.what
                onPicked: root.choose(modelData.what)
            }
        }
        Rectangle {
            width: 1
            height: 24
            anchors.verticalCenter: parent.verticalCenter
            color: ColorUtils.transparentize(Tacit.inkMain, 0.86)
        }
        Choice {
            glyph: root.sound.glyph
            label: root.sound.label
            quiet: true
            onPicked: root.nextSound()
        }
    }
    StyledText {
        visible: root.mode === "choose"
        anchors.horizontalCenter: parent.horizontalCenter
        y: 58
        text: `Enter records ${root.pick === "screen" ? "the whole screen" : root.pick === "window" ? "a window" : "an area"} again · Esc closes`
        font.pixelSize: 13
        color: Tacit.inkFaint
    }

    // ---------------------------------------------------------------- saved
    readonly property string file: Persistent.states.record.file
    readonly property string folder: root.file.replace(/\/[^\/]*$/, "")
    Item {
        visible: root.mode === "saved"
        x: 14
        y: 8
        width: parent.width - 28
        height: 76

        Item {
            id: still
            y: 5
            width: 118
            height: 66
            ClippingRectangle {
                anchors.fill: parent
                radius: 10
                color: ColorUtils.transparentize(Tacit.inkMain, 0.88)
                border.width: 1
                border.color: ColorUtils.transparentize(Tacit.inkMain, 0.92)
                Image {
                    anchors.fill: parent
                    source: Persistent.states.record.thumb !== "" ? "file://" + Persistent.states.record.thumb : ""
                    fillMode: Image.PreserveAspectCrop
                    horizontalAlignment: Image.AlignLeft
                    verticalAlignment: Image.AlignTop
                    asynchronous: true
                    sourceSize.height: 132
                }
            }
            MaterialSymbol {
                x: 6
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                text: "movie"
                iconSize: 16
                color: "white"
            }
            // a click plays it; a drag hands the file to a window (the shelf tile's way, IslandShelf.qml)
            MouseArea {
                id: stillArea
                anchors.fill: parent
                drag.target: root.dragProxy ? parent : null
                cursorShape: Qt.OpenHandCursor
                onPressed: if (root.dragProxy) parent.grabToImage(result => root.dragProxy.Drag.imageSource = result.url)
                onReleased: {
                    if (root.dragProxy && root.dragProxy.Drag.active)
                        root.dragProxy.Drag.drop();
                    parent.x = 0;
                    parent.y = 5;
                }
                onClicked: {
                    root.acted();
                    Quickshell.execDetached(["xdg-open", root.file]);
                    root.close();
                }
                drag.onActiveChanged: {
                    root.draggingOut = stillArea.drag.active;
                    if (!root.dragProxy)
                        return;
                    if (stillArea.drag.active) {
                        root.acted();
                        root.dragProxy.Drag.mimeData = { "text/uri-list": "file://" + root.file };
                        root.dragProxy.Drag.active = true;
                    } else {
                        root.dragProxy.Drag.active = false;
                    }
                }
            }
        }

        Column {
            anchors.left: still.right
            anchors.leftMargin: 12
            anchors.right: showPill.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3
            StyledText {
                width: parent.width
                text: root.file.replace(/^.*\//, "").replace(/\.mp4$/, "")
                font.pixelSize: 15
                font.variableAxes: ({ "wght": 560 })
                color: Tacit.inkMain
                elide: Text.ElideMiddle
            }
            StyledText {
                width: parent.width
                text: `${IslandController.recordLength} · in ${root.folder.replace(/^.*\//, "")} · drag it anywhere`
                font.pixelSize: 13
                color: Tacit.inkFaint
                elide: Text.ElideRight
            }
        }

        Choice {
            id: showPill
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 34
            glyph: "open_in_new"
            label: "Show"
            onPicked: {
                root.acted();
                Files.reveal(root.file);
                root.close();
            }
        }
    }
}
