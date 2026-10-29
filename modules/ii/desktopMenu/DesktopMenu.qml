pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Scope {
    id: root

    function openCentered(shouldOpen) {
        if (!shouldOpen) {
            GlobalStates.desktopMenuOpen = false
            return
        }
        const focusedName = Hyprland.focusedMonitor?.name
        const screen = Quickshell.screens.find(s => s.name === focusedName) ?? Quickshell.screens[0]
        GlobalStates.desktopMenuScreen = screen
        GlobalStates.desktopMenuX = screen.width / 2
        GlobalStates.desktopMenuY = screen.height / 2
        GlobalStates.desktopMenuOpen = true
    }

    function displayPathFor(path) {
        if (!path) return path
        return /\.(mp4|webm|mkv|avi|mov)$/i.test(path)
            ? Config.options.background.thumbnailPath
            : path
    }

    // Wallpaper folder images
    FolderListModel {
        id: wallpaperFolder
        folder: {
            const wallPath = Config.options.background.wallpaperPath
            if (!wallPath || wallPath.length === 0) return ""
            const lastSlash = wallPath.lastIndexOf("/")
            return "file://" + wallPath.substring(0, lastSlash)
        }
        showDirs: false
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp"]
    }

    property int carouselExtraCount: 5
    property bool useDarkMode: Appearance.m3colors.darkmode
    property var randomWallpapers: {
        const current = FileUtils.trimFileProtocol(Config.options.background.wallpaperPath)
        let all = []
        for (let i = 0; i < wallpaperFolder.count; i++) {
            const fp = FileUtils.trimFileProtocol(wallpaperFolder.get(i, "filePath").toString())
            if (fp !== current) all.push(fp)
        }
        for (let i = all.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [all[i], all[j]] = [all[j], all[i]]
        }
        return all.slice(0, carouselExtraCount)
    }

    property var carouselModel: {
        const current = FileUtils.trimFileProtocol(Config.options.background.wallpaperPath)
        if (!current || current.length === 0) return randomWallpapers.map(p => root.displayPathFor(p))
        return [root.displayPathFor(current), ...randomWallpapers.map(p => root.displayPathFor(p))]
    }

    // Menu window
    Loader {
        active: GlobalStates.desktopMenuOpen
        sourceComponent: PanelWindow {
            id: menuWindow

            screen: GlobalStates.desktopMenuScreen ?? Quickshell.screens[0]

            color: "transparent"
            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            WlrLayershell.namespace: "quickshell:desktopMenu"
            WlrLayershell.layer: WlrLayer.Overlay
            // Without this the layer defaults to no keyboard focus, so the menu could only
            // ever be dismissed with the pointer. Same setting the overview uses.
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // In the grab like the other click-opened surfaces: a panel that already holds it
            // (a sidebar, the settings window) would otherwise take the first click aimed at
            // this menu, and dismissing that panel would leave this one behind.
            Component.onCompleted: GlobalFocusGrab.addDismissable(menuWindow)
            Component.onDestruction: GlobalFocusGrab.removeDismissable(menuWindow)
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    GlobalStates.desktopMenuOpen = false
                }
            }

            property Component openSubmenuComponent: null
            property real submenuAnchorY: 0
            property real submenuWidth: 284

            // A panel opens once the pointer has rested on its row for 250 ms, and closes 250 ms
            // after the pointer has left the row and the panel.
            property Component pendingSubmenu: null
            property Item pendingRow: null

            function rowHovered(hovered, component, row) {
                if (!hovered) {
                    submenuOpenTimer.stop()
                    submenuCloseTimer.restart()
                    return
                }
                submenuCloseTimer.stop()
                if (menuWindow.openSubmenuComponent === component) {
                    submenuOpenTimer.stop()
                    return
                }
                menuWindow.pendingSubmenu = component
                menuWindow.pendingRow = row
                submenuOpenTimer.restart()
            }

            Timer {
                id: submenuOpenTimer
                interval: 250
                onTriggered: {
                    menuWindow.submenuAnchorY = menuCard.y + menuWindow.pendingRow.mapToItem(menuCard, 0, 0).y
                    menuWindow.openSubmenuComponent = menuWindow.pendingSubmenu
                }
            }

            Timer {
                id: submenuCloseTimer
                interval: 250
                onTriggered: menuWindow.openSubmenuComponent = null
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: GlobalStates.desktopMenuOpen = false
            }

            // Menu card
            Rectangle {
                id: menuCard
                width: 348
                implicitHeight: menuCol.implicitHeight + 28
                x: Math.min(Math.max(GlobalStates.desktopMenuX - width / 2, 8), menuWindow.width - width - 8)
                y: Math.min(Math.max(GlobalStates.desktopMenuY - implicitHeight / 2, 8), menuWindow.height - implicitHeight - 8)
                radius: Appearance.rounding.verylarge
                // near-opaque: the desktop behind is often bright
                color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.04)

                scale: 0.85
                opacity: 0
                transformOrigin: Item.Center

                focus: true
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Escape) {
                        GlobalStates.desktopMenuOpen = false
                        event.accepted = true
                    }
                }

                Component.onCompleted: {
                    scale = 1.0
                    opacity = 1.0
                }

                Behavior on scale {
                    animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                ColumnLayout {
                    id: menuCol
                    anchors { fill: parent; margins: 14 }
                    spacing: 6

                    MenuPictures {
                        Layout.fillWidth: true
                        model: root.carouselModel
                        onPicked: (path) => {
                            Wallpapers.select(path, Appearance.m3colors.darkmode)
                            GlobalStates.desktopMenuOpen = false
                        }
                    }

                    MenuHairline {}

                    // Wallpapers
                    MenuRow {
                        id: wallpaperRow
                        glyph: "format_paint"
                        label: "Wallpaper & style"
                        trail: "chevron_right"
                        open: menuWindow.openSubmenuComponent === wallpaperSubmenu
                        Component {
                            id: wallpaperSubmenu
                            WallpaperPanel {}
                        }
                        HoverHandler {
                            onHoveredChanged: menuWindow.rowHovered(hovered, wallpaperSubmenu, wallpaperRow)
                        }
                        onClicked: GlobalStates.desktopMenuOpen = false
                    }

                    // Widgets
                    MenuRow {
                        id: widgetsRow
                        glyph: "widgets"
                        label: "Widgets"
                        trail: "chevron_right"
                        open: menuWindow.openSubmenuComponent === widgetsSubmenu
                        Component {
                            id: widgetsSubmenu
                            WidgetsPanel {}
                        }
                        HoverHandler {
                            onHoveredChanged: menuWindow.rowHovered(hovered, widgetsSubmenu, widgetsRow)
                        }
                    }

                    MenuRow {
                        glyph: "stacks"
                        label: "Shelf"
                        hint: DropShelf.items.length > 0 ? String(DropShelf.items.length) : ""
                        trail: DropShelf.items.length > 0 ? "" : "chevron_right"
                        onClicked: {
                            GlobalStates.desktopMenuOpen = false
                            GlobalStates.dropShelfX = GlobalStates.desktopMenuX
                            GlobalStates.dropShelfY = GlobalStates.desktopMenuY
                            GlobalStates.dropShelfOpen = true
                        }
                    }

                    MenuRow {
                        glyph: "video_template"
                        label: "Live wallpaper"
                        onClicked: {
                            GlobalStates.desktopMenuOpen = false
                            Wallpapers.openFallbackPicker(
                                Appearance.m3colors.darkmode,
                                Config.options.wallpaperSelector.liveWallpapersPath ?? ""
                            )
                        }
                    }

                    MenuHairline {}

                    MenuRow {
                        glyph: "settings"
                        label: "Settings"
                        onClicked: {
                            GlobalStates.desktopMenuOpen = false
                            SettingsApp.open("")
                        }
                    }
                }
            }

            // SubMenu
            Loader {
                id: submenuLoader
                active: menuWindow.openSubmenuComponent !== null
                width: menuWindow.submenuWidth
                sourceComponent: menuWindow.openSubmenuComponent

                x: (menuCard.x + menuCard.width + 8 + menuWindow.submenuWidth > menuWindow.width)
                    ? menuCard.x - menuWindow.submenuWidth - 8
                    : menuCard.x + menuCard.width + 8

                y: Math.min(
                    Math.max(menuWindow.submenuAnchorY, 8),
                    menuWindow.height - (item?.implicitHeight ?? 0) - 8
                )

                scale: active ? 1.0 : 0.9
                opacity: active ? 1.0 : 0.0
                transformOrigin: Item.Center

                Behavior on scale {
                    animation: Appearance.animation.elementMoveEnter.numberAnimation.createObject(this)
                }
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }

                HoverHandler {
                    onHoveredChanged: {
                        if (hovered) submenuCloseTimer.stop()
                        else submenuCloseTimer.restart()
                    }
                }
            }
        }
    }
}