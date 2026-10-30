import qs.modules.common
import qs.services
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

Singleton {
    id: root
    signal requestBluetoothDialog()
    property bool barOpen: true
    property bool equalizerOpen: false
    property bool sidebarRightOpen: false
    // A section the control panel opens on (one of SidebarRightContent's section flags), then
    // clears: `sidebarRight openSound` (CTRL+SUPER+V).
    property string sidebarRightSection: ""
    property bool notificationCenterOpen: false
    property bool mediaControlsOpen: false
    property bool osdBrightnessOpen: false
    property bool settingsOpen: false
    property bool osdVolumeOpen: false
    property bool oskOpen: false
    property bool overlayOpen: false
    property bool overviewOpen: false
    // The workspace sheet is out (opening, open or going back): it is drawn over the notch and
    // takes its place, so the notch hides its body and centre and fades its wings (Overview.qml).
    property bool gridOver: false
    property bool regionSelectorOpen: false
    property bool searchOpen: false
    property bool screenLocked: false
    property bool screenLockContainsCharacters: false
    property bool screenUnlockFailed: false
    property bool screenTranslatorOpen: false
    property bool sessionOpen: false
    property bool superDown: false
    property bool superReleaseMightTrigger: true
    property bool wallpaperSelectorOpen: false
    property string settingsPage: ""
    property Item currentPageInstance: null
    property list<real> visualizerPoints: []
    property bool desktopWidgetKeyboardFocus: false
    property bool desktopMenuOpen: false
    property var desktopMenuScreen: null
    property real desktopMenuX: 0
    property real desktopMenuY: 0
    property string wallpaperSelectorTarget: "wallpaper"
    property bool dropShelfOpen: false
    property real dropShelfX: 0
    property real dropShelfY: 0
    // the monitor dropShelfX/Y are local to
    property var dropShelfScreen: null
    // the notch's recording choice for the area picker: "area" or "window", a pulse RegionSelector clears
    property string recordPick: ""

    readonly property var hotCornerOptions: CornerActions.list

    function toggleState(name) {
        if (!name || name === "none") return;
        // A name that is not in hotCornerOptions comes from a config written by an older version -
        // a corner pointed at a surface that no longer exists. Assigning it would create a stray
        // property and the corner would do nothing for the rest of the session with no clue why.
        if (!root.hotCornerOptions.some(option => option.value === name)) {
            console.log(`GlobalStates: corner action "${name}" is not a state this shell has; ignoring.`);
            return;
        }
        // The media corner goes where SUPER+M goes: the notch, when it shows what is playing.
        if (name === "mediaControlsOpen" && IslandController.ownsMedia) {
            IslandController.openRequested();
            return;
        }
        root[name] = !root[name];
    }
    
    // The notification centre is where notifications are read (D2 of the sweep plan: any opening,
    // the corner rest included). The control panel used to mark everything read and hold popups
    // back although it shows no notifications.
    onNotificationCenterOpenChanged: {
        if (GlobalStates.notificationCenterOpen)
            Notifications.markAllRead();
    }

    // This property is the whole lock: LockScreen's WlSessionLock is bound straight to it, and a
    // reload or a crash rebuilds it as false. LockScreen reads logind's LockedHint on every start
    // to re-lock, but only a client can set that hint and nothing here was setting it, so it was
    // always "no". Told here rather than in LockScreen because this is where the state lives.
    onScreenLockedChanged: {
        Quickshell.execDetached(["busctl", "call", "org.freedesktop.login1",
            "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session",
            "SetLockedHint", "b", root.screenLocked ? "true" : "false"]);
    }

    Timer {
        id: barRefreshTimer
        interval: 200
        repeat: false
        onTriggered: {
            root.barOpen = true
        }
    }

    function refreshBar() {
        if (!root.barOpen) return;
        root.barOpen = false
        barRefreshTimer.restart()
    }

    // This singleton's shortcuts and IPC live in shell.qml: GlobalStates is also read in the
    // Settings app's process, where they registered a second time.
}
