import QtQuick
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import Tacit.Kit as K

/**
 * The rail: places, then the trash at its foot. Rows say where you are and take you there.
 *
 * Tacit.Kit's Rail (Praxis's): 300 wide; the toggle at the top folds it to its symbols, 56 wide, and back. The toggle
 * is remembered (Files.railPref). Nothing opens under a passing pointer: folded, a row names itself in a tooltip.
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

    implicitWidth: places.implicitWidth

    // The kit's row, plus what Files' rows do that it does not draw: a row that takes dropped files rings in the
    // accent while a drag is over it; folded, the row names itself under the pointer.
    component Place: Item {
        id: place
        property alias glyph: kitRow.glyph
        property alias label: kitRow.label
        property alias context: kitRow.context
        property alias current: kitRow.current
        property alias fresh: kitRow.fresh
        property string dropPath: ""      // a row that takes dropped files
        property bool dropParks: false    // the Shelf's: a drop parks
        readonly property bool hovered: kitRow.hovered
        readonly property bool folded: kitRow.folded
        signal picked()
        signal menu(real x, real y)       // a right click, in the rail's coordinates
        width: kitRow.width
        height: kitRow.height
        K.RailRow {
            id: kitRow
            onPicked: place.picked()
            onContextRequested: at => {
                const p = kitRow.mapToItem(rail, at.x, at.y);
                place.menu(p.x, p.y);
            }
        }
        DropArea {
            id: drop
            anchors.fill: parent
            enabled: place.dropPath.length > 0 || place.dropParks
            keys: ["text/uri-list"]
            onDropped: d => {
                d.accept();
                if (place.dropParks) DropShelf.addItems(d.urls ?? []);
                else rail.droppedOn(place.dropPath, d.urls ?? [], d.keyboardModifiers, d.source !== null);
            }
        }
        Rectangle {   // on the kit row's wash
            anchors { fill: parent; leftMargin: 8; rightMargin: 8; topMargin: 1; bottomMargin: 1 }
            visible: drop.containsDrag
            radius: K.Kit.tokens.radius.row
            color: "transparent"
            border.width: 1.5
            border.color: K.Kit.tokens.accent
        }
        K.Tooltip { text: place.label; shown: place.folded && place.hovered }
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

    K.Rail {
        id: places
        height: rail.height
        folded: rail.compact
        onToggle: rail.toggle()

        Column {
            id: upper
            width: places.width
            // the pins below the places; a pinned place is already a row there
            readonly property var ownPins: Files.pins.filter(p => !Files.places.some(x => x.path === p))

            // what is happening this minute: only while something is
            K.RailSection { visible: rail.nowItems.length > 0; text: "Now" }
            Repeater {
                model: rail.nowItems
                delegate: Place {
                    required property var modelData
                    glyph: modelData.glyph
                    label: modelData.text
                    onPicked: rail.now(modelData)
                }
            }
            Item { visible: rail.nowItems.length > 0; width: 1; height: K.Kit.tokens.space.s }

            // Recent: what arrived and what you touched, as a timeline; the Shelf while anything is parked
            Place {
                glyph: "schedule"
                label: "Recent"
                current: rail.recentShown
                onPicked: rail.recent()
            }
            Place {
                visible: DropShelf.items.length > 0 || rail.shelfShown
                glyph: "stacks"
                label: "Shelf"
                context: DropShelf.items.length > 0 ? String(DropShelf.items.length) : ""
                current: rail.shelfShown
                dropParks: true
                onPicked: rail.shelf()
            }

            K.RailSection { text: "Places" }
            Repeater {
                model: Files.places
                delegate: Place {
                    required property var modelData
                    glyph: modelData.glyph
                    label: Files.placeName(modelData.path)
                    current: rail.folder === modelData.path
                    fresh: !current && rail.arrivalsTick >= 0 && Files.hasNew(modelData.path)
                    dropPath: modelData.path
                    onPicked: rail.go(modelData.path)
                    onMenu: (x, y) => rail.placeActions(label, modelData.path, x, y)
                }
            }

            K.RailSection { visible: upper.ownPins.length > 0; text: "Pinned" }
            Repeater {
                model: upper.ownPins
                delegate: Place {
                    required property var modelData
                    glyph: "folder"
                    label: Files.placeName(modelData)
                    current: rail.folder === modelData
                    fresh: !current && rail.arrivalsTick >= 0 && Files.hasNew(modelData)
                    dropPath: modelData
                    onPicked: rail.go(modelData)
                    onMenu: (x, y) => rail.placeActions(label, modelData, x, y)
                }
            }

            // disks: a click mounts and enters; the eject symbol unmounts and, for USB, powers off
            K.RailSection { visible: Devices.list.length > 0; text: "Drives" }
            Repeater {
                model: Devices.list
                delegate: Place {
                    id: drive
                    required property var modelData
                    readonly property bool mounted: modelData.mountpoint.length > 0
                    property string free: ""
                    glyph: Devices.glyphFor(modelData)
                    label: Devices.nameFor(modelData)
                    // the room left; under the pointer it gives way to the eject (Praxis's rows: the context gives
                    // way to the row's own actions)
                    context: eject.visible ? "" : free
                    current: mounted && (rail.folder === modelData.mountpoint || rail.folder.startsWith(modelData.mountpoint + "/"))
                    onPicked: if (!eject.hovered) rail.device(modelData)   // the eject's own tap reaches the row too

                    function readFree() { if (drive.mounted) freeProbe.running = true; }
                    Component.onCompleted: readFree()
                    Connections { target: rail; function onFolderChanged() { drive.readFree(); } }
                    Process {
                        id: freeProbe
                        command: ["df", "--output=avail", "-B1", drive.modelData.mountpoint]
                        stdout: StdioCollector {
                            onStreamFinished: {
                                const n = parseFloat((text.trim().split("\n").pop() || "").trim());
                                drive.free = n > 0 ? `${Voice.size(n)} free` : "";
                            }
                        }
                    }
                    K.IconButton {
                        id: eject
                        anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        width: 28
                        height: 28
                        visible: drive.mounted && !drive.folded && (drive.hovered || hovered)
                        symbol: "eject"
                        size: K.Kit.tokens.icon.rail
                        label: drive.modelData.usb ? "Eject, safe to pull" : "Unmount"
                        onPressed: rail.eject(drive.modelData)
                        K.Tooltip { text: eject.label; shown: eject.hovered }
                    }
                }
            }
        }

        // the trash at the rail's foot (16 from the bottom, as the approved design), unless the places run past it.
        // The kit's places start 52 under the rail's top (the toggle's row) and end 16 short of their content.
        Item {
            width: 1
            height: Math.max(K.Kit.tokens.space.l, places.height - 52 - K.Kit.tokens.space.l - upper.height - foot.height)
        }
        Column {
            id: foot
            width: places.width
            Place {
                visible: rail.diskTight || rail.largeOldShown
                glyph: "data_usage"
                label: "Large & old"
                context: rail.diskPct > 0 ? `${rail.diskPct} % full` : ""
                current: rail.largeOldShown
                onPicked: rail.largeOld()
            }
            Place {
                glyph: "delete"
                label: "Trash"
                context: Files.trashCount > 0 ? String(Files.trashCount) : ""
                current: rail.folder === Files.trashDir
                dropPath: Files.trashDir
                onPicked: rail.go(Files.trashDir)
                onMenu: (x, y) => rail.placeActions("Trash", Files.trashDir, x, y)
            }
        }
    }
}
