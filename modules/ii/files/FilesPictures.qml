import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit
import Tacit.Kit as K

/**
 * A folder of pictures in the grid: each picture at its own shape in rows about 200 high (times the grid's size),
 * filled edge to edge, and a picture never alone on a row (a lone last one joins the row above). While the folder is
 * in time order, a heading over each day, folders first under their own. This is K.PictureGrid's layout, drawn with
 * Files' own cells: the kit part owns its selection by index, and Files keeps the selection, the cursor and the keys
 * by path in the window (drag and drop, cut, rename and the band need that). A picture's shape is read from its
 * header once per window (magick identify -ping); until then it is taken as 3:2.
 */
Item {
    id: pics

    property var model                      // the window's FolderListModel
    property bool byDay: false
    property real size: 1                   // the grid's size (Ctrl+= and Ctrl+-, a pinch)
    property real inset: 0                  // from this item's sides to the pictures
    property real bottomRoom: 0
    property var selectedMap: ({})
    property int cursor: -1
    property bool keysShown: false          // the keyboard's focus ring is showing
    property string flashPath: ""
    property var cutMap: ({})
    property Item dragProxy: null
    property var uriList: i => ""
    readonly property alias bar: picsBar

    signal pressedAt(var mouse, int index)
    signal clicked(var mouse, int index)
    signal doubleClicked(int index)
    signal contextRequested(int index, real x, real y)
    signal zoom(int step)

    readonly property real rowHeight: Math.round(200 * pics.size)
    readonly property int gap: 6
    readonly property int headingHeight: 50
    // the selection ring reaches 4 px past a picture, the focus ring 4 more
    readonly property int ringRoom: 8

    // ------------------------------------------------------------------ what is shown
    property var shapes: ({})               // path -> width / height, kept for the window's life
    property bool headProbed: false         // this folder's first batch of shapes has been asked for
    property var items: []                  // [{ i, path, name, isDir, size, modified, ratio, group }], the model's order
    function dayName(d) {
        const day = new Date(d.getTime()); day.setHours(0, 0, 0, 0);
        const today = new Date(); today.setHours(0, 0, 0, 0);
        const days = Math.round((today.getTime() - day.getTime()) / 86400000);
        if (days === 0) return "Today";
        if (days === 1) return "Yesterday";
        const name = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][day.getDay()] + " " + day.getDate() + " "
            + ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][day.getMonth()];
        return day.getFullYear() === today.getFullYear() ? name : `${name} ${day.getFullYear()}`;
    }
    function rebuild() {
        if (!pics.visible || !pics.model)
            return;
        const out = [], unknown = [];
        for (let i = 0; i < pics.model.count; i++) {
            const path = pics.model.get(i, "filePath") + "";
            const isDir = pics.model.get(i, "fileIsDir");
            const name = pics.model.get(i, "fileName") + "";
            const modified = pics.model.get(i, "fileModified");
            const kind = isDir ? "folder" : Things.kindOf(name);
            if (kind === "image" && !(path in pics.shapes))
                unknown.push(path);
            out.push({ "i": i, "path": path, "name": name, "isDir": isDir, "size": pics.model.get(i, "fileSize"), "modified": modified,
                       "ratio": kind === "image" ? (pics.shapes[path] ?? 1.5) : kind === "video" ? 16 / 9 : 1,
                       "group": !pics.byDay ? "" : isDir ? "Folders" : pics.dayName(modified) });
        }
        pics.items = out;
        if (unknown.length > 0 && !shapeProbe.running) {
            // the first screenful alone at a folder's first look, so the view need not wait for every header
            shapeProbe.paths = unknown.slice(0, pics.headProbed ? 3000 : 100);
            shapeProbe.more = unknown.length > shapeProbe.paths.length;
            pics.headProbed = true;
            shapeProbe.running = true;
        }
    }
    Timer { id: rebuildSoon; interval: 0; onTriggered: pics.rebuild() }
    Connections {
        target: pics.model
        function onRowsChanged() { rebuildSoon.restart(); }
        function onStatusChanged() { rebuildSoon.restart(); }
    }
    onVisibleChanged: rebuildSoon.restart()
    onByDayChanged: rebuildSoon.restart()
    onShapesChanged: rebuildSoon.restart()
    Process {
        id: shapeProbe
        property var paths: []
        property bool more: false
        onRunningChanged: if (!running) {
            shapeWait.stop();   // the first look ends with the first batch; the rest loads behind a visible grid
            if (more) rebuildSoon.restart();   // the rest, once this batch has exited
        }
        command: ["magick", "identify", "-ping", "-format", "%w %h %i\n"].concat(shapeProbe.paths)
        stdout: StdioCollector {
            onStreamFinished: {
                let next = Object.assign({}, pics.shapes);
                for (const l of text.split("\n")) {
                    const a = l.indexOf(" "), b = l.indexOf(" ", a + 1);
                    const w = parseInt(l.substring(0, a)), h = parseInt(l.substring(a + 1, b));
                    if (b > 0 && w > 0 && h > 0)
                        next[l.substring(b + 1)] = w / h;
                }
                for (const p of shapeProbe.paths)   // unreadable: asked once, shown at 3:2
                    if (!(p in next))
                        next[p] = 1.5;
                pics.shapes = next;
            }
        }
    }
    // A folder's first look waits for its shapes (at most 1.5 s) rather than showing every picture at 3:2 and then moving.
    Timer { id: shapeWait; interval: 1500 }
    onModelChanged: { pics.headProbed = false; shapeWait.restart(); }
    Connections {
        target: pics.model
        function onFolderChanged() { pics.headProbed = false; shapeWait.restart(); }
    }
    readonly property bool waiting: shapeProbe.running && shapeWait.running

    // The width the rows are laid out for: a resize reflows once it settles, not per frame (a new layout makes every
    // cell again, and each asks for its thumbnail).
    property real layoutWidth: 0
    Timer { id: widthSettled; interval: 120; onTriggered: pics.layoutWidth = view.width }
    // rows of cells and headings, for the ListView; place[i] = [row, cell] for the keyboard; y in content coordinates
    readonly property var layout: {
        const W = Math.max(1, (pics.layoutWidth > 0 ? pics.layoutWidth : view.width) - 2 * pics.inset), H = pics.rowHeight, g = pics.gap, P = pics.items;
        const rows = [], place = ({});
        let y = 0, k = 0;
        while (k < P.length) {
            const group = P[k].group;
            const members = [];
            while (k < P.length && P[k].group === group) { members.push(k); k++; }
            if (group !== "") {
                rows.push({ "heading": group, "y": y });
                y += pics.headingHeight;
            }
            // fill rows until they are no taller than H
            let lines = [], line = [], sum = 0;
            for (const j of members) {
                line.push(j); sum += P[j].ratio;
                if ((W - g * (line.length - 1)) / sum <= H) { lines.push(line); line = []; sum = 0; }
            }
            if (line.length) {
                if (line.length === 1 && lines.length) lines[lines.length - 1] = lines[lines.length - 1].concat(line);
                else lines.push(line);
            }
            for (const l of lines) {
                const total = l.reduce((t, j) => t + P[j].ratio, 0);
                let h = (W - g * (l.length - 1)) / total;
                if (h > H * 1.3) h = H;       // a short last row keeps the usual height, not a giant one
                h = Math.round(h);
                let x = 0;
                const cells = [];
                for (const j of l) {
                    const left = Math.round(x), right = Math.round(x + P[j].ratio * h);
                    place[P[j].i] = [rows.length, cells.length];
                    cells.push({ "k": j, "x": left, "w": right - left });
                    x += P[j].ratio * h + g;
                }
                rows.push({ "cells": cells, "h": h, "y": y });
                y += h + g;
            }
        }
        return { "rows": rows, "place": place };
    }

    // ------------------------------------------------------------------ for the window's keys, band and ground
    // the picture in the row above or below whose middle is nearest this one's
    function vertical(from, by) {
        const L = pics.layout, p = L.place[from];
        if (!p)
            return from;
        const c = L.rows[p[0]].cells[p[1]], mid = c.x + c.w / 2;
        for (let r = p[0] + by; r >= 0 && r < L.rows.length; r += by) {
            const cells = L.rows[r].cells;
            if (!cells)
                continue;     // a heading
            let best = cells[0];
            for (const d of cells)
                if (Math.abs(d.x + d.w / 2 - mid) < Math.abs(best.x + best.w / 2 - mid))
                    best = d;
            return pics.items[best.k].i;
        }
        return from;
    }
    function positionViewAtIndex(i, mode) {
        const p = pics.layout.place[i];
        if (!p)
            return;
        view.positionViewAtIndex(p[0], mode);
        // the rings reach past the row; a group's first row brings its heading along when it comes in from the top
        const top = view.originY - view.topMargin;
        const it = view.itemAtIndex(p[0]);
        if (!it)
            return;
        if (it.y - view.contentY < pics.ringRoom) {
            const above = p[0] > 0 && pics.layout.rows[p[0] - 1].heading !== undefined ? pics.headingHeight : pics.ringRoom;
            view.contentY = Math.max(top, it.y - above);
        } else if (it.y + it.height + pics.ringRoom - view.contentY > view.height) {
            view.contentY = it.y + it.height + pics.ringRoom - view.height;
        }
    }
    // the model index under a point of this item, or -1
    function indexAt(x, y) {
        const cy = y + view.contentY, cx = x - pics.inset;
        for (const r of pics.layout.rows) {
            if (!r.cells || cy < r.y || cy >= r.y + r.h)
                continue;
            for (const c of r.cells)
                if (cx >= c.x && cx < c.x + c.w)
                    return pics.items[c.k].i;
        }
        return -1;
    }
    // the model indexes whose picture crosses a band drawn over this item
    function indexesIn(top, bottom, left, right) {
        const out = [];
        const t = top + view.contentY, b = bottom + view.contentY, l = left - pics.inset, rr = right - pics.inset;
        for (const r of pics.layout.rows) {
            if (!r.cells || r.y + r.h < t || r.y > b)
                continue;
            for (const c of r.cells)
                if (c.x < rr && c.x + c.w > l)
                    out.push(pics.items[c.k].i);
        }
        return out;
    }

    // ------------------------------------------------------------------ the look
    ListView {
        id: view
        anchors.fill: parent
        onWidthChanged: if (pics.layoutWidth > 0) widthSettled.restart(); else pics.layoutWidth = width
        opacity: pics.waiting ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: Tacit.motion.fadeFast.ms } }
        topMargin: pics.byDay ? 0 : Tacit.space.s
        bottomMargin: Tacit.space.l + pics.bottomRoom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // no cell is made while the folder is still being read or the shapes are still coming: a cell made for a layout
        // that is replaced a moment later asks for its thumbnail and is gone again, which stalls the thumbnail queue
        model: pics.waiting || pics.model?.status !== FolderListModel.Ready ? [] : pics.layout.rows
        ScrollBar.vertical: StyledScrollBar { id: picsBar }
        delegate: Item {
            id: line
            required property var modelData
            readonly property bool heading: line.modelData.heading !== undefined
            // the row with the keyboard's picture draws over its neighbours: its focus ring reaches into the gap
            z: !line.heading && line.modelData.cells.some(c => pics.items[c.k]?.i === pics.cursor) ? 1 : 0
            width: view.width
            height: line.heading ? pics.headingHeight : line.modelData.h + pics.gap
            K.SectionHeading {
                visible: line.heading
                x: pics.inset - Tacit.space.l
                height: pics.headingHeight
                text: line.modelData.heading ?? ""
            }
            Repeater {
                model: line.heading ? [] : line.modelData.cells
                Item {
                    id: spot
                    required property var modelData
                    readonly property var it: pics.items[spot.modelData.k]
                    x: pics.inset + spot.modelData.x
                    width: spot.modelData.w
                    height: line.modelData.h
                    z: picture.focused ? 1 : 0
                    FilesCell {
                        id: picture
                        anchors.fill: parent
                        bare: true
                        fileName: spot.it.name
                        filePath: spot.it.path
                        fileIsDir: spot.it.isDir
                        fileSize: spot.it.size
                        fileModified: spot.it.modified
                        index: spot.it.i
                        zoom: Math.min(1, pics.size)
                        selected: pics.selectedMap[spot.it.path] === true
                        current: pics.cursor === spot.it.i
                        focused: pics.keysShown && pics.cursor === spot.it.i
                        flash: pics.flashPath === spot.it.path
                        cut: pics.cutMap[spot.it.path] === true
                        dragProxy: pics.dragProxy
                        uriList: pics.uriList
                        onPressedAt: (mouse, i) => pics.pressedAt(mouse, i)
                        onClicked: (mouse, i) => pics.clicked(mouse, i)
                        onDoubleClicked: i => pics.doubleClicked(i)
                        onContextRequested: (i, x, y) => pics.contextRequested(i, x, y)
                    }
                }
            }
        }
    }
    GlideWheel { view: view }
    // a pinch on the touchpad steps the size, a step per 25 % of the pinch (as the grid)
    PinchHandler {
        target: null
        property real from: 1
        onActiveChanged: if (active) from = activeScale
        onActiveScaleChanged: {
            if (activeScale / from > 1.25) { pics.zoom(1); from = activeScale; }
            else if (activeScale / from < 0.8) { pics.zoom(-1); from = activeScale; }
        }
    }
}
