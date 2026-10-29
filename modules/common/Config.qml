pragma Singleton
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common.functions

Singleton {
    id: root
    property string filePath: Directories.shellConfigPath
    property alias options: configOptionsJsonAdapter
    property bool ready: false
    property int readWriteDelay: 50 // milliseconds
    property bool blockWrites: false // writes go to disk synchronously, not blocked
    // Nothing writes config.json until it has been read back and parsed once.
    property bool loadedCleanly: false
    // config.json is there but cannot be used (why, in plain words): nothing set is saved until it is fixed.
    // Settings says so on every page.
    property string unusableReason: ""
    readonly property bool fileBroken: ready && !loadedCleanly && unusableReason !== ""
    readonly property string backupPath: `${filePath}.bak`
    property bool backupUsable: false
    // Only the desktop's process sends the notice (shell.qml turns this on): every Tacit program loads this file,
    // and each sent its own, at each reload (Discord 2026-10-24: 17 of them). Said once per problem.
    property bool reportsProblems: false
    property string reportedProblem: ""
    property string brokenText: ""
    onReportsProblemsChanged: reportUnusableConfig()
    // Bumped whenever a key is renamed or moved. The adapter serialises only the properties it
    // declares, so without a stamp on the file there is no way to tell a value that was never
    // set from one this build no longer knows the name of - and the next settings change writes
    // the loss to disk. migrate() carries a file with a lower stamp forward.
    readonly property int currentConfigVersion: 3

    function setNestedValue(nestedKey, value) {
        let keys = nestedKey.split(".");
        let obj = root.options;
        let parents = [obj];

        // Traverse and collect parent objects
        for (let i = 0; i < keys.length - 1; ++i) {
            if (!obj[keys[i]] || typeof obj[keys[i]] !== "object") {
                obj[keys[i]] = {};
            }
            obj = obj[keys[i]];
            parents.push(obj);
        }

        // Convert value to correct type using JSON.parse when safe
        let convertedValue = value;
        if (typeof value === "string") {
            let trimmed = value.trim();
            if (trimmed === "true" || trimmed === "false" || !isNaN(Number(trimmed))) {
                try {
                    convertedValue = JSON.parse(trimmed);
                } catch (e) {
                    convertedValue = value;
                }
            }
        }

        obj[keys[keys.length - 1]] = convertedValue;
    }

    Timer {
        id: fileReloadTimer
        interval: root.readWriteDelay
        repeat: false
        onTriggered: {
            configFileView.reload()
        }
    }

    Timer {
        id: fileWriteTimer
        interval: root.readWriteDelay
        repeat: false
        onTriggered: {
            configFileView.writeAdapter()
        }
    }

    // A process that stores one answer and exits right after cannot use the timer: it is still
    // pending when Qt.quit() ends the event loop, and the answer is lost (killDialog.qml).
    // Values that named something the shell no longer has. Without this a corner, a keybind or a
    // toggle keeps pointing at a surface that was removed and silently does nothing.
    function migrate() {
        const from = root.options.configVersion;
        // v0 (no stamp at all): the left sidebar and its corner action were removed.
        if (from < 1 && root.options.sidebar.cornerOpen.bottomLeftAction === "sidebarLeftOpen")
            root.options.sidebar.cornerOpen.bottomLeftAction = "overviewOpen";
        // v2: the wallpaper is no longer blurred unless asked for (Settings > Wallpaper). Everyone who had it came
        // from the old default, and turned it off by editing this file (Discord, 2026-10-19/20)
        if (from < 2)
            root.options.background.showBlur = false;
        // v3: the apps' see-through follows Settings > Appearance (Tacit.windowSeeThrough). It never did: every app was
        // Frosted while Settings showed Solid, the default (Discord, 2026-10-20: "I'm choosing solid"). A Solid that
        // never worked becomes what was on screen, Frosted; Clear is kept.
        if (from < 3 && !root.options.appearance.transparency.enable) {
            root.options.appearance.transparency.enable = true;
            root.options.appearance.transparency.automatic = true;
        }
        if (from === root.currentConfigVersion) return;
        root.options.configVersion = root.currentConfigVersion;
        root.writeNow();
    }

    // The one way back from a key this build dropped or renamed. Once per start, on the first
    // clean read: the file reloads after every write, and a .bak refreshed each time would only
    // ever hold what the adapter had already rewritten.
    property bool backedUp: false
    function backupConfig() {
        if (root.backedUp) return;
        root.backedUp = true;
        Quickshell.execDetached(["cp", "-f", root.filePath, `${root.filePath}.bak`]);
    }

    function writeNow() {
        if (!root.loadedCleanly) return;
        fileWriteTimer.stop();
        configFileView.writeAdapter();
    }

    function markUnusable(reason, text) {
        root.unusableReason = reason;
        root.brokenText = text;
        backupCheck.running = false;
        backupCheck.running = true;
        root.reportUnusableConfig();
    }

    function markUsable() {
        root.unusableReason = "";
        root.reportedProblem = "";     // a later mistake is said again
        root.brokenText = "";
    }

    // The notice offers the last good copy (backupConfig takes it from a clean read only, so a broken file never
    // reaches it); Restore copies it back, which the file watch then reads.
    function reportUnusableConfig() {
        if (!root.reportsProblems || root.unusableReason === "") return;
        const problem = root.unusableReason + "\n" + root.brokenText;
        if (problem === root.reportedProblem) return;
        root.reportedProblem = problem;
        Quickshell.execDetached(["bash", "-c",
            'body="$1 has a mistake in it ($3), so Tacit is using its defaults and keeps nothing you change until it is fixed."; a=(); '
            + 'if jq empty "$2" 2>/dev/null; then body="$body The last good copy is next to it, config.json.bak."; a=(-A "restore=Restore the last good copy"); fi; '
            + 'r=$(notify-send -a Tacit "${a[@]}" "Your settings couldn\'t be read" "$body"); '
            + '[ "$r" = restore ] && jq empty "$2" 2>/dev/null && cp -f "$2" "$1"',
            "config-notice", root.filePath, root.backupPath, root.unusableReason]);
    }

    function restoreBackup() {
        Quickshell.execDetached(["bash", "-c", 'jq empty "$2" 2>/dev/null && cp -f "$2" "$1"', "config-restore", root.filePath, root.backupPath]);
    }

    Process {
        id: backupCheck
        command: ["jq", "empty", root.backupPath]
        onExited: exitCode => root.backupUsable = exitCode === 0
    }

    // The FileNotFound path writes the defaults into a directory Directories creates with a
    // detached mkdir, which cannot be relied on to have finished by the time the load fails.
    Process {
        id: configDirProc
        command: ["mkdir", "-p", Directories.shellConfig]
        onExited: {
            configFileView.writeAdapter();
            root.loadedCleanly = true;
            root.markUsable();
            root.ready = true;
        }
    }

    FileView {
        id: configFileView
        path: root.filePath
        watchChanges: true
        blockWrites: root.blockWrites
        onFileChanged: fileReloadTimer.restart()
        onAdapterUpdated: if (root.loadedCleanly) fileWriteTimer.restart()
        onLoaded: {
            // A JSON syntax error is not a load failure: the read succeeds, this fires, and the
            // JsonAdapter quietly keeps the compiled-in defaults ("Failed to deserialize json:"
            // in the log). The next property change would then serialise those defaults over
            // the file, so nothing writes until the file parses.
            let clean = false;
            try {
                JSON.parse(configFileView.text());
                clean = true;
            } catch (e) {
            }
            root.loadedCleanly = clean;
            root.ready = true;
            if (!clean) root.markUnusable("it isn't valid JSON", configFileView.text());
            else {
                root.markUsable();
                root.backupConfig();
                root.migrate();
            }
        }
        onLoadFailed: error => {
            if (error == FileViewError.FileNotFound) {
                configDirProc.running = true;
                return;
            }
            // Every surface is gated on ready, so the desktop still comes up on the defaults
            // rather than black - it just says so and leaves the file alone.
            root.ready = true;
            root.markUnusable(FileViewError.toString(error), "");
        }

        JsonAdapter {
            id: configOptionsJsonAdapter

            // 0 means a file written before versioning existed; see Config.currentConfigVersion.
            property int configVersion: 0

            property string panelFamily: "ii" // panelFamilies/ ships only "ii"


            property JsonObject appearance: JsonObject {
                property bool extraBackgroundTint: true
                property int fakeScreenRounding: 2 // 0: None | 1: Always | 2: When not fullscreen
                // Tacit's own type everywhere (the owner's, 2026-10-16); the defaults named fonts Tacit does not ship
                property JsonObject fonts: JsonObject {
                    property string main: "Tacit Sans"
                    property string numbers: "Tacit Sans"
                    property string title: "Tacit Sans"
                    property string iconNerd: "JetBrainsMono Nerd Font"
                    property string monospace: "Tacit Code"
                    property string reading: "Tacit Sans"
                    property string expressive: "Tacit Sans"
                }
                property JsonObject transparency: JsonObject {
                    // Frosted (Tacit.windowSeeThrough): the apps' glass as designed
                    property bool enable: true
                    property bool automatic: true
                    property real backgroundTransparency: 0.4
                    property real contentTransparency: 0.55
                }
                property JsonObject wallpaperTheming: JsonObject {
                    property bool enableAppsAndShell: true
                    property bool enableQtApps: true
                    property bool enableTerminal: true
                    property JsonObject terminalGenerationProps: JsonObject {
                        property real harmony: 0.6
                        property real harmonizeThreshold: 100
                        property real termFgBoost: 0.35
                        property bool forceDarkMode: false
                    }
                }
                property JsonObject palette: JsonObject {
                    // scheme-content: the owner's (2026-10-16), which Tacit's calm palette was made with from dusk.jpg
                    property string type: "scheme-content" // Allowed: auto, scheme-content, scheme-expressive, scheme-fidelity, scheme-fruit-salad, scheme-monochrome, scheme-neutral, scheme-rainbow, scheme-tonal-spot
                    property string accentColor: ""
                }
            }

            property JsonObject audio: JsonObject {
                // Values in %
                property JsonObject protection: JsonObject {
                    // Prevent sudden bangs
                    property bool enable: true
                    property real maxAllowedIncrease: 10
                    property real maxAllowed: 99
                }
            }

            property JsonObject profile: JsonObject {
                property string avatarPath: ""
                property string avatarPicture: ""
                property string descriptionText: "::distro::"
                property string displayName: ""
                property bool onlinePresets: false

            }

            property JsonObject hyprland: JsonObject {
                property JsonObject animations: JsonObject {
                    property string animation: "normal"
                    property bool enable: true
                }
                property JsonObject autostartApps: JsonObject {
                    property bool enable: false
                    property list<var> apps: []
                }
                property JsonObject decoration: JsonObject {
                    property int rounding: 22
                    property real activeOpacity: 1.0
                    property real inactiveOpacity: 0.82
                    property JsonObject blur: JsonObject {
                        property bool enabled: true
                        property int size: 10
                        property int passes: 3
                    }
                    // shadow.range was declared here and read nowhere; no page writes it either.
                    property JsonObject shadow: JsonObject {
                        property bool enabled: true
                    }
                }
                property JsonObject general: JsonObject {
                    property int borderSize: 1
                    property int gapsIn: 2
                    property int gapsOut: 5
                    property string layout: "dwindle"
                }
                property JsonObject input: JsonObject {
                    property string kbLayout: "us"
                    property bool numlock: true
                    property int repeatDelay: 250
                    property int repeatRate: 35
                    property int followMouse: 1
                    property real sensitivity: 0 // pointer speed, -1..1
                    property JsonObject touchpad: JsonObject {
                        property real speed: 0 // the touchpad's own speed, -1..1 (Settings writes it per touchpad)
                        property bool naturalScroll: true
                        property bool disableWhileTyping: true
                        property bool clickfingerBehavior: true
                        property real scrollFactor: 0.7
                        property bool tapToClick: true
                    }
                }
            }

            // bluetooth, network, manageUser, networkEthernet and volumeMixer were declared here
            // and read nowhere; they named kcmshell6 pages this desktop does not open.
            property JsonObject apps: JsonObject {
                property string changePassword: "foot --hold fish -i -c 'passwd'"
                property string taskManager: "activity-open"   // Tacit's Activity (was foot btop)
                property string terminal: "foot" // This is only for shell actions
                property string update: "foot --hold fish -i -c 'pkexec pacman -Syu'"
            }

            property JsonObject settings: JsonObject {
                property string style: "default" // default - minimal
                property real borderSize: 1
                property string borderColor: "primaryContainer"
            }

            property JsonObject background: JsonObject {
                property string lockWall: ""
                property bool widgetsLocked: false
                property bool showGrid: true
                property bool showBlur: false
                property string splitRatio: "100" // 25 50 100
                property string splitSide: "left"
                property bool showSnapLines: true
                property JsonObject widgets: JsonObject {
                    property bool blurWidgets: false
                    property real blurRadius: 32
                    property JsonObject clock: JsonObject {
                        // off, as on the owner's desktop (2026-10-16): a new account came up with a clock card on it
                        property bool enable: false
                        property bool showOnlyWhenLocked: false
                        property string placementStrategy: "leastBusy" // "free", "leastBusy", "mostBusy"
                        property real x: 100
                        property real y: 100
                        property string style: "cookie"        // Options: "cookie", "digital"
                        property string color: ""
                        property string styleLocked: "cookie"  // Options: "cookie", "digital"
                        property JsonObject cookie: JsonObject {
                            property bool aiStyling: false
                            property int sides: 14
                            property string dialNumberStyle: "full"   // Options: "dots" , "numbers", "full" , "none"
                            property string hourHandStyle: "fill"     // Options: "classic", "fill", "hollow", "hide"
                            property string minuteHandStyle: "medium" // Options "classic", "thin", "medium", "bold", "hide"
                            property string secondHandStyle: "dot"    // Options: "dot", "line", "classic", "hide"
                            property string dateStyle: "bubble"       // Options: "border", "rect", "bubble" , "hide"
                            property bool timeIndicators: true
                            property bool hourMarks: false
                            property bool constantlyRotate: false
                            property bool useSineCookie: false
                        }
                        property JsonObject digital: JsonObject {
                            property bool adaptiveAlignment: true
                            property bool showDate: true
                            property bool animateChange: true
                            property bool vertical: false
                            property JsonObject font: JsonObject {
                                property string family: "Rubik"
                                property real weight: 350
                                property real width: 100
                                property real size: 90
                                property real roundness: 0
                            }
                        }
                        property JsonObject pixel: JsonObject {
                            property string orientation: "vertical"
                        }
                        property JsonObject quote: JsonObject {
                            property bool enable: false
                            property string text: ""
                            property bool followClock: false
                        }
                    }
                    property JsonObject weather: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free" // "free", "leastBusy", "mostBusy"
                        property real x: 400
                        property real y: 100
                        property string sizeMode: "1x3"
                        property bool expanded: false
                    }

                    property JsonObject calendar: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free" // "free", "leastBusy", "mostBusy"
                        property real x: 400
                        property real y: 100
                        property string sizeMode: "2x2"
                    }
                    property JsonObject worldClock: JsonObject {
                        property bool enable: false
                        property list<string> timezones: ["Australia/Sydney", "Asia/Tokyo", "Europe/London", "America/New_York"]
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                        property string sizeMode: "2x2"
                        property int clockCount: 4 
                    }

                    property JsonObject notes: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                    }

                    property JsonObject todo: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                    }

                    property JsonObject userCard: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                        property string sizeMode: "1x2" 
                    }

                    property JsonObject images: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                    }

                    property JsonObject visualizer: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 0
                        property real y: 0
                    }

                    property JsonObject customImage: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                        property string path: ""
                        property string shape: "Cookie4Sided"
                        property real size: 200
                    }

                    property JsonObject resources: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                        property bool vertical: false
                    }

                    property JsonObject timers: JsonObject {
                        property bool enable: false
                        property string placementStrategy: "free"
                        property real x: 400
                        property real y: 100
                        property bool vertical: false
                    }

                    // showControls, showTitles and backgroundShape were declared here and read nowhere.
                    property JsonObject media: JsonObject {
                        property bool enable: false
                        property bool showLyrics: false
                        property string placementStrategy: "free" // "free", "leastBusy", "mostBusy"
                        property real x: 800
                        property real y: 500
                        property string sizeMode: "1x3" 
                    }
                }
                property list<string> screenList: [] 
                property string wallpaperPath: ""
                property bool centeredWallpaper: false
                property string centeredWallpaperShape: "Cookie7Sided"
                property int centeredWallpaperSize: 400
                property string centeredWallpaperColor: "primaryContainer"
                property bool centeredWallpaperOnlyWhenLocked: false
                property string wallpaperAnimation: "magic"
                property bool enableWallpaperPreview: false
                property string thumbnailPath: ""
                property bool hideWhenFullscreen: true
                // background.parallax.* was declared here and read nowhere - the whole feature
                // it described was never implemented.
            }

            property JsonObject bar: JsonObject {
                // Off: the notch replaced the bar (panelFamilies/IllogicalImpulseFamily.qml).
                property bool enable: false
                property JsonObject autoHide: JsonObject {
                    property bool enable: false
                    property int hoverRegionWidth: 2
                    property bool pushWindows: false
                    property JsonObject showWhenPressingSuper: JsonObject {
                        property bool enable: true
                        property int delay: 140
                    }
                }
                property bool showFrame: false
                property real frameThickness: 4
                property string frameColor: "black"
                property bool followFrameColor: false
                property bool bottom: false // Instead of top
                property int cornerStyle: 0 // 0: Hug | 1: Float | 2: Plain rectangle
                property string groupColor: "layer1"
                // floatStyleShadow and topLeftIcon were declared here and read nowhere.
                property string borderless: "pills"
                property bool showBackground: true
                property bool verbose: true
                property bool vertical: false
                property JsonObject resources: JsonObject {
                    property string style: "filled"
                    property bool showValue: false
                    property bool alwaysShowSwap: false
                    property bool alwaysShowCpu: true
                    property bool alwaysShowCpuTemp: false
                    property bool alwaysShowDisk: false
                    property bool alwaysShowRam: true
                    property int memoryWarningThreshold: 95
                    property int swapWarningThreshold: 85
                    property int cpuWarningThreshold: 90
                }
                property JsonObject divider: JsonObject {
                    property string style: "rect" // rect - dot - space
                    property int spacing: 20
                }

                property JsonObject layouts: JsonObject {
                    property list<string> leftLayout: ["launcherButton", "workspaces", "activeWindow"]
                    property list<string> middleLayout: ["clockWidget"]
                    property list<string> rightLayout: ["sysTray", "utilButtons", "systemIcons", "powerButton"]
                }
                
                property list<string> screenList: [] // List of names, like "eDP-1", find out with 'hyprctl monitors' command
                property JsonObject utilButtons: JsonObject {
                    property bool showScreenSnip: true
                    property bool showColorPicker: true
                    property bool showMicToggle: false
                    property bool showKeyboardToggle: false
                    property bool showWallpaperToggle: true
                    property bool showDarkModeToggle: false
                    property bool showPerformanceProfileToggle: false
                    property bool showScreenRecord: false       
                }

                property JsonObject workspaces: JsonObject {
                    property bool monochromeIcons: true
                    property int shown: 10
                    property bool showAppIcons: false
                    property string indicatorStyle: "dot" // "dot" or "icon"
                    property bool alwaysShowNumbers: true
                    property list<string> numberMap: ["1", "2"] // Characters to show instead of numbers on workspace indicator
                    property bool useNerdFont: false
                }
                property JsonObject weather: JsonObject {
                    property bool enableGPS: true // gps based location
                    property string city: "" // When 'enableGPS' is false
                    property bool useUSCS: false // Instead of metric (SI) units
                    property int fetchInterval: 10 // minutes
                    // Your own OpenWeather key (free tier). Empty = weather stays off; no
                    // credential ships with the desktop. openweathermap.org/api
                    property string apiKey: ""
                }
                property JsonObject indicators: JsonObject {
                    property JsonObject notifications: JsonObject {
                        property bool showUnreadCount: false
                    }
                }
                property JsonObject tooltips: JsonObject {
                    property bool clickToShow: false
                }
                property JsonObject media: JsonObject {
                    property string preferredPlayer: ""
                    property bool alwaysVisible: false
                    property bool onlyTitle: false
                    property int maxWidth: 280
                    property int minWidth: 100
                }
            }

            property JsonObject island: JsonObject {
                property bool enable: true
                // The island replaces the clock, not the bar: the tray, workspaces, window title
                // and power button still live there. Set true to run the island alone.
                property bool hideBar: true
                property int reservedHeight: 38
                property int topMargin: 0
                property list<string> screenList: [] // List of names, like "eDP-1", find out with 'hyprctl monitors' command
                property int notificationQueueDepth: 3
                property bool hoverExpand: true
                // boring.notch hideNotchOption = nowPlayingOnly: stay visible over a fullscreen
                // window only while something plays (Overlay layer), hide otherwise.
                property bool showInFullscreenWhilePlaying: true
                property JsonObject media: JsonObject {
                    property bool enable: true
                    property int keepPausedMinutes: 5 // a paused player stays in the sheet this long
                    property bool keepWhenPaused: true
                    property bool waveform: true
                }
                // Repos watched for uncommitted work (plus every Claude session's folder): a quiet
                // glyph once changes have sat for unsavedAfterMinutes, and a line on the session menu.
                property list<string> unsavedRepos: []
                property int unsavedAfterMinutes: 60
                // Pull requests watched (owner/name): merged, failing checks, review requested
                // peek once each and go into the day record. Needs `gh auth login`.
                property list<string> prRepos: []
                property JsonObject greeting: JsonObject {
                    property bool enable: true
                    // Empty falls through to profile.displayName, and then to no name at all.
                    property string name: ""
                }
                property JsonObject states: JsonObject {
                    property bool notification: false
                    property bool volume: true
                    property bool brightness: true
                    property bool power: true
                    property bool network: true
                    property bool workspace: true
                    property bool focus: true
                    property bool activity: true // long jobs pushed in over IPC
                    property bool download: true // a new file in ~/Downloads peeks and is parked on the shelf
                }
                property JsonObject hold: JsonObject { // milliseconds
                    property int greeting: 4200
                    property int power: 2600
                    property int battery: 4000
                    property int meter: 1300
                    property int notification: 4000
                    property int network: 2400
                    property int workspace: 750
                    property int timerDone: 3500
                    // A running activity holds this long, then demotes itself into the ambient
                    // glyph slot and keeps tracking there.
                    property int activity: 30000
                    property int activityDone: 2000
                    property int activityFail: 4000
                    property int download: 3000
                }
            }

            // commandPalette.enable and .topMargin were declared here and read nowhere.
            property JsonObject commandPalette: JsonObject {
                property int width: 720
                property int maxListHeight: 468
                property int resultLimit: 40
                property bool showSectionHeaders: true
                property bool showFooter: true
                // Open windows rank ABOVE the app that would launch a second copy.
                property JsonObject emptyState: JsonObject {
                    property int windows: 6   // rows shown with an empty query
                    property int apps: 6
                }
                // score = count * 0.5^(days / halfLifeDays); a boost, never a reordering
                // of sections, so it cannot beat the window-over-app rule.
                property JsonObject frecency: JsonObject {
                    property bool enable: true
                    property int halfLifeDays: 7
                    property int boost: 2
                    property int boostCap: 8   // most places an app may climb
                    property int maxEntries: 200
                }
                property JsonObject files: JsonObject {
                    property bool enable: true
                    property string root: "" // Empty means $HOME
                    property int maxDepth: 6
                    property int limit: 20
                    property list<string> excludeDirs: [".git", "node_modules", ".cache"]
                }
                // One switch per section id in PaletteSearch.sections; an undeclared key reads as
                // on there, which is how six of these were permanently on with no way to stop them.
                property JsonObject sections: JsonObject {
                    property bool apps: true
                    property bool files: true
                    property bool calculator: true
                    property bool clipboard: true
                    property bool emoji: true
                    property bool system: true
                    property bool keybinds: true
                    property bool settings: true
                    property bool windows: true
                    property bool symbols: true
                    property bool actions: true
                    property bool flow: true
                    property bool command: true
                    property bool claude: true
                    property bool web: true
                }
            }

            property JsonObject battery: JsonObject {
                property int low: 20
                property int critical: 5
                property int full: 101
                property bool automaticSuspend: false
                property int suspend: 3
            }

            property JsonObject bluetooth: JsonObject {
                // Nearby phones and watches broadcast a random address that rotates every
                // few minutes and carries no name, so they arrive as "46-95-74-23-1C-E0".
                // They can never be identified or usefully paired from that list entry.
                // Connected and paired devices are always shown regardless of this.
                property bool hideUnnamedDevices: false
            }

            property JsonObject conflictKiller: JsonObject {
                property bool autoKillNotificationDaemons: false
                property bool autoKillTrays: false
            }

            property JsonObject crosshair: JsonObject {
                // Valorant crosshair format. Use https://www.vcrdb.net/builder
                property string code: "0;P;d;1;0l;10;0o;2;1b;0"
            }

            property JsonObject dock: JsonObject {
                property bool enable: false
                property bool showBackground: true
                property bool showPinButton: true
                property bool showAppsButton: true
                property bool showMedia: true
                property bool monochromeIcons: true
                property real height: 60
                property real hoverRegionHeight: 2
                property bool pinnedOnStartup: false
                property bool hoverToReveal: true // When false, only reveals on empty workspace
                // Tacit's own apps, all shipped by its packages, in the owner's order (2026-10-16): Praxis, Files,
                // the terminal, Thyris, Graphis, Settings. A default naming apps it does not ship shows broken icons.
                property list<string> pinnedApps: ["praxis", "org.quickshell", "foot", "thyris", "graphis", "settings"] // IDs of pinned entries
                property list<string> ignoredAppRegexes: []
            }

            property JsonObject interactions: JsonObject {
                property JsonObject scrolling: JsonObject {
                    property bool fasterTouchpadScroll: false // Enable faster scrolling with touchpad
                    property int mouseScrollDeltaThreshold: 120 // delta >= this then it gets detected as mouse scroll rather than touchpad
                    property int mouseScrollFactor: 120
                    property int touchpadScrollFactor: 450
                }
                property JsonObject deadPixelWorkaround: JsonObject { // Hyprland leaves out 1 pixel on the right for interactions
                    property bool enable: false
                }
            }

            property JsonObject language: JsonObject {
                property string ui: "auto" // UI language. "auto" for system locale, or specific language code like "zh_CN", "en_US"
            }

            property JsonObject launcher: JsonObject {
                property list<string> pinnedApps: []
            }

            property JsonObject light: JsonObject {
                property JsonObject night: JsonObject {
                    property bool automatic: false
                    property string from: "19:00" // Format: "HH:mm", 24-hour time
                    property string to: "06:30"   // Format: "HH:mm", 24-hour time
                    property int colorTemperature: 5800
                }
                property JsonObject antiFlashbang: JsonObject {
                    property bool enable: false
                }
            }

            property JsonObject lock: JsonObject {
                property bool useHyprlock: false
                property bool launchOnStartup: false
                property bool showWidgets: false
                property bool showMedia: true
                property JsonObject blur: JsonObject {
                    property bool enable: true
                    property real radius: 100
                    property real extraZoom: 1.1
                    property int size: 20
                }
                property bool centerClock: true
                property bool showLockedText: true
                property JsonObject security: JsonObject {
                    property bool unlockKeyring: true
                    property bool requirePasswordToPower: false
                }
                property bool materialShapeChars: true
            }

            property JsonObject media: JsonObject {
                // Attempt to remove dupes (the aggregator playerctl one and browsers' native ones when there's plasma browser integration)
                property bool filterDuplicatePlayers: true
            }

            property JsonObject networking: JsonObject {
                property string userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"
            }

            property JsonObject notifications: JsonObject {
                property int timeout: 7000
                property string position: "top_right"
            }

            property JsonObject osd: JsonObject {
                property int timeout: 1000
            }

            property JsonObject osk: JsonObject {
                // A key of modules/ii/onScreenKeyboard/layouts.js; anything else falls back to it
                property string layout: "English (US)"
                property bool pinnedOnStartup: false
            }

            property JsonObject overlay: JsonObject {
                property bool openingZoomAnimation: true
                property bool darkenScreen: true
                property real clickthroughOpacity: 0.8
                property JsonObject floatingImage: JsonObject {
                    property string imageSource: ""   // was end-4's tenor GIF (sweep D12 a)
                    property real scale: 0.5
                }
            }

            property JsonObject overview: JsonObject {
                property bool enable: true
                property string style: "default"
                property real scale: 0.18 // Relative to screen size
                property real rows: 2
                property real columns: 5
                property bool orderRightLeft: false
                property bool orderBottomUp: false
                property bool centerIcons: true
            }

            property JsonObject regionSelector: JsonObject {
                property JsonObject targetRegions: JsonObject {
                    property bool windows: true
                    property bool layers: false
                    property bool content: true
                    property bool showLabel: false
                    property real opacity: 0.3
                    property real contentRegionOpacity: 0.8
                    property int selectionPadding: 5
                }
                property JsonObject rect: JsonObject {
                    property bool showAimLines: true
                }
                property JsonObject circle: JsonObject {
                    property int strokeWidth: 6
                    property int padding: 10
                }
                property JsonObject annotation: JsonObject {
                    property bool useSatty: false
                }
            }

            property JsonObject resources: JsonObject {
                property int updateInterval: 3000
                property int historyLength: 60
            }

            property JsonObject tray: JsonObject {
                property bool monochromeIcons: true
                property bool showItemId: false
                property bool invertPinnedItems: true // Makes the below a whitelist for the tray and blacklist for the pinned area
                property list<var> pinnedItems: [ "Fcitx" ]
                property bool filterPassive: true
            }

            property JsonObject musicRecognition: JsonObject {
                property int timeout: 16
                property int interval: 4
            }

            property JsonObject search: JsonObject {
                property int nonAppResultDelay: 30 // This prevents lagging when typing
                property string engineBaseUrl: "https://www.google.com/search?q="
                property list<string> excludedSites: ["quora.com", "facebook.com"]
                property bool sloppy: false // Uses levenshtein distance based scoring instead of fuzzy sort. Very weird.
                property JsonObject prefix: JsonObject {
                    property bool showDefaultActionsWithoutPrefix: true
                    property string action: "/"
                    property string app: ">"
                    property string clipboard: ";"
                    property string dictation: "'"    // Flow's past dictations
                    property string emojis: ":"
                    property string files: "~"
                    property string keybinds: "<"
                    property string symbols: "."
                    property string math: "="
                    property string shellCommand: "$"
                    property string webSearch: "?"
                    property string windows: "@"
                }
                property JsonObject imageSearch: JsonObject {
                    property string imageSearchEngineBaseUrl: "https://lens.google.com/uploadbyurl?url="
                    property bool useCircleSelection: false
                }
            }

            property JsonObject sidebar: JsonObject {
                property bool banner: false
                property bool bottomGroup: true
                property bool keepRightSidebarLoaded: true
                
                property JsonObject cornerOpen: JsonObject {
                    property bool enable: true
                    property bool bottom: true
                    property bool valueScroll: true
                    property bool clickless: false
                    property int cornerRegionWidth: 250
                    property int cornerRegionHeight: 5
                    property string bottomLeftAction: "overviewOpen"
                    property string bottomRightAction: "sidebarRightOpen"
                    property bool visualize: false
                    property bool clicklessCornerEnd: true
                    property int clicklessCornerVerticalOffset: 1
                }
            }

            // custom.distroIcon was declared here and read nowhere; SystemInfo picks the icon.
            property JsonObject custom: JsonObject {
                property bool colorizeIcon: true
            }

            property JsonObject screenRecord: JsonObject {
                property string savePath: Directories.videos.replace("file://","") // strip "file://"
            }

            property JsonObject screenSnip: JsonObject {
                property string savePath: Directories.pictures.replace("file://", "") + "/Screenshots" // only copy to clipboard when empty
            }

            property JsonObject sounds: JsonObject {
                property bool battery: true
                property bool pomodoro: false
                property string theme: "freedesktop"
            }

            property JsonObject time: JsonObject {
                // https://doc.qt.io/qt-6/qtime.html#toString
                property string format: "hh:mm"
                property bool showDate: true
                property string shortDateFormat: "dd/MM"
                property string dateWithYearFormat: "dd/MM/yyyy"
                property string dateFormat: "ddd, dd/MM"
                property JsonObject pomodoro: JsonObject {
                    property int breakTime: 300
                    property int cyclesBeforeLongBreak: 4
                    property int focus: 1500
                    property int longBreak: 900
                }
                property bool secondPrecision: false
            }

            property JsonObject updates: JsonObject {
                // the notch says once when updates are downloaded (Updates.qml); on, as a Mac's is
                property bool enableCheck: true
                property int checkInterval: 120 // minutes
                property int adviseUpdateThreshold: 75 // packages
                property int stronglyAdviseUpdateThreshold: 200 // packages
            }
            
            property JsonObject wallpaperSelector: JsonObject {
                property bool useSystemFileDialog: false
                property bool showBlurBackground: false
                property bool showHomePath: true
                property string userPath: "" // This can be set to any path and it will show up as a quick access in the wallpaper selector"
                property string liveWallpapersPath: ""
                property bool showSearchbar: true
                property int columns: 4
                property bool closeAfterSelection: true
                property int changeInterval: 0 
            }

            property JsonObject windows: JsonObject {
                property bool showTitlebar: true // Client-side decoration for shell apps
                property bool centerTitle: true
            }

            property JsonObject hacks: JsonObject {
                property int arbitraryRaceConditionDelay: 20 // milliseconds
            }

            property JsonObject workSafety: JsonObject {
                property JsonObject enable: JsonObject {
                    property bool wallpaper: false
                    property bool clipboard: false
                }
                property JsonObject triggerCondition: JsonObject {
                    property list<string> networkNameKeywords: ["airport", "cafe", "college", "company", "eduroam", "free", "guest", "public", "school", "university"]
                    property list<string> fileKeywords: ["anime", "booru", "ecchi", "hentai", "yande.re", "konachan", "breast", "nipples", "pussy", "nsfw", "spoiler", "girl"]
                    property list<string> linkKeywords: ["hentai", "porn", "sukebei", "hitomi.la", "rule34", "gelbooru", "fanbox", "dlsite"]
                }
            }
        }
    }
}
