pragma Singleton
pragma ComponentBehavior: Bound

import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * File and folder search for the palette, through fd, ranked here.
 *
 * What it answers: every word typed, in any order, found in the name or along the path ("swedbank budget"
 * finds Resultatbudget.xlsx in ~/Documents/Swedbank); accents do not matter ("affarsplan" finds
 * Affärsplan); folders too. fd brings up to 1500 candidates for the longest word (~0.2 s over home) and
 * this ranks them: the name matching beats the path matching, a word at the start of a word beats one
 * inside it, files opened lately come first, and deep, hidden, build and duplicate copies sink (the first
 * 20 fd happened to reach used to be the answer, so the documents drowned under build output and copies).
 *
 * fd is asynchronous: callers push a query with setQuery() and read `results`, a plain binding.
 */
Singleton {
    id: root

    readonly property bool enable: Config.options.commandPalette?.files?.enable ?? true
    readonly property string searchRoot: {
        const configured = Config.options.commandPalette?.files?.root ?? "";
        return FileUtils.trimFileProtocol(configured.length > 0 ? configured : Directories.home);
    }
    readonly property int maxDepth: Config.options.commandPalette?.files?.maxDepth ?? 8
    readonly property int limit: Config.options.commandPalette?.files?.limit ?? 12
    // what nobody opens from a launcher: tools' output, caches, other machines' packages
    readonly property var excludeDirs: Config.options.commandPalette?.files?.excludeDirs
        ?? [".git", "node_modules", ".cache", "build", "dist", "target", ".gradle", "__pycache__", ".venv", "venv",
            ".npm", ".cargo", ".rustup", ".m2", ".android", ".kotlin", ".pub-cache", "Trash", ".var", ".mozilla"]

    // Shortest query fd is run for. Single letters match most of $HOME and are useless.
    readonly property int minQueryLength: 2

    property string query: ""
    property bool running: false
    property bool available: true // Flipped off once fd is known to be missing
    // fd exits 0 for "no matches", so any other code is a real failure and must not be
    // shown as an empty result - that is what made a broken search look like a missing file.
    property bool failed: false
    property list<string> paths: []
    // The last disk search: its word and everything it found. A longer word that holds it ("budg" after "bud")
    // can only narrow that list, so while the list was not cut off at the cap it is filtered here instead of
    // searching the disk again (a search walks all of home: ~190 ms, ~1.4 s of CPU across the cores).
    property string fdWord: ""
    property var fdPaths: []
    property bool fdComplete: false
    property real fdAt: 0
    readonly property int fdCap: 1500

    // lower case, accents gone: "Affärsplan" and "affarsplan" are one word
    function fold(s) { return String(s).normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase(); }
    readonly property var words: root.fold(root.query).split(/\s+/).filter(w => w.length > 0)
    // fd's pattern for one word: each letter that has accented forms matches them too
    function patternFor(word) {
        const kin = { a: "aàáâãäåæ", e: "eèéêë", i: "iìíîï", o: "oòóôõöø", u: "uùúûü", c: "cç", n: "nñ", y: "yýÿ", s: "sß" };
        return word.split("").map(ch => kin[ch] ? `[${kin[ch]}]` : ch.replace(/[.*+?^${}()|[\]\\\/]/g, "\\$&")).join("");
    }

    function setQuery(search) {
        const trimmed = (search ?? "").trim();
        if (trimmed === root.query)
            return;
        root.query = trimmed;
        root.failed = false;
        if (trimmed.length === 0) root.fdWord = "";   // the palette closed or cleared: the next search reads the disk
        const longest = root.words.slice().sort((a, b) => b.length - a.length)[0] ?? "";
        if (!root.enable || trimmed.length < root.minQueryLength || longest.length < root.minQueryLength) {
            debounceTimer.stop();
            if (fdProc.running)
                fdProc.exitAction = "discard";
            fdProc.running = false;
            root.running = false;
            root.paths = [];
            return;
        }
        root.running = true;
        debounceTimer.restart();
    }

    // The ranking. A candidate must hold every word somewhere in its path under the search root.
    readonly property var ranked: {
        const ws = root.words;
        if (ws.length === 0 || root.paths.length === 0) return [];
        const home = root.searchRoot.replace(/\/$/, "");
        const recent = {};
        for (const r of PaletteRecent.files) recent[r.path] = true;
        const whole = ws.join(" ");
        const out = [];
        for (const raw of root.paths) {
            const isDir = raw.endsWith("/");
            const path = isDir ? raw.slice(0, -1) : raw;
            const rel = root.fold(path.startsWith(home + "/") ? path.slice(home.length + 1) : path);
            const base = rel.slice(rel.lastIndexOf("/") + 1);
            const stem = isDir ? base : base.replace(/\.[^.]{1,6}$/, "");
            let score = 0, all = true;
            for (const w of ws) {
                const at = base.indexOf(w);
                if (at >= 0) score += 20 + (at === 0 || /[^a-z0-9]/.test(base.charAt(at - 1)) ? 10 : 0);
                else if (rel.includes(w)) score += 6;
                else { all = false; break; }
            }
            if (!all) continue;
            if (stem === whole) score += 60;
            else if (stem.startsWith(whole)) score += 25;
            if (isDir && base === whole) score += 10;
            if (recent[path]) score += 40;
            // what a launcher is for: documents and pictures in your own folders; a compiled object is not
            if (/^(documents|desktop|downloads|pictures|music|videos)(\/|$)/.test(rel)) score += 15;
            const kind = isDir ? "folder" : Things.kindOf(base);
            if (["doc", "pdf", "image", "video", "audio", "text", "archive"].includes(kind)) score += 20;
            else if (kind === "code") score -= 5;
            if (/\.(o|a|so|ko|d|cmd|pyc|class|obj|lo|mod\.c)$/.test(base)) score -= 30;
            const depth = rel.split("/").length - 1;
            score -= depth * 1.5;
            if (/(^|\/)\./.test(rel)) score -= 40;                                   // inside a hidden folder: rarely what is wanted
            if (/(^|\/)(backups?|archive|arkiv[^/]*|out|shots|tmp|scratch)(\/|$)|-wt-|\.bak$|~$/.test(rel)) score -= 10;
            out.push({ path: path, isDir: isDir, base: base, score: score });
        }
        out.sort((a, b) => b.score - a.score || a.path.length - b.path.length);
        // the same name in many places (worktree copies, builds): the best two of it
        const seen = {}, kept = [];
        for (const r of out) {
            const n = (seen[r.base] ?? 0) + 1;
            seen[r.base] = n;
            if (n <= 2) kept.push(r);
            if (kept.length >= root.limit) break;
        }
        return kept;
    }

    // A file found here is the same thing it is in a Files row or a notch row: Things says what
    // it looks like, opens it (and says why when nothing can), and lists what can be done with
    // it, in the one order the whole desktop uses. A folder opens in Pinax.
    readonly property list<var> results: root.ranked.map(r => {
        const thing = Things.describe(r.path + (r.isDir ? "/" : ""));
        return fileResultComp.createObject(null, {
            name: thing.name,
            comment: r.path,
            rawValue: r.path,
            type: Translation.tr("Files"),
            verb: Translation.tr("Open"),
            iconName: thing.glyph,
            iconType: LauncherSearchResult.IconType.Material,
            execute: r.isDir ? () => Files.open(r.path, "") : () => Things.open(r.path),
            actions: Things.actions(r.path + (r.isDir ? "/" : "")).filter(action => action.id !== "open").map(action => fileResultComp.createObject(null, {
                    name: action.label,
                    iconName: action.glyph,
                    iconType: LauncherSearchResult.IconType.Material,
                    execute: action.run
                }))
        });
    })

    Timer {
        id: debounceTimer
        interval: 160
        repeat: false
        onTriggered: fdProc.restartSearch()
    }

    Process {
        id: fdProc
        property list<string> buffer: []
        property string word: ""
        // What the next exited signal is for, when it belongs to a run we killed:
        // "discard", "restart", or "" for a run that ran to the end and may be published.
        property string exitAction: ""

        function restartSearch() {
            // Killing and starting in the same call let the dead run's exited handler
            // publish the new run's half-filled buffer, which showed a short wrong list and
            // stopped the spinner early. Queue behind the kill instead.
            if (fdProc.running) {
                fdProc.exitAction = "restart";
                fdProc.running = false;
                return;
            }
            fdProc.exitAction = "";
            fdProc.buffer = [];
            // The longest word goes to fd, matched anywhere along the path below the search root (a folder's name
            // counts for what is in it), accents and case aside; the other words are checked in the ranking.
            const longest = root.words.slice().sort((a, b) => b.length - a.length)[0] ?? "";
            const home = root.searchRoot.replace(/\/$/, "");
            if (root.fdComplete && root.fdWord.length > 0 && longest.includes(root.fdWord) && Date.now() - root.fdAt < 30000) {
                root.paths = root.fdPaths.filter(p => root.fold(p.startsWith(home + "/") ? p.slice(home.length + 1) : p).includes(longest));
                root.running = false;
                return;
            }
            fdProc.word = longest;
            // idle priority and two threads: the walk is background work and must not compete with typing and animation
            const argv = ["nice", "-n", "19", "ionice", "-c", "3", "fd", "--threads", "2", "--type", "f", "--type", "d", "--color", "never", "--ignore-case", "--full-path",
                          "--max-depth", String(root.maxDepth), "--max-results", String(root.fdCap)];
            for (const dir of root.excludeDirs) argv.push("--exclude", dir);
            // anchored past the root: "ho" must be in what is below /home/abdul, not in /home itself
            argv.push("--", "^" + home.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/.*" + root.patternFor(longest), home);
            fdProc.command = argv;
            fdProc.running = true;
        }

        stdout: SplitParser {
            onRead: line => {
                if (line.length > 0)
                    fdProc.buffer.push(line);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (fdProc.exitAction !== "") {
                const action = fdProc.exitAction;
                fdProc.exitAction = "";
                // callLater, so `running` is settled before the next run starts.
                if (action === "restart")
                    Qt.callLater(fdProc.restartSearch);
                return;
            }
            root.running = false;
            if (exitCode === 127 || exitStatus !== 0 && fdProc.buffer.length === 0 && exitCode < 0) {
                root.available = false;
                root.paths = [];
                return;
            }
            root.available = true;
            root.failed = exitCode !== 0 && fdProc.buffer.length === 0;
            root.paths = root.failed ? [] : fdProc.buffer;
            root.fdWord = root.failed ? "" : fdProc.word;
            root.fdPaths = root.paths;
            root.fdComplete = fdProc.buffer.length < root.fdCap;
            root.fdAt = Date.now();
        }
    }

    Component {
        id: fileResultComp
        LauncherSearchResult {}
    }
}
