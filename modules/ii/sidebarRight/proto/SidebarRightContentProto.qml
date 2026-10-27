pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.models.quickToggles
import qs.modules.tacit
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Tacit.Kit
import qs.modules.ii.sidebarRight.bluetoothDevices
import qs.modules.ii.sidebarRight.vpn
import qs.modules.ii.sidebarRight.nightLight
import qs.modules.ii.sidebarRight.volumeMixer
import qs.modules.ii.sidebarRight.wifiNetworks
import qs.modules.ii.sidebarRight.calendar

/**
 * Prototype: the control panel rearranged for the idea issue.
 *
 * Compared with SidebarRightContent.qml:
 *   - timer and tasks (BottomWidgetGroup) are gone
 *   - Settings and Session are icon buttons on the footer's right (Session is
 *     risk-coloured: it ends the session)
 *   - sliders are horizontal, below the toggles; the calendar lives below them,
 *     always visible
 *   - four primary toggles stacked in a 2×2 square, a row of secondary pills below it
 *     (always full: the drawer's own toggles fill its empty cells), the dots (drawer
 *     opener) as the row's last cell, the rest hidden in a drawer; the user's
 *     arrangement is kept in Directories.state/user/sidebar-arrangement.json
 *   - a toggle's submenu opens as a card in the panel's own ground floating over the
 *     panel (no shadow, no scrim), pinned under the toggles block; click outside
 *     closes; one submenu at a time
 *
 * The parts the design kit carries are the kit's own (`import Tacit.Kit`): Symbol, IconButton,
 * Slider, FocusRing. Values (corners, text sizes, spaces, motion) come from
 * Kit.tokens; the panel's own frost and the pill washes stay the shell's, in
 * Appearance/Tacit roles (Tacit.q carries the same token block, generated from
 * tacit-kit's tokens.json).
 *
 * Arranging: a pill is a drag in edit mode — a ghost follows the pointer, the zone
 * under it tints, and the release decides placement: a primary square cell, a
 * secondary row slot, or retired to the drawer anywhere else. Primary and secondary
 * take at most 4 and 6; an overflowed pill returns to the drawer. Every placement
 * (drag or keyboard) is undoable: a line offers Undo at the foot, Ctrl+Z works too.
 * Every pill takes Tab and moves with the arrows: left/right swap it with its
 * neighbour in its own level, up promotes (the square, the row, then the drawer),
 * down demotes. The keyboard ring is the kit's FocusRing.
 */
