import QtQuick
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * One file or folder as a line: glyph, name, where it came from (when the desktop knows),
 * age, size. Selection and hover are the same quiet layers as everywhere else.
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
    property bool current: false
    property bool flash: false
    property bool editing: false     // the name is a field (F2)
    property bool hidden: false      // the filter keeps the row in the model, off the screen
    property bool cut: false         // waiting to be pasted elsewhere: drawn faint
    property bool taken: false       // the edited name is already here
    property var offer: null         // { label, glyph, run }: one thing the desktop suggests; a pill
    signal offerTaken(int index)
    signal offerDismissed(int index)
    readonly property var thing: Things.describe(row.filePath + (row.fileIsDir ? "/" : ""))
    readonly property string from: row.fileIsDir ? "" : row.thing.from
    readonly property bool partial: /\.(part|crdownload|tmp)$/i.test(row.fileName)

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
    // Praxis's measures: 34 high (48 with where it came from), the name in 15 px, what it is beside it in the meta ink
    height: row.hidden ? 0 : (row.from.length > 0 ? 48 : 34)
    visible: !row.hidden
    onEditingChanged: {
        if (editing) {
            nameEdit.text = row.fileName;
            const dot = row.fileIsDir ? -1 : row.fileName.lastIndexOf(".");
            nameEdit.select(0, dot > 0 ? dot : row.fileName.length);
            nameEdit.forceActiveFocus();
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: 8
        // chosen: Tacit's neutral wash (12 %), under the pointer 5 %; no palette container
        color: row.selected ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
            : (area.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent")
        Behavior on color { ColorAnimation { duration: 80 } }
    }
    // A folder row is a place to drop into: it swells a little under the drag.
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
        radius: 8
        color: "transparent"
        border.width: 1.5
        border.color: Tacit.accent
        opacity: into.containsDrag ? 0.9 : 0
        Behavior on opacity { NumberAnimation { duration: 100 } }
    }
    // the arrival highlight after a reveal: primary at 18%, fading over a second
    Rectangle {
        anchors.fill: parent
        radius: 8
        color: Appearance.colors.colPrimary
        opacity: row.flash ? 0.18 : 0
        Behavior on opacity { NumberAnimation { duration: 1200; easing.type: Easing.OutCubic } }
    }
    Rectangle {   // keyboard cursor without selection: a hairline
        anchors.fill: parent
        radius: 8
        color: "transparent"
        border.width: 1
        border.color: Appearance.colors.colOutlineVariant
        visible: row.current && !row.selected
        opacity: 0.7
    }

    MaterialSymbol {
        id: glyph
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: row.thing.glyph
        fill: row.fileIsDir ? 1 : 0
        iconSize: 20
        color: row.fileIsDir ? Tacit.inkSec : (row.selected ? Tacit.inkMain : Tacit.inkMeta)
        opacity: row.partial ? 0.5 : 1
    }
    Column {
        anchors.left: parent.left
        anchors.leftMargin: 46
        anchors.right: offerPill.visible ? offerPill.left : meta.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        StyledText {
            id: nameText
            width: parent.width
            visible: !row.editing
            text: row.fileName
            elide: Text.ElideMiddle
            font.pixelSize: 15
            font.weight: row.selected ? Font.Medium : Font.Normal
            color: Tacit.inkMain
            opacity: row.partial || row.cut ? 0.5 : 1
        }
        // The name as a field: the stem selected, the extension kept; Enter commits, Escape
        // reverts, Tab commits and edits the next row. A name already here turns the field
        // to the error colour and refuses.
        Rectangle {
            width: parent.width
            height: 26
            visible: row.editing
            radius: 6
            color: Appearance.m3colors.m3surfaceContainerHighest
            border.width: 1
            border.color: row.taken ? Appearance.colors.colError : Appearance.colors.colPrimary
            TextInput {
                id: nameEdit
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                font.pixelSize: 16
                font.family: Appearance.font.family.main
                color: row.taken ? Appearance.colors.colError : Tacit.inkMain
                selectionColor: Appearance.colors.colSecondaryContainer
                selectedTextColor: Appearance.colors.colOnSecondaryContainer
                clip: true
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
        StyledText {
            width: parent.width
            visible: row.from.length > 0
            text: row.from
            elide: Text.ElideRight
            font.pixelSize: 13
            color: Tacit.inkSec
        }
    }
    // The offer: a pill before the dates. Click takes it; Right on the row takes it; Escape
    // dismisses it for this file. Shown once per file per window.
    RippleButton {
        id: offerPill
        visible: row.offer !== null && !row.editing
        anchors.right: meta.left
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: 26
        leftPadding: 10
        rightPadding: 12
        buttonRadius: Appearance.rounding.full
        colBackground: ColorUtils.transparentize(Tacit.accent, 0.86)
        colBackgroundHover: Tacit.accent
        releaseAction: () => row.offerTaken(row.index)
        altAction: () => row.offerDismissed(row.index)
        contentItem: Row {
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: row.offer?.glyph ?? ""
                iconSize: 16
                color: offerPill.hovered ? Tacit.onAccent : Tacit.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: row.offer?.label ?? ""
                // a narrow window: the pill gives way before the name does
                width: Math.min(implicitWidth, Math.max(60, row.width * 0.4 - 80))
                elide: Text.ElideRight
                font.pixelSize: 14
                color: offerPill.hovered ? Tacit.onAccent : Tacit.accent
            }
        }
        StyledToolTip { text: "Enter or Right takes it · right-click dismisses" }
    }
    Row {
        id: meta
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 18
        StyledText {
            width: 84
            horizontalAlignment: Text.AlignRight
            text: row.partial ? "downloading" : Voice.age(row.fileModified.getTime())
            font.pixelSize: 14
            font.family: Appearance.font.family.numbers
            color: row.partial ? Tacit.accent : row.selected ? Tacit.inkSec : Tacit.inkMeta
        }
        StyledText {
            width: 72
            horizontalAlignment: Text.AlignRight
            text: row.fileIsDir ? "—" : Voice.size(row.fileSize)
            font.pixelSize: 14
            font.family: Appearance.font.family.numbers
            color: row.selected ? Tacit.inkSec : Tacit.inkMeta
        }
    }

    // Dragging a row carries the selection as files, so it lands in any app that takes them.
    // The drag source is the window's, not this delegate's: a row destroyed mid-drag (the
    // folder changed, the window closed) left Qt reading a dead item and took the shell down.
    readonly property Item dragProxy: row.ListView.view?.dragProxy ?? null
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        property bool rightHeld: false
        property bool metaPress: false      // pressed past the name: a band, not a file drag
        property bool banding: false
        drag.target: rightHeld || metaPress || !row.dragProxy ? null : row.dragProxy
        drag.threshold: 10
        property real pressX: 0
        property real pressY: 0
        property bool grabbed: false
        property real lastClick: 0
        onPressed: mouse => {
            rightHeld = mouse.button !== Qt.LeftButton;
            metaPress = !rightHeld && mouse.x > 40 + nameText.contentWidth + 12;
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
                    const o = row.mapToItem(null, pressX, pressY);
                    row.band(o.x, o.y);
                }
                const p = row.mapToItem(null, mouse.x, mouse.y);
                row.band(p.x, p.y);
                return;
            }
            if (grabbed || row.partial || Math.abs(mouse.x - pressX) + Math.abs(mouse.y - pressY) < 4)
                return;
            grabbed = true;
            row.grabToImage(result => { if (row.dragProxy) row.dragProxy.Drag.imageSource = result.url; });
        }
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                const p = row.mapToItem(null, mouse.x, mouse.y);   // window coordinates
                row.contextRequested(row.index, p.x, p.y);
            } else if (mouse.button === Qt.MiddleButton) {
                row.middleClicked(row.index);
            } else {
                // the one selected row, clicked again on its name after a pause (past the
                // double-click window, within a few seconds): a rename, right now
                const now = Date.now();
                const since = now - lastClick;
                lastClick = now;
                const onName = mouse.x > 40 && mouse.x < 40 + nameText.contentWidth + 8;
                const alone = row.selected && row.ListView.view.selectedCount() === 1 && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier));
                row.clicked(mouse, row.index);
                if (alone && onName && since > 450 && since < 3000)
                    row.slowClicked(row.index);
            }
        }
        onDoubleClicked: mouse => { if (mouse.button === Qt.LeftButton) { lastClick = 0; row.doubleClicked(row.index); } }
        drag.onActiveChanged: {
            if (!row.dragProxy)
                return;
            if (drag.active && !row.partial) {
                row.dragProxy.Drag.mimeData = { "text/uri-list": row.ListView.view.uriList(row.index) };
                row.dragProxy.Drag.active = true;
            } else if (!drag.active) {
                row.dragProxy.Drag.active = false;
            }
        }
        onReleased: {
            if (banding) { banding = false; row.bandEnd(); }
            if (row.dragProxy && row.dragProxy.Drag.active)
                row.dragProxy.Drag.drop();
        }
    }
}
