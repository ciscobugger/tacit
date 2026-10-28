import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit
import Tacit.Kit as K

/**
 * The Columns view (kit v0, "View controls"): the hierarchy. One column per folder from the root place (Home, or /)
 * down to the folder shown, each 250 wide with a hairline after it; an ancestor column lists its folder with the way
 * down chosen, the last column is the folder itself (the window's rows: its selection, cursor, filter and order).
 * A folder opens as the next column (the window goes there); a file in an ancestor column is that folder with the file
 * chosen. Folders end in a chevron. The strip scrolls sideways when the columns outgrow the width and follows the
 * deepest one. The last column is a plain list of K.ListRows: no drag out or rename here (a list's, a grid's).
 */
Item {
    id: columns

    property string folder: ""
    property string home: ""
    property var rows: []                  // the window's rows (the last column)
    property var selectedMap: ({})
    property int cursor: -1
    property bool keysShown: false
    property bool showHidden: false
    property var shown: name => true       // the typed name filter
    property var pictureFor: (path, isDir) => ""
    readonly property real columnWidth: 250
    readonly property alias lastList: last

    signal goTo(string path)               // a folder: it becomes the last column
    signal revealIn(string path)           // a file of an ancestor column: its folder, the file chosen
    signal picked(int index, int modifiers)
    signal opened(int index)
    signal contextRequested(int index, real x, real y)

    readonly property var levels: {
        const f = columns.folder, h = columns.home;
        const root = f === h || f.startsWith(h + "/") ? h : "/";
        const out = [root];
        let acc = root === "/" ? "" : root;
        for (const part of f.substring(acc.length).split("/").filter(s => s.length > 0)) {
            acc += "/" + part;
            out.push(acc);
        }
        return out;
    }
    readonly property int count: columns.levels.length

    function positionViewAtIndex(i, mode) { last.positionViewAtIndex(i, mode); }
    // is there a row under this point (of this item)? The ground between and below them is the page's
    function overRow(x, y) {
        const cx = x + strip.contentX;
        const c = Math.floor(cx / columns.columnWidth);
        if (c < 0 || c >= columns.count)
            return false;
        const lx = cx - c * columns.columnWidth;
        const lv = c === columns.count - 1 ? last : ancestors.itemAt(c)?.list;
        return !!lv && lv.indexAt(lx, y + lv.contentY) >= 0;
    }
    // follow the deepest column
    function follow() { strip.contentX = Math.max(0, strip.contentWidth - strip.width); }
    onCountChanged: followSoon.restart()
    onWidthChanged: followSoon.restart()
    Timer { id: followSoon; interval: 0; onTriggered: columns.follow() }

    Flickable {
        id: strip
        anchors.fill: parent
        contentWidth: columns.count * columns.columnWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        Behavior on contentX {
            enabled: !strip.moving && !strip.dragging
            NumberAnimation { duration: K.Kit.tokens.motion.hover.ms * 2; easing.type: Easing.OutCubic }
        }

        Repeater {
            id: ancestors
            model: ScriptModel { values: columns.levels.slice(0, -1) }
            delegate: Item {
                id: col
                required property string modelData
                required property int index
                readonly property alias list: lv
                readonly property string chosen: columns.levels[col.index + 1] ?? ""
                x: col.index * columns.columnWidth
                width: columns.columnWidth
                height: strip.height
                FolderListModel {
                    id: dir
                    folder: "file://" + col.modelData
                    showDirsFirst: true
                    showDotAndDotDot: false
                    showHidden: columns.showHidden
                    caseSensitive: false
                    onStatusChanged: if (status === FolderListModel.Ready) bring.restart()
                }
                Timer {
                    id: bring
                    interval: 0
                    onTriggered: {
                        for (let i = 0; i < dir.count; i++)
                            if (dir.get(i, "filePath") === col.chosen) { lv.positionViewAtIndex(i, ListView.Contain); return; }
                    }
                }
                ListView {
                    id: lv
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    topMargin: 8
                    bottomMargin: 8
                    clip: true
                    model: dir
                    boundsBehavior: Flickable.StopAtBounds
                    GlideWheel { view: lv }
                    delegate: K.ListRow {
                        id: line
                        required property string fileName
                        required property string filePath
                        required property bool fileIsDir
                        readonly property var thing: Things.describe(line.filePath + (line.fileIsDir ? "/" : ""))
                        width: lv.width
                        focusable: false
                        glyph: line.thing.glyph
                        picture: columns.pictureFor(line.filePath, line.fileIsDir)
                        name: line.fileName
                        selected: line.filePath === col.chosen
                        // a file here: its folder opens with the file chosen
                        onClicked: line.fileIsDir ? columns.goTo(line.filePath) : columns.revealIn(line.filePath)
                        onActivated: line.fileIsDir ? columns.goTo(line.filePath) : columns.revealIn(line.filePath)
                        K.Symbol {
                            visible: line.fileIsDir
                            x: line.width - width - K.Kit.tokens.space.m
                            anchors.verticalCenter: parent.verticalCenter
                            text: "chevron_right"
                            color: K.Kit.tokens.inkMeta
                        }
                    }
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: K.Kit.tokens.hairline }
            }
        }

        Item {
            x: (columns.count - 1) * columns.columnWidth
            width: columns.columnWidth
            height: strip.height
            ListView {
                id: last
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                topMargin: 8
                bottomMargin: 8
                clip: true
                model: ScriptModel { values: columns.rows; objectProp: "filePath" }
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: StyledScrollBar { }
                GlideWheel { view: last }
                delegate: K.ListRow {
                    id: item
                    required property var modelData
                    required property int index
                    readonly property var thing: Things.describe(item.modelData.filePath + (item.modelData.fileIsDir ? "/" : ""))
                    readonly property bool here: columns.shown(item.modelData.fileName)
                    width: last.width
                    height: item.here ? implicitHeight : 0
                    visible: item.here
                    focusable: false
                    glyph: item.thing.glyph
                    picture: columns.pictureFor(item.modelData.filePath, item.modelData.fileIsDir)
                    name: item.modelData.fileName
                    selected: columns.selectedMap[item.modelData.filePath] === true
                    current: columns.cursor === item.index
                    ring: columns.cursor === item.index && columns.keysShown
                    onClicked: m => {
                        if (item.modelData.fileIsDir && m === 0) columns.goTo(item.modelData.filePath);
                        else columns.picked(item.index, m);
                    }
                    onActivated: columns.opened(item.index)
                    onContextRequested: at => { const p = item.mapToItem(null, at.x, at.y); columns.contextRequested(item.index, p.x, p.y); }
                    K.Symbol {
                        visible: item.modelData.fileIsDir
                        x: item.width - width - K.Kit.tokens.space.m
                        anchors.verticalCenter: parent.verticalCenter
                        text: "chevron_right"
                        color: K.Kit.tokens.inkMeta
                    }
                }
            }
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: K.Kit.tokens.hairline }
        }
    }
}
