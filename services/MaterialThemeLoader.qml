pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Automatically reloads generated material colors.
 * It is necessary to run reapplyTheme() on startup because Singletons are lazily loaded.
 */
Singleton {
    id: root
    property string filePath: Directories.generatedMaterialThemePath

    function reapplyTheme() {
        themeFileView.reload()
    }

    // matugen writes colors.json by truncating and rewriting it, not by renaming one into place, so
    // the read 100 ms after the watcher fires can land on a partial or empty file. JSON.parse then
    // threw out of the Timer handler and nothing ever re-read: bar, notch and panels stayed on the
    // previous wallpaper's colours until the wallpaper was changed again.
    property int readAttempts: 0
    function retryRead() {
        // useLockTheme()/useLiveTheme() blank filePath for a tick; there is nothing to re-read yet
        if (root.filePath.length === 0 || root.readAttempts >= 5) return
        root.readAttempts++
        themeFileView.reload()
        delayedFileRead.restart()
    }

    function applyColors(fileContent) {
        if ((fileContent ?? "").length === 0) {
            root.retryRead()
            return
        }
        let json
        try {
            json = JSON.parse(fileContent)
        } catch (e) {
            root.retryRead()
            return
        }
        root.readAttempts = 0
        for (const key in json) {
            if (json.hasOwnProperty(key)) {
                // Convert snake_case to CamelCase
                const camelCaseKey = key.replace(/_([a-z])/g, (g) => g[1].toUpperCase())
                const m3Key = `m3${camelCaseKey}`
                Appearance.m3colors[m3Key] = json[key]
            }
        }
        Appearance.m3colors.darkmode = (Appearance.m3colors.m3background.hslLightness < 0.5)
    }

    function resetFilePathNextTime() {
        resetFilePathNextWallpaperChange.enabled = true
    }

    function useLockTheme() {
        root.filePath = ""
        root.filePath = Directories.generatedLockMaterialThemePath
    }

    function useLiveTheme() {
        root.filePath = ""
        root.filePath = Directories.generatedMaterialThemePath
    }

    Connections {
        id: resetFilePathNextWallpaperChange
        enabled: false
        target: Config.options.background
        function onWallpaperPathChanged() {
            root.filePath = ""
            root.filePath = Directories.generatedMaterialThemePath
            resetFilePathNextWallpaperChange.enabled = false
        }
    }

    // A colors.json that is not there yet (a new account's first session: matugen makes its folder on its first run) has
    // no file to watch, and the re-arm above waits for a wallpaper change that an accent change never makes, so the
    // desktop kept the built-in colours until a relogin (Discord, Noid). Look again every 2 s until it loads.
    property string missingPath: ""
    // a different file starts again at the quick retry
    onMissingPathChanged: missingRetry.tries = 0
    Timer {
        id: missingRetry
        // 2 s, then 10 s, then 60 s: a file that never comes (theming off) is not polled every 2 s all session
        property int tries: 0
        interval: tries < 5 ? 2000 : tries < 10 ? 10000 : 60000
        repeat: true
        running: root.missingPath.length > 0
        onRunningChanged: if (!running) tries = 0
        onTriggered: {
            tries++;
            const p = root.missingPath;
            root.filePath = "";
            root.filePath = p;
        }
    }

    Timer {
        id: delayedFileRead
        interval: Config.options?.hacks?.arbitraryRaceConditionDelay ?? 100
        repeat: false
        running: false
        onTriggered: {
            root.applyColors(themeFileView.text())
        }
    }

    FileView {
        id: themeFileView
        path: Qt.resolvedUrl(root.filePath)
        watchChanges: true
        onFileChanged: {
            this.reload()
            delayedFileRead.start()
        }
        onLoadedChanged: {
            if (themeFileView.loaded)
                root.missingPath = ""
            const fileContent = themeFileView.text()
            root.applyColors(fileContent)
        }
        // Loud on purpose. A missing colors.json used to fail silently and the shell just came
        // up in Appearance.qml's literal defaults, which reads as a broken design, not a
        // missing file. The `filePath` guard keeps useLockTheme()/useLiveTheme(), which blank
        // filePath for one tick to force a reload, from firing a false alarm.
        onLoadFailed: error => {
            if (root.filePath.length > 0 && root.missingPath !== root.filePath) {
                console.error("[MaterialThemeLoader] COULD NOT LOAD THE GENERATED MATERIAL COLOUR SCHEME.");
                console.error(`[MaterialThemeLoader]   missing or unreadable file: ${root.filePath}`);
                console.error(`[MaterialThemeLoader]   FileView error code: ${error}`);
                console.error("[MaterialThemeLoader]   The shell WILL still start. Every colour now falls back to the literal defaults hard-coded in modules/common/Appearance.qml (m3colors.m3background \"#141313\", m3onBackground \"#e6e1e1\", m3primary \"#cbc4cb\", and the rest), so the desktop will look wrong - untinted, not matched to the wallpaper - but nothing has crashed.");
                console.error(`[MaterialThemeLoader]   Regenerate it by running ${Directories.wallpaperSwitchScriptPath}, or by picking a wallpaper.`);
            }
            root.resetFilePathNextTime();
            if (root.filePath.length > 0)
                root.missingPath = root.filePath;
        }
    }
}
