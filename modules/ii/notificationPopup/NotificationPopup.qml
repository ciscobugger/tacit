import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland

/**
 * Top right: what happened. ONE panel flush in the corner (DockedRect corner mode), the same
 * silhouette family as the notch and the controls.
 *
 *   arrivals   rows drop out of the corner as notifications come, and leave on their own
 *   centre     hover the panel (or the empty corner) 300ms, or click a row's edge: the panel
 *              grows into the notification centre - every notification, silent, clear -
 *              sized to its rows, capped at 55% of the screen, then it scrolls. The pointer
 *              leaving closes it 100ms later; so does Esc.
 *
 * Same edge, same topic: the corner where notifications arrive is the door to their archive.
 */
Scope {
    id: notificationPopup

    PanelWindow {
        id: root
        // Always mapped (transparent), so the corner door can be hovered when nothing shows.
        visible: !GlobalStates.screenLocked
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

        property string position: {
            const raw = Config.options.notifications.position ?? "top_right"
            if (raw === "top") return "top_right"
            if (raw === "bottom") return "bottom_right"
            return raw
        }
        property bool isTop: position.startsWith("top")
        property bool isBottom: position.startsWith("bottom")
        property bool isCenter: position.endsWith("center")
        property bool isLeft: position.endsWith("left")
        property bool isRight: position.endsWith("right")

        readonly property bool centerOpen: GlobalStates.notificationCenterOpen
        // One event, one surface: with the island peeking notifications, the transient popup here
        // would be the second. Only the popup stands down - this file also owns the notification
        // CENTRE and the `notifications` IPC, and gating the whole panel off (which is what the
        // panel family did) left a default install with no centre at all, a screen corner that
        // toggled it into the void, and `ipc call notifications` answering nothing.
        readonly property bool islandOwnsPopups: (Config.options.island.enable ?? false)
            && (Config.options.island.states.notification ?? false)
        readonly property bool hasPopups: !root.islandOwnsPopups && Notifications.popupList.length > 0
        readonly property bool showing: root.hasPopups || root.centerOpen

        WlrLayershell.namespace: "quickshell:notificationPopup"
        WlrLayershell.layer: WlrLayer.Overlay
        // Typing a reply needs the keyboard: on demand (a click in the field) while the centre
        // is open or a popup carries a reply field; never taken otherwise. Once a field has
        // focus the layer holds the keyboard (exclusive): with focus following the mouse, an
        // on-demand layer lost it the moment the pointer crossed a window. Enter or Escape
        // ends it.
        readonly property bool replying: Notifications.list.some(n => n.replyActive)
        WlrLayershell.keyboardFocus: root.replying ? WlrKeyboardFocus.Exclusive
            : (root.centerOpen || (!root.islandOwnsPopups && Notifications.popupList.some(n => n.hasInlineReply))) ? WlrKeyboardFocus.OnDemand
            : WlrKeyboardFocus.None
        // Ignore other layers' reserved zones (the notch reserves 38px at the top), so the
        // panel really starts at the screen edge like the notch does.
        exclusionMode: ExclusionMode.Ignore
        exclusiveZone: 0

        // The panel's own corner, at a fixed size, not the whole screen: the compositor blends
        // every mapped layer over every damaged pixel it overlaps, and a full-screen
        // transparent layer taxed every frame of everything (a video, the notch's motion).
        // Fixed so it never resizes (a resizing layer reads as jank).
        anchors {
            top: root.isTop
            bottom: root.isBottom
            left: root.isLeft
            right: root.isRight
        }
        implicitWidth: Appearance.sizes.notificationPopupWidth + 40
        implicitHeight: Math.round(dock.cap) + 34 + dock.pad * 2 + 40

        // Input only where something is: the panel, or the corner door.
        mask: Region {
            item: root.showing ? dock : door
        }

        color: "transparent"

        function openCenter() {
            GlobalStates.notificationCenterOpen = true;
        }
        function closeCenter() {
            GlobalStates.notificationCenterOpen = false;
        }

        // Esc folds everything, through the same compositor shortcut the notch uses.
        Connections {
            target: IslandController
            function onCollapseExpansion() {
                root.closeCenter();
            }
        }

        Timer {
            id: hoverTimer
            interval: 300
            repeat: false
            // not under a hand that is dragging a row away
            onTriggered: root.openCenter()
        }
        Timer {
            id: leaveTimer
            interval: 100
            repeat: false
            onTriggered: root.closeCenter()
        }

        // The corner door: the panel's own footprint, empty. Bounded to where the panel lives.
        Item {
            id: door
            width: Appearance.sizes.notificationPopupWidth
            // only the screen's very edge: the pointer stops there however far it is flung, and a window that reaches
            // the top keeps its own buttons (60 px tall, it took the top-right buttons' hovers and clicks of every
            // window filling the screen, and opened the empty centre over them; Discord 2026-10-29)
            height: 3
            anchors.top: root.isTop ? parent.top : undefined
            anchors.bottom: root.isBottom ? parent.bottom : undefined
            anchors.right: root.isRight ? parent.right : undefined
            anchors.left: root.isLeft ? parent.left : undefined
            anchors.horizontalCenter: root.isCenter ? parent.horizontalCenter : undefined
            visible: !root.showing

            HoverHandler {
                onHoveredChanged: {
                    if (hovered)
                        hoverTimer.restart();
                    else
                        hoverTimer.stop();
                }
            }
            // A click opens at once; the hover above is for the hand that only lingers.
            MouseArea {
                anchors.fill: parent
                onClicked: root.openCenter()
            }
        }

        Item {
            id: dock
            readonly property int pad: 8
            readonly property int sideMargin: 0
            readonly property string dockEdge: root.isCenter
                ? (root.isBottom ? "bottom" : "top")
                : `${root.isBottom ? "bottom" : "top"}-${root.isLeft ? "left" : "right"}`
            readonly property real cap: root.screen ? root.screen.height * 0.55 : 600
            // Popups too: a burst does not take the screen; the newest rows show, the rest
            // wait in the centre (the dock clips).
            readonly property real listHeight: root.centerOpen
                ? Math.min(centerList.contentHeight, dock.cap - 34 - pad * 2)
                : popupList.rowsHeight

            width: Appearance.sizes.notificationPopupWidth
            height: root.showing ? (root.centerOpen ? 34 : 0) + dock.listHeight + pad * 2 : 0
            visible: root.showing || height > 0
            clip: true
            Behavior on height {
                // Arrivals and stacks unfolding animate here; a single row expanding animates
                // in the row, and the panel follows it exactly (Notifications.expanding).
                enabled: !Notifications.expanding
                Anim {}
            }

            anchors.top: root.isTop ? parent.top : undefined
            anchors.bottom: root.isBottom ? parent.bottom : undefined
            anchors.right: root.isRight ? parent.right : undefined
            anchors.left: root.isLeft ? parent.left : undefined
            anchors.horizontalCenter: root.isCenter ? parent.horizontalCenter : undefined
            anchors.rightMargin: sideMargin
            anchors.leftMargin: sideMargin

            DockedRect {
                anchors.fill: parent
                edge: dock.dockEdge
                cornerRadius: Appearance.rounding.verylarge
                fillet: 12
                color: Appearance.colors.colPanelFrost
            }

            // Hover on the panel grows it into the centre; leaving folds it. Not while popups
            // show: a popup under the hand is being read, dragged, clicked or typed into, and
            // the centre replacing it 300ms in broke every one of those. With popups showing,
            // the centre opens by a click on the panel's edge, or on a popup with nothing else
            // to do.
            HoverHandler {
                id: dockHover
                onHoveredChanged: {
                    if (hovered) {
                        leaveTimer.stop();
                        if (!root.centerOpen && !root.hasPopups)
                            hoverTimer.restart();
                    } else {
                        hoverTimer.stop();
                        if (root.centerOpen)
                            leaveTimer.restart();
                    }
                }
            }

            // The panel itself is a handle: a click on its edge or padding opens the centre.
            // Rows sit above this and keep their own clicks.
            MouseArea {
                anchors.fill: parent
                onClicked: root.openCenter()
            }

            // Centre header: count, silent, clear.
            Item {
                id: centerHeader
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: dock.pad
                anchors.leftMargin: dock.pad + 10
                anchors.rightMargin: dock.pad + 4
                height: root.centerOpen ? 34 : 0
                opacity: root.centerOpen ? 1 : 0
                visible: opacity > 0
                clip: true
                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: Notifications.list.length > 0
                        ? Translation.tr("Notifications · %1").arg(Notifications.list.length)
                        : Translation.tr("Nothing")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colSubtext
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    HeaderAction {
                        glyph: Notifications.silent ? "notifications_paused" : "notifications"
                        active: Notifications.silent
                        tip: Translation.tr("Silent")
                        onClicked: Notifications.silent = !Notifications.silent
                    }
                    HeaderAction {
                        glyph: "delete_sweep"
                        tip: Translation.tr("Clear all")
                        visible: Notifications.list.length > 0
                        onClicked: Notifications.discardAllNotifications()
                    }
                }
            }

            // Arrivals: the popup rows.
            NotificationPopupList {
                id: popupList
                anchors.top: root.isBottom ? undefined : parent.top
                anchors.bottom: root.isBottom ? parent.bottom : undefined
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: dock.pad
                visible: !root.centerOpen && !root.islandOwnsPopups
                reverse: root.isBottom
                maxHeight: dock.cap - dock.pad * 2
            }

            // The centre: everything.
            NotificationListView {
                id: centerList
                anchors.top: centerHeader.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: dock.pad
                anchors.topMargin: 0
                visible: root.centerOpen
                opacity: root.centerOpen ? 1 : 0
                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
                popup: false
                flat: true
                clip: true
            }
        }

        component HeaderAction: RippleButton {
            id: action
            property string glyph: ""
            property string tip: ""
            property bool active: false
            implicitWidth: 30
            implicitHeight: 30
            buttonRadius: 15
            colBackground: "transparent"
            colBackgroundHover: Appearance.colors.colLayer1Hover
            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                text: action.glyph
                iconSize: 18
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                color: action.active ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
            }
            StyledToolTip {
                text: action.tip
            }
        }

        IpcHandler {
            target: "notifications"

        function expand(appName: string): void {
            Notifications.expandRequested(appName);
        }
            function open(): void { GlobalStates.notificationCenterOpen = true; }
            function close(): void { GlobalStates.notificationCenterOpen = false; }
            function toggle(): void { GlobalStates.notificationCenterOpen = !GlobalStates.notificationCenterOpen; }
            // The lock screen asks how much waited: qs -c tacit ipc call notifications count
            function count(): int { return Notifications.unread; }
            // Do not disturb, for the Settings app: it runs in its own process and cannot hold a
            // second notification server to flip this on.
            function silent(): bool { return Notifications.silent; }
            function setSilent(on: bool): void { Notifications.silent = on; }
        }
    }
}
