//@ pragma UseQApplication
//@ pragma AppId viewer
//@ pragma Env QS_NO_RELOAD_POPUP=1
//@ pragma Env QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_QUICK_FLICKABLE_WHEEL_DECELERATION=10000

// The viewer: pictures, PDFs, video and audio in one window, its own process
// (`qs -p ~/.config/quickshell/tacit/viewer.qml`), so a fault here never reaches the shell.
// VIEWER_OPEN picks the file at start; later opens come over IPC (`viewer-open`).

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.functions
import "modules/viewer"

ApplicationWindow {
    id: root

    visible: true
    // An app does not reload itself when a file in the shared config changes: a reload rebuilt the
    // window as visible, so every deploy (even one only for the shell) popped a closed app back up.
    // New code arrives the next time the app starts.
    Binding { target: Quickshell; property: "watchFiles"; value: false }
    title: viewer.entry ? `${viewer.entry.name} — Viewer` : "Viewer"
    minimumWidth: 640
    minimumHeight: 400
    width: 1280
    height: 820
    color: "transparent"

    // The window material is the terminal's, as Graphis and Pinax have it (see code.qml).
    FileView {
        id: termColors
        path: FileUtils.trimFileProtocol(`${Directories.state}/user/generated/terminal/sequences.txt`)
        blockLoading: true
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
    }
    readonly property color base: {
        const m = /\]11;(#[0-9a-fA-F]{6})/.exec(termColors.text() || "");
        return m ? m[1] : Appearance.m3colors.m3surfaceContainerLow;
    }

    Component.onCompleted: {
        MaterialThemeLoader.reapplyTheme();
        const f = Quickshell.env("VIEWER_OPEN");
        if (f && f.length) viewer.open(f);
    }

    // hidden, it stops playing and lets go of the pictures
    onVisibleChanged: if (!visible) viewer.release()

    Rectangle {
        anchors.fill: parent
        // a file shown on its own stands on the solid ground: through the glass around a letterboxed video the desktop
        // behind looked like a border cut from the video (Discord 2026-10-23, Yugank: a screen recording of the same
        // wallpaper). The roll of files keeps the glass; the ground firms up as the file settles.
        color: ColorUtils.transparentize(root.base, Tacit.windowSeeThrough * (1 - viewer.settle))
        Viewer {
            id: viewer
            anchors.fill: parent
            ground: root.base
            onCloseRequested: root.visible = false
        }
    }

    IpcHandler {
        target: "viewer"
        function open(path: string): void { viewer.open(path); root.visible = true; }
        // closing the window only hides it; every way in shows it again (viewer-open)
        function present(): void { root.visible = true; }
        function state(): string { return viewer.state(); }
    }
}
