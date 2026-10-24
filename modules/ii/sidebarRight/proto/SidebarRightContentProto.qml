pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.common.models.quickToggles
import qs.modules.tacit
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.modules.ii.sidebarRight.bluetoothDevices
import qs.modules.ii.sidebarRight.vpn
import qs.modules.ii.sidebarRight.nightLight
import qs.modules.ii.sidebarRight.volumeMixer
import qs.modules.ii.sidebarRight.wifiNetworks

/**
 * Prototype: the control panel rearranged for the idea issue.
 *
 * Compared with SidebarRightContent.qml:
 *   - timer and tasks (BottomWidgetGroup) are gone
 *   - Settings and Session are icon-only buttons on the footer's right
 *   - sliders are vertical, right of the toggles
 *   - two primary toggles in a rounded-rectangle body, four secondary pills, the rest
 *     hidden in a drawer; the user's arrangement is kept in
 *     Directories.state/user/sidebar-arrangement.json
 *
 * Edit mode (the drawer's pencil): tap a main pill to retire it to the drawer, tap a
 * drawer pill to make it secondary, right-click a drawer pill to make it primary.
 * Primary and secondary take at most 2 and 4; an overflowed pill returns to the drawer.
 */
Item {
    id: root
    property int sidebarWidth: Appearance.sizes.sidebarWidth
    property int sidebarPadding: 14
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
            }
        }
    }

    // The user's arrangement: two primary, three secondary (the square's fourth cell is
    // the dots button), the rest in the drawer. Empty lists mean "first boot": the
    // defaults below apply until the user moves something.
    readonly property list<string> defaultPrimary: ["wifi", "bluetooth"]
    readonly property list<string> defaultSecondary: ["nightLight", "mic", "notifications"]
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
    property point dragPoint
    function beginDrag(icon, rootPos) {
        root.dragIcon = icon;
        root.dragPoint = rootPos;
        root.dragging = true;
    }
    function moveDrag(rootPos) {
        root.dragPoint = rootPos;
    }
    // The square is two 40 px cells with a 6 px gap: the column is the x half, the row
    // the y half.
    function cellIndex(pointInGrid) {
        const col = Math.floor((pointInGrid.x + 3) / 46);
        const row = Math.floor((pointInGrid.y + 3) / 46);
        return row * 2 + col;
    }
    // Which drop zone the pointer sits in: the primary column, the square, or none
    // ("retire"). Used for the drop highlight while dragging and by endDrag; both pass
    // root.dragPoint, so the highlight re-evaluates on every move.
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
        root.dragging = false;
        root.dragTarget = "";
        if (pill.length === 0)
            return;
        // Where the pointer sat, in panel coordinates, against each zone's bounds.
        const zone = root.zoneAt(rootPos);
        if (zone === "primary") {
            const p0 = primaryZone.mapToItem(root, 0, 0);
            root.promoteAt(pill, "primary", rootPos.y < p0.y + primaryZone.height / 2 ? 0 : 1);
        } else if (zone === "secondary") {
            const idx = root.cellIndex(root.mapToItem(secondaryZone, rootPos.x, rootPos.y));
            if (idx < 3) // the fourth cell is the dots: a drop there retires the pill
                root.promoteAt(pill, "secondary", idx);
            else
                root.demote(pill);
        } else {
            root.demote(pill);
        }
    }
    // Promote with a place: a full level retires the pill that loses its spot (the last
    // one), and a drop with an index can also reorder within a level.
    function promoteAt(id, level, index) {
        root.demote(id); // idempotent for pills not shown
        if (level === "primary") {
            const i = Math.max(0, Math.min(index ?? 0, 1));
            const list = root.primary.filter(v => v !== id);
            list.splice(i, 0, id);
            if (list.length > 2) {
                const retired = list[2];
                root.primary = list.slice(0, 2);
                root.secondary = root.secondary.filter(v => v !== retired);
            } else {
                root.primary = list;
            }
        } else {
            const i = Math.max(0, Math.min(index ?? 0, 2));
            const list = root.secondary.filter(v => v !== id);
            list.splice(i, 0, id);
            if (list.length > 3) {
                const retired = list[3];
                root.secondary = list.slice(0, 3);
                root.primary = root.primary.filter(v => v !== retired);
            } else {
                root.secondary = list;
            }
        }
        root.saveArrangement();
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
    // Which pills the drawer shows: everything not on a shown level.
    function drawerIds() {
        return root.toggleCatalog.map(e => e[0]).filter(id => root.primary.indexOf(id) < 0 && root.secondary.indexOf(id) < 0);
    }

    // An "on" pill is raised like the real panel's (SidebarRightContent.qml): colLayer2 is
    // darker than the frost, so on used to read as a hole.
    readonly property color colPillOn: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.88)
    readonly property color colPillOnHover: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.84)
    property real maxHeight: 700
    // The toggles block is the panel's measure: primary column, then the square's two
    // pill cells (the dots sit in the fourth) — the sliders match this width so the
    // panel's columns all close on the same right edge.
    readonly property real togglesWidth: 180 + 10 + 40 + 6 + 40
    implicitHeight: Math.min(column.implicitHeight + root.sidebarPadding * 2, root.maxHeight)
    // Body padding on both sides on top of the toggles measure, or the square's right
    // column is cut by the body's own margin.
    implicitWidth: Math.min(root.togglesWidth + root.sidebarPadding * 2, sidebarWidth)

    property var brightnessMonitor: Brightness.getMonitorForScreen(root.QsWindow.window?.screen)

    FileView {
        id: arrangementFile
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
        radius: Appearance.rounding.verylarge

        DockedRect {
            id: dockedBg
            anchors.fill: parent
            edge: "bottom-right"
            cornerRadius: sidebarRightBackground.radius
            fillet: 12
            color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainerHigh, 0.08)
        }

        StyledFlickable {
            id: body
            anchors.fill: parent
            anchors.margins: root.sidebarPadding
            contentHeight: column.implicitHeight
            interactive: contentHeight > height
            clip: true

            ColumnLayout {
                id: column
                width: body.width
                spacing: 10

                // --------------------------------- toggles (left) · vertical sliders (right)
                // The toggles: the two primaries stacked in a column on the left; the
                // four secondaries in a 2×2 square grid to their right — the last cell
                // of that grid is the drawer button, not a pill. A Grid, not a Flow: the
                // Flow was squeezed by the layout and wrapped every pill onto its own
                // line.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Item {
                        id: primaryZone
                        implicitWidth: primaryCol.implicitWidth
                        implicitHeight: primaryCol.implicitHeight
                        Layout.preferredWidth: implicitWidth
                        Layout.preferredHeight: implicitHeight
                        Layout.fillWidth: false

                        // The drop highlight: the zone tints while a dragged pill is aimed
                        // at it, so aiming is visible rather than imagined.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -6
                            radius: Appearance.rounding.normal
                            color: ColorUtils.transparentize(root.colPillOn, 0.75)
                            opacity: root.dragging && root.zoneAt(root.dragPoint) === "primary" ? 1 : 0
                            Behavior on opacity {
                                Anim {
                                    type: Anim.DefaultEffects
                                }
                            }
                        }

                        ColumnLayout {
                            id: primaryCol
                            spacing: 6

                            Repeater {
                                model: root.primary
                                delegate: PrimaryPill {
                                    required property string modelData
                                    pillId: modelData
                                    editMode: root.editMode
                                    Layout.preferredWidth: 180
                                    Layout.fillWidth: false
                                    onDemoted: id => root.demote(id)
                                }
                            }
                        }
                    }

                    Item {
                        id: secondaryZone
                        implicitWidth: secondaryGrid.width
                        implicitHeight: secondaryGrid.height
                        Layout.preferredWidth: implicitWidth
                        Layout.preferredHeight: implicitHeight
                        Layout.alignment: Qt.AlignTop

                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -6
                            radius: Appearance.rounding.normal
                            color: ColorUtils.transparentize(root.colPillOn, 0.75)
                            opacity: root.dragging && root.zoneAt(root.dragPoint) === "secondary" ? 1 : 0
                            Behavior on opacity {
                                Anim {
                                    type: Anim.DefaultEffects
                                }
                            }
                        }

                        Grid {
                            id: secondaryGrid
                            columns: 2
                            spacing: 6

                        Repeater {
                            model: root.secondary
                            delegate: TogglePill {
                                required property string modelData
                                pillId: modelData
                                editMode: root.editMode
                                onDemoted: id => root.demote(id)
                            }
                        }

                        // The dots in the grid's last cell: opens (or closes) the drawer.
                        RippleButton {
                            implicitWidth: 40
                            implicitHeight: 40
                            buttonRadius: 20
                            toggled: root.drawerOpen
                            colBackgroundToggled: root.colPillOn
                            colBackgroundToggledHover: root.colPillOnHover
                            onClicked: root.drawerOpen = !root.drawerOpen
                            contentItem: MaterialSymbol {
                                anchors.centerIn: parent
                                text: root.drawerOpen ? "expand_less" : "more_horiz"
                                iconSize: 22
                                color: Appearance.colors.colOnLayer0
                            }
                            StyledToolTip {
                                text: Translation.tr("More")
                            }
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
                        Anim {
                            type: Anim.Emphasized
                        }
                    }

                    ColumnLayout {
                        id: drawerColumn
                        width: parent.width
                        spacing: 8

                        // The caption exists only while a pill is in the air: at rest the
                        // drawer is just a shelf, and the mechanics show themselves in use.
                        StyledText {
                            text: root.dragging ? Translation.tr("Drop on the square to promote — anywhere else retires") : ""
                            visible: root.dragging
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                        }

                        // The pills fill the grid; the pencil takes the tail of the last
                        // incomplete row, so it is never alone on a line of its own.
                        Grid {
                            id: drawerGrid
                            Layout.fillWidth: true
                            columns: 4
                            spacing: 6

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
                                implicitWidth: 40
                                implicitHeight: 40
                                buttonRadius: 20
                                toggled: root.editMode
                                colBackgroundToggled: root.colPillOn
                                onClicked: {
                                    root.editMode = !root.editMode;
                                }
                                contentItem: MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "edit"
                                    iconSize: 16
                                    color: root.editMode ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                }
                                StyledToolTip {
                                    text: Translation.tr("Reshuffle")
                                }
                            }
                        }
                    }
                }

                // -------------------------------------------------- sliders
                // One full-width-of-the-toggles row per slider, below the toggles: the
                // notch meter's language (glyph left, number right) exactly as the
                // shipped panel's LineSlider draws it. Backlight keeps the 2% floor and
                // gamma rescue; the block is as wide as the toggles block, so the
                // numbers close on the same right edge the pills do.
                ColumnLayout {
                    Layout.fillWidth: false
                    Layout.preferredWidth: root.togglesWidth
                    spacing: 10

                    LineSlider {
                        Layout.fillWidth: true
                        glyph: "brightness_6"
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
                        value: Audio.sink?.audio?.volume ?? 0
                        onMoved: {
                            if (Audio.sink?.audio)
                                Audio.sink.audio.volume = value;
                        }
                    }
                }

                // -------------------------------------------------- section lists, in place
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

                Hairline {}

                // -------------------------------------------------- footer: date · icons
                // The time and date lead the row on the left, mirroring the notch's
                // clock; the two actions close it on the right. The shipped panel
                // closes itself before opening Settings, handing it the screen.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    StyledText {
                        text: DateTime.time
                        font.family: Appearance.font.family.numbers
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer0
                    }
                    StyledText {
                        text: DateTime.longDate
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colSubtext
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                    RippleButton {
                        implicitWidth: 40
                        implicitHeight: 40
                        buttonRadius: 20
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: {
                            GlobalStates.sidebarRightOpen = false;
                            SettingsApp.open("");
                        }
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "settings"
                            iconSize: 20
                            color: Appearance.colors.colSubtext
                        }
                        StyledToolTip {
                            text: Translation.tr("Settings")
                        }
                    }
                    RippleButton {
                        implicitWidth: 40
                        implicitHeight: 40
                        buttonRadius: 20
                        colBackground: "transparent"
                        colBackgroundHover: Appearance.colors.colLayer1Hover
                        onClicked: {
                            GlobalStates.sidebarRightOpen = false;
                            GlobalStates.sessionOpen = true;
                        }
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            text: "mode_off_on"
                            iconSize: 20
                            color: Appearance.colors.colSubtext
                        }
                        StyledToolTip {
                            text: Translation.tr("Session")
                        }
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
                x: root.dragPoint.x - 20
                y: root.dragPoint.y - 20
                width: 40
                height: 40
                radius: 20
                color: root.colPillOn
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: root.dragIcon
                    iconSize: 22
                    color: Appearance.colors.colPrimary
                }
                Behavior on x {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
                Behavior on y {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- pieces
    // One-line slider with its glyph on the left and the number at the right (the
    // slider's own, no tooltip popup: it would close the panel), the same shape the
    // shipped panel draws (SidebarRightContent.qml).
    component LineSlider: RowLayout {
        id: line
        property string glyph: "tune"
        property alias value: slider.value
        signal moved()
        spacing: 8

        property bool ready: false
        Component.onCompleted: line.ready = true
        onGlyphChanged: if (line.ready) lineMotion.settle()
        SymbolMotion {
            id: lineMotion
            target: lineSymbol
        }
        MaterialSymbol {
            id: lineSymbol
            text: line.glyph
            iconSize: 20
            color: Appearance.colors.colOnLayer0
        }
        TacitSlider {
            id: slider
            Layout.fillWidth: true
            onMoved: line.moved()
        }
    }

    component Hairline: Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Appearance.colors.colLayer0Border
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
            onPositionChanged: mouse => pill.rootMoveDrag(mouse)
            onReleased: mouse => pill.rootEndDrag(mouse)
        }
        // Map the pointer into panel coordinates for the ghost and the drop resolve.
        function rootBeginDrag(mouse) {
            const p = pill.mapToItem(root, mouse.x, mouse.y);
            root.beginDrag(pill.model?.icon ?? "", p);
            root.dragTarget = pill.pillId;
            pill.opacity = 0.3;
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
            pill.opacity = 1;
            root.endDrag(p);
        }

        readonly property var entry: pillId.length > 0 ? root.catalogEntry(pillId) : null
        readonly property string dialog: entry?.[2] ?? ""
        readonly property string name: model?.name ?? pillId
        readonly property bool primary: !inDrawer

        Component.onCompleted: {
            model = entry[1].createObject(pill);
            console.log("[proto]", pillId, "w", pill.width, "iw", pill.implicitWidth, "inDrawer", inDrawer);
        }

        implicitWidth: 40
        implicitHeight: 40
        buttonRadius: 20
        toggled: pill.model?.toggled ?? false
        enabled: pill.editMode || pill.dialog.length > 0 || pill.inDrawer
            || (pill.model?.available ?? false) || !!pill.model?.altAction
        opacity: !pill.editMode && !pill.inDrawer && !(pill.model?.available ?? true) ? 0.4
            : (!pill.editMode && pill.model?.busy ? 0.6 : 1)
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        colBackgroundToggled: root.colPillOn
        colBackgroundToggledHover: root.colPillOnHover

        // Normal use (edit off): click = the pill's action. In edit mode the click moves
        // the pill instead: a main pill retires, a drawer pill promotes.
        releaseAction: () => {
            if (pill.editMode) {
                if (pill.inDrawer)
                    pill.promoted(pill.pillId, "secondary");
                else
                    pill.demoted(pill.pillId);
                return;
            }
            if (pill.dialog.length > 0) {
                root[pill.dialog] = !root[pill.dialog];
            } else {
                pill.model.mainAction();
            }
        }
        // In edit mode the right button promotes (drawer pills only); otherwise it
        // toggles directly for pills with a list, as the real panel does.
        altAction: pill.editMode
            ? (pill.inDrawer ? (function() { pill.promoted(pill.pillId, "primary"); }) : null)
            : (pill.dialog.length > 0
                ? (function() { if (pill.model.available) pill.model.mainAction(); })
                : pill.model?.altAction)

        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            text: pill.model?.icon ?? ""
            fill: pill.toggled ? 1 : 0
            iconSize: 22
            color: pill.toggled ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
        }
        StyledToolTip {
            text: pill.editMode
                ? (pill.inDrawer ? Translation.tr("Make secondary · right-click: primary") : Translation.tr("Back to the drawer"))
                : pill.name
        }
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
            onPositionChanged: mouse => primary.rootMoveDrag(mouse)
            onReleased: mouse => primary.rootEndDrag(mouse)
        }
        function rootBeginDrag(mouse) {
            const p = primary.mapToItem(root, mouse.x, mouse.y);
            root.beginDrag(primary.model?.icon ?? "", p);
            root.dragTarget = primary.pillId;
            primary.opacity = 0.3;
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
            primary.opacity = 1;
            root.endDrag(p);
        }

        readonly property var entry: pillId.length > 0 ? root.catalogEntry(pillId) : null
        readonly property string dialog: entry?.[2] ?? ""

        Component.onCompleted: {
            model = entry[1].createObject(primary);
        }

        implicitWidth: 92
        implicitHeight: 44
        buttonRadius: 16
        toggled: primary.model?.toggled ?? false
        enabled: primary.editMode || (primary.model?.available ?? false) || primary.dialog.length > 0
        opacity: primary.model?.busy ? 0.6 : 1
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer1Hover
        colBackgroundToggled: root.colPillOn
        colBackgroundToggledHover: root.colPillOnHover

        releaseAction: () => {
            if (primary.editMode) {
                primary.demoted(primary.pillId);
                return;
            }
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
            spacing: 6
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: primary.model?.icon ?? ""
                fill: primary.toggled ? 1 : 0
                iconSize: 20
                color: primary.toggled ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 20 - parent.spacing
                elide: Text.ElideRight
                // The pill's own name wiring, as the real panel's row reads it.
                text: (primary.model?.name ?? "") + (primary.model?.hasStatusText && (primary.model?.statusText ?? "").length > 0 ? " · " + primary.model.statusText : "")
                color: Appearance.colors.colOnLayer0
            }
        }
        StyledToolTip {
            text: primary.editMode ? Translation.tr("Back to the drawer") : ((primary.model?.name ?? "") + (primary.dialog.length > 0 ? Translation.tr("\nRight-click to turn on/off") : ""))
        }
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