Item {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    property int sidebarPadding: Kit.tokens.space.l
    property bool showAudioOutputDialog: false
    property bool showAudioInputDialog: false
    property bool showBluetoothDialog: false
    property bool showNightLightDialog: false
    property bool showWifiDialog: false

    property bool showVpn: false
    readonly property var sectionFlags: ["showWifiDialog", "showVpn", "showBluetoothDialog", "showAudioOutputDialog", "showAudioInputDialog", "showNightLightDialog"]
    function only(flag) {
        for (const f of root.sectionFlags)
            if (f !== flag && root[f])
                root[f] = false;
    }
    onShowWifiDialogChanged: if (showWifiDialog) only("showWifiDialog")
    onShowVpnChanged: if (showVpn) only("showVpn")
    onShowBluetoothDialogChanged: if (showBluetoothDialog) only("showBluetoothDialog")
    onShowAudioOutputDialogChanged: if (showAudioOutputDialog) only("showAudioOutputDialog")
    onShowAudioInputDialogChanged: if (showAudioInputDialog) only("showAudioInputDialog")
    onShowNightLightDialogChanged: if (showNightLightDialog) only("showNightLightDialog")

    // Same clearing the shipped content does on close (SidebarRightContent.qml): the
    // lists fold and the drawer shuts, so the panel comes back drawn, not used.
    Connections {
        target: GlobalStates
        function onSidebarRightOpenChanged() {
            if (!GlobalStates.sidebarRightOpen) {
                for (const f of root.sectionFlags)
                    root[f] = false;
                root.drawerOpen = false;
                root.editMode = false;
                _undoBox.hide();
            }
        }
    }

    // ---------------------------------------------------------------- undo
    // The undo line (a small stand-in for the kit's Notice, which reads
    // Kit.tokens.overlay — a token the shell's Tacit does not carry yet). One step
    // back: only the last placement can be undone.
    property var _undoSnapshot: null
    function pushUndo(line) {
        _undoSnapshot = {
            primary: root.primary.slice(),
            secondary: root.secondary.slice()
        };
        _undoBox.show(line, "Undo");
    }
    function doUndo() {
        if (!root._undoSnapshot)
            return;
        const s = root._undoSnapshot;
        root.primary = s.primary.slice();
        root.secondary = s.secondary.slice();
        root._undoSnapshot = null;
        root.saveArrangement();
        _undoBox.hide();
    }

    // The user's arrangement: four primary in a 2×2 square (they stack two wide), a
    // single row of secondaries below it whose last cell is the dots button, the rest
    // in the drawer. Empty lists mean "first boot": the defaults below apply until the
    // user moves something.
    readonly property list<string> defaultPrimary: ["wifi", "bluetooth", "vpn", "nightLight"]
    readonly property list<string> defaultSecondary: ["mic", "notifications", "keepAwake"]
    property list<string> primary
    property list<string> secondary
    readonly property bool arrangementLoaded: primary.length > 0 || secondary.length > 0
    function loadArrangement() {
        const p = arrangementAdapter.primary ?? [];
        const s = arrangementAdapter.secondary ?? [];
        root.primary = p.length > 0 ? p : root.defaultPrimary;
        root.secondary = s.length > 0 ? s : root.defaultSecondary;
    }
    function saveArrangement() {
        arrangementAdapter.primary = root.primary;
        arrangementAdapter.secondary = root.secondary;
        arrangementFile.writeAdapter();
    }
    function demote(id) {
        root.primary = root.primary.filter(v => v !== id);
        root.secondary = root.secondary.filter(v => v !== id);
        root.saveArrangement();
    }
    // ------------------------------------------------------------------ drag & drop
    // In edit mode a pill is a drag rather than a click: a ghost follows the pointer,
    // and on release the pointer's position decides where the pill goes — the primary
    // column's row, a cell of the square, or back into the drawer (anywhere else, the
    // square's dots cell included, retires the pill).
    property bool dragging: false
    property string dragTarget: ""
    property string dragIcon: ""
    property string dragName: ""
    property point dragPoint
    function beginDrag(icon, name, rootPos) {
        root.dragIcon = icon;
        root.dragName = name;
        root.dragPoint = rootPos;
        root.dragging = true;
    }
    function moveDrag(rootPos) {
        root.dragPoint = rootPos;
    }
    // Where a drop sits, per zone: the primary square is two cells wide split of the
    // toggles measure in two rows with an s gap; the secondary row is height.action
    // pills on one line, the dots in its last cell.
    function primaryIndex(pointInGrid) {
        // The square: two cells split of the toggles measure, two rows of the primary
        // pill's own height, both with an s gap (cell pitch 168).
        const cell = (root.togglesWidth - Kit.tokens.space.s) / 2;
        const rowHeight = Kit.tokens.height.action + Kit.tokens.space.l;
        const col = Math.min(1, Math.floor((pointInGrid.x + Kit.tokens.space.s / 2) / (cell + Kit.tokens.space.s)));
        const row = Math.min(1, Math.floor((pointInGrid.y + Kit.tokens.space.s / 2) / (rowHeight + Kit.tokens.space.s)));
        return row * 2 + col;
    }
    function secondaryIndex(pointInGrid) {
        const pitch = Kit.tokens.height.action + Kit.tokens.space.s;
        const idx = Math.min(6, Math.floor(pointInGrid.x / pitch));
        return idx < 6 ? idx : -1; // -1: the dots' cell
    }
    // Which drop zone the pointer sits in: the primary square, the secondary row, or
    // none ("retire"). Used for the drop highlight while dragging and by endDrag; both
    // pass root.dragPoint, so the highlight re-evaluates on every move.
    function zoneAt(rootPos) {
        const p0 = primaryZone.mapToItem(root, 0, 0);
        const s0 = secondaryZone.mapToItem(root, 0, 0);
        if (rootPos.x >= p0.x && rootPos.x < p0.x + primaryZone.width
            && rootPos.y >= p0.y && rootPos.y < p0.y + primaryZone.height)
            return "primary";
        if (rootPos.x >= s0.x && rootPos.x < s0.x + secondaryZone.width
            && rootPos.y >= s0.y && rootPos.y < s0.y + secondaryZone.height)
            return "secondary";
        return "";
    }
    function endDrag(rootPos) {
        const pill = root.dragTarget;
        const name = root.dragName;
        root.dragging = false;
        root.dragTarget = "";
        root.dragIcon = ""; // no stale glyph under the hidden ghost's next appearance
        root.dragName = "";
        if (pill.length === 0)
            return;
        // Where the pointer sat, in panel coordinates, against each zone's bounds.
        const zone = root.zoneAt(rootPos);
        root.pushUndo(`Moved ${name}`);
        if (zone === "primary") {
            root.promoteAt(pill, "primary", root.primaryIndex(root.mapToItem(primaryZone, rootPos.x, rootPos.y)));
        } else if (zone === "secondary") {
            const idx = root.secondaryIndex(root.mapToItem(secondaryZone, rootPos.x, rootPos.y));
            if (idx >= 0) // the dots' cell or the empty tail retires the pill
                root.promoteAt(pill, "secondary", idx);
            else
                root.demote(pill);
        } else {
            root.demote(pill);
        }
    }
    // The drop that never lands: the grab was taken away (the panel closing under the
    // pointer, a reload). Nothing is placed — the pointer never chose a zone.
    function cancelDrag() {
        root.dragging = false;
        root.dragTarget = "";
        root.dragIcon = "";
        root.dragName = "";
    }
    // Promote with a place: a full level retires the pill that loses its spot (the last
    // one), and a drop with an index can also reorder within a level. Four primaries in
    // the square, six in the row (its last cell is the dots).
    function promoteAt(id, level, index) {
        root.demote(id); // idempotent for pills not shown
        if (level === "primary") {
            const i = Math.max(0, Math.min(index ?? 0, 3));
            const list = root.primary.filter(v => v !== id);
            list.splice(i, 0, id);
            if (list.length > 4) {
                const retired = list[4];
                root.primary = list.slice(0, 4);
                root.secondary = root.secondary.filter(v => v !== retired);
            } else {
                root.primary = list;
            }
        } else {
            const i = Math.max(0, Math.min(index ?? 0, 5));
            const list = root.secondary.filter(v => v !== id);
            list.splice(i, 0, id);
            if (list.length > 6) {
                const retired = list[6];
                root.secondary = list.slice(0, 6);
                root.primary = root.primary.filter(v => v !== retired);
            } else {
                root.secondary = list;
            }
        }
        root.saveArrangement();
    }

    // ------------------------------------------------------------------ keyboard
    // Tab reaches every pill; arrows move it. Names ride with the move for the undo
    // line. After a move the moved pill keeps the keyboard focus (the Repeater
    // recreates delegates on any list change, so the id is handed back).
    property string pendingFocus: ""
    function focusNext(id) {
        if (id.length > 0)
            root.pendingFocus = id;
    }
    function keyboardMove(id, name, level, dir) {
        if (level === "primary") {
            const i = root.primary.indexOf(id);
            if ((dir === "left" || dir === "right") && i >= 0) {
                const j = i + (dir === "left" ? -1 : 1);
                if (j < 0 || j >= root.primary.length)
                    return;
                root.pushUndo(`Swapped ${name} and ${root.primary[j]}`);
                const list = root.primary.slice();
                list[i] = list[j];
                list[j] = id;
                root.primary = list;
                root.focusNext(id);
            } else if (dir === "down") {
                root.pushUndo(`Moved ${name} to the row`);
                root.promoteAt(id, "secondary", root.secondary.length);
                root.focusNext(id);
            }
        } else if (level === "secondary") {
            const i = root.secondary.indexOf(id);
            if ((dir === "left" || dir === "right") && i >= 0) {
                const j = i + (dir === "left" ? -1 : 1);
                if (j < 0 || j >= root.secondary.length)
                    return;
                root.pushUndo(`Swapped ${name} and ${root.secondary[j]}`);
                const list = root.secondary.slice();
                list[i] = list[j];
                list[j] = id;
                root.secondary = list;
                root.focusNext(id);
            } else if (dir === "up") {
                root.pushUndo(`Moved ${name} to the square`);
                root.promoteAt(id, "primary", root.primary.length);
                root.focusNext(id);
            } else if (dir === "down") {
                root.pushUndo(`Moved ${name} to the drawer`);
                root.demote(id);
                root.focusNext(id);
            }
        } else if (level === "drawer") {
            if (dir === "up") {
                root.pushUndo(`Moved ${name} to the square`);
                root.promoteAt(id, "primary", root.primary.length);
                root.focusNext(id);
            }
        }
    }

    // Everything the drawer can hold. Each id wants a toggle model and, for the ones with
    // a list, the section to open on the body below.
    readonly property var toggleCatalog: [
        ["wifi", networkComp, "showWifiDialog"],
        ["vpn", vpnComp, "showVpn"],
        ["bluetooth", bluetoothComp, "showBluetoothDialog"],
        ["notifications", notificationComp, ""],
        ["nightLight", nightLightComp, "showNightLightDialog"],
        ["mic", micComp, "showAudioInputDialog"],
        ["keepAwake", idleComp, ""],
        ["audio", audioComp, "showAudioOutputDialog"],
        ["screenRecord", screenRecordComp, ""],
        ["screenSnip", screenSnipComp, ""],
        ["colorPicker", colorPickerComp, ""],
        ["darkMode", darkModeComp, ""],
        ["powerProfiles", powerProfilesComp, ""],
        ["osk", oskComp, ""],
        ["wallpaper", wallpaperComp, ""]
    ]
    function catalogEntry(id) {
        return root.toggleCatalog.find(e => e[0] === id) ?? null;
    }

    // Pills are raised the way the rules want (Tacit.qml): ink *mixed* over the ground —
    // "on" at the raised slab (11 %), "off" at a fainter mix of the same two, no
    // transparency anywhere (text ranked by brightness, never by opacity).
    readonly property color colPillOn: Tacit.raised
    readonly property color colPillOnHover: Tacit.raisedHot
    readonly property color colPillOff: ColorUtils.mix(Tacit.inkMain, Tacit.ground, 0.05)
    readonly property color colPillOffHover: ColorUtils.mix(Tacit.inkMain, Tacit.ground, 0.07)
    property real maxHeight: 700
    // The toggles block is the panel's measure: seven height.action cells — six
    // secondaries in the row with the dots as the seventh — close it; the primary
    // square's two pills split the same width. The sliders, row and drawer's grid all
    // match this width so the panel's columns close on the same right edge.
    readonly property real togglesWidth: Kit.tokens.height.action * 7 + Kit.tokens.space.s * 6
    // The row's six pills are height.action with the dots as the seventh cell.
    // The row is always full: the user's secondaries first, then the drawer's next ids
    // take the rest of the row's cells (they stay drawer items until placed by hand).
    function rowIds() {
        return root.secondary.concat(root.rowFillerIds());
    }
    // Everything placed nowhere: neither level shows it.
    function unplacedIds() {
        return root.toggleCatalog.map(e => e[0]).filter(id => root.primary.indexOf(id) < 0 && root.secondary.indexOf(id) < 0);
    }
    function rowFillerIds() {
        return root.unplacedIds().slice(0, 6 - root.secondary.length);
    }
    // Which pills the drawer shows: placed nowhere and not auto-filling the row.
    function drawerIds() {
        const filler = root.rowFillerIds();
        return root.unplacedIds().filter(id => filler.indexOf(id) < 0);
    }
    implicitHeight: Math.min(Math.max(
        column.implicitHeight + root.sidebarPadding * 2, // the content as drawn
        submenuLayer.active ? submenuLayer.cardBottom + root.sidebarPadding : 0 // the floating submenu may hang lower
    ), root.maxHeight)
    // Body padding on both sides on top of the toggles measure, or the square's right
    // column is cut by the body's own margin.
    implicitWidth: Math.min(root.togglesWidth + root.sidebarPadding * 2, sidebarWidth)

    property var brightnessMonitor: Brightness.getMonitorForScreen(root.QsWindow.window?.screen)

    // The arrangement's file, exposed for the test harness (a QObject, not an Item:
    // unreachable by object-name search from outside).
    readonly property QtObject arrangementView: arrangementFile

    FileView {
        id: arrangementFile
        objectName: "arrangementFile"
        path: `${Directories.state}/user/sidebar-arrangement.json`
        watchChanges: true
        blockLoading: true
        printErrors: false
        onFileChanged: root.loadArrangement()
        onLoaded: root.loadArrangement()
        adapter: JsonAdapter {
            id: arrangementAdapter
            property list<string> primary: []
            property list<string> secondary: []
        }
    }

    Rectangle {
        id: sidebarRightBackground

        anchors.fill: parent
        color: "transparent"
        // The panel's own silhouette (DockedRect's coves) — the shell's surface, not
        // content; the shipped panel carries this radius, the kit's radius.token
        // ladder begins at content.
        radius: Appearance.rounding.verylarge

        // The panel's own material — frost and body — gathered under one item; the
        // layers above it occupy the same frame without being part of it.
        Item {
            id: panelContent
            anchors.fill: parent

            DockedRect {
                id: dockedBg
                anchors.fill: parent
                edge: "bottom-right"
                cornerRadius: sidebarRightBackground.radius
                fillet: 12
                // The rule's own role: a shell surface that floats over apps is the frost.
                color: Appearance.colors.colPanelFrost
            }

        StyledFlickable {
            id: body
            anchors.fill: parent
            anchors.margins: root.sidebarPadding
            contentHeight: column.implicitHeight
            interactive: contentHeight > height
            clip: true

            // Escape folds what is open (the submenu first, the drawer, then edit
            // mode); Ctrl+Z steps the last placement back.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (root.sectionFlags.some(f => root[f])) {
                        for (const f of root.sectionFlags)
                            root[f] = false;
                    } else if (root.drawerOpen) {
                        root.drawerOpen = false;
                    } else {
                        root.editMode = false;
                    }
                    event.accepted = true;
                } else if (event.key === Qt.Key_Z && (event.modifiers & Qt.ControlModifier)) {
                    root.doUndo();
                    event.accepted = true;
                }
            }

            ColumnLayout {
                id: column
                width: body.width
                // The panel reads in three groups — the toggles (square, row, drawer)
                // and the sliders with them, the calendar, the bottom row — so inside
                // a group the gap is space.m and between groups an s more.
                spacing: Kit.tokens.space.m

                // ----------------------------------------- the toggles block
                // Four primaries stacked in a 2×2 square; below them, one full-width row
                // of secondary pills whose last cell (after the pills) is the dots, the
                // drawer's opener. A Grid, not a Flow: the Flow was squeezed by the layout
                // and wrapped every pill onto its own line.
                ColumnLayout {
                    id: togglesBlock
                    Layout.fillWidth: true
                    spacing: Kit.tokens.space.s

                    Item {
                        id: primaryZone
                        objectName: "primaryZone"
                        // An s more: the square stands a step apart from the row under it.
                        Layout.bottomMargin: Kit.tokens.space.xs
                        implicitWidth: primaryGrid.width
                        implicitHeight: primaryGrid.height
                        Layout.preferredWidth: implicitWidth
                        Layout.preferredHeight: implicitHeight
                        Layout.fillWidth: false

                        // The drop highlight: the zone tints while a dragged pill is aimed
                        // at it, so aiming is visible rather than imagined.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -Kit.tokens.space.s
                            radius: Kit.tokens.radius.row
                            color: ColorUtils.transparentize(root.colPillOn, 0.75)
                            opacity: root.dragging && root.zoneAt(root.dragPoint) === "primary" ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Kit.ms(Kit.motion("fadeFast").ms)
                                }
                            }
                        }

                        Grid {
                            id: primaryGrid
                            columns: 2
                            spacing: Kit.tokens.space.s

                            Repeater {
                                model: root.primary
                                delegate: PrimaryPill {
                                    required property string modelData
                                    pillId: modelData
                                    editMode: root.editMode
                                    onDemoted: id => root.demote(id)
                                }
                            }
                        }
                    }

                    Item {
                        id: secondaryZone
                        objectName: "secondaryZone"
                        implicitWidth: secondaryGrid.width
                        implicitHeight: secondaryGrid.height
                        Layout.preferredWidth: implicitWidth
                        Layout.preferredHeight: implicitHeight
                        Layout.alignment: Qt.AlignLeft

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -Kit.tokens.space.s
                            radius: Kit.tokens.radius.row
                            color: ColorUtils.transparentize(root.colPillOn, 0.75)
                            opacity: root.dragging && root.zoneAt(root.dragPoint) === "secondary" ? 1 : 0
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: Kit.ms(Kit.motion("fadeFast").ms)
                                }
                            }
                        }

                        // The row: six height.action pills — the user's secondaries, then
                        // auto-filled from the drawer — and the dots as the seventh
                        // cell, wide enough to close the row's right edge.
                        Grid {
                            id: secondaryGrid
                            objectName: "secondaryGrid"
                            rows: 1
                            spacing: Kit.tokens.space.s
                            horizontalItemAlignment: Qt.AlignLeft

                            Repeater {
                                model: root.rowIds()
                                delegate: TogglePill {
                                    required property string modelData
                                    pillId: modelData
                                    editMode: root.editMode
                                    onDemoted: id => root.demote(id)
                                }
                            }

                            // The dots, the row's last cell: opens (or closes) the drawer.
                            RippleButton {
                                implicitWidth: Kit.tokens.height.action
                                implicitHeight: Kit.tokens.height.action
                                buttonRadius: width / 2
                                borderWidth: 0
                                toggled: root.drawerOpen
                                colBackgroundToggled: root.colPillOn
                                colBackgroundToggledHover: root.colPillOnHover
                                onClicked: root.drawerOpen = !root.drawerOpen
                                contentItem: Symbol {
                                    anchors.centerIn: parent
                                    text: root.drawerOpen ? "expand_less" : "more_horiz"
                                    size: Kit.tokens.icon.nav
                                    color: Tacit.inkMain
                                }
                                FocusRing {
                                    shown: parent.keyboardFocus
                                    corner: width / 2
                                }
                                StyledToolTip {
                                    text: Translation.tr("More")
                                }
                                Keys.onPressed: event => {
                                    Kit.focusVisible = true;
                                }
                                Accessible.role: Accessible.Button
                                Accessible.name: Translation.tr("More")
                                Accessible.checkable: true
                                Accessible.checked: root.drawerOpen
                            }
                        }
                    }
                }

                // The drawer: the rest, closed by default, opened by the dots, kept in the
                // shape the user last chose.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: !root.drawerOpen ? 0 : drawerColumn.implicitHeight
                    visible: implicitHeight > 0
                    clip: true
                    Behavior on implicitHeight {
                        NumberAnimation {
                            duration: Kit.ms(Kit.motion("arrive").ms)
                        }
                    }

                    ColumnLayout {
                        id: drawerColumn
                        objectName: "drawerColumn"
                        width: parent.width
                        spacing: Kit.tokens.space.m

                        // The caption exists only while a pill is in the air: at rest the
                        // drawer is just a shelf, and the mechanics show themselves in use.
                        StyledText {
                            text: root.dragging ? Translation.tr("Drop on the square to promote — anywhere else retires") : ""
                            visible: root.dragging
                            font.pixelSize: Kit.tokens.size.meta
                            color: Tacit.inkMeta
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }

                        // The pills fill the grid in seven across — every row of
                        // height.action cells closes on the same right edge as the square
                        // — and the pencil takes the tail of the last incomplete row, so
                        // it is never alone on a line of its own.
                        Grid {
                            id: drawerGrid
                            objectName: "drawerGrid"
                            Layout.fillWidth: true
                            columns: 7
                            spacing: Kit.tokens.space.s

                            Repeater {
                                model: root.drawerIds()
                                delegate: TogglePill {
                                    required property string modelData
                                    pillId: modelData
                                    editMode: root.editMode
                                    inDrawer: true
                                    onPromoted: (id, level) => root.promoteAt(id, level, 0)
                                }
                            }

                            RippleButton {
                                implicitWidth: Kit.tokens.height.action
                                implicitHeight: Kit.tokens.height.action
                                buttonRadius: width / 2
                                borderWidth: 0
                                toggled: root.editMode
                                colBackground: root.colPillOff
                                colBackgroundHover: root.colPillOffHover
                                colBackgroundToggled: root.colPillOn
                                onClicked: {
                                    root.editMode = !root.editMode;
                                }
                                contentItem: Symbol {
                                    anchors.centerIn: parent
                                    text: "edit"
                                    size: Kit.tokens.icon.nav
                                    // Measured at the pill's own scale: the glyph's ink
                                    // is centred in its box, reading a hair high — a
                                    // single pixel returned. The same TacitSymbols face
                                    // the kit draws with, so the correction rides on it.
                                    anchors.verticalCenterOffset: size / 22
                                    // The wash says edit mode is on; the glyph stays ink.
                                    color: Tacit.inkSec
                                }
                                FocusRing {
                                    shown: parent.keyboardFocus
                                    corner: width / 2
                                }
                                StyledToolTip {
                                    text: Translation.tr("Reshuffle")
                                }
                                Keys.onPressed: event => {
                                    Kit.focusVisible = true;
                                }
                                Accessible.role: Accessible.Button
                                Accessible.name: Translation.tr("Reshuffle")
                                Accessible.checkable: true
                                Accessible.checked: root.editMode
                            }
                        }
                    }
                }

                // -------------------------------------------------- sliders
                // One full-width-of-the-toggles row per slider, below the toggles: the
                // kit's own Slider for the bar and the keyboard, the pill glyph left.
                // Backlight keeps the 2% floor and gamma rescue; the block is as wide as
                // the toggles block, so the numbers close on the same right edge the
                // pills do.
                ColumnLayout {
                    Layout.fillWidth: false
                    Layout.preferredWidth: root.togglesWidth
                    spacing: Kit.tokens.space.m

                    LineSlider {
                        Layout.fillWidth: true
                        glyph: "brightness_6"
                        label: Translation.tr("Brightness")
                        value: root.brightnessMonitor?.brightness ?? 0
                        onMoved: {
                            if (Hyprsunset.gamma !== 100 && (root.brightnessMonitor?.brightness ?? 1) < 0.01)
                                Hyprsunset.setGamma(100);
                            root.brightnessMonitor?.setBrightness(Math.max(0.02, value));
                        }
                    }
                    LineSlider {
                        Layout.fillWidth: true
                        glyph: (Audio.sink?.audio?.muted ?? false) ? "volume_off"
                            : ((Audio.sink?.audio?.volume ?? 0) < 0.34 ? "volume_down" : "volume_up")
                        label: Translation.tr("Volume")
                        value: Audio.sink?.audio?.volume ?? 0
                        onMoved: {
                            if (Audio.sink?.audio)
                                Audio.sink.audio.volume = value;
                        }
                    }
                }

                // -------------------------------------- calendar (its own group)
                // Always with the panel, below the sliders: no opener, no flag — it is
                // where the clock used to lead you to, kept in place instead. The week
                // strip is the resting shape: one row, the current week; the header's
                // button unfolds the full month and folds it back.
                CalendarWidget {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Kit.tokens.space.s
                    expandable: true
                }

                // The sections (wifi, vpn, bluetooth, mixer...) are not here any more:
                // with a submenu the toggle opens its floating card over the panel — see
                // submenuLayer below the body.

                // The hairline opens the bottom row's group: calendar apart, then the
                // row and the notice's strip together.
                Hairline {
                    Layout.topMargin: Kit.tokens.space.s
                }

                // -------------------------------------------------- footer: date · icons
                // The time and date lead the row on the left, mirroring the notch's
                // clock; the two actions close it on the right. Session's symbol is in
                // the risk ink regardless. The shipped panel closes itself before
                // opening Settings, handing it the screen.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kit.tokens.space.s

                    ColumnLayout {
                        spacing: 0

                        StyledText {
                            Layout.alignment: Qt.AlignLeft
                            text: DateTime.time
                            font.family: Appearance.font.family.numbers
                            font.pixelSize: Kit.tokens.size.row
                            color: Tacit.inkMain
                        }
                        StyledText {
                            Layout.alignment: Qt.AlignLeft
                            text: DateTime.longDate
                            font.pixelSize: Kit.tokens.size.meta
                            color: Tacit.inkMeta
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    IconButton {
                        symbol: "settings"
                        label: Translation.tr("Settings")
                        tip: Translation.tr("Settings")
                        onActivated: {
                            GlobalStates.sidebarRightOpen = false;
                            SettingsApp.open("");
                        }
                    }
                    RippleButton {
                        implicitWidth: 36
                        implicitHeight: 36
                        buttonRadius: width / 2
                        borderWidth: 0
                        colBackgroundHover: root.colPillOffHover
                        onClicked: {
                            GlobalStates.sidebarRightOpen = false;
                            GlobalStates.sessionOpen = true;
                        }
                        contentItem: Symbol {
                            anchors.centerIn: parent
                            text: "mode_off_on"
                            size: Kit.tokens.icon.row
                            // An action that risks something (the session ends) is risk-
                            // coloured, with its warning companion as the tooltip.
                            color: Tacit.risk
                        }
                        FocusRing {
                            shown: parent.keyboardFocus
                            corner: width / 2
                        }
                        StyledToolTip {
                            text: Translation.tr("Ends the session")
                        }
                        Keys.onPressed: event => {
                            Kit.focusVisible = true;
                        }
                        Accessible.role: Accessible.Button
                        Accessible.name: Translation.tr("Ends the session")
                    }
                }

                // The notice's own strip: while the undo line is up, the panel grows a
                // line at its foot for it (the strip is what the toast draws over), so
                // the message never covers the working panel.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: _undoBox.isShown ? undoRow.height + Kit.tokens.space.s : 0
                    visible: implicitHeight > 0
                    Behavior on implicitHeight {
                        NumberAnimation {
                            duration: Kit.ms(Kit.motion("arriveSmall").ms)
                        }
                    }
                }
            }
        }
        } // panelContent

        // -------------------------------------------------- submenus, a floating layer
        // A toggle with a submenu opens its card floating on top of the panel — pinned
        // under the toggles block, on the panel's own ground (the frost, no shadow, no
        // scrim — opening it dims nothing). The panel grows beneath it only to keep the
        // card inside the silhouette; a click outside the card closes it, one submenu
        // at a time (root.only()).
        Item {
            id: submenuLayer
            anchors.fill: parent
            z: 250
            readonly property bool active: root.sectionFlags.some(f => root[f])
            // The card hangs under the toggles block: the pill that opened it stays visible.
            readonly property real cardY: togglesBlock.mapToItem(root, 0, 0).y + togglesBlock.height + Kit.tokens.space.m
            readonly property real cardBottom: cardY + submenuCard.height

            opacity: active ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: Kit.ms(Kit.motion("fade").ms)
                }
            }

            // The outside click: a click anywhere not on the card closes the submenu. As a
            // backdrop it eats the click; the toggle that was open is marked closed by the
            // click handler only (a re-open from a pill is a second click).
            MouseArea {
                anchors.fill: parent
                visible: submenuLayer.active
                onClicked: (mouse) => {
                    mouse.accepted = true;
                    for (const f of root.sectionFlags)
                        root[f] = false;
                }
            }

            Rectangle {
                id: submenuCard
                x: root.sidebarPadding
                y: submenuLayer.active ? submenuLayer.cardY : submenuLayer.cardY - Kit.tokens.space.m
                width: root.togglesWidth
                height: submenuColumn.implicitHeight + root.sidebarPadding * 2
                radius: Kit.tokens.radius.panel
                // The card is the panel's own ground, solid: the same role the
                // panel's frost is made of (m3surfaceContainerHigh) without the
                // see-through, so the contents the card floats over stay behind it.
                // No shadow lifts it, no scrim dims what is behind; the panel keeps
                // its silhouette and the card its place.
                color: Appearance.m3colors.m3surfaceContainerHigh

                Behavior on y {
                    NumberAnimation {
                        duration: Kit.ms(Kit.motion("arriveSmall").ms)
                    }
                }

                ColumnLayout {
                    id: submenuColumn
                    // Spacious: a card's interior is its measure's own inset
                    // (space.l) on every side.
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: root.sidebarPadding
                    anchors.rightMargin: root.sidebarPadding
                    anchors.topMargin: root.sidebarPadding
                    anchors.bottomMargin: root.sidebarPadding

                    WifiSection {
                        shown: root.showWifiDialog
                    }
                    VpnSection {
                        shown: root.showVpn
                    }
                    BluetoothSection {
                        shown: root.showBluetoothDialog
                    }
                    AudioSection {
                        input: false
                        shown: root.showAudioOutputDialog
                    }
                    AudioSection {
                        input: true
                        shown: root.showAudioInputDialog
                    }
                    NightLightSection {
                        shown: root.showNightLightDialog
                    }
                }
            }
        }

        // The drag ghost: the pill being carried, following the pointer while edit mode
        // drags. A quiet disc with the pill's own glyph — the pointer's shadow, basically.
        Item {
            id: dragOverlay
            anchors.fill: parent
            z: 300
            visible: root.dragging

            Rectangle {
                x: root.dragPoint.x - Kit.tokens.height.action / 2
                y: root.dragPoint.y - Kit.tokens.height.action / 2
                width: Kit.tokens.height.action
                height: Kit.tokens.height.action
                radius: width / 2
                color: root.colPillOn
                Symbol {
                    anchors.centerIn: parent
                    text: root.dragIcon
                    size: Kit.tokens.icon.nav
                    // The wash on the disc is this one signal too; the glyph is ink, not
                    // an accent colour (accent is a mark for places and playing).
                    color: Tacit.inkMain
                }
                Behavior on x {
                    NumberAnimation {
                        duration: Kit.ms(Kit.motion("hover").ms)
                    }
                }
                Behavior on y {
                    NumberAnimation {
                        duration: Kit.ms(Kit.motion("hover").ms)
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- pieces
    // The undo line, the kit's Notice shape from the shell's own tokens (the kit part
    // would read Kit.tokens.overlay, which the shell's Tacit does not carry). The line
    // stays motion.notice while the pointer rests on it or the keyboard is in it.
    Item {
        id: _undoBox
        parent: sidebarRightBackground
        z: 400
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.sidebarPadding
        width: undoRow.implicitWidth
        height: undoRow.implicitHeight
        property string text: ""
        property string actionWords: ""
        property bool isShown: false
        function show(line, words) {
            _undoBox.text = line;
            _undoBox.actionWords = words ?? "";
            isShown = true;
            stay.restart();
        }
        function hide() {
            if (!isShown)
                return;
            isShown = false;
            stay.stop();
        }
        Timer {
            id: stay
            interval: Kit.ms(Kit.motion("notice").ms)
            onTriggered: _undoBox.hide()
        }
        opacity: _undoBox.isShown ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                duration: Kit.ms(Kit.motion("fadeFast").ms)
            }
        }
        HoverHandler {
            onHoveredChanged: if (_undoBox.isShown) hovered ? stay.stop() : stay.restart()
        }
        RowLayout {
            id: undoRow
            spacing: Kit.tokens.space.s

            StyledText {
                text: _undoBox.text
                font.pixelSize: Kit.tokens.size.row
                color: Tacit.inkMain
            }
            RippleButton {
                implicitWidth: undoWords.implicitWidth + Kit.tokens.space.m * 2
                implicitHeight: Kit.tokens.height.railRow
                buttonRadius: height / 2
                borderWidth: 0
                toggled: true
                colBackgroundToggled: Tacit.accent
                colBackgroundToggledHover: ColorUtils.mix(Tacit.inkMain, Tacit.accent, 0.12)
                onClicked: {
                    root.doUndo();
                    stay.restart();
                }
                contentItem: StyledText {
                    id: undoWords
                    text: Translation.tr(_undoBox.actionWords)
                    color: Tacit.inkOnAccent
                }
                FocusRing {
                    shown: parent.keyboardFocus
                    corner: height / 2
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        _undoBox.hide();
                        event.accepted = true;
                    }
                }
                Accessible.role: Accessible.Button
                Accessible.name: Translation.tr("Undo")
            }
        }
    }

    // One-line slider: the pill's glyph on the left and the kit's own Slider for the
    // bar (its keyboard comes free) and the value as a word at the right.
    component LineSlider: RowLayout {
        id: line
        property string glyph: "tune"
        property string label: ""
        property alias value: slider.value
        signal moved()
        spacing: Kit.tokens.space.s

        Symbol {
            text: line.glyph
            size: Kit.tokens.icon.row
            color: Tacit.inkMain
        }
        Slider {
            id: slider
            Layout.fillWidth: true
            label: line.label
            word: `${Math.round(value * 100)}%`
            onMoved: line.moved()
        }
    }

    component Hairline: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Tacit.hairline
    }

    // Dynamic toggle models: each pill builds its own from the catalog so the arrangement
    // can hold any of them.
    component TogglePill: RippleButton {
        id: pill
        property string pillId: ""
        property bool editMode: false
        property bool inDrawer: false
        signal demoted(string id)
        signal promoted(string id, string level)
        // Not required this time: the model arrives from createObject, not the catalog.
        property var model

        // In edit mode the pill is dragged, not clicked: this area takes the press and
        // hands the pointer to the panel's ghost; with edit off the button below acts.
        MouseArea {
            anchors.fill: parent
            z: 10
            enabled: pill.editMode
            cursorShape: Qt.ClosedHandCursor
            onPressed: mouse => {
                pill.rootBeginDrag(mouse);
                mouse.accepted = true;
            }
            // A lifted grab (the panel closing under the pointer) is not a drop.
            onCanceled: root.cancelDrag()
            onPositionChanged: mouse => pill.rootMoveDrag(mouse)
            onReleased: mouse => pill.rootEndDrag(mouse)
        }
        // Map the pointer into panel coordinates for the ghost and the drop resolve.
        function rootBeginDrag(mouse) {
            const p = pill.mapToItem(root, mouse.x, mouse.y);
            root.beginDrag(pill.model?.icon ?? "", pill.model?.name ?? pill.pillId, p);
            root.dragTarget = pill.pillId;
        }
        function rootMoveDrag(mouse) {
            if (!root.dragging)
                return;
            root.moveDrag(pill.mapToItem(root, mouse.x, mouse.y));
        }
        function rootEndDrag(mouse) {
            if (!root.dragging)
                return;
            const p = pill.mapToItem(root, mouse.x, mouse.y);
            root.endDrag(p);
        }
        function arrowMove(dir) {
            root.keyboardMove(pill.pillId, pill.model?.name ?? pill.pillId, pill.inDrawer ? "drawer" : "secondary", dir);
        }

        readonly property var entry: pillId.length > 0 ? root.catalogEntry(pillId) : null
        readonly property string dialog: entry?.[2] ?? ""
        readonly property string name: model?.name ?? pillId
        readonly property bool primary: !inDrawer

        Component.onCompleted: {
            model = entry[1].createObject(pill);
            if (root.pendingFocus === pill.pillId) {
                root.pendingFocus = "";
                pill.forceActiveFocus();
            }
        }

        implicitWidth: Kit.tokens.height.action
        implicitHeight: Kit.tokens.height.action
        buttonRadius: width / 2
        borderWidth: 0 // the kit's FocusRing draws the keyboard ring
        toggled: pill.model?.toggled ?? false
        enabled: pill.editMode || pill.dialog.length > 0 || pill.inDrawer
            || (pill.model?.available ?? false) || !!pill.model?.altAction
        // Being carried draws the pill out (the ghost carries its shape); state drives
        // it, not an imperative restore, so a stolen grab heals too.
        opacity: root.dragging && root.dragTarget === pill.pillId ? 0.3 : 1
        colBackground: root.colPillOff
        colBackgroundHover: root.colPillOffHover
        colBackgroundToggled: root.colPillOn
        colBackgroundToggledHover: root.colPillOnHover

        // Normal use (edit off): click = the pill's action. In edit mode a click is
        // nothing (the owner's call): drag or the arrows place the pill.
        releaseAction: () => {
            if (pill.editMode)
                return;
            if (pill.dialog.length > 0) {
                root[pill.dialog] = !root[pill.dialog];
            } else {
                pill.model.mainAction();
            }
        }
        // In edit mode the right button promotes (drawer pills only); otherwise it
        // toggles directly for pills with a list, as the real panel does.
        altAction: pill.editMode
            ? (pill.inDrawer ? (function() { root.pushUndo(`Moved ${pill.name} to the square`); pill.promoted(pill.pillId, "primary"); }) : null)
            : (pill.dialog.length > 0
                ? (function() { if (pill.model.available) pill.model.mainAction(); })
                : pill.model?.altAction)

        contentItem: Symbol {
            anchors.centerIn: parent
            text: pill.model?.icon ?? "apps"
            filled: pill.toggled
            size: Kit.tokens.icon.nav
            // One signal: the raised wash says "on"; the glyph is ink in both states
            // (the kit's accent is a mark, and an active pill is not a mark).
            // Unavailable (the service behind is not) fades to the faint ink, not
            // opacity: text is quieter by ink, never by transparency.
            color: !pill.enabled ? Tacit.inkFaint : Tacit.inkSec
        }
        FocusRing {
            shown: pill.keyboardFocus
            corner: width / 2
        }
        StyledToolTip {
            text: pill.editMode
                ? (pill.inDrawer ? Translation.tr("Make secondary · right-click: primary") : Translation.tr("Back to the drawer"))
                : pill.name
        }
        Keys.onPressed: event => {
            Kit.focusVisible = true;
            switch (event.key) {
            case Qt.Key_Left: pill.arrowMove("left"); event.accepted = true; break;
            case Qt.Key_Right: pill.arrowMove("right"); event.accepted = true; break;
            case Qt.Key_Up: pill.arrowMove("up"); event.accepted = true; break;
            case Qt.Key_Down: pill.arrowMove("down"); event.accepted = true; break;
            }
        }
        Accessible.role: Accessible.Button
        Accessible.name: pill.name + (pill.inDrawer ? Translation.tr(", in the drawer") : "")
        Accessible.checkable: true
        Accessible.checked: pill.model?.toggled ?? false
    }

    // The primary pill's body is a rounded rectangle (the change the proposal puts first),
    // so the hierarchy is readable by shape before anything else: two large corners on
    // two, twenty-four circles around them.
    component PrimaryPill: RippleButton {
        id: primary
        property string pillId: ""
        property bool editMode: false
        signal demoted(string id)
        property var model

        // The drag layer, same as the round pills': the press is taken from the pill
        // only while edit mode is on.
        MouseArea {
            anchors.fill: parent
            z: 10
            enabled: primary.editMode
            cursorShape: Qt.ClosedHandCursor
            onPressed: mouse => primary.rootBeginDrag(mouse)
            // A lifted grab (the panel closing under the pointer) is not a drop.
            onCanceled: root.cancelDrag()
            onPositionChanged: mouse => primary.rootMoveDrag(mouse)
            onReleased: mouse => primary.rootEndDrag(mouse)
        }
        function rootBeginDrag(mouse) {
            const p = primary.mapToItem(root, mouse.x, mouse.y);
            root.beginDrag(primary.model?.icon ?? "", primary.model?.name ?? primary.pillId, p);
            root.dragTarget = primary.pillId;
        }
        function rootMoveDrag(mouse) {
            if (!root.dragging)
                return;
            root.moveDrag(primary.mapToItem(root, mouse.x, mouse.y));
        }
        function rootEndDrag(mouse) {
            if (!root.dragging)
                return;
            const p = primary.mapToItem(root, mouse.x, mouse.y);
            root.endDrag(p);
        }
        function arrowMove(dir) {
            root.keyboardMove(primary.pillId, primary.model?.name ?? primary.pillId, "primary", dir);
        }

        readonly property var entry: pillId.length > 0 ? root.catalogEntry(pillId) : null
        readonly property string dialog: entry?.[2] ?? ""

        Component.onCompleted: {
            model = entry[1].createObject(primary);
            if (root.pendingFocus === primary.pillId) {
                root.pendingFocus = "";
                primary.forceActiveFocus();
            }
        }

        implicitWidth: (root.togglesWidth - Kit.tokens.space.s) / 2
        implicitHeight: Kit.tokens.height.action + Kit.tokens.space.l
        buttonRadius: Kit.tokens.radius.slab
        borderWidth: 0 // the kit's FocusRing draws the keyboard ring
        toggled: primary.model?.toggled ?? false
        enabled: primary.editMode || (primary.model?.available ?? false) || primary.dialog.length > 0
        opacity: root.dragging && root.dragTarget === primary.pillId ? 0.3 : 1
        colBackground: root.colPillOff
        colBackgroundHover: root.colPillOffHover
        colBackgroundToggled: root.colPillOn
        colBackgroundToggledHover: root.colPillOnHover

        releaseAction: () => {
            if (primary.editMode)
                return; // a click in edit mode is nothing (the owner's call)
            if (primary.dialog.length > 0)
                root[primary.dialog] = !root[primary.dialog];
            else if (primary.model)
                primary.model.mainAction();
        }
        altAction: primary.dialog.length > 0
            ? (function() { if (primary.model.available) primary.model.mainAction(); })
            : primary.model?.altAction

        contentItem: Row {
            id: primaryRow
            anchors.centerIn: parent
            width: primary.width - 28
            spacing: Kit.tokens.space.s

            Symbol {
                anchors.verticalCenter: parent.verticalCenter
                text: primary.model?.icon ?? "apps"
                filled: primary.toggled
                size: Kit.tokens.icon.row
                // One signal: the wash, not a colour change on the glyph.
                color: Tacit.inkSec
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Kit.tokens.icon.row - parent.spacing
                elide: Text.ElideRight
                // The pill's own name wiring, as the real panel's row reads it.
                text: (primary.model?.name ?? "") + (primary.model?.hasStatusText && (primary.model?.statusText ?? "").length > 0 ? " · " + primary.model.statusText : "")
                color: Tacit.inkMain
            }
        }
        FocusRing {
            shown: primary.keyboardFocus
            corner: Kit.tokens.radius.slab
        }
        StyledToolTip {
            text: primary.editMode ? Translation.tr("Back to the drawer") : ((primary.model?.name ?? "") + (primary.dialog.length > 0 ? Translation.tr("\nRight-click to turn on/off") : ""))
        }
        Keys.onPressed: event => {
            Kit.focusVisible = true;
            switch (event.key) {
            case Qt.Key_Left: primary.arrowMove("left"); event.accepted = true; break;
            case Qt.Key_Right: primary.arrowMove("right"); event.accepted = true; break;
            case Qt.Key_Up: primary.arrowMove("up"); event.accepted = true; break;
            case Qt.Key_Down: primary.arrowMove("down"); event.accepted = true; break;
            }
        }
        Accessible.role: Accessible.Button
        Accessible.name: primary.model?.name ?? primary.pillId
        Accessible.checkable: true
        Accessible.checked: primary.model?.toggled ?? false
    }

    property bool drawerOpen: false
    property bool editMode: false

    // The dots button sits in the primary row's tail: the drawer is reachable whether or
    // not the user has filled all eight shown places.
    // (Kept at file scope to be wired from the prototype when opened.)
    // Dynamic toggle model components.
    Component {
        id: networkComp
        NetworkToggle {}
    }
    Component {
        id: vpnComp
        VpnToggle {}
    }
    Component {
        id: bluetoothComp
        BluetoothToggle {}
    }
    Component {
        id: notificationComp
        NotificationToggle {}
    }
    Component {
        id: nightLightComp
        NightLightToggle {}
    }
    Component {
        id: micComp
        MicToggle {}
    }
    Component {
        id: idleComp
        IdleInhibitorToggle {}
    }
    Component {
        id: audioComp
        AudioToggle {}
    }
    Component {
        id: screenRecordComp
        ScreenRecordToggle {}
    }
    Component {
        id: screenSnipComp
        ScreenSnipToggle {}
    }
    Component {
        id: colorPickerComp
        ColorPickerToggle {}
    }
    Component {
        id: darkModeComp
        DarkModeToggle {}
    }
    Component {
        id: powerProfilesComp
        PowerProfilesToggle {}
    }
    Component {
        id: oskComp
        OnScreenKeyboardToggle {}
    }
    Component {
        id: wallpaperComp
        WallpaperToggle {}
    }

    Component.onCompleted: {
        root.loadArrangement();
    }
}
