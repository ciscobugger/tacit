import qs
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
pragma Singleton
pragma ComponentBehavior: Bound

/**
 * Provides a list of wallpapers and an "apply" action that calls the existing
 * switchwall.sh script. Pretty much a limited file browsing service.
 */
Singleton {
    id: root

    property string thumbgenScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/thumbgen-venv.sh`
    property string generateThumbnailsMagickScriptPath: `${FileUtils.trimFileProtocol(Directories.scriptPath)}/thumbnails/generate-thumbnails-magick.sh`
    property alias directory: folderModel.folder
    readonly property string effectiveDirectory: FileUtils.trimFileProtocol(folderModel.folder.toString())
    // the folder Settings > Wallpaper shows and the rotation picks from (it was always ~/Pictures/Wallpapers here)
    property url defaultFolder: Config.options.wallpaperSelector.userPath.length > 0
        ? Qt.resolvedUrl(`file://${Config.options.wallpaperSelector.userPath}`) : Qt.resolvedUrl(`${Directories.pictures}/Wallpapers`)
    property alias folderModel: folderModel // Expose for direct binding when needed
    property string searchQuery: ""
    readonly property list<string> extensions: [ // TODO: add videos
        "jpg", "jpeg", "png", "webp", "avif", "bmp", "svg"
    ]
    property list<string> wallpapers: [] // List of absolute file paths (without file://)
    readonly property bool thumbnailGenerationRunning: thumbgenProc.running
    property real thumbnailGenerationProgress: 0
    property string previewPath: ""  // Set during arrow navigation; empty by default
    property string confirmedPath: ""  // Holds confirmed path until config catches up

    signal changed()
    signal thumbnailGenerated(directory: string)
    signal thumbnailGeneratedFile(filePath: string)

    function load () {} // For forcing initialization

    function startPreview(path) {
        if (!path || path.length === 0) return;
        root.previewPath = path;
    }

    function stopPreview() {
        root.previewPath = "";
    }

    // Executions
    Process {
        id: applyProc
    }
    
    // Choosing a file for the wallpaper (or the lock): Files in pick mode, answered through
    // `wallpapers picked`. The KDE picker (kdialog in switchwall.sh) is left only for the key used
    // when the shell is dead (keybinds.lua, CTRL+SUPER+T).
    property bool pickDarkMode: true
    property string pickTarget: "wallpaper"
    function openFallbackPicker(darkMode = Appearance.m3colors.darkmode, startDir = "") {
        root.pickDarkMode = darkMode;
        root.pickTarget = GlobalStates.wallpaperSelectorTarget;
        Files.pick(startDir !== "" ? startDir : root.effectiveDirectory,
            FileUtils.trimFileProtocol(Quickshell.shellPath("shell.qml")), "wallpapers",
            root.pickTarget === "lockWall" ? "Use for the lock" : "Use as wallpaper");
    }
    function picked(paths) {
        const path = (paths ?? [])[0] ?? "";
        if (path.length === 0)
            return;
        if (root.pickTarget === "lockWall") {
            root.select(path, root.pickDarkMode, finalPath => Config.options.background.lockWall = finalPath);
            GlobalStates.wallpaperSelectorTarget = "wallpaper";
        } else {
            root.apply(path, root.pickDarkMode);
        }
    }

    // Pictures used as the wallpaper, newest first: the selector's "Yours" (WallpaperStrip.qml).
    // Kept in the user state folder, 40 at most.
    property var used: []
    FileView {
        id: usedFile
        path: `${Directories.userStateDir}/wallpapers-used.json`
        printErrors: false
        onLoaded: {
            try {
                const parsed = JSON.parse(usedFile.text());
                root.used = Array.isArray(parsed) ? parsed.filter(p => typeof p === "string") : [];
            } catch (e) {
                root.used = [];
            }
            root.remember(Config.options.background.wallpaperPath ?? "");
        }
        onLoadFailed: root.remember(Config.options.background.wallpaperPath ?? "")
    }
    // the wallpaper you have now is always the newest
    function remember(path) {
        if (!path || path.length === 0 || path.startsWith("file:"))
            return;
        if (root.used[0] === path)
            return;
        root.used = [path, ...root.used.filter(p => p !== path)].slice(0, 40);
        usedFile.setText(JSON.stringify(root.used));
    }

    // An online picture (OnlineWallpapers.results item): downloaded to Pictures/Wallpapers, then
    // applied. The url and id come out of a provider's JSON: https only, the id reduced to
    // file-name characters, curl given argv (OnlineWallpaperGrid.qml did the same).
    function downloadAndApply(item, darkMode = Appearance.m3colors.darkmode) {
        const url = String(item?.full ?? "");
        if (!/^https:\/\//.test(url))
            return;
        const lower = url.toLowerCase().split("?")[0];
        const ext = lower.includes(".png") ? "png" : lower.includes(".webp") ? "webp" : "jpg";
        const id = String(item.id).replace(/[^A-Za-z0-9_-]/g, "_");
        const target = `${FileUtils.trimFileProtocol(Directories.pictures)}/Wallpapers/${item.provider}-${id}.${ext}`;
        downloadProc.target = target;
        downloadProc.darkMode = darkMode;
        downloadProc.command = ["bash", "-c",
            'mkdir -p "$(dirname -- "$1")" || exit 1; exec curl -L --silent --fail -o "$1" -- "$2"',
            "wallpaper-download", target, url];
        downloadProc.running = true;
    }
    Process {
        id: downloadProc
        property string target: ""
        property bool darkMode: true
        onExited: exitCode => {
            if (exitCode === 0)
                root.apply(downloadProc.target, downloadProc.darkMode);
            else
                Quickshell.execDetached(["notify-send", Translation.tr("The picture did not download"), downloadProc.target, "-a", "Wallpaper"]);
        }
    }

    function apply(path, darkMode = Appearance.m3colors.darkmode) {
        if (!path || path.length === 0) return;
        root.remember(path);
        // into the shell's own settings first, as the first run does: switchwall.sh writes the same path later, and a
        // write of its lost under the shell's left the old path on disk while confirmedPath kept the new picture on
        // screen, so it came back after a restart and Settings showed no preview (Discord 2026-10-22, Axy)
        Config.options.background.wallpaperPath = path;
        Config.writeNow();
        root.confirmedPath = path;
        Quickshell.execDetached([Directories.wallpaperSwitchScriptPath, "--mode", darkMode ? "dark" : "light", "--image", path]);
        root.changed()
    }

    Process {
        id: selectProc
        property string filePath: ""
        property bool darkMode: Appearance.m3colors.darkmode
        property var onFileSelected: null
        function select(filePath, darkMode = Appearance.m3colors.darkmode, onFileSelected = null) {
            selectProc.filePath = filePath
            selectProc.darkMode = darkMode
            selectProc.onFileSelected = onFileSelected
            selectProc.exec(["test", "-d", FileUtils.trimFileProtocol(filePath)])
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                setDirectory(selectProc.filePath);
                return;
            }
            if (selectProc.onFileSelected) {
                selectProc.onFileSelected(selectProc.filePath);
            } else {
                root.apply(selectProc.filePath, selectProc.darkMode);
            }
        }
    }

    function select(filePath, darkMode = Appearance.m3colors.darkmode, onFileSelected = null) {
        selectProc.select(filePath, darkMode, onFileSelected);
    }

    // Only the pictures: the folder model lists subfolders too, and a random pick that landed on
    // one just browsed into it instead of changing the wallpaper.
    function imagesInCurrentFolder() {
        const candidates = [];
        for (let i = 0; i < folderModel.count; i++) {
            if (folderModel.get(i, "fileIsDir")) continue;
            const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"));
            // a folder that does not exist lists the working directory instead (quickshell-gotchas): only its own pictures
            if (path && path.startsWith(root.effectiveDirectory + "/")) candidates.push(path);
        }
        return candidates;
    }

    // A wallpaper that cannot be shown, said once: the background is one per screen and every screen's copy fails on
    // the same picture at the same moment (two screens, two notices). The same picture again later is said again.
    property string unloadableLast: ""
    property real unloadableAt: 0
    function reportUnloadable(path) {
        const now = Date.now();
        if (path === root.unloadableLast && now - root.unloadableAt < 10000) return;
        root.unloadableLast = path;
        root.unloadableAt = now;
        Quickshell.execDetached(["notify-send",
            Translation.tr("Wallpaper could not be loaded"),
            path,
            "-a", "Wallpaper switcher", "-c", "im.error"
        ]);
    }

    function randomFromCurrentFolder(darkMode = Appearance.m3colors.darkmode) {
        const candidates = root.imagesInCurrentFolder();
        if (candidates.length === 0) {
            Quickshell.execDetached(["notify-send",
                Translation.tr("No wallpaper to pick from"),
                root.effectiveDirectory, "-a", "Wallpaper switcher"
            ]);
            return;
        }
        root.apply(candidates[Math.floor(Math.random() * candidates.length)], darkMode);
    }

    function getRandomWallpaperPath(excludePath = "") {
        if (folderModel.count === 0) return "";
        const excludeClean = FileUtils.trimFileProtocol(excludePath);
        const candidates = [];
        for (let i = 0; i < folderModel.count; i++) {
            const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"));
            if (path && path.length && FileUtils.trimFileProtocol(path) !== excludeClean) {
                candidates.push(path);
            }
        }
        if (candidates.length === 0) return "";
        return candidates[Math.floor(Math.random() * candidates.length)];
    }

    Process {
        id: validateDirProc
        property string nicePath: ""
        function setDirectoryIfValid(path) {
            validateDirProc.nicePath = FileUtils.trimFileProtocol(path).replace(/\/+$/, "")
            if (/^\/*$/.test(validateDirProc.nicePath)) validateDirProc.nicePath = "/";
            // The path is typed or pasted, so it reaches the shell as an argument and never as
            // part of the script: a folder named with a quote or $(...) broke the test or ran.
            validateDirProc.exec([
                "bash", "-c",
                'if [ -d "$1" ]; then echo dir; elif [ -f "$1" ]; then echo file; else echo invalid; fi',
                "validate-dir", validateDirProc.nicePath
            ])
        }
        stdout: StdioCollector {
            onStreamFinished: {
                const result = text.trim()
                // Only a real folder moves the grid. It used to move first and read the answer
                // after, so a typo or a stale recent left an empty view and no way back.
                if (result === "dir") {
                    root.directory = Qt.resolvedUrl(validateDirProc.nicePath)
                } else if (result === "file") {
                    root.directory = Qt.resolvedUrl(FileUtils.parentDirectory(validateDirProc.nicePath))
                } else {
                    Quickshell.execDetached(["notify-send",
                        Translation.tr("No such folder"),
                        validateDirProc.nicePath, "-a", "Wallpaper switcher"
                    ]);
                }
            }
        }
    }
    function setDirectory(path) {
        validateDirProc.setDirectoryIfValid(path)
    }
    function navigateUp() {
        folderModel.navigateUp()
    }
    function navigateBack() {
        folderModel.navigateBack()
    }
    function navigateForward() {
        folderModel.navigateForward()
    }

    // Folder model
    FolderListModelWithHistory {
        id: folderModel
        folder: Qt.resolvedUrl(root.defaultFolder)
        caseSensitive: false
        // One glob per extension. Interpolating the term list straight into the template joined
        // it with a comma, so any two-word query became a glob that matched nothing.
        nameFilters: {
            const terms = root.searchQuery.split(" ").filter(s => s.length > 0);
            return root.extensions.map(ext => `*${terms.join("*")}*.${ext}`);
        }
        showDirs: true
        showDotAndDotDot: false
        showOnlyReadable: true
        sortField: FolderListModel.Time
        sortReversed: false
        onCountChanged: {
            root.wallpapers = []
            for (let i = 0; i < folderModel.count; i++) {
                const path = folderModel.get(i, "filePath") || FileUtils.trimFileProtocol(folderModel.get(i, "fileURL"))
                if (path && path.length) root.wallpapers.push(path)
            }
        }
    }

    // Thumbnail generation. The directory is explicit: setDirectory() only lands in a callback
    // after a subprocess, so a caller that set it a moment ago would generate for the old folder.
    function generateThumbnail(size: string, directory = root.effectiveDirectory) {
        if (!["normal", "large", "x-large", "xx-large"].includes(size)) throw new Error("Invalid thumbnail size");
        const dir = FileUtils.trimFileProtocol(String(directory));
        thumbgenProc.directory = dir
        thumbgenProc.running = false
        // argv, not a shell string: a folder name is user input and used to be pasted in bare.
        thumbgenProc.command = [
            "bash", "-c",
            '"$1" --size "$4" --machine_progress -d "$3" || "$2" --size "$4" -d "$3"',
            "thumbgen", root.thumbgenScriptPath, root.generateThumbnailsMagickScriptPath, dir, size,
        ]
        // console.log("[Wallpapers] Updating thumbnails with command ", thumbgenProc.command.join(" "))
        root.thumbnailGenerationProgress = 0
        thumbgenProc.running = true
    }
    Process {
        id: thumbgenProc
        property string directory
        stdout: SplitParser {
            onRead: data => {
                // print("thumb gen proc:", data)
                let match = data.match(/PROGRESS (\d+)\/(\d+)/)
                if (match) {
                    const completed = parseInt(match[1])
                    const total = parseInt(match[2])
                    root.thumbnailGenerationProgress = completed / total
                }
                match = data.match(/FILE (.+)/)
                if (match) {
                    const filePath = match[1]
                    root.thumbnailGeneratedFile(filePath)
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            // print("[Wallpapers] Thumbnail generation completed with exit code", exitCode)
            root.thumbnailGenerated(thumbgenProc.directory)
        }
    }

    // confirmedPath only bridges the wait for switchwall.sh to write config.json, and the
    // desktop prefers it over the config value. Once the config moves - to this picture or to
    // one set by a keybind, the file picker or the script from a terminal - it has to go.
    Connections {
        target: Config.options.background
        function onWallpaperPathChanged() {
            root.confirmedPath = "";
        }
    }

    // One timer for the machine. It used to live in the per-monitor Background window, so every
    // tick started one switchwall.sh per monitor at the same instant, all writing config.json.
    Timer {
        interval: Config.options.wallpaperSelector.changeInterval
        running: Config.options.wallpaperSelector.changeInterval > 0
        repeat: true
        // Silent when there is nothing to pick: an unattended tick must not notify every time.
        onTriggered: if (root.imagesInCurrentFolder().length > 0) root.randomFromCurrentFolder()
    }

    IpcHandler {
        target: "wallpapers"

        function apply(path: string): void {
            root.apply(path);
        }

        // Files' answer to openFallbackPicker: a JSON list of paths
        function picked(json: string): void {
            root.picked(JSON.parse(json));
        }
    }
}