pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs
import qs.services
import qs.modules.common
import Tacit.Kit as K

/**
 * The Desktop folder's files as tags on the desktop. A layer of its own just above the wallpaper, so the
 * compositor can frost the tags (rules.lua) the way it frosts the notch; it takes the pointer only where a tag
 * (or the open menu, or the Notice) is, so the wallpaper's right click and drops reach the wallpaper everywhere else.
 * Files that have not been moved join a column down the left edge; a tag that has been moved stays where it
 * was put (DesktopIcons keeps the places). Selection, Enter, F2, Delete, Ctrl+Z and the arrows work from the keyboard.
 */
Scope {
    id: root

    PanelWindow {
        id: win
        screen: Quickshell.screens[0]
        visible: !DesktopIcons.hidden
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "quickshell:desktopIcons"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        mask: Region { regions: maskMaker.instances }
        Component.onCompleted: K.Kit.tokens = Tacit

        Variants {
            id: maskMaker
            model: board.maskItems
            Region { required property var modelData; item: modelData }
        }

        FocusScope {
            id: board
            anchors.fill: parent
            focus: true

            readonly property real edgeGap: Tacit.space.xl
            readonly property real topGap: Tacit.space.page
            readonly property real bottomClear: 3 * Tacit.space.xl     // keeps clear of the dock, as the notch's own margin does
            property bool dragging: false
            property real dragDx: 0
            property real dragDy: 0
            property var tagItems: []
            // where the pointer lands on this layer: the tags, the open menu (the whole layer, to catch the click away), the Notice
            readonly property var maskItems: tagItems.concat(menu.visible ? [board] : [], notice.shown ? [notice] : [])
            readonly property var byName: ({})

            function register(name, tag) {
                board.byName[name] = tag;
                board.tagItems = board.tagItems.concat([tag]);
            }
            function unregister(name, tag) {
                if (board.byName[name] === tag)
                    delete board.byName[name];
                board.tagItems = board.tagItems.filter(t => t !== tag);
            }

            // ---- a drag ends: the moved tags keep where they were set down, snapped to a neighbour's edge
            function commitDrag(grabbed) {
                const names = DesktopIcons.selected.filter(n => board.byName[n]);
                const lead = board.byName[grabbed];
                if (!lead || names.length === 0) {
                    board.dragging = false;
                    return;
                }
                const gap = Tacit.space.s, near = Tacit.space.m;
                const at = lead.mapToItem(board, 0, 0);
                let sx = 0, sy = 0, bx = near, by = near;
                for (const o of board.tagItems) {
                    if (names.some(n => board.byName[n] === o))
                        continue;
                    const p = o.mapToItem(board, 0, 0);
                    if (Math.abs(at.x - p.x) < bx) { bx = Math.abs(at.x - p.x); sx = p.x - at.x; }
                    if (at.x < p.x + o.width && at.x + lead.width > p.x) {
                        const below = p.y + o.height + gap - at.y, above = p.y - gap - lead.height - at.y;
                        if (Math.abs(below) < by) { by = Math.abs(below); sy = below; }
                        if (Math.abs(above) < by) { by = Math.abs(above); sy = above; }
                    }
                }
                const map = ({});
                for (const n of names) {
                    const t = board.byName[n], p = t.mapToItem(board, 0, 0);
                    map[n] = [Math.round(Math.max(gap, Math.min(p.x + sx, board.width - t.width - gap))),
                              Math.round(Math.max(gap, Math.min(p.y + sy, board.height - t.height - gap)))];
                }
                board.dragging = false;
                board.dragDx = 0;
                board.dragDy = 0;
                DesktopIcons.place(map);
            }

            // ---- the tag menu
            function openMenu(x, y) {
                const one = DesktopIcons.selected.length === 1;
                menu.items = one ? [{ "label": "Open" }, { "label": "Rename" }, { "label": "Move to the trash" }]
                                 : [{ "label": "Open" }, { "label": "Move to the trash" }];
                menu.openAt(board, x, y);
            }
            K.Menu {
                id: menu
                onPicked: i => {
                    const w = menu.items[i].label;
                    if (w === "Open") DesktopIcons.selected.forEach(n => DesktopIcons.open(n));
                    else if (w === "Rename") DesktopIcons.editing = DesktopIcons.selected[0];
                    else DesktopIcons.trash(DesktopIcons.selected);
                }
                onClosed: if (DesktopIcons.editing === "") board.forceActiveFocus()
            }

            // ---- the keys
            function move(dx, dy) {
                const names = DesktopIcons.entries.map(e => e.name).filter(n => board.byName[n]);
                if (names.length === 0)
                    return;
                const from = board.byName[DesktopIcons.cursor];
                if (!from) {
                    DesktopIcons.selectOnly(names[0]);
                    return;
                }
                const c = from.mapToItem(board, from.width / 2, from.height / 2);
                let best = "", score = Infinity;
                for (const n of names) {
                    if (n === DesktopIcons.cursor)
                        continue;
                    const t = board.byName[n], p = t.mapToItem(board, t.width / 2, t.height / 2);
                    const along = (p.x - c.x) * dx + (p.y - c.y) * dy, across = Math.abs((p.x - c.x) * dy) + Math.abs((p.y - c.y) * dx);
                    if (along <= 0)
                        continue;
                    const s = along + 2 * across;
                    if (s < score) { score = s; best = n; }
                }
                if (best !== "")
                    DesktopIcons.selectOnly(best);
            }
            Keys.onPressed: event => {
                K.Kit.focusVisible = true;
                const ctrl = event.modifiers & Qt.ControlModifier;
                event.accepted = true;
                if (ctrl && event.key === Qt.Key_A) DesktopIcons.selectAll();
                else if (ctrl && event.key === Qt.Key_Z) DesktopIcons.undo();
                else if (event.key === Qt.Key_Escape) DesktopIcons.clear();
                else if (event.key === Qt.Key_Left) board.move(-1, 0);
                else if (event.key === Qt.Key_Right) board.move(1, 0);
                else if (event.key === Qt.Key_Up) board.move(0, -1);
                else if (event.key === Qt.Key_Down) board.move(0, 1);
                else if (event.key === Qt.Key_Home && DesktopIcons.entries.length > 0) DesktopIcons.selectOnly(DesktopIcons.entries[0].name);
                else if (event.key === Qt.Key_End && DesktopIcons.entries.length > 0) DesktopIcons.selectOnly(DesktopIcons.entries[DesktopIcons.entries.length - 1].name);
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) DesktopIcons.selected.forEach(n => DesktopIcons.open(n));
                else if (event.key === Qt.Key_F2 && DesktopIcons.selected.length === 1) DesktopIcons.editing = DesktopIcons.selected[0];
                else if (event.key === Qt.Key_Delete) DesktopIcons.trash(DesktopIcons.selected);
                else event.accepted = false;
            }

            // ---- a drop that lands on a tag is a drop on the desktop
            DropArea {
                anchors.fill: parent
                keys: ["text/uri-list"]
                onEntered: drag => { drag.accepted = drag.hasUrls; DesktopIcons.dropCount = drag.urls.length; }
                onExited: DesktopIcons.dropCount = 0
                onDropped: drop => {
                    drop.accept();
                    DesktopIcons.put(drop.urls ?? [], drop.keyboardModifiers, drop.source !== null);
                    DesktopIcons.dropCount = 0;
                }
            }

            // ---- the column the unmoved files join, and the place a drop will land
            Flow {
                id: column
                x: board.edgeGap; y: board.topGap
                width: board.width - board.edgeGap; height: Math.max(0, board.height - board.topGap - board.bottomClear)
                flow: Flow.TopToBottom
                spacing: Tacit.space.s
                Repeater {
                    model: DesktopIcons.joined
                    Item {
                        required property var modelData
                        // a column gap of space.xl (Flow has one spacing for rows and columns)
                        width: joined.width + Tacit.space.l
                        height: joined.height
                        DesktopFile { id: joined; info: parent.modelData; desk: board }
                    }
                }
                Item {
                    visible: DesktopIcons.dropShown
                    width: ghostTag.width + Tacit.space.l; height: ghostTag.height
                    DesktopTag {
                        id: ghostTag
                        ghost: true
                        name: `Put ${Voice.count(DesktopIcons.dropCount, "file")} on the Desktop`
                    }
                }
            }

            // ---- the tags a person has put somewhere
            Repeater {
                model: DesktopIcons.placed
                DesktopFile {
                    required property var modelData
                    info: modelData
                    desk: board
                    x: Math.max(0, Math.min(DesktopIcons.places[modelData.name][0], board.width - width))
                    y: Math.max(0, Math.min(DesktopIcons.places[modelData.name][1], board.height - height))
                }
            }

            DesktopNotice {
                id: notice
                anchors.bottomMargin: board.bottomClear + Tacit.space.l
                onActivated: DesktopIcons.undo()
            }
            Connections {
                target: DesktopIcons
                function onSaid(text, words) { notice.show(text, words); }
            }
        }
    }
}
