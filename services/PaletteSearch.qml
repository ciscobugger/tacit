pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Sectioned search model for the command palette.
 *
 * The palette needs its sources grouped into labelled sections with a per-section prefix.
 * Everything that can be reused is reused (AppSearch, Cliphist, Emojis, MaterialSymbolsSearch,
 * HyprlandKeybinds, SettingsPages, LauncherSearch.allActions); only the grouping and the qalc
 * call live here.
 */
Singleton {
    id: root

    property string query: ""

    // ---------------------------------------------------------------- prefixes
    readonly property string pfxMath: Config.options.search.prefix.math
    readonly property string pfxApp: Config.options.search.prefix.app
    readonly property string pfxFiles: Config.options.search.prefix.files ?? "~"
    readonly property string pfxClipboard: Config.options.search.prefix.clipboard
    readonly property string pfxDictation: Config.options.search.prefix.dictation ?? "'"
    readonly property string pfxEmojis: Config.options.search.prefix.emojis
    readonly property string pfxSymbols: Config.options.search.prefix.symbols
    readonly property string pfxKeybinds: Config.options.search.prefix.keybinds ?? "<"
    readonly property string pfxWindows: Config.options.search.prefix.windows ?? "@"
    readonly property string pfxAction: Config.options.search.prefix.action
    readonly property string pfxCommand: Config.options.search.prefix.shellCommand
    readonly property string pfxWeb: Config.options.search.prefix.webSearch

    readonly property var sectionForPrefix: {
        const map = {};
        map[root.pfxMath] = "calculator";
        map[root.pfxApp] = "apps";
        map[root.pfxFiles] = "files";
        map[root.pfxClipboard] = "clipboard";
        map[root.pfxDictation] = "flow";
        map[root.pfxEmojis] = "emoji";
        map[root.pfxSymbols] = "symbols";
        map[root.pfxKeybinds] = "keybinds";
        map[root.pfxWindows] = "windows";
        map[root.pfxAction] = "actions";
        map[root.pfxCommand] = "command";
        map[root.pfxWeb] = "web";
        return map;
    }

    readonly property var sectionTitles: ({
            calculator: Translation.tr("Calculator"),
            windows: PaletteWindows.sectionTitle,
            apps: Translation.tr("Applications"),
            projects: PaletteApps.projectsTitle,
            sessions: PaletteApps.sessionsTitle,
            places: PaletteApps.placesTitle,
            files: Translation.tr("Files"),
            system: Translation.tr("System"),
            settings: Translation.tr("Settings"),
            clipboard: Translation.tr("Clipboard"),
            flow: Translation.tr("Flow"),
            emoji: Translation.tr("Emoji"),
            symbols: Translation.tr("Symbols"),
            keybinds: Translation.tr("Keybinds"),
            actions: Translation.tr("Actions"),
            command: Translation.tr("Command"),
            claude: Translation.tr("Claude"),
            web: Translation.tr("Web"),
            recent: Translation.tr("Recent")
        })

    function prefixOf(q) {
        if (!q || q.length === 0)
            return "";
        const first = q.charAt(0);
        return root.sectionForPrefix[first] !== undefined ? first : "";
    }

    function bodyOf(q) {
        const prefix = root.prefixOf(q);
        return prefix.length > 0 ? q.slice(prefix.length) : q;
    }

    readonly property string activePrefix: root.prefixOf(root.query)
    readonly property string activeSection: root.activePrefix.length > 0 ? root.sectionForPrefix[root.activePrefix] : ""
    readonly property string activeSectionTitle: root.activeSection.length > 0 ? root.sectionTitles[root.activeSection] : ""
    readonly property string body: root.bodyOf(root.query)

    // ------------------------------------------------------------ section gates
    /**
     * On screen, i.e. worth building anything at all.
     *
     * Every section binding checks this FIRST, so when the palette is down each one is left
     * depending on this one property and nothing else. Without it the sections stayed bound
     * to the live Wi-Fi strength, the Bluetooth device count, the power profile and the
     * clipboard, and rebuilt the whole result tree in the background all session.
     */
    readonly property bool live: GlobalStates.overviewOpen || GlobalStates.searchOpen

    readonly property var sectionConfig: Config.options.commandPalette?.sections ?? null
    function sectionEnabled(key) {
        if (root.sectionConfig === null)
            return true;
        const value = root.sectionConfig[key];
        return value === undefined ? true : value;
    }

    readonly property int resultLimit: Config.options.commandPalette?.resultLimit ?? 40
    // Without a prefix every section is on screen at once, so keep each one short.
    readonly property int sectionLimit: root.activePrefix.length > 0 ? root.resultLimit : 8
    // With nothing typed the palette leads with what is already running and what is
    // actually used; keep both lists short so the System rows stay reachable.
    readonly property int emptyWindowLimit: Math.max(0, Config.options.commandPalette?.emptyState?.windows ?? 6)
    readonly property int emptyAppLimit: Math.max(0, Config.options.commandPalette?.emptyState?.apps ?? 6)

    function wants(key) {
        if (!root.live)
            return false;
        if (root.query.length === 0)
            return false;
        if (root.activeSection.length > 0)
            return root.activeSection === key && root.sectionEnabled(key);
        return root.sectionEnabled(key);
    }

    // ---------------------------------------------------------------- qalc
    // The same binary and flags the launcher used, run from here: the calculation belongs to the
    // section that shows it.
    property string mathResult: ""
    property bool mathError: false
    property bool mathPending: false

    readonly property bool calculatorWanted: {
        if (!root.live)
            return false;
        if (root.query.length === 0 || !root.sectionEnabled("calculator"))
            return false;
        if (root.activeSection.length > 0)
            return root.activeSection === "calculator";
        return /^\d/.test(root.query);
    }

    onQueryChanged: {
        const prefix = root.prefixOf(root.query);
        const section = prefix.length > 0 ? root.sectionForPrefix[prefix] : "";
        const trimmedBody = prefix.length > 0 ? root.query.slice(prefix.length) : root.query;

        const filesWanted = root.sectionEnabled("files") && (section === "" || section === "files");
        PaletteFiles.setQuery(filesWanted ? trimmedBody : "");

        const mathWanted = root.sectionEnabled("calculator") && (section === "calculator" || (section === "" && /^\d/.test(root.query)));
        if (mathWanted) {
            root.mathError = false;
            root.mathPending = true;
            mathTimer.restart();
        } else {
            mathTimer.stop();
            root.mathPending = false;
            root.mathResult = "";
            root.mathError = false;
        }
    }

    Timer {
        id: mathTimer
        interval: Config.options.search.nonAppResultDelay
        repeat: false
        onTriggered: mathProc.calculateExpression(root.body)
    }

    Process {
        id: mathProc
        property list<string> baseCommand: ["qalc", "-t"]
        property string buffer: ""
        // The expression waiting for a terminated run to be reaped, or null.
        property var queued: null

        function calculateExpression(expression) {
            // A terminated run still emits exited, and that handler would then publish the
            // NEW run's buffer - empty at that moment, which reads as "not a valid
            // expression" on a sum that is perfectly valid. Queue behind it instead.
            if (mathProc.running) {
                mathProc.queued = expression;
                mathProc.running = false;
                return;
            }
            mathProc.queued = null;
            mathProc.buffer = "";
            // qalc reads "12 % of 349" as a remainder; say it the way it understands
            const percentOf = /^\s*([\d.,]+)\s*%\s*of\s+(.+)$/i.exec(expression);
            if (percentOf)
                expression = `(${percentOf[2]}) * ${percentOf[1]}%`;
            mathProc.command = mathProc.baseCommand.concat(expression);
            mathProc.running = true;
        }

        stdout: SplitParser {
            onRead: data => {
                mathProc.buffer = data;
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (mathProc.queued !== null) {
                // callLater, so `running` is settled before the next run starts.
                const next = mathProc.queued;
                mathProc.queued = null;
                Qt.callLater(() => mathProc.calculateExpression(next));
                return;
            }
            root.mathPending = false;
            root.mathResult = mathProc.buffer;
            root.mathError = exitCode !== 0 || mathProc.buffer.length === 0 || /^error/i.test(mathProc.buffer);
        }
    }

    readonly property bool busy: root.mathPending || PaletteFiles.running

    // ------------------------------------------------------------- section data
    readonly property list<var> calculatorEntries: {
        if (!root.calculatorWanted || root.mathError || root.mathResult.length === 0)
            return [];
        const value = root.mathResult;
        return [resultComp.createObject(null, {
                name: value,
                comment: root.body,
                type: root.sectionTitles.calculator,
                verb: Translation.tr("Copy"),
                fontType: LauncherSearchResult.FontType.Monospace,
                iconName: "calculate",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    Quickshell.clipboardText = value;
                }
            })];
    }

    /**
     * Open windows. Same shape as the System section: PaletteWindows hands back
     * ready-made results, this only decides when to ask for them. With nothing typed
     * the whole (capped) list comes back, which is what the palette now opens on.
     */
    readonly property list<var> windowEntries: {
        if (!root.live)
            return [];
        if (!root.sectionEnabled("windows"))
            return [];
        if (root.query.length === 0)
            return PaletteWindows.fuzzyQuery("").slice(0, root.emptyWindowLimit);
        if (!root.wants("windows"))
            return [];
        if (root.activeSection === "" && root.body.trim().length === 0)
            return [];
        return PaletteWindows.fuzzyQuery(root.body).slice(0, root.sectionLimit);
    }

    /** DesktopEntries behind the top of the frecency table, for the untyped palette. */
    readonly property var frecentApps: {
        if (!root.live)
            return [];
        const out = [];
        for (const key of PaletteFrecency.topKeys(root.emptyAppLimit * 4)) {
            if (key.indexOf("app:") !== 0)
                continue;
            const app = AppSearch.list.find(candidate => candidate.id === key.slice(4));
            if (app)
                out.push(app);
            if (out.length >= root.emptyAppLimit)
                break;
        }
        return out;
    }

    /**
     * The DesktopEntries the apps section is built from.
     *
     * AppSearch.fuzzyQuery already returns everything sorted by match quality;
     * PaletteFrecency.reorder only lets a used app climb a bounded number of places
     * inside that order, so it is a tiebreaker and never beats a much better match -
     * and because the whole Windows section sits above this one, it can never float
     * a launcher above a window that is already open.
     */
    readonly property var appMatches: {
        if (!root.live)
            return [];
        if (!root.sectionEnabled("apps"))
            return [];
        if (root.query.length === 0)
            return root.frecentApps;
        if (!root.wants("apps"))
            return [];
        if (root.activeSection === "" && root.body.trim().length === 0)
            return [];
        // Nothing below sectionLimit + boostCap can climb into view, so only sort that much.
        const head = AppSearch.fuzzyQuery(root.body).slice(0, root.sectionLimit + Math.ceil(PaletteFrecency.boostCap));
        return PaletteFrecency.reorder(head, app => `app:${app.id}`).slice(0, root.sectionLimit);
    }

    // An app installed twice, natively and as a Flatpak (LibreOffice, Chrome, GIMP here), is one row: the native one.
    // Two different apps that only share a name ("Text Editor") both stay.
    function isFlatpak(e) { return (e.command ?? []).join(" ").includes("flatpak run") || /\/flatpak\//.test(e.execString ?? ""); }
    readonly property var appMatchesOnce: {
        const natives = {};
        for (const e of root.appMatches) if (!root.isFlatpak(e)) natives[root.fold(e.name)] = true;
        return root.appMatches.filter(e => !(root.isFlatpak(e) && natives[root.fold(e.name)]));
    }
    readonly property list<var> appEntries: {
        return root.appMatchesOnce.map(entry => resultComp.createObject(null, {
            type: root.sectionTitles.apps,
            id: entry.id,
            name: entry.name,
            comment: entry.comment,
            iconName: entry.icon,
            iconType: LauncherSearchResult.IconType.System,
            verb: Translation.tr("Open"),
            runInTerminal: entry.runInTerminal,
            genericName: entry.genericName,
            keywords: entry.keywords,
            execute: () => {
                PaletteFrecency.record(`app:${entry.id}`);
                if (!entry.runInTerminal)
                    AppScope.launch(entry);
                else
                    Quickshell.execDetached(["bash", "-c", `${Config.options.apps.terminal} -e '${StringUtils.shellSingleQuoteEscape(entry.command.join(" "))}'`]);
            },
            actions: entry.actions.map(action => resultComp.createObject(null, {
                name: action.name,
                iconName: action.icon,
                iconType: LauncherSearchResult.IconType.System,
                execute: () => {
                    PaletteFrecency.record(`app:${entry.id}`);
                    if (!action.runInTerminal)
                        AppScope.launch(action);
                    else
                        Quickshell.execDetached(["bash", "-c", `${Config.options.apps.terminal} -e '${StringUtils.shellSingleQuoteEscape(action.command.join(" "))}'`]);
                }
            }))
        }));
    }

    readonly property list<var> systemEntries: {
        if (!root.live)
            return [];
        if (!root.sectionEnabled("system") || root.activeSection.length > 0)
            return [];
        // Nothing wraps execute here any more: reading entry.execute and then writing it back
        // made this binding depend on a property it also set, which is a binding loop, and the
        // wrapper had nothing left in it once frecency stopped recording system actions.
        return PaletteSystemActions.fuzzyQuery(root.query);
    }

    // The desktop's own apps: the projects Graphis remembers, the sessions running now, the
    // places Pinax keeps. Typed only - an untyped palette still leads with windows and apps.
    readonly property list<var> projectEntries: {
        if (!root.wants("projects"))
            return [];
        return PaletteApps.projectQuery(root.body, root.sectionLimit);
    }

    readonly property list<var> sessionEntries: {
        if (!root.wants("sessions"))
            return [];
        return PaletteApps.sessionQuery(root.body, root.sectionLimit);
    }

    readonly property list<var> placeEntries: {
        if (!root.wants("places"))
            return [];
        return PaletteApps.placeQuery(root.body, root.sectionLimit);
    }

    readonly property list<var> settingsEntries: {
        if (!root.live)
            return [];
        if (!root.sectionEnabled("settings") || root.activeSection.length > 0)
            return [];
        const needle = root.query.toLowerCase().trim();
        if (needle.length === 0)
            return [];
        // The Settings app's own page list (SettingsCatalog), so a result always names a page the
        // app has; a page answers to its name and to the names of the settings on it.
        return SettingsCatalog.categories.reduce((acc, page) => {
            const byName = page.name.toLowerCase().includes(needle);
            if (byName || `${page.note} ${page.words ?? ""}`.toLowerCase().includes(needle)) {
                acc.push(resultComp.createObject(null, {
                    name: page.name,
                    comment: byName ? page.note : Translation.tr("Has %1").arg(needle),
                    type: root.sectionTitles.settings,
                    verb: Translation.tr("Go"),
                    iconName: page.glyph,
                    iconType: LauncherSearchResult.IconType.Material,
                    execute: () => SettingsApp.open(page.key)
                }));
            }
            return acc;
        }, []);
    }

    readonly property list<var> fileEntries: {
        if (!root.wants("files"))
            return [];
        return PaletteFiles.results;
    }

    readonly property list<var> clipboardEntries: {
        if (!root.wants("clipboard") || root.activeSection !== "clipboard")
            return [];
        return Cliphist.fuzzyQuery(root.body).slice(0, root.sectionLimit).map((entry, index, array) => {
            const mightBlurImage = Cliphist.entryIsImage(entry) && LauncherSearch.clipboardWorkSafetyActive;
            const shouldBlurImage = mightBlurImage && (LauncherSearch.containsUnsafeLink(array[index - 1]) || LauncherSearch.containsUnsafeLink(array[index + 1]));
            return resultComp.createObject(null, {
                rawValue: entry,
                name: StringUtils.cleanCliphistEntry(entry),
                type: root.sectionTitles.clipboard,
                verb: Translation.tr("Copy"),
                blurImage: shouldBlurImage,
                execute: () => {
                    Cliphist.copy(entry);
                },
                actions: [resultComp.createObject(null, {
                        name: Translation.tr("Copy"),
                        iconName: "content_copy",
                        iconType: LauncherSearchResult.IconType.Material,
                        execute: () => {
                            Cliphist.copy(entry);
                        }
                    }), resultComp.createObject(null, {
                        name: Translation.tr("Delete"),
                        iconName: "delete",
                        iconType: LauncherSearchResult.IconType.Material,
                        execute: () => {
                            Cliphist.deleteEntry(entry);
                        }
                    })]
            });
        });
    }

    // Flow's past dictations, newest first: Enter types one where the cursor was (flowd waits for
    // the palette to close, and a terminal gets the same care as a live dictation)
    readonly property list<var> dictationEntries: {
        if (!root.wants("flow") || root.activeSection !== "flow")
            return [];
        const needle = root.body.trim().toLowerCase();
        const today = new Date().toDateString();
        return Dictation.history().filter(d => (d.text ?? "").toLowerCase().includes(needle)).slice(0, root.sectionLimit).map(d => {
            const when = new Date(d.t);
            return resultComp.createObject(null, {
                rawValue: d.text,
                name: d.text.replace(/\s*\n\s*/g, " "),
                comment: `${when.toDateString() === today ? "" : Qt.formatDate(when, "d MMM") + " "}${Qt.formatTime(when, "HH:mm")}${d.app ? " · " + d.app : ""}`,
                type: root.sectionTitles.flow,
                verb: Translation.tr("Type"),
                execute: () => {
                    Dictation.insert(d.text);
                },
                actions: [resultComp.createObject(null, {
                        name: Translation.tr("Copy"),
                        iconName: "content_copy",
                        iconType: LauncherSearchResult.IconType.Material,
                        execute: () => {
                            Quickshell.clipboardText = d.text;
                        }
                    })]
            });
        });
    }

    readonly property list<var> emojiEntries: {
        if (!root.wants("emoji") || root.activeSection !== "emoji")
            return [];
        return Emojis.fuzzyQuery(root.body).slice(0, root.sectionLimit).map(entry => {
            const glyph = entry.match(/^\s*(\S+)/)?.[1] ?? "";
            return resultComp.createObject(null, {
                rawValue: entry,
                name: entry.replace(/^\s*\S+\s+/, ""),
                type: root.sectionTitles.emoji,
                verb: Translation.tr("Copy"),
                iconName: glyph,
                iconType: LauncherSearchResult.IconType.Text,
                execute: () => {
                    Quickshell.clipboardText = glyph;
                }
            });
        });
    }

    readonly property list<var> symbolEntries: {
        if (!root.wants("symbols") || root.activeSection !== "symbols")
            return [];
        return MaterialSymbolsSearch.fuzzyQuery(root.body).slice(0, root.sectionLimit).map(entry => {
            const tabIdx = entry.indexOf("\t");
            const symName = tabIdx >= 0 ? entry.slice(0, tabIdx) : entry;
            const symTags = tabIdx >= 0 ? entry.slice(tabIdx + 1) : "";
            return resultComp.createObject(null, {
                rawValue: entry,
                name: symName,
                comment: symTags,
                type: root.sectionTitles.symbols,
                verb: Translation.tr("Copy"),
                iconName: symName,
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    Quickshell.clipboardText = symName;
                }
            });
        });
    }

    readonly property list<var> keybindEntries: {
        if (!root.wants("keybinds") || root.activeSection !== "keybinds")
            return [];
        const needle = root.body.toLowerCase();
        const flatBinds = (function flatten(node) {
            let acc = [...(node.keybinds ?? [])];
            for (const child of (node.children ?? [])) {
                acc = acc.concat(flatten(child));
            }
            return acc;
        })(HyprlandKeybinds.keybinds).concat(AppKeys.binds);   // compositor binds, then the apps' own

        return flatBinds.filter(bind => {
            if (!bind.comment)
                return false;
            if (needle.length === 0)
                return true;
            return bind.comment.toLowerCase().includes(needle) || bind.key.toLowerCase().includes(needle);
        }).slice(0, root.sectionLimit).map(bind => {
            const modsStr = bind.mods.join(" + ");
            const keyStr = modsStr.length > 0 ? `${modsStr} + ${bind.key}` : bind.key;
            return resultComp.createObject(null, {
                name: bind.comment,
                comment: keyStr,
                type: root.sectionTitles.keybinds,
                verb: Translation.tr("Copy"),
                iconName: "keyboard",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    Quickshell.clipboardText = keyStr;
                }
            });
        });
    }

    readonly property list<var> actionEntries: {
        if (!root.wants("actions"))
            return [];
        if (root.activeSection === "" && root.query.length === 0)
            return [];
        // The old word (/dark) and the plain name both find a row; only the old word carries arguments.
        const typed = root.query.slice(root.pfxAction.length).toLowerCase();
        return LauncherSearch.allActions.map(action => {
            const actionString = `${root.pfxAction}${action.action}`;
            const byWord = actionString.startsWith(root.query) || root.query.startsWith(actionString);
            const label = action.label ?? action.action;
            const byName = !byWord && label.toLowerCase().split(" ").some(w => w.startsWith(typed.trim()));
            if (!byWord && !byName)
                return null;
            const args = byWord ? root.query.slice(actionString.length).trim() : "";
            return resultComp.createObject(null, {
                name: label,
                comment: args.length > 0 ? args : (action.hint ?? ""),
                type: root.sectionTitles.actions,
                verb: Translation.tr("Run"),
                iconName: "settings_suggest",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    // Not recorded: only "app:" keys are ever read back, and these would evict them.
                    // PaletteFrecency.record(`act:${action.action}`);
                    action.execute(args);
                }
            });
        }).filter(Boolean).slice(0, root.sectionLimit);
    }

    // The programs on PATH, read when the shell starts and each time the palette opens: "Run" is offered for a
    // first word that is one (or after Tab to commands), not for every word typed - "budget" ran as a command.
    property var executables: ({})
    function refreshExecutables() { if (!execList.running) execList.running = true; }
    Process {
        id: execList
        running: true
        command: ["sh", "-c", 'IFS=:; for d in $PATH; do ls -1 "$d" 2>/dev/null; done']
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                for (const n of this.text.split("\n")) if (n.length) m[n] = true;
                root.executables = m;
            }
        }
    }
    function runnable(text) {
        const words = text.trim().split(/\s+/);
        const first = words[0] === "sudo" ? (words[1] ?? "") : words[0];
        return first.length > 0 && (root.executables[first] === true || /^(\.{0,2}\/|~\/)/.test(first));
    }

    readonly property list<var> commandEntries: {
        if (!root.live)
            return [];
        if (root.query.length === 0)
            return [];
        if (root.activeSection.length > 0 && root.activeSection !== "command")
            return [];
        if (root.activeSection === "" && !Config.options.search.prefix.showDefaultActionsWithoutPrefix)
            return [];
        const command = root.body.replace("file://", "");
        if (command.trim().length === 0)
            return [];
        if (root.activeSection !== "command" && !root.runnable(command))
            return [];
        return [resultComp.createObject(null, {
                name: command,
                type: root.sectionTitles.command,
                verb: Translation.tr("Run"),
                fontType: LauncherSearchResult.FontType.Monospace,
                iconName: "terminal",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    Quickshell.execDetached(["bash", "-c", command.startsWith("sudo") ? `${Config.options.apps.terminal} fish -C '${StringUtils.shellSingleQuoteEscape(command)}'` : command]);
                }
            })];
    }

    // What you typed, asked in the notch (IslandAsk): shown where the web search is.
    readonly property list<var> claudeEntries: {
        if (!root.live)
            return [];
        if (root.query.length === 0 || root.activeSection.length > 0)
            return [];
        if (!Config.options.search.prefix.showDefaultActionsWithoutPrefix)
            return [];
        const terms = root.body;
        if (terms.trim().length === 0)
            return [];
        return [resultComp.createObject(null, {
                name: terms,
                type: root.sectionTitles.claude,
                verb: Translation.tr("Ask"),
                iconName: "auto_awesome",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => IslandController.openAsk("palette", [], terms.trim())
            })];
    }

    /**
     * The untyped palette: the files opened last and the apps started last, newest first, each
     * with where it lives and how long ago (PaletteRecent). Files are the same rows a search
     * finds (Things), apps the same rows as the Applications section.
     */
    readonly property int recentLimit: 5
    readonly property list<var> recentEntries: {
        if (!root.live || root.query.length > 0)
            return [];
        const home = FileUtils.trimFileProtocol(Directories.home);
        const files = PaletteRecent.files.slice(0, 3).map(file => ({
                    "at": file.at,
                    "make": () => {
                        const thing = Things.describe(file.path);
                        const dir = file.path.slice(0, file.path.length - file.name.length - 1);
                        const where = dir === home ? "~" : dir.startsWith(home + "/") ? `~/${dir.slice(home.length + 1)}` : dir;
                        return resultComp.createObject(null, {
                            name: thing.name,
                            comment: `${where} · ${Voice.age(file.at)}`,
                            rawValue: file.path,
                            type: root.sectionTitles.recent,
                            verb: Translation.tr("Open"),
                            iconName: thing.glyph,
                            iconType: LauncherSearchResult.IconType.Material,
                            execute: () => Things.open(file.path),
                            actions: Things.actions(file.path).filter(action => action.id !== "open").map(action => resultComp.createObject(null, {
                                    name: action.label,
                                    iconName: action.glyph,
                                    iconType: LauncherSearchResult.IconType.Material,
                                    execute: action.run
                                }))
                        });
                    }
                }));
        const apps = PaletteRecent.apps(3).map(item => ({
                    "at": item.at,
                    "make": () => {
                        const entry = DesktopEntries.byId(item.id);
                        if (!entry)
                            return null;
                        return resultComp.createObject(null, {
                            type: root.sectionTitles.recent,
                            id: entry.id,
                            name: entry.name,
                            comment: `${Translation.tr("app")} · ${Voice.age(item.at)}`,
                            iconName: entry.icon,
                            iconType: LauncherSearchResult.IconType.System,
                            verb: Translation.tr("Open"),
                            execute: () => {
                                PaletteFrecency.record(`app:${entry.id}`);
                                AppScope.launch(entry);
                            }
                        });
                    }
                }));
        return files.concat(apps).sort((a, b) => b.at - a.at).map(item => item.make()).filter(Boolean).slice(0, root.recentLimit);
    }

    readonly property list<var> webEntries: {
        if (!root.live)
            return [];
        if (root.query.length === 0)
            return [];
        if (root.activeSection.length > 0 && root.activeSection !== "web")
            return [];
        if (root.activeSection === "" && !Config.options.search.prefix.showDefaultActionsWithoutPrefix)
            return [];
        const terms = root.body;
        if (terms.trim().length === 0)
            return [];
        return [resultComp.createObject(null, {
                name: terms,
                type: root.sectionTitles.web,
                verb: Translation.tr("Search"),
                iconName: "travel_explore",
                iconType: LauncherSearchResult.IconType.Material,
                execute: () => {
                    let url = Config.options.search.engineBaseUrl + terms;
                    for (const site of Config.options.search.excludedSites) {
                        url += ` -site:${site}`;
                    }
                    Qt.openUrlExternally(url);
                }
            })];
    }

    /**
     * Ordered, non-empty sections. Section 5 of the brief: without a prefix the order
     * is Calculator, Windows, Applications, Projects, Sessions, Places, System, Settings,
     * Files, Actions, Command, Web; with a prefix only that section is built at all.
     *
     * Windows sits above Applications so an open window always outranks the launcher
     * that would start a second copy of it, whatever the frecency table says. With an
     * empty query the same order reads as: what is open, what you actually use, then
     * the System rows.
     */
    // Lower case, accents gone ("Affärsplan" and "affarsplan" are one word).
    function fold(t) { return String(t ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase(); }
    // An app is a strong match when every word typed is in its name, generic name or keywords; the fuzzy match on
    // its description alone ("budget" found LibreOffice Base through "...manage your information") is weak.
    function strongApp(e) {
        const hay = root.fold(`${e.name} ${e.genericName ?? ""} ${(e.keywords ?? []).join(" ")}`);
        return root.fold(root.body).trim().split(/\s+/).every(w => hay.includes(w));
    }
    readonly property var strongApps: root.appEntries.filter(e => root.strongApp(e))
    // and of those, only ones whose name holds the letters typed, in order ("firefox" is not LibreOffice Writer)
    function lettersInOrder(word, name) {
        let i = 0;
        for (const ch of name) if (ch === word[i]) i++;
        return i >= word.length;
    }
    readonly property var weakApps: root.appEntries.filter(e => !root.strongApp(e)
        && root.lettersInOrder(root.fold(root.body).replace(/\s+/g, ""), root.fold(e.name).replace(/\s+/g, "")))
    // A command typed with arguments ("ls -la"), or a program no app is named for, is what Enter should run.
    readonly property bool commandFirst: root.commandEntries.length > 0 && root.activeSection === ""
        && (/\s/.test(root.body.trim()) || root.strongApps.length === 0)

    readonly property var sections: {
        const ordered = [
            {
                key: "calculator",
                entries: root.calculatorEntries
            },
            {
                key: "command",
                entries: root.commandFirst ? root.commandEntries : []
            },
            {
                // Above Applications on purpose: focusing the Firefox that is already
                // open beats launching a second one, so "fire" offers the window first.
                key: "windows",
                entries: root.windowEntries
            },
            {
                key: "apps",
                entries: root.activeSection === "" ? root.strongApps : root.appEntries
            },
            {
                key: "projects",
                entries: root.projectEntries
            },
            {
                key: "sessions",
                entries: root.sessionEntries
            },
            {
                key: "places",
                entries: root.placeEntries
            },
            {
                key: "system",
                entries: root.systemEntries
            },
            {
                key: "settings",
                entries: root.settingsEntries
            },
            {
                key: "files",
                entries: root.fileEntries
            },
            {
                // apps that only matched by their description: below your files
                key: "apps",
                entries: root.activeSection === "" ? root.weakApps : []
            },
            {
                key: "clipboard",
                entries: root.clipboardEntries
            },
            {
                key: "flow",
                entries: root.dictationEntries
            },
            {
                key: "emoji",
                entries: root.emojiEntries
            },
            {
                key: "symbols",
                entries: root.symbolEntries
            },
            {
                key: "keybinds",
                entries: root.keybindEntries
            },
            {
                key: "actions",
                entries: root.actionEntries
            },
            {
                key: "command",
                entries: root.commandFirst ? [] : root.commandEntries
            },
            {
                key: "claude",
                entries: root.claudeEntries
            },
            {
                key: "web",
                entries: root.webEntries
            }
        ];

        // Nothing typed: what you used last, when there is any
        if (root.query.length === 0 && root.recentEntries.length > 0)
            return [{
                    key: "recent",
                    title: root.sectionTitles.recent,
                    entries: root.recentEntries
                }];

        let budget = root.resultLimit;
        const out = [];
        for (const section of ordered) {
            if (section.entries.length === 0 || budget <= 0)
                continue;
            const entries = section.entries.slice(0, budget);
            budget -= entries.length;
            out.push({
                key: section.key,
                title: root.sectionTitles[section.key],
                entries: entries
            });
        }
        return out;
    }

    readonly property int resultCount: root.sections.reduce((acc, section) => acc + section.entries.length, 0)

    Component {
        id: resultComp
        LauncherSearchResult {}
    }
}
