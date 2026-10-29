import QtQuick
import QtQuick.Effects
import qs.modules.common
import Tacit.Kit as K

/**
 * One Desktop file as a tag: the notch's pill, with its kind (a symbol, or a small picture of the file) and
 * the whole name. As wide as the name needs, up to 12 x space.xl; a longer name wraps to a second line
 * inside the same tag, so no name is cut at rest. Selected = the wash Files uses and the accent hairline;
 * renaming turns the name into the line to type in, never narrower than 8 x space.xl. `ghost` is the place a
 * drop will land: frost in the accent ring, saying what letting go does.
 */
Item {
    id: tag
    property string name: ""
    property string glyph: "draft"
    property url picture: ""
    property bool selected: false
    property bool hovered: false
    property bool editing: false
    property bool ring: false                 // the keyboard's tag (the ring shows once a key has been pressed)
    property bool taken: false                // the typed name is already on the Desktop
    property bool ghost: false
    signal renamed(string to)
    signal editDone()
    readonly property real unit: Tacit.space.xl
    readonly property real pad: Tacit.space.m
    readonly property real kind: Tacit.height.field - 2 * Tacit.space.xs        // the picture's square
    readonly property real maxText: 12 * unit - 2 * pad - kind - Tacit.space.s
    readonly property real wash: selected ? Tacit.wash.current : hovered ? Tacit.wash.hover : 0
    readonly property bool showPicture: picture.toString() !== "" && !ghost && thumb.status !== Image.Error
    K.TacitText { id: measure; visible: false; text: tag.name; size: "fileText"; weight: "medium" }
    readonly property real textW: Math.min(Math.ceil(measure.implicitWidth), maxText)
    readonly property bool wraps: measure.implicitWidth > maxText
    readonly property real inkW: editing ? Math.max(textW, 8 * unit - 2 * pad - kind - Tacit.space.s) : textW
    width: ghost ? 2 * pad + textW : 2 * pad + kind + Tacit.space.s + inkW
    height: wraps ? Math.ceil(2 * measure.implicitHeight) + 2 * Tacit.space.s : Tacit.height.field
    readonly property real corner: wraps ? Tacit.radius.panel : height / 2

    Accessible.role: Accessible.ListItem
    Accessible.name: tag.ghost ? tag.name : tag.name + (tag.selected ? ", selected" : "")

    // the notch's frost (the compositor blurs what is under this window; see rules.lua)
    Rectangle {
        anchors.fill: parent; radius: tag.corner
        color: Appearance.colors.colPanelFrost
        border.width: 1
        border.color: tag.selected ? Qt.alpha(Tacit.accent, 0.85) : Qt.alpha(Tacit.inkMain, 0.10)
    }
    Rectangle {
        anchors.fill: parent; radius: tag.corner
        color: Qt.alpha(Tacit.inkMain, tag.wash)
        Behavior on color { ColorAnimation { duration: K.Kit.ms(Tacit.motion.hover.ms) } }
    }
    Rectangle {
        visible: tag.ghost
        anchors.fill: parent; radius: tag.corner; color: "transparent"
        border.width: Tacit.state.focusRing; border.color: Tacit.accent
    }
    K.FocusRing { shown: tag.ring && K.Kit.focusVisible && !tag.editing; corner: tag.corner }

    K.Symbol {
        visible: !tag.showPicture && !tag.ghost && !tag.editing
        x: tag.pad; y: (tag.height - height) / 2
        text: tag.glyph; size: Tacit.icon.row; color: Tacit.inkMain
    }
    Image {
        id: thumb
        visible: false
        source: tag.ghost ? "" : tag.picture
        sourceSize: Qt.size(2 * tag.kind, 2 * tag.kind)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        width: tag.kind; height: tag.kind
    }
    Rectangle { id: thumbMask; visible: false; width: tag.kind; height: tag.kind; radius: Tacit.radius.art; layer.enabled: true }
    MultiEffect {
        visible: tag.showPicture && !tag.editing
        x: tag.pad - Tacit.space.xs; y: (tag.height - height) / 2; width: tag.kind; height: tag.kind
        source: thumb; maskEnabled: true; maskSource: thumbMask
    }
    K.TacitText {
        visible: !tag.editing
        x: tag.ghost ? tag.pad : tag.pad + tag.kind + Tacit.space.s; y: (tag.height - height) / 2; width: tag.textW
        text: tag.name; size: "fileText"; weight: "medium"
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere; maximumLineCount: 2; elide: Text.ElideRight
    }
    Rectangle {
        visible: tag.editing
        anchors.fill: parent; radius: tag.corner; color: Tacit.windowGround
        border.width: Tacit.state.focusRing; border.color: tag.taken ? Tacit.risk : Tacit.accent
        K.Symbol { x: tag.pad; y: (parent.height - height) / 2; text: tag.glyph; size: Tacit.icon.row; color: Tacit.inkMain }
        TextInput {
            id: field
            x: tag.pad + tag.kind + Tacit.space.s; width: tag.inkW; height: parent.height
            verticalAlignment: TextInput.AlignVCenter
            wrapMode: TextInput.WrapAtWordBoundaryOrAnywhere
            color: Tacit.inkMain
            font.family: Tacit.font.main; font.pixelSize: Tacit.size.fileText; font.weight: Tacit.weight.medium
            persistentSelection: true; selectionColor: Tacit.accent; selectedTextColor: Tacit.inkOnAccent
            Accessible.role: Accessible.EditableText
            Accessible.name: "Name"
            onTextChanged: tag.taken = text !== tag.name && text.trim().length > 0 && tag.nameTaken(text.trim())
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (!tag.taken)
                        tag.renamed(text);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Escape) {
                    tag.editDone();
                    event.accepted = true;
                } else {
                    event.accepted = false;
                }
            }
            onActiveFocusChanged: if (!activeFocus && tag.editing) tag.editDone()
            Connections {
                target: tag
                function onEditingChanged() {
                    if (!tag.editing) return;
                    field.text = tag.name;
                    field.forceActiveFocus();
                    const dot = tag.name.lastIndexOf(".");
                    field.select(0, dot > 0 && tag.glyph !== "folder" ? dot : tag.name.length);
                }
            }
        }
    }
    property var nameTaken: name => false
}
