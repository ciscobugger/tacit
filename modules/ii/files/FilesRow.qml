import QtQuick
import qs
import qs.services
import qs.modules.common
import Tacit.Kit as K

/**
 * One file or folder as a line, drawn by the kit's ListRow: its kind (or the picture itself),
 * the name, where it came from beside it (when the desktop knows), size and time. A day's
 * heading sits above the row when the list starts a section here. ListRow's own pointer
 * handlers sit under this row's MouseArea, which keeps the input (drag out, band, middle and
 * slow click); the row's look follows it through previewState.
 */
Item {
    id: row

    required property string fileName
    required property string filePath
    required property bool fileIsDir
    required property double fileSize
    required property date fileModified
    required property int index

    property bool selected: false
    property bool joinAbove: false   // the shown row above is selected too: one wash
    property bool joinBelow: false
    property bool ring: false        // the keyboard's row (the ring shows only after a key)
    property string heading: ""      // a day's section starts at this row
    property string when: ""         // the time, as the list writes it
    property url picture: ""         // a picture shows itself instead of its kind
    property bool flash: false
    property bool editing: false     // the name is a field (F2)
    property bool hidden: false      // the filter keeps the row in the model, off the screen
    property bool cut: false         // waiting to be pasted elsewhere: drawn faint
    property bool taken: false       // the edited name is already here
    property var offer: null         // { label, glyph, run }: one thing the desktop suggests
    signal offerTaken(int index)
    signal offerDismissed(int index)
    readonly property var thing: Things.describe(row.filePath + (row.fileIsDir ? "/" : ""))
    readonly property string from: row.fileIsDir ? "" : row.thing.from
    readonly property bool partial: /\.(part|crdownload|tmp)$/i.test(row.fileName)
    // the size and time columns; the offer takes its own room before them, and a narrow window drops it
    readonly property var factWidths: [96, 108]
    readonly property bool offerShown: row.offer !== null && !row.editing && offerPill.implicitWidth <= row.width * 0.4
    readonly property real headingHeight: row.heading.length > 0 ? dayHeading.implicitHeight : 0

    signal pressedAt(var mouse, int index)
    signal clicked(var mouse, int index)
    signal doubleClicked(int index)
    signal contextRequested(int index, real x, real y)
    signal renamed(int index, string name)
    signal editDone()
    signal droppedInto(int index, var urls, int modifiers, bool internal)
    signal band(real sceneX, real sceneY)      // a drag from the blank part of the row: a selection band
    signal bandEnd()
    signal middleClicked(int index)
    signal slowClicked(int index)   // a second click on the name of the one selected row

    width: ListView.view ? ListView.view.width : 400
    height: row.hidden ? 0 : row.headingHeight + Tacit.height.row
    visible: !row.hidden
    onEditingChanged: {
        if (editing) {
            nameEdit.text = row.fileName;
            const dot = row.fileIsDir ? -1 : row.fileName.lastIndexOf(".");
            nameEdit.select(0, dot > 0 ? dot : row.fileName.length);
            nameEdit.forceActiveFocus();
        }
    }

    K.SectionHeading {
        id: dayHeading
        visible: row.heading.length > 0
        width: row.width
        text: row.heading
    }

    Item {
        id: line
        y: row.headingHeight
        width: row.width
        height: Tacit.height.row

        K.ListRow {
            id: look
            anchors.fill: parent
            focusable: false
            // cut and still downloading: the whole row faint (ListRow has no quiet state of its own)
            opacity: row.partial || row.cut ? 0.5 : 1
            glyph: row.thing.glyph
            picture: row.picture
            name: row.editing ? "" : row.fileName
            aside: row.editing ? "" : row.from
            facts: {
                const f = [row.fileIsDir ? "—" : Voice.size(row.fileSize), row.partial ? "downloading" : row.when];
                return row.offerShown ? [""].concat(f) : f;
            }
            factWidths: row.offerShown ? [offerPill.implicitWidth + Tacit.space.s].concat(row.factWidths) : row.factWidths
            selected: row.selected
            joinAbove: row.joinAbove
            joinBelow: row.joinBelow
            ring: row.ring
            previewState: area.pressed && !area.rightHeld && !area.banding ? "pressed" : area.containsMouse ? "hover" : ""
        }
        // A folder row is a place to drop into: a ring of the accent while something is held over it.
        DropArea {
            id: into
            anchors.fill: parent
            enabled: row.fileIsDir
            keys: ["text/uri-list"]
            onDropped: drop => {
                drop.accept();
                row.droppedInto(row.index, drop.urls ?? [], drop.keyboardModifiers, drop.source !== null);
            }
        }
        Rectangle {
            anchors.fill: parent
            radius: Tacit.radius.row
            color: "transparent"
            border.width: Tacit.state.focusRing
            border.color: Tacit.accent
            opacity: into.containsDrag ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Tacit.motion.hover.ms } }
        }
        // the arrival after a reveal: the accent faintly over the row, fading over a second
        Rectangle {
            anchors.fill: parent
            radius: Tacit.radius.row
            color: Tacit.accent
            opacity: row.flash ? 0.18 : 0
            Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
        }

        // Dragging a row carries the selection as files, so it lands in any app that takes them.
        // The drag source is the window's, not this delegate's: a row destroyed mid-drag (the
        // folder changed, the window closed) left Qt reading a dead item and took the shell down.
        readonly property Item dragProxy: row.ListView.view?.dragProxy ?? null
        // where the name ends: past it a press draws a band instead of taking the file
        readonly property real nameEnd: 52 + look.nameRoom
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            property bool rightHeld: false
            property bool metaPress: false      // pressed past the name: a band, not a file drag
            property bool banding: false
            drag.target: rightHeld || metaPress || !line.dragProxy ? null : line.dragProxy
            drag.threshold: 10
            property real pressX: 0
            property real pressY: 0
            property bool grabbed: false
            property real lastClick: 0
            onPressed: mouse => {
                rightHeld = mouse.button !== Qt.LeftButton;
                metaPress = !rightHeld && mouse.x > line.nameEnd + 12;
                banding = false;
                pressX = mouse.x; pressY = mouse.y; grabbed = false;
                row.pressedAt(mouse, row.index);
            }
            // the drag image is taken only once the hand moves with the button down (before the
            // drag threshold): a plain click never pays for a render
            onPositionChanged: mouse => {
                if (!pressed || rightHeld)
                    return;
                if (metaPress) {
                    if (!banding && Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < 6)
                        return;
                    if (!banding) {   // the band starts where the button went down, not where the hand is now
                        banding = true;
                        const o = line.mapToItem(null, pressX, pressY);
                        row.band(o.x, o.y);
                    }
                    const p = line.mapToItem(null, mouse.x, mouse.y);
                    row.band(p.x, p.y);
                    return;
                }
                if (grabbed || row.partial || Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < 4)
                    return;
                grabbed = true;
                line.grabToImage(result => { if (line.dragProxy) line.dragProxy.Drag.imageSource = result.url; });
            }
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = line.mapToItem(null, mouse.x, mouse.y);   // window coordinates
                    row.contextRequested(row.index, p.x, p.y);
                } else if (mouse.button === Qt.MiddleButton) {
                    row.middleClicked(row.index);
                } else {
                    // the one selected row, clicked again on its name after a pause (past the
                    // double-click window, within a few seconds): a rename, right now
                    const now = Date.now();
                    const since = now - lastClick;
                    lastClick = now;
                    const onName = mouse.x > 52 - 4 && mouse.x < line.nameEnd + 8;
                    const alone = row.selected && row.ListView.view.selectedCount() === 1 && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier));
                    row.clicked(mouse, row.index);
                    if (alone && onName && since > 450 && since < 3000)
                        row.slowClicked(row.index);
                }
            }
            onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) { lastClick = 0; row.doubleClicked(row.index); } }
            drag.onActiveChanged: {
                if (!line.dragProxy)
                    return;
                if (drag.active && !row.partial) {
                    line.dragProxy.Drag.mimeData = { "text/uri-list": row.ListView.view.uriList(row.index) };
                    line.dragProxy.Drag.active = true;
                } else if (!drag.active) {
                    line.dragProxy.Drag.active = false;
                }
            }
            onReleased: {
                if (banding) { banding = false; row.bandEnd(); }
                if (line.dragProxy && line.dragProxy.Drag.active)
                    line.dragProxy.Drag.drop();
            }
        }

        // The name as a field, where the name stands (the kit's Field: a faint wash, the ring while
        // typing): the stem selected, the extension kept; Enter commits, Escape reverts, Tab commits
        // and edits the next row. A name already here turns the ring and the words to the risk ink
        // and refuses. Above the row's MouseArea, so a click in it places the caret.
        Item {
            visible: row.editing
            x: 52 - Tacit.space.m
            width: look.textRoom + 2 * Tacit.space.m
            height: Tacit.height.field
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                anchors.fill: parent
                radius: Tacit.radius.slab
                color: Tacit.inkMain
                opacity: Tacit.wash.action
            }
            K.FocusRing {
                shown: nameEdit.activeFocus
                corner: Tacit.radius.slab
                border.color: row.taken ? Tacit.risk : Tacit.accent
            }
            TextInput {
                id: nameEdit
                x: Tacit.space.m
                width: parent.width - 2 * Tacit.space.m
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                color: row.taken ? Tacit.risk : Tacit.inkMain
                selectionColor: Qt.alpha(Tacit.accent, 0.4)
                selectedTextColor: Tacit.inkMain
                font.family: Tacit.font.main
                font.pixelSize: Tacit.size.row
                font.variableAxes: ({ "wght": Tacit.weight.regular, "wdth": 100 })
                font.hintingPreference: Font.PreferNoHinting
                renderType: Text.NativeRendering
                cursorDelegate: Rectangle { width: 1.5; color: Tacit.accent; visible: nameEdit.cursorVisible }
                onTextChanged: row.taken = row.ListView.view ? row.ListView.view.nameTaken(text, row.fileName) : false
                // a click elsewhere commits a good name, as Finder does; a bad one is dropped
                onActiveFocusChanged: {
                    if (activeFocus || !row.editing)
                        return;
                    const n = text.trim();
                    if (n.length > 0 && n !== "." && n !== ".." && !n.includes("/") && n !== row.fileName && !row.taken)
                        row.renamed(row.index, n);
                    row.editing = false;
                    row.editDone();
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) { row.editing = false; row.editDone(); event.accepted = true; }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                        const n = text.trim();
                        if (n.length > 0 && n !== "." && n !== ".." && !n.includes("/") && n !== row.fileName && !row.taken)
                            row.renamed(row.index, n);
                        row.editing = false;
                        if (event.key === Qt.Key_Tab) row.ListView.view.editNext(row.index); else row.editDone();
                        event.accepted = true;
                    }
                }
            }
        }

        // The offer: a quiet Slab before the size. Click takes it, as do Enter and Right on the
        // row; a right click or Escape dismisses it for this file. Shown once per file per window.
        K.Slab {
            id: offerPill
            visible: row.offerShown
            anchors.right: parent.right
            anchors.rightMargin: Tacit.space.l + row.factWidths[0] + row.factWidths[1] + Tacit.space.s
            anchors.verticalCenter: parent.verticalCenter
            text: row.offer?.label ?? ""
            onPicked: row.offerTaken(row.index)
        }
        MouseArea {
            anchors.fill: offerPill
            enabled: row.offerShown
            acceptedButtons: Qt.RightButton
            onClicked: row.offerDismissed(row.index)
        }
    }
}
