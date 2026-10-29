import QtQuick
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The rail: places, then the trash. Rows say where you are and take you there.
 *
 * Like Zen's sidebar: a toggle at the top folds it to glyphs; while folded, resting the
 * pointer on it expands it over the list with the names (it does not push the list), and
 * it folds back when the pointer leaves. The toggle is remembered.
 */
Item {
    id: rail

    property string folder: ""
    property bool compact: false
    signal go(string path)
    signal placeActions(string name, string path, real x, real y)
    signal toggle()
    signal droppedOn(string path, var urls, int modifiers, bool internal)
    signal device(var dev)          // click: mount if needed, then enter
    signal eject(var dev)
    signal recent()                 // the timeline
    property bool recentShown: false
    signal shelf()                  // the parked files as a list
    property bool shelfShown: false
    signal now(var item)            // a row of what is happening: click reveals or stops
    signal largeOld()
    property bool largeOldShown: false
    // re-evaluate the dots when arrivals change
    property int arrivalsTick: 0
    Connections { target: Recents; function onItemsChanged() { rail.arrivalsTick++; } }
    // the place appears past 85 % and leaves below 80 %, so it never flickers at the line
    property bool diskTight: false
    readonly property int diskPct: IslandController.diskPct
    onDiskPctChanged: { if (diskPct >= 85) diskTight = true; else if (diskPct < 80) diskTight = false; }
    Component.onCompleted: diskTight = IslandController.diskPct >= 85
    // What is happening this minute: a download growing, a copy running, a file that just
    // arrived, a disk that just appeared. The section exists only while there is something.
    property var nowItems: {
        const t = Date.now();
        let items = [];
        for (const j of Jobs.running)
            items.push({ "kind": "job", "glyph": j.kind === "download" ? "downloading" : "sync", "text": Jobs.label(j), "job": j });
        for (const r of Recents.items)
            if ((r.kind === "download" || r.kind === "screenshot") && t - r.at < 90000 && !Jobs.running.some(j => j.kind === "download" && j.name === r.text))
                items.push({ "kind": "file", "glyph": r.kind === "screenshot" ? "screenshot_monitor" : "download_done", "text": r.text, "path": r.path });
        for (const d of Devices.list)
            if (d.at && t - d.at < 90000)
                items.push({ "kind": "device", "glyph": Devices.glyphFor(d), "text": `${Devices.nameFor(d)} appeared`, "dev": d });
        return items.slice(0, 4);
    }
    Timer { interval: 15000; running: rail.nowItems.length > 0; repeat: true; onTriggered: rail.nowItemsChanged() }

    readonly property int fullWidth: 248
    readonly property int compactWidth: 60
    // expanded over the content while folded and hovered
    readonly property bool expanded: !compact || hoverHold.hovering
    implicitWidth: compact ? compactWidth : fullWidth
    Behavior on implicitWidth { Anim {} }
    z: 2

    // A beat before it opens under a passing pointer; a beat before it folds after leaving.
    QtObject {
        id: hoverHold
        property bool hovering: false
        property bool armed: true     // false right after the toggle, until the pointer leaves
    }
    Timer {
        id: openTimer
        interval: 160
        onTriggered: hoverHold.hovering = true
    }
    Timer {
        id: closeTimer
        interval: 260
        onTriggered: hoverHold.hovering = false
    }
    HoverHandler {
        id: hover
        onHoveredChanged: {
            if (hovered) {
                closeTimer.stop();
                if (rail.compact && hoverHold.armed)
                    openTimer.restart();
            } else {
                hoverHold.armed = true;
                openTimer.stop();
                closeTimer.restart();
            }
        }
    }

    // The panel: as wide as the rail, or over the list while expanded from folded.
    Rectangle {
        id: panel
        width: rail.expanded ? rail.fullWidth : rail.compactWidth
        height: parent.height
        radius: 14
        // its own ground only while it lies over the list
        color: rail.compact && rail.expanded ? Appearance.m3colors.m3surfaceContainerHigh : "transparent"
        border.width: rail.compact && rail.expanded ? 1 : 0
        border.color: Appearance.colors.colLayer0Border
        Behavior on width { Anim {} }
        Behavior on color { CAnim {} }
        clip: true

        // the toggle, in line with the header
        RippleButton {
            id: toggleButton
            anchors.top: parent.top
            anchors.topMargin: 2
            anchors.left: parent.left
            anchors.leftMargin: 14
            implicitWidth: 32
            implicitHeight: 32
            padding: 0
            buttonRadius: Appearance.rounding.full
            releaseAction: () => {
                hoverHold.armed = false;
                openTimer.stop();
                hoverHold.hovering = false;
                rail.toggle();
            }
            contentItem: MaterialSymbol {
                text: rail.compact ? "left_panel_open" : "left_panel_close"
                iconSize: 20
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: Tacit.inkSec
            }
            StyledToolTip { text: rail.compact ? "Show the places" : "Fold the places" }
        }

        // Praxis's row (modules/claude/SessionList.qml), measure for measure: 32 high, the wash inset 8 r 8 (here 10 %,
        // under the pointer 5 %), where you are marked by the sand tick at the edge, the glyph at x 20, the word at x 44
        // in 15 px (here Medium in the main ink, the rest in the secondary ink), what it holds in the meta ink at the end
        component RailRow: Item {
            id: rr
            property string glyph: ""
            property string label: ""
            property string context: ""       // at the row's end: a count, how full
            property bool current: false
            property bool fresh: false        // something arrived since you last looked: a sand dot at the end
            property color glyphColor: rr.current || rrArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
            property string dropPath: ""      // a row that takes dropped files
            property bool dropParks: false    // the Shelf's: a drop parks
            property alias hovered: rrArea.containsMouse
            property real rightRoom: 0        // kept free at the end (the eject button)
            signal clicked(var mouse)
            width: panel.width
            height: 32
            Rectangle {
                anchors { fill: parent; leftMargin: 8; rightMargin: 8; topMargin: 1; bottomMargin: 1 }
                radius: 8
                color: rr.current ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
                    : rrArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95) : "transparent"
                Behavior on color { ColorAnimation { duration: 80 } }
            }
            Rectangle {   // where you are: Praxis's sand bar at the row's edge
                visible: rr.current && rail.expanded
                x: 8
                y: 8
                width: 3
                height: 16
                radius: 1.5
                color: Tacit.accent
            }
            DropArea {
                id: rrDrop
                anchors.fill: parent
                enabled: rr.dropPath.length > 0 || rr.dropParks
                keys: ["text/uri-list"]
                onDropped: drop => {
                    drop.accept();
                    if (rr.dropParks) DropShelf.addItems(drop.urls ?? []);
                    else rail.droppedOn(rr.dropPath, drop.urls ?? [], drop.keyboardModifiers, drop.source !== null);
                }
            }
            Rectangle {   // a drag over a row that takes it: a ring in the accent
                anchors { fill: parent; leftMargin: 8; rightMargin: 8; topMargin: 1; bottomMargin: 1 }
                radius: 8
                color: "transparent"
                border.width: 1.5
                border.color: Tacit.accent
                opacity: rrDrop.containsDrag ? 0.9 : 0
            }
            MaterialSymbol {
                x: 20
                anchors.verticalCenter: parent.verticalCenter
                text: rr.glyph
                fill: rr.current ? 1 : 0
                iconSize: 18
                color: rr.glyphColor
            }
            StyledText {
                anchors { left: parent.left; leftMargin: 44; right: rrEnd.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                text: rr.label
                elide: Text.ElideRight
                font.family: Appearance.font.family.compact
                font.pixelSize: 15
                font.weight: rr.current ? Font.Medium : Font.Normal
                color: rr.current || rrArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
                opacity: rail.expanded ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }
            Item {
                id: rrEnd
                anchors { right: parent.right; rightMargin: 20 + rr.rightRoom; verticalCenter: parent.verticalCenter }
                width: rr.fresh ? 6 : rrContext.implicitWidth
                height: 16
                opacity: rail.expanded ? 1 : 0
                StyledText {
                    id: rrContext
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    visible: !rr.fresh && rr.context.length > 0
                    text: rr.context
                    font.family: Appearance.font.family.numbers
                    font.pixelSize: 13
                    color: Tacit.inkMeta
                }
                Rectangle {
                    anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                    visible: rr.fresh
                    width: 6; height: 6; radius: 3
                    color: Tacit.accent
                }
            }
            MouseArea {
                id: rrArea
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => rr.clicked(mouse)
            }
            StyledToolTip { text: rr.label; extraVisibleCondition: !rail.expanded && rrArea.containsMouse }
        }
        // Praxis's section label: 15 DemiBold in the secondary ink, a count in the meta ink beside it
        component RailLabel: Item {
            id: rl
            property string text: ""
            property int count: -1
            width: panel.width
            height: 34
            opacity: rail.expanded ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Row {
                anchors { left: parent.left; leftMargin: 20; bottom: parent.bottom; bottomMargin: 8 }
                spacing: 8
                StyledText {
                    id: rlText
                    text: rl.text
                    font.family: Appearance.font.family.compact
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    color: Tacit.inkSec
                }
                StyledText {
                    anchors.baseline: rlText.baseline
                    visible: rl.count > 0
                    text: rl.count
                    font.family: Appearance.font.family.numbers
                    font.pixelSize: 14
                    color: Tacit.inkMeta
                }
            }
        }

        // a folder dropped on the rail's own ground is pinned
        DropArea {
            anchors.fill: parent
            keys: ["text/uri-list"]
            onDropped: drop => {
                drop.accept();
                for (const u of drop.urls ?? [])
                    Files.pin(FileUtils.trimFileProtocol(decodeURIComponent(u.toString())));
            }
        }

        // the rail's edge: Praxis's hairline, while it stands beside the list
        Rectangle {
            visible: !rail.compact
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Tacit.hairline
            opacity: 0.4
        }

        Flickable {
            anchors { fill: parent; topMargin: 44 }
            contentHeight: column.implicitHeight + 12
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
        Column {
            id: column
            width: panel.width
            spacing: 0
            // the pins below the places; a pinned place is already a row there
            readonly property var ownPins: Files.pins.filter(p => !Files.places.some(x => x.path === p))

            // what is happening this minute: only while something is
            RailLabel { visible: rail.nowItems.length > 0; text: "Now"; height: visible ? 30 : 0 }
            Repeater {
                model: rail.nowItems
                delegate: RailRow {
                    required property var modelData
                    glyph: modelData.glyph
                    label: modelData.text
                    glyphColor: Tacit.accent
                    onClicked: mouse => rail.now(modelData)
                }
            }
            Item { width: 1; height: rail.nowItems.length > 0 ? 8 : 0 }

            // Recent: what arrived and what you touched, as a timeline; the Shelf while anything is parked
            RailRow {
                glyph: "schedule"
                label: "Recent"
                current: rail.recentShown
                onClicked: mouse => rail.recent()
            }
            RailRow {
                visible: DropShelf.items.length > 0 || rail.shelfShown
                height: visible ? 32 : 0
                glyph: "stacks"
                label: "Shelf"
                context: DropShelf.items.length > 0 ? String(DropShelf.items.length) : ""
                current: rail.shelfShown
                dropParks: true
                onClicked: mouse => rail.shelf()
            }

            RailLabel { text: "Places" }
            Repeater {
                model: Files.places
                delegate: RailRow {
                    id: placeRow
                    required property var modelData
                    readonly property string path: modelData.path
                    glyph: modelData.glyph
                    label: Files.placeName(modelData.path)
                    current: rail.folder === modelData.path
                    fresh: !current && rail.arrivalsTick >= 0 && Files.hasNew(modelData.path)
                    dropPath: modelData.path
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) { const at = placeRow.mapToItem(rail, mouse.x, mouse.y); rail.placeActions(placeRow.label, placeRow.path, at.x, at.y); }
                        else rail.go(placeRow.path);
                    }
                }
            }

            RailLabel { visible: column.ownPins.length > 0; height: visible ? 34 : 0; text: "Pinned"; count: column.ownPins.length }
            Repeater {
                model: column.ownPins
                delegate: RailRow {
                    id: pinRow
                    required property var modelData
                    glyph: "push_pin"
                    label: Files.placeName(modelData)
                    current: rail.folder === modelData
                    fresh: !current && rail.arrivalsTick >= 0 && Files.hasNew(modelData)
                    dropPath: modelData
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) { const at = pinRow.mapToItem(rail, mouse.x, mouse.y); rail.placeActions(pinRow.label, modelData, at.x, at.y); }
                        else rail.go(modelData);
                    }
                }
            }

            // disks: a click mounts and enters; the eject glyph unmounts and, for USB, powers off
            RailLabel { visible: Devices.list.length > 0; height: visible ? 34 : 0; text: "Drives" }
            Repeater {
                model: Devices.list
                delegate: RailRow {
                    id: dev
                    required property var modelData
                    glyph: Devices.glyphFor(modelData)
                    label: Devices.nameFor(modelData)
                    current: modelData.mountpoint.length > 0 && (rail.folder === modelData.mountpoint || rail.folder.startsWith(modelData.mountpoint + "/"))
                    rightRoom: ejectButton.visible ? 22 : 0
                    onClicked: mouse => rail.device(modelData)
                    RippleButton {
                        id: ejectButton
                        anchors.right: parent.right
                        anchors.rightMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        visible: rail.expanded && dev.modelData.mountpoint.length > 0 && (dev.hovered || hovered)
                        implicitWidth: 26
                        implicitHeight: 26
                        buttonRadius: Appearance.rounding.full
                        releaseAction: () => rail.eject(dev.modelData)
                        contentItem: MaterialSymbol {
                            text: "eject"
                            iconSize: 17
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: Tacit.inkSec
                        }
                        StyledToolTip { text: dev.modelData.usb ? "Eject, safe to pull" : "Unmount" }
                    }
                }
            }

            // the foot, under Praxis's hairline: the disk when it runs out of room, and the trash
            Item {
                width: panel.width
                height: 19
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 20; rightMargin: 20; bottomMargin: 8 }
                    height: 1
                    color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
                    opacity: rail.expanded ? 1 : 0
                }
            }
            RailRow {
                visible: rail.diskTight || rail.largeOldShown
                height: visible ? 32 : 0
                glyph: "data_usage"
                label: "Large & old"
                // the disk filling up needs you: sand, as Praxis's "needs you"; how full, in the meta ink
                glyphColor: current ? Tacit.inkMain : Tacit.accent
                context: rail.diskPct > 0 ? `${rail.diskPct} % full` : ""
                current: rail.largeOldShown
                onClicked: mouse => rail.largeOld()
            }
            RailRow {
                id: trashRow
                glyph: "delete"
                label: "Trash"
                context: Files.trashCount > 0 ? String(Files.trashCount) : ""
                current: rail.folder === Files.trashDir
                dropPath: Files.trashDir
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) { const at = trashRow.mapToItem(rail, mouse.x, mouse.y); rail.placeActions("Trash", Files.trashDir, at.x, at.y); }
                    else rail.go(Files.trashDir);
                }
            }
        }
        }
    }
}
