import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: screenCorners
    readonly property Toplevel activeWindow: ToplevelManager.activeToplevel

    property var actionForCorner: ({
        // Was the left sidebar, which this desktop no longer has; the launcher is the surface
        // that took over its role. The bottom-left corner is configurable and migrates to the same.
        [RoundCorner.CornerEnum.TopLeft]: () => GlobalStates.overviewOpen = !GlobalStates.overviewOpen,
        [RoundCorner.CornerEnum.BottomLeft]: () => GlobalStates.toggleState(Config.options.sidebar.cornerOpen.bottomLeftAction),
        // The top-right corner is the notification panel's own corner (the control panel lives
        // bottom-right, see bottomRightAction); a press on the top edge there opens the centre.
        [RoundCorner.CornerEnum.TopRight]: () => GlobalStates.notificationCenterOpen = !GlobalStates.notificationCenterOpen,
        [RoundCorner.CornerEnum.BottomRight]: () => GlobalStates.toggleState(Config.options.sidebar.cornerOpen.bottomRightAction)
    })

    // The four corners of a screen in two windows, a strip along the top and one along the bottom: each window has a
    // renderer of its own, and four of them were a third of the shell's memory (313 MB of 960 on a 1080p test
    // computer, 2026-11-04). The strips are see-through and take pointer input only in the corner areas.
    component CornerStrip: PanelWindow {
        id: strip
        property bool top
        property bool fullscreen
        readonly property bool deadPixel: Config.options.interactions.deadPixelWorkaround.enable
        readonly property bool decorationVisible: (Config.options.appearance.fakeScreenRounding === 1 || (Config.options.appearance.fakeScreenRounding === 2 && !fullscreen))
        // An unmapped layer surface receives no pointer input, so the window stays mapped for the
        // corner gesture even with the rounding decoration off - only the decoration follows it.
        visible: strip.decorationVisible || leftArea.active || rightArea.active || door.active

        exclusionMode: ExclusionMode.Ignore
        mask: Region {
            Region { item: leftArea.active ? leftArea : null }
            Region { item: rightArea.active ? rightArea : null }
            Region { item: door.active ? door : null }
        }
        WlrLayershell.namespace: "quickshell:screenCorners"
        WlrLayershell.layer: WlrLayer.Overlay
        color: "transparent"

        anchors {
            top: strip.top
            bottom: !strip.top
            left: true
            right: true
        }
        margins {
            right: strip.deadPixel * -1
            bottom: (strip.deadPixel && !strip.top) * -1
        }

        implicitHeight: Math.max(Appearance.rounding.screenRounding, leftArea.implicitHeight, rightArea.implicitHeight)

        RoundCorner {
            id: leftCorner
            anchors { left: parent.left; top: strip.top ? parent.top : undefined; bottom: strip.top ? undefined : parent.bottom }
            visible: strip.decorationVisible
            corner: strip.top ? RoundCorner.CornerEnum.TopLeft : RoundCorner.CornerEnum.BottomLeft
            bottomVisualMargin: (strip.deadPixel && !strip.top) * 1
            implicitSize: Appearance.rounding.screenRounding
        }
        RoundCorner {
            id: rightCorner
            anchors { right: parent.right; top: strip.top ? parent.top : undefined; bottom: strip.top ? undefined : parent.bottom }
            visible: strip.decorationVisible
            corner: strip.top ? RoundCorner.CornerEnum.TopRight : RoundCorner.CornerEnum.BottomRight
            rightVisualMargin: strip.deadPixel * 1
            bottomVisualMargin: (strip.deadPixel && !strip.top) * 1
            implicitSize: Appearance.rounding.screenRounding
        }

        // The notification centre's door, here since the notification window exists only while something shows in it:
        // the screen's very edge where notifications arrive, 3 px, on the focused screen, while nothing shows there.
        // Hovered 300 ms or clicked, it opens the centre. Under the corner areas, as its window was under theirs.
        readonly property string notificationPosition: {
            const raw = Config.options.notifications.position ?? "top_right"
            if (raw === "top") return "top_right"
            if (raw === "bottom") return "bottom_right"
            return raw
        }
        Item {
            id: door
            // NotificationPopup's `showing`, for the window that is not there
            readonly property bool panelShowing: GlobalStates.notificationCenterOpen
                || (!((Config.options.island.enable ?? false) && (Config.options.island.states.notification ?? false))
                    && Notifications.popupList.length > 0)
            readonly property bool active: strip.top === strip.notificationPosition.startsWith("top")
                && strip.screen?.name === Hyprland.focusedMonitor?.name && !door.panelShowing
            visible: door.active
            width: Appearance.sizes.notificationPopupWidth
            height: 3
            anchors.top: strip.top ? parent.top : undefined
            anchors.bottom: strip.top ? undefined : parent.bottom
            anchors.bottomMargin: (strip.deadPixel && !strip.top) * 1
            anchors.right: strip.notificationPosition.endsWith("right") ? parent.right : undefined
            anchors.rightMargin: strip.deadPixel * 1
            anchors.left: strip.notificationPosition.endsWith("left") ? parent.left : undefined
            anchors.horizontalCenter: strip.notificationPosition.endsWith("center") ? parent.horizontalCenter : undefined

            Timer {
                id: doorTimer
                interval: 300
                onTriggered: GlobalStates.notificationCenterOpen = true
            }
            HoverHandler {
                onHoveredChanged: hovered ? doorTimer.restart() : doorTimer.stop()
            }
            // A click opens at once; the hover above is for the hand that only lingers.
            MouseArea {
                anchors.fill: parent
                onClicked: GlobalStates.notificationCenterOpen = true
            }
        }

        // Siblings of the corners, not children: an invisible parent takes no pointer input.
        CornerArea { id: leftArea; cornerItem: leftCorner; fullscreen: strip.fullscreen }
        CornerArea { id: rightArea; cornerItem: rightCorner; fullscreen: strip.fullscreen }
    }

    // A corner's gesture area: its action on a press (or on arrival, when clickless), brightness or volume on a scroll
    component CornerArea: Loader {
        id: area
        required property RoundCorner cornerItem
        property bool fullscreen
        active: {
            if (!Config.options.sidebar.cornerOpen.enable) return false;
            if (area.fullscreen) return false;
            return true;
        }
        anchors {
            top: area.cornerItem.isTop ? parent.top : undefined
            bottom: area.cornerItem.isBottom ? parent.bottom : undefined
            left: area.cornerItem.isLeft ? parent.left : undefined
            right: area.cornerItem.isRight ? parent.right : undefined
        }

        sourceComponent: FocusedScrollMouseArea {
            id: mouseArea
            implicitWidth: Config.options.sidebar.cornerOpen.cornerRegionWidth
            implicitHeight: Config.options.sidebar.cornerOpen.cornerRegionHeight
            hoverEnabled: true
            onPositionChanged: {
                if (area.cornerItem.isBottom) return;
                if (!Config.options.sidebar.cornerOpen.clicklessCornerEnd || !Config.options.sidebar.cornerOpen.clickless) return;
                const verticalOffset = Config.options.sidebar.cornerOpen.clicklessCornerVerticalOffset;
                const correctX = (area.cornerItem.isRight && mouseArea.mouseX >= mouseArea.width - 2) || (area.cornerItem.isLeft && mouseArea.mouseX <= 2);
                const correctY = (area.cornerItem.isTop && mouseArea.mouseY > verticalOffset || area.cornerItem.isBottom && mouseArea.mouseY < mouseArea.height - verticalOffset);
                if (correctX && correctY)
                    screenCorners.actionForCorner[area.cornerItem.corner]();
            }
            onEntered: {
                if (area.cornerItem.isBottom) return;
                if (Config.options.sidebar.cornerOpen.clickless)
                    screenCorners.actionForCorner[area.cornerItem.corner]();
            }
            onPressed: {
                screenCorners.actionForCorner[area.cornerItem.corner]();
            }
            onScrollDown: {
                if (!Config.options.sidebar.cornerOpen.valueScroll)
                    return;
                if (area.cornerItem.isLeft)
                    Brightness.decreaseBrightness()
                else
                    Audio.decrementVolume()
            }
            onScrollUp: {
                if (!Config.options.sidebar.cornerOpen.valueScroll)
                    return;
                if (area.cornerItem.isLeft)
                    Brightness.increaseBrightness()
                else
                    Audio.incrementVolume()
            }
            onMovedAway: {
                if (!Config.options.sidebar.cornerOpen.valueScroll)
                    return;
                if (area.cornerItem.isLeft)
                    GlobalStates.osdBrightnessOpen = false;
                else
                    GlobalStates.osdVolumeOpen = false;
            }

            Loader {
                active: Config.options.sidebar.cornerOpen.visualize
                anchors.fill: parent
                sourceComponent: Rectangle {
                    color: Appearance.colors.colPrimary
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens

        Scope {
            id: monitorScope
            required property var modelData
            property HyprlandMonitor monitor: Hyprland.monitorFor(modelData)

            // Hide when fullscreen
            property list<HyprlandWorkspace> workspacesForMonitor: Hyprland.workspaces.values.filter(workspace => workspace.monitor && workspace.monitor.name == monitor.name)
            property var activeWorkspaceWithFullscreen: workspacesForMonitor.filter(workspace => ((workspace.toplevels.values.filter(window => window.wayland?.fullscreen)[0] != undefined) && workspace.active))[0]
            property bool fullscreen: activeWorkspaceWithFullscreen != undefined
            // A special workspace open on top of the fullscreen window should bring corners back,
            // same reasoning as the bar's layer fix: fullscreen only buries them when nothing else is above it.
            property var thisMonitorData: HyprlandData.monitors.find(m => m.name === monitor.name)
            property bool specialOpen: (thisMonitorData?.specialWorkspace?.name ?? "") !== ""

            CornerStrip {
                screen: modelData
                top: true
                fullscreen: monitorScope.fullscreen && !monitorScope.specialOpen
            }
            CornerStrip {
                screen: modelData
                top: false
                fullscreen: monitorScope.fullscreen && !monitorScope.specialOpen
            }
        }
    }
}