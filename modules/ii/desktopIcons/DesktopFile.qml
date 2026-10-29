import QtQuick
import qs.services
import qs.modules.common
import Tacit.Kit as K

/**
 * One Desktop file: its tag and the pointer on it. A press selects (Ctrl adds, Shift extends), a drag moves the
 * selection (the window keeps the drag; the tags only shift while it lasts), a double click opens, a right click
 * opens the tag's menu. The tag's place comes from the window: the column it joined, or where it was put.
 */
Item {
    id: entry
    required property var info          // DesktopIcons.entries[i]
    required property Item desk         // the window's root: drag, menu, registry
    readonly property string name: info.name
    width: tag.width
    height: tag.height

    DesktopTag {
        id: tag
        name: entry.name
        glyph: entry.info.glyph
        picture: entry.info.picture
        selected: DesktopIcons.selected.includes(entry.name)
        hovered: area.containsMouse && !entry.desk.dragging
        editing: DesktopIcons.editing === entry.name
        ring: DesktopIcons.cursor === entry.name
        nameTaken: n => DesktopIcons.nameTaken(n, entry.name)
        z: entry.desk.dragging && selected ? 10 : 0
        transform: Translate { x: entry.desk.dragging && tag.selected ? entry.desk.dragDx : 0; y: entry.desk.dragging && tag.selected ? entry.desk.dragDy : 0 }
        onRenamed: to => { DesktopIcons.rename(entry.name, to); entry.desk.forceActiveFocus(); }
        onEditDone: { DesktopIcons.editing = ""; entry.desk.forceActiveFocus(); }
        Component.onCompleted: entry.desk.register(entry.name, tag)
        Component.onDestruction: entry.desk.unregister(entry.name, tag)

        MouseArea {
            id: area
            anchors.fill: parent
            enabled: !tag.editing
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property point pressAt
            property bool wasSelected: false
            property bool plain: true
            onPressed: mouse => {
                entry.desk.forceActiveFocus();
                K.Kit.focusVisible = false;
                if (mouse.button === Qt.RightButton) {
                    if (!tag.selected)
                        DesktopIcons.selectOnly(entry.name);
                    const p = area.mapToItem(entry.desk, mouse.x, mouse.y);
                    entry.desk.openMenu(p.x, p.y);
                    return;
                }
                pressAt = area.mapToItem(entry.desk, mouse.x, mouse.y);
                wasSelected = tag.selected;
                plain = !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier));
                if (mouse.modifiers & Qt.ControlModifier)
                    DesktopIcons.toggle(entry.name);
                else if (mouse.modifiers & Qt.ShiftModifier)
                    DesktopIcons.extendTo(entry.name);
                else if (!tag.selected)
                    DesktopIcons.selectOnly(entry.name);
                else
                    DesktopIcons.cursor = entry.name;
            }
            onPositionChanged: mouse => {
                if (!(pressedButtons & Qt.LeftButton) || !tag.selected)
                    return;
                const p = area.mapToItem(entry.desk, mouse.x, mouse.y);
                if (!entry.desk.dragging && Math.hypot(p.x - pressAt.x, p.y - pressAt.y) > Tacit.space.s)
                    entry.desk.dragging = true;
                if (entry.desk.dragging) {
                    entry.desk.dragDx = p.x - pressAt.x;
                    entry.desk.dragDy = p.y - pressAt.y;
                }
            }
            onReleased: mouse => {
                if (entry.desk.dragging)
                    entry.desk.commitDrag(entry.name);
                else if (plain && wasSelected && mouse.button === Qt.LeftButton)
                    DesktopIcons.selectOnly(entry.name);
            }
            onCanceled: entry.desk.dragging = false
            onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) DesktopIcons.open(entry.name); }
        }
    }
}
