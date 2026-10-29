//@ pragma UseQApplication
//@ pragma Env QS_NO_RELOAD_POPUP=1
// the notch's sand (Tacit.Sand, native/sand/build.sh) is installed in ~/.local/lib/qml
//@ pragma Env QML_IMPORT_PATH=/home/abdul/.local/lib/qml
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000
// Remove two slashes below and adjust the value to change the UI scale
////@ pragma Env QT_SCALE_FACTOR=1
import "modules/common"
import "services"
import "panelFamilies"
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.SystemTray

ShellRoot {
    id: root

    ReloadPopup {}

    // Tacit draws no tray, but Discord, Steam and the like register a tray icon only when some
    // process owns org.kde.StatusNotifierWatcher. Quickshell creates it in the process that first
    // uses SystemTray; a binding on the root is evaluated when the shell starts, so this
    // process always does (Activity reads the items as a host).
    readonly property var trayHost: SystemTray.items

    Process {
        id: autostartProc
        command: ["python3", `${Directories.scriptPath}/hyprland/autostart.py`]
    }

    Connections {
        target: Config
        function onReadyChanged() {
            if (!Config.ready) return

            if (WM.compositor === "niri") {
                Config.options.background.lockWall = ""
                Config.options.overview.enable = false
            }

            if (Config.options.hyprland.autostartApps.enable &&
                Config.options.hyprland.autostartApps.apps.length > 0) {
                autostartProc.running = true
            }
        }
    }

    Component.onCompleted: {
        // the desktop is the one Tacit program that says config.json cannot be read (Config.reportsProblems)
        Config.reportsProblems = true
        MaterialThemeLoader.reapplyTheme()
        Hyprsunset.load()
        FirstRunExperience.load()
        ConflictKiller.load()
        Cliphist.refresh()
        Wallpapers.load()
        Updates.load()
    }
    
    // GlobalStates' shortcuts and IPC, here so only the shell holds them. GlobalStates is also
    // read in the Settings app's process (DateTime and BluetoothAgent watch screenLocked), where
    // they registered a second time: a key press reached both processes, and the wallpaper toggle
    // flipped the config twice.
    CompositorGlobalShortcut {
        name: "workspaceNumber"
        description: "Held while dragging a Files window: it snaps to an edge or maximises"
        onPressed: GlobalStates.superDown = true
        onReleased: GlobalStates.superDown = false
    }
    CompositorGlobalShortcut {
        name: "centeredWallpaperToggle"
        description: "Toggles centered wallpaper"
        onPressed: Config.options.background.centeredWallpaper = !Config.options.background.centeredWallpaper
    }
    IpcHandler {
        target: "background"
        function toggleCenteredWallpaper(): void {
            Config.options.background.centeredWallpaper = !Config.options.background.centeredWallpaper
        }
    }

    PanelFamilyLoader {
        identifier: "ii"
        component: IllogicalImpulseFamily {}
    }

    component PanelFamilyLoader: LazyLoader {
        required property string identifier
        // config.json has the last word on panelFamily and panelFamilies/ ships one family, so
        // this loader also answers for a string that names no family: a typo or a preset used to
        // leave the shell running with nothing on screen at all - no island, no background, no
        // launcher - and no way back but editing JSON from a TTY. A second family means listing
        // it here too, and then only one of them may take the unknown case.
        readonly property var knownFamilies: ["ii"]
        active: Config.ready && (Config.options.panelFamily === identifier
            || !knownFamilies.includes(Config.options.panelFamily))
    }
}
