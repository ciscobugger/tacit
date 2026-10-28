import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import Qt.labs.synchronizer
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

Scope {
    id: overviewScope
    property bool dontAutoCancelSearch: false
    // Which prefix hotkey opened the palette, if any. One shared "opened by a hotkey" flag
    // made each of the four hotkeys read every other one as "pressed again, so close".
    property string prefixMode: ""
    // The palette (Super) and the workspace grid (Super+Tab) share this window but
    // never show at the same time.
    property bool paletteMode: true
    // The workspace sheet lives from its opening until it has shrunk back into the notch, so the
    // Loader keeps it (it used to follow overviewOpen and destroyed the sheet before the close ran).
    property bool gridAlive: false
    // shrinking back: the window stays up, without input, until OverviewWidget says it is closed
    readonly property bool gridClosing: gridAlive && !GlobalStates.overviewOpen
    // Back in the notch: the notch is shown again first, the sheet goes two frames later and its
    // window after that. Unmapped at once, the screen showed one empty frame before the notch.
    property bool sheetHome: false
    // The palette slides back into the bottom edge after a close: the window stays up, without
    // input, until SearchWidget says it is in (its `closed`), and the query is cleared only then,
    // so the results ride down with it instead of vanishing first.
    property bool paletteAlive: false
    // The dock: up while the bottom edge is touched (dockEdge below), the palette's shape without
    // its field; dockAlive keeps the window up while it slides back into the edge.
    property bool dockShown: false
    property bool dockAlive: false
    // Super raises the dock holding the keyboard (dockByKeys); the first letter typed turns it into
    // the search (searchActive). A prefix hotkey, the disc, or IPC open go straight to the search.
    property bool searchActive: true
    property bool dockByKeys: false
    function openDock() {
        if (GlobalStates.overviewOpen) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.paletteMode = true;
        overviewScope.prefixMode = "";
        overviewScope.searchActive = false;
        searchWidget.cancelSearch();
        overviewScope.moveToFocusedScreen();
        overviewScope.dockByKeys = true;
        overviewScope.dockAlive = true;
        overviewScope.dockShown = true;
        GlobalStates.overviewOpen = true;
    }
    function showDock() {
        if (GlobalStates.overviewOpen || GlobalStates.screenLocked)
            return;
        overviewScope.moveToFocusedScreen();
        overviewScope.paletteMode = true;
        overviewScope.dockAlive = true;
        overviewScope.dockShown = true;
    }
    Binding {
        target: GlobalStates
        property: "gridOver"
        value: overviewScope.gridAlive && !overviewScope.paletteMode && !overviewScope.sheetHome
    }
    function handBack() {
        if (GlobalStates.overviewOpen || overviewScope.sheetHome)
            return;
        overviewScope.sheetHome = true;
        sheetHide.restart();
    }
    Timer {
        id: sheetHide
        interval: 34
        onTriggered: {
            if (overviewLoader.item)
                overviewLoader.item.bodyHidden = true;
            sheetGone.restart();
        }
    }
    Timer {
        id: sheetGone
        interval: 50
        onTriggered: {
            if (!GlobalStates.overviewOpen)
                overviewScope.gridAlive = false;
            overviewScope.sheetHome = false;
        }
    }

    // The window is a single instance, so it stays wherever it was last shown. Same lookup
    // as DesktopMenu.openCentered, and only while the window is down: reassigning the screen
    // of a mapped layer surface would move the palette out from under the pointer.
    function moveToFocusedScreen() {
        if (GlobalStates.overviewOpen)
            return;
        const focusedName = Hyprland.focusedMonitor?.name;
        const target = Quickshell.screens.find(s => s.name === focusedName);
        if (target && panelWindow.screen !== target)
            panelWindow.screen = target;
    }

    function openPalette(toggle) {
        if (toggle && GlobalStates.overviewOpen && overviewScope.paletteMode) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.paletteMode = true;
        overviewScope.prefixMode = "";
        overviewScope.searchActive = true;
        // Cleared here and not left to onOverviewOpenChanged: opening the palette over the
        // already-open workspace grid does not change overviewOpen, so nothing fired.
        searchWidget.cancelSearch();
        overviewScope.moveToFocusedScreen();
        GlobalStates.overviewOpen = true;
    }

    function openWorkspaces() {
        if (GlobalStates.overviewOpen && !overviewScope.paletteMode) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.paletteMode = false;
        overviewScope.paletteAlive = false;
        overviewScope.dockShown = false;
        overviewScope.prefixMode = "";
        searchWidget.cancelSearch();
        overviewScope.moveToFocusedScreen();
        overviewScope.gridRequested = true;
        GlobalStates.overviewOpen = true;
        // no change when it was already open (the palette): cleared here, not only in the handler
        overviewScope.gridRequested = false;
    }

    // Only SUPER+Tab opens the grid. The corners and the dock set overviewOpen directly, and
    // after one SUPER+Tab they opened the grid instead of the palette: paletteMode stayed false.
    property bool gridRequested: false
    Connections {
        target: GlobalStates
        function onOverviewOpenChanged() {
            if (GlobalStates.overviewOpen && !overviewScope.gridRequested)
                overviewScope.paletteMode = true;
        }
    }

    // Palette open state, as declared in GlobalStates.qml; it stays on while the palette slides out
    Binding {
        target: GlobalStates
        property: "searchOpen"
        value: (GlobalStates.overviewOpen || overviewScope.paletteAlive) && overviewScope.paletteMode
    }

    PanelWindow {
        id: panelWindow
        property string searchingText: ""
        readonly property HyprlandMonitor monitor: Hyprland.monitorFor(panelWindow.screen)
        property bool monitorIsFocused: (Hyprland.focusedMonitor?.id == monitor?.id)
        // gridAlive, not gridClosing: gridClosing is derived from overviewOpen, and read while
        // overviewOpen changes it can still be stale, which unmapped the window for a frame
        visible: GlobalStates.overviewOpen || overviewScope.gridAlive || overviewScope.paletteAlive || overviewScope.dockAlive

        WlrLayershell.namespace: "quickshell:overview"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: GlobalStates.overviewOpen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
        // The workspace sheet docks into the top edge over the notch, so the window must not start
        // below the notch's reserved band.
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        mask: Region {
            item: GlobalStates.overviewOpen || overviewScope.dockShown ? columnLayout : null
        }

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Connections {
            target: GlobalStates
            function onOverviewOpenChanged() {
                if (!GlobalStates.overviewOpen) {
                    const sheet = overviewLoader.item;
                    if (overviewScope.gridAlive && sheet && typeof sheet.close === "function") {
                        sheet.close();
                        closeLimit.restart();
                    } else {
                        overviewScope.gridAlive = false;
                    }
                    searchWidget.disableExpandAnimation();
                    overviewScope.dontAutoCancelSearch = false;
                    overviewScope.prefixMode = "";
                    // The query used to survive the close, which left every section binding
                    // live on it for the rest of the session. In palette mode it is cleared once
                    // the palette is back in the edge (onClosed below).
                    if (!overviewScope.paletteAlive)
                        searchWidget.cancelSearch();
                    GlobalFocusGrab.dismiss();
                    // the dock Super raised goes with it
                    if (overviewScope.dockByKeys) {
                        overviewScope.dockByKeys = false;
                        overviewScope.dockShown = false;
                    }
                } else {
                    closeLimit.stop();
                    sheetHide.stop();
                    sheetGone.stop();
                    overviewScope.sheetHome = false;
                    if (overviewLoader.item)
                        overviewLoader.item.bodyHidden = false;
                    if (overviewScope.paletteMode) {
                        overviewScope.gridAlive = false;
                        overviewScope.paletteAlive = true;
                    } else if (overviewScope.gridAlive && overviewLoader.item && typeof overviewLoader.item.reopen === "function") {
                        // opened again while it was going back into the notch: it grows out again
                        overviewLoader.item.reopen();
                    } else {
                        overviewScope.gridAlive = true;
                    }
                    if (!overviewScope.dontAutoCancelSearch) {
                        searchWidget.cancelSearch();
                    }
                    GlobalFocusGrab.addDismissable(panelWindow);
                }
            }
        }

        Connections {
            target: GlobalFocusGrab
            function onDismissed() {
                GlobalStates.overviewOpen = false;
            }
        }
        // the close never stays up longer than its animation, whatever happens to the sheet
        Timer {
            id: closeLimit
            interval: 700
            onTriggered: overviewScope.handBack()
        }
        Connections {
            target: overviewLoader.item
            ignoreUnknownSignals: true
            function onClosed() {
                closeLimit.stop();
                overviewScope.handBack();
            }
        }
        implicitWidth: columnLayout.implicitWidth
        implicitHeight: columnLayout.implicitHeight

        function setSearchingText(text) {
            searchWidget.setSearchingText(text);
            searchWidget.focusFirstItem();
        }

        Rectangle {
            // Subtle scrim behind the workspace grid. Deliberately outside the input mask, so
            // clicks still fall through to whatever is underneath and the focus grab dismisses
            // as before. The palette has none: it is part of the edge, not a dialog.
            anchors.fill: parent
            color: ColorUtils.transparentize(Appearance.m3colors.m3scrim, 0.75)
            opacity: GlobalStates.overviewOpen && !overviewScope.paletteMode ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
        }

        Column {
            id: columnLayout
            visible: GlobalStates.overviewOpen || overviewScope.gridAlive || overviewScope.paletteAlive || overviewScope.dockAlive
            anchors.horizontalCenter: parent.horizontalCenter
            // The palette sits on the bottom edge and slides up by a transform in
            // SearchWidget.qml. It used to slide by animating a bottomMargin from below the
            // window; the column (and with it the input mask) then started outside the surface,
            // and on 2026-09-29 the palette stopped reaching the screen although the shell drew
            // it. The workspace overview keeps its place at the top.
            // Placed by y, not by switching top/bottom anchors: when the two anchor bindings
            // changed in the wrong order the column was briefly anchored to both edges, kept the
            // full window height after, and the dock drew at the top of the screen (2026-10-02).
            y: overviewScope.paletteMode ? parent.height - columnLayout.height : 0
            spacing: -8

            // The handler below only runs while something in this window holds active focus,
            // and in palette mode the search input holds it.
            focus: GlobalStates.overviewOpen && !overviewScope.paletteMode

            Keys.onPressed: event => {
                // Left and Right already move to the workspace; Enter stays on the one shown
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    GlobalStates.overviewOpen = false;
                } else if (event.key === Qt.Key_Left) {
                    if (!panelWindow.searchingText)
                        Hyprland.dispatch('hl.dsp.focus({workspace = "r-1"})');
                } else if (event.key === Qt.Key_Right) {
                    if (!panelWindow.searchingText)
                        Hyprland.dispatch('hl.dsp.focus({workspace = "r+1"})');
                }
            }

            SearchWidget {
                id: searchWidget
                visible: overviewScope.paletteMode
                paletteMode: overviewScope.paletteMode
                dockShown: overviewScope.dockShown
                searchActive: overviewScope.searchActive
                anchors.horizontalCenter: parent.horizontalCenter
                Synchronizer on searchingText {
                    property alias source: panelWindow.searchingText
                }
                onClosed: {
                    if (GlobalStates.overviewOpen || overviewScope.dockShown)
                        return;
                    overviewScope.paletteAlive = false;
                    overviewScope.dockAlive = false;
                    searchWidget.cancelSearch();
                }
                onSearchRequested: {
                    if (GlobalStates.overviewOpen)
                        overviewScope.searchActive = true;
                    else
                        overviewScope.openPalette(false);
                }
                onBackToDock: {
                    if (overviewScope.dockByKeys) {
                        searchWidget.cancelSearch();
                        overviewScope.searchActive = false;
                    } else {
                        GlobalStates.overviewOpen = false;
                    }
                }
                onDockDone: {
                    overviewScope.dockShown = false;
                    overviewScope.dockByKeys = false;
                    GlobalStates.overviewOpen = false;
                }
            }

            Loader {
                id: overviewLoader
                active: overviewScope.gridAlive && !overviewScope.paletteMode && (Config?.options.overview.enable ?? true)
                // A Loader keeps its last item's height after it unloads; left visible, the column
                // counted that height and the dock sat 205 px above the edge after any workspace
                // grid (2026-10-02). Hidden, the Column skips it.
                visible: overviewLoader.active
                sourceComponent: (Config?.options.overview.style ?? "default") === "niri" ? niriComponent : defaultComponent

                Component {
                    id: defaultComponent
                    OverviewWidget {
                        screen: panelWindow.screen
                        visible: !overviewScope.paletteMode
                    }
                }

                Component {
                    id: niriComponent
                    NiriOverview {
                        screen: panelWindow.screen
                        panelWindow: panelWindow
                        visible: !overviewScope.paletteMode
                    }
                }
            }
        }
    }

    // The bottom edge, under the dock's place: resting the pointer on it raises the dock. Not over a
    // fullscreen window, not while the palette or the dock is up.
    PanelWindow {
        id: dockEdge
        screen: panelWindow.screen
        readonly property bool fullscreenHere: WM.fullscreenOnMonitor(panelWindow.monitor?.name)
        visible: !GlobalStates.screenLocked && !GlobalStates.overviewOpen && !overviewScope.dockShown && !dockEdge.fullscreenHere
        WlrLayershell.namespace: "quickshell:dockEdge"
        WlrLayershell.layer: WlrLayer.Top
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        anchors.bottom: true
        implicitWidth: 880
        implicitHeight: 2
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: revealTimer.restart()
            onExited: revealTimer.stop()
        }
        Timer {
            id: revealTimer
            interval: 90
            onTriggered: overviewScope.showDock()
        }
    }

    /**
     * A prefix hotkey: opens the palette on one section, and closes it only when the same
     * hotkey is pressed again. Pressing a different one switches section, which is what the
     * shared dontAutoCancelSearch test used to get wrong.
     */
    function togglePrefix(mode, prefix) {
        if (GlobalStates.overviewOpen && overviewScope.prefixMode === mode) {
            GlobalStates.overviewOpen = false;
            return;
        }
        overviewScope.dontAutoCancelSearch = true;
        overviewScope.prefixMode = mode;
        overviewScope.paletteMode = true;
        overviewScope.searchActive = true;
        overviewScope.moveToFocusedScreen();
        panelWindow.setSearchingText(prefix);
        GlobalStates.overviewOpen = true;
    }

    function toggleClipboard() {
        overviewScope.togglePrefix("clipboard", Config.options.search.prefix.clipboard);
    }

    function toggleEmojis() {
        overviewScope.togglePrefix("emoji", Config.options.search.prefix.emojis);
    }

    function toggleSymbols() {
        overviewScope.togglePrefix("symbols", Config.options.search.prefix.symbols);
    }

    // SUPER+/ was bound to "quickshell:cheatsheetToggle", which nothing in this build
    // registers - the separate cheatsheet panel does not exist here, so the key was dead
    // while still being listed as "Shell: Toggle cheatsheet". The palette already indexes
    // every Hyprland bind behind the `<` prefix, so the key now opens that.
    function toggleKeybinds() {
        overviewScope.togglePrefix("keybinds", Config.options.search.prefix.keybinds);
    }

    IpcHandler {
        target: "search"

        function toggle() {
            overviewScope.openDock();
        }
        function workspacesToggle() {
            overviewScope.openWorkspaces();
        }
        function close() {
            GlobalStates.overviewOpen = false;
        }
        function open() {
            overviewScope.openPalette(false);
        }
        function toggleReleaseInterrupt() {
            GlobalStates.superReleaseMightTrigger = false;
        }
        function clipboardToggle() {
            overviewScope.toggleClipboard();
        }

        function keybindsToggle() {
            overviewScope.toggleKeybinds();
        }
        // Opens the palette with a query in it, as if typed (scripts, and checking the palette
        // without sending keys)
        // Raises the dock as touching the bottom edge does
        function dock(): void {
            overviewScope.showDock();
        }
        function query(text: string): void {
            overviewScope.openPalette(false);
            searchWidget.setSearchingText(text);
        }
    }

    CompositorGlobalShortcut {
        name: "searchToggle"
        description: "Raises the dock (type to search) on press"

        onPressed: {
            overviewScope.openDock();
        }
    }
    CompositorGlobalShortcut {
        name: "overviewWorkspacesClose"
        description: "Closes overview on press"

        onPressed: {
            GlobalStates.overviewOpen = false;
        }
    }
    CompositorGlobalShortcut {
        name: "overviewWorkspacesToggle"
        description: "Toggles overview on press"

        onPressed: {
            overviewScope.openWorkspaces();
        }
    }
    CompositorGlobalShortcut {
        name: "searchToggleRelease"
        description: "Toggles search on release"

        onPressed: {
            GlobalStates.superReleaseMightTrigger = true;
        }

        onReleased: {
            if (!GlobalStates.superReleaseMightTrigger) {
                GlobalStates.superReleaseMightTrigger = true;
                return;
            }
            overviewScope.openDock();
        }
    }
    CompositorGlobalShortcut {
        name: "searchToggleReleaseInterrupt"
        description: "Interrupts possibility of search being toggled on release. " + "This is necessary because GlobalShortcut.onReleased in quickshell triggers whether or not you press something else while holding the key. " + "To make sure this works consistently, use binditn = MODKEYS, catchall in an automatically triggered submap that includes everything."

        onPressed: {
            GlobalStates.superReleaseMightTrigger = false;
        }
    }
    CompositorGlobalShortcut {
        name: "overviewClipboardToggle"
        description: "Toggle clipboard query on overview widget"

        onPressed: {
            overviewScope.toggleClipboard();
        }
    }

    CompositorGlobalShortcut {
        name: "overviewEmojiToggle"
        description: "Toggle emoji query on overview widget"

        onPressed: {
            overviewScope.toggleEmojis();
        }
    }

    CompositorGlobalShortcut {
        name: "overviewSymbolsToggle"
        description: "Toggle material symbols search on overview widget"

        onPressed: {
            overviewScope.toggleSymbols();
        }
    }

    // Keeps the historical name so the existing SUPER+/ bind ("quickshell:cheatsheetToggle")
    // starts working again without touching every keybind list that mentions it.
    CompositorGlobalShortcut {
        name: "cheatsheetToggle"
        description: "Open the palette on the keybinds section"

        onPressed: {
            overviewScope.toggleKeybinds();
        }
    }
}
