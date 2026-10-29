pragma ComponentBehavior: Bound
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

/**
 * The workspace overview (Super+Tab): the notch grown wide, docked into the top edge, holding one
 * card per workspace in use plus the next free one. It opens on the notch's own spring, from the
 * closed notch's size. Windows are live previews (OverviewWindow) drawn over the cards so a drag
 * can cross from one card to another.
 */
Item {
    id: root
    required property var screen
    readonly property HyprlandMonitor monitor: Hyprland.monitorFor(screen)
    // Clamp to avoid lock-screen temp workspace (2147483647 - N) leaking into UI
    readonly property int effectiveActiveWorkspaceId: Math.max(1, Math.min(100, monitor?.activeWorkspace?.id ?? 1))
    property var windows: HyprlandData.windowList
    property var windowByAddress: HyprlandData.windowByAddress
    property var monitorData: HyprlandData.monitors.find(m => m.id === root.monitor?.id)

    // The workspaces in use (a window on it, or shown on a monitor), then the lowest free number.
    readonly property var workspaceIds: {
        const used = new Set([root.effectiveActiveWorkspaceId]);
        for (const m of HyprlandData.monitors) {
            const id = m.activeWorkspace?.id ?? -1;
            if (id >= 1 && id <= 100)
                used.add(id);
        }
        for (const w of root.windows) {
            const id = w.workspace?.id ?? -1;
            if (id >= 1 && id <= 100)
                used.add(id);
        }
        let free = 1;
        while (used.has(free))
            free++;
        if (free <= 100)
            used.add(free);
        return Array.from(used).sort((a, b) => a - b);
    }

    // Layout, in the notch's terms: the 34 px strip on top, then the cards. The sheet is as wide as
    // the cards need, and the cards shrink to fit the screen.
    readonly property real stripHeight: 34
    readonly property real sidePadding: 28
    readonly property real cardGap: 12
    readonly property real numeralHeight: 18
    readonly property real numeralGap: 4
    readonly property real bottomPadding: 24
    readonly property real fillet: 6
    readonly property real openRadius: 24
    readonly property int count: root.workspaceIds.length
    readonly property real maxCardWidth: 224
    readonly property real minCardWidth: 64
    readonly property real screenWidth: root.screen?.width ?? 1920
    property real workspaceImplicitWidth: Math.max(root.minCardWidth, Math.min(root.maxCardWidth,
        (root.screenWidth - 2 * root.fillet - 2 * root.sidePadding - (root.count - 1) * root.cardGap - 16) / root.count))

    // The monitor's work area (what a maximised window fills), in the card's proportions.
    readonly property var reserved: root.monitorData?.reserved ?? [0, 0, 0, 0]
    readonly property bool rotated: root.monitorData?.transform % 2 === 1
    readonly property real workWidth: (rotated ? monitor.height : monitor.width) - reserved[0] - reserved[2]
    readonly property real workHeight: (rotated ? monitor.width : monitor.height) - reserved[1] - reserved[3]
    // Card pixels per work-area pixel, as OverviewWindow reads `scale` (it sizes a tile from the
    // window's own size).
    property real scale: root.workspaceImplicitWidth * monitor.scale / root.workWidth
    property real workspaceImplicitHeight: root.workHeight * root.scale / monitor.scale

    property int draggingFromWorkspace: -1
    property int draggingTargetWorkspace: -1
    property int windowZ: 1
    property int windowDraggingZ: 99999

    readonly property real cardsWidth: root.count * root.workspaceImplicitWidth + (root.count - 1) * root.cardGap
    readonly property real cardsTop: root.stripHeight + 10 + root.numeralHeight + root.numeralGap
    readonly property real fullWidth: root.cardsWidth + 2 * root.sidePadding
    readonly property real fullHeight: root.cardsTop + root.workspaceImplicitHeight + root.bottomPadding

    // 0 is the closed notch, 1 the open sheet. The notch's open spring (IslandContent.qml
    // geometryCurve), so the sheet grows out of the notch and settles the way its own sheets do.
    property real openness: 0
    // Closing runs the opening backwards, on the notch's own close (IslandContent: 450 ms,
    // emphasizedDecel, no overshoot), so the sheet goes back into the notch it came out of.
    property bool closing: false
    // set by Overview.qml once the notch is drawn again under the closed sheet
    property bool bodyHidden: false
    signal closed()
    function close() {
        root.closing = true;
        root.openness = 0;
    }
    function reopen() {
        root.closing = false;
        root.openness = 1;
    }
    Behavior on openness {
        NumberAnimation {
            id: openAnimation
            duration: root.closing ? 450 : Appearance.animationCurves.expressiveDefaultSpatialDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: root.closing ? Appearance.animationCurves.emphasizedDecel : Appearance.animationCurves.expressiveDefaultSpatial
            onRunningChanged: if (!running && root.closing && root.openness === 0) root.closed()
        }
    }
    Component.onCompleted: root.openness = 1

    readonly property var closedGeometry: IslandController.geometryFor("idle")

    implicitWidth: root.fullWidth + 2 * root.fillet
    implicitHeight: root.fullHeight

    DockedRect {
        id: sheet
        visible: !root.bodyHidden
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.closedGeometry.w + (root.fullWidth - root.closedGeometry.w) * root.openness
        height: root.closedGeometry.h + (root.fullHeight - root.closedGeometry.h) * root.openness
        edge: "top"
        cornerRadius: root.closedGeometry.r + (root.openRadius - root.closedGeometry.r) * root.openness
        fillet: root.fillet
        // It grows out of the notch, so it is the notch's body: the same frost. The layer's blur
        // (custom/rules.lua, xray) shows only the wallpaper behind it, never windows.
        color: IslandController.bodyColor

        // The notch's centre, as the notch draws it (IslandHeader: the time alone at the exact middle, the status glyph at
        // the closed notch's right edge, in the notch's inks), held still and never faded: the sheet grows out of it and
        // shrinks back into it.
        Item {
            anchors.horizontalCenter: parent.horizontalCenter
            width: centreTime.width
            height: root.stripHeight
            z: 1
            StyledText {
                id: centreTime
                anchors.verticalCenter: parent.verticalCenter
                text: DateTime.time
                font.family: Appearance.font.family.numbers
                font.pixelSize: 16
                font.variableAxes: ({ "wght": 500 })
                font.features: ({ "tnum": 1 })
                color: IslandController.contentColor
            }
            MaterialSymbol {
                readonly property string glyph: IslandController.ambientGlyph
                readonly property bool isDot: glyph === "circle"
                readonly property bool attention: ["fiber_manual_record", "mic", "battery_alert", "circle", "progress_activity", "back_hand", "rate_review"].includes(glyph)
                x: Math.round(centreTime.width / 2 + root.closedGeometry.w / 2 - 12 - width)
                anchors.verticalCenter: parent.verticalCenter
                visible: glyph !== ""
                text: glyph
                fill: isDot ? 1 : 0
                iconSize: isDot ? 8 : 18
                color: isDot ? Appearance.colors.colPrimary : attention ? Tacit.inkMain : Tacit.inkMeta
            }
        }

        // Content is laid out at its final size and fades in as the sheet passes half way. It is cut
        // to the sheet only while the sheet grows, so a dragged tile is never cut afterwards.
        Item {
            id: viewport
            anchors.fill: parent
            clip: openAnimation.running

            Item {
                id: contents
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.fullWidth
                height: root.fullHeight
                opacity: Math.max(0, Math.min(1, (root.openness - 0.4) / 0.4))

                MaterialSymbol {
                    anchors.left: parent.left
                    anchors.leftMargin: 22
                    y: (root.stripHeight - height) / 2
                    text: "grid_view"
                    iconSize: 16
                    color: Appearance.colors.colSubtext
                }

                Row { // Workspaces
                    id: workspaceRow
                    x: root.sidePadding
                    y: root.stripHeight + 10
                    spacing: root.cardGap

                    Repeater {
                        model: ScriptModel {
                            values: root.workspaceIds
                        }
                        delegate: Column {
                            id: column
                            required property int modelData
                            readonly property bool current: column.modelData === root.effectiveActiveWorkspaceId
                            spacing: root.numeralGap

                            StyledText { // Numeral, with a dot on the current workspace
                                height: root.numeralHeight
                                text: column.modelData
                                font.family: Appearance.font.family.numbers
                                font.pixelSize: 15
                                color: column.current ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                Rectangle {
                                    visible: column.current
                                    anchors.left: parent.right
                                    anchors.leftMargin: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 4
                                    height: 4
                                    radius: 2
                                    color: Appearance.colors.colPrimary
                                }
                            }

                            Rectangle { // Workspace
                                id: workspace
                                property int workspaceValue: column.modelData
                                property bool hoveredWhileDragging: false

                                implicitWidth: root.workspaceImplicitWidth
                                implicitHeight: root.workspaceImplicitHeight
                                radius: Appearance.rounding.small
                                color: hoveredWhileDragging ? Appearance.m3colors.m3surfaceContainerHigh : Appearance.m3colors.m3surfaceContainerLow
                                border.width: 2
                                border.color: hoveredWhileDragging ? Appearance.colors.colSecondary : "transparent"

                                MouseArea {
                                    id: workspaceArea
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton
                                    onPressed: {
                                        if (root.draggingTargetWorkspace === -1) {
                                            GlobalStates.overviewOpen = false
                                            Hyprland.dispatch(`hl.dsp.focus({ workspace = ${workspace.workspaceValue} })`)
                                        }
                                    }
                                }

                                DropArea {
                                    anchors.fill: parent
                                    onEntered: {
                                        root.draggingTargetWorkspace = workspace.workspaceValue
                                        if (root.draggingFromWorkspace == root.draggingTargetWorkspace) return;
                                        workspace.hoveredWhileDragging = true
                                    }
                                    onExited: {
                                        workspace.hoveredWhileDragging = false
                                        if (root.draggingTargetWorkspace == workspace.workspaceValue) root.draggingTargetWorkspace = -1
                                    }
                                }
                            }
                        }
                    }
                }

                Item { // Windows, over the cards
                    id: windowSpace
                    x: workspaceRow.x
                    y: workspaceRow.y + root.numeralHeight + root.numeralGap
                    width: root.cardsWidth
                    height: root.workspaceImplicitHeight

                    Repeater { // Window repeater
                        model: ScriptModel {
                            values: {
                                return ToplevelManager.toplevels.values.filter((toplevel) => {
                                    const address = `0x${toplevel.HyprlandToplevel?.address}`
                                    var win = root.windowByAddress[address]
                                    return root.workspaceIds.includes(win?.workspace?.id)
                                })
                            }
                        }
                        delegate: OverviewWindow {
                            id: window
                            required property var modelData
                            property int monitorId: windowData?.monitor
                            property var monitor: HyprlandData.monitors.find(m => m.id == monitorId)
                            property var address: `0x${modelData.HyprlandToplevel.address}`
                            toplevel: modelData
                            sheetSettled: !openAnimation.running && !root.closing
                            monitorData: this.monitor
                            scale: root.scale
                            widgetMonitor: HyprlandData.monitors.find(m => m.id == root.monitor.id)
                            windowData: root.windowByAddress[address]

                            // Offset on the canvas
                            xOffset: (root.workspaceImplicitWidth + root.cardGap) * root.workspaceIds.indexOf(windowData?.workspace.id)
                            yOffset: 0
                            property real xWithinWorkspaceWidget: Math.max((windowData?.at[0] - (monitor?.x ?? 0) - monitorData?.reserved[0]) * root.scale, 0)
                            property real yWithinWorkspaceWidget: Math.max((windowData?.at[1] - (monitor?.y ?? 0) - monitorData?.reserved[1]) * root.scale, 0)

                            readonly property real tileRadius: Math.min(Appearance.rounding.verysmall, Math.min(targetWindowWidth, targetWindowHeight) / 4)
                            topLeftRadius: tileRadius
                            topRightRadius: tileRadius
                            bottomLeftRadius: tileRadius
                            bottomRightRadius: tileRadius

                            Timer {
                                id: updateWindowPosition
                                interval: Config.options.hacks.arbitraryRaceConditionDelay
                                repeat: false
                                running: false
                                onTriggered: {
                                    window.x = Math.round(xWithinWorkspaceWidget + xOffset)
                                    window.y = Math.round(yWithinWorkspaceWidget + yOffset)
                                }
                            }

                            z: Drag.active ? root.windowDraggingZ : (root.windowZ + windowData?.floating + windowData?.fullscreen * 2)
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2
                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: hovered = true // For hover color change
                                onExited: hovered = false // For hover color change
                                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                drag.target: parent
                                onPressed: (mouse) => {
                                    root.draggingFromWorkspace = windowData?.workspace.id
                                    window.pressed = true
                                    window.Drag.active = true
                                    window.Drag.source = window
                                    window.Drag.hotSpot.x = mouse.x
                                    window.Drag.hotSpot.y = mouse.y
                                }
                                onReleased: {
                                    const targetWorkspace = root.draggingTargetWorkspace
                                    window.pressed = false
                                    window.Drag.active = false
                                    root.draggingFromWorkspace = -1
                                    if (targetWorkspace !== -1 && targetWorkspace !== windowData?.workspace.id) {
                                        Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${targetWorkspace}, follow = false, window = "address:${window.windowData?.address}" })`)
                                    }
                                    else {
                                        if (!window.windowData.floating) {
                                            updateWindowPosition.restart()
                                            return
                                        }
                                        const percentageX = (window.x - xOffset) / root.workspaceImplicitWidth
                                        const percentageY = (window.y - yOffset) / root.workspaceImplicitHeight
                                        Hyprland.dispatch(`hl.dsp.window.move({ x = "${percentageX * root.screen.width}", y = "${percentageY * root.screen.height}", window = "address:${window.windowData?.address}" })`)
                                    }
                                }
                                onClicked: (event) => {
                                    if (!windowData) return;

                                    if (event.button === Qt.LeftButton) {
                                        GlobalStates.overviewOpen = false
                                        Hyprland.dispatch(`hl.dsp.focus({ window = "address:${windowData.address}" })`)
                                        event.accepted = true
                                    } else if (event.button === Qt.MiddleButton) {
                                        Hyprland.dispatch(`hl.dsp.window.close({ window = "address:${windowData.address}" })`)
                                        event.accepted = true
                                    }
                                }

                                StyledToolTip {
                                    extraVisibleCondition: false
                                    alternativeVisibleCondition: dragArea.containsMouse && !window.Drag.active
                                    text: `${windowData?.title}\n[${windowData?.class}] ${windowData?.xwayland ? "[XWayland] " : ""}`
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
