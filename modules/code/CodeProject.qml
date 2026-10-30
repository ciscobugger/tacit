import QtQuick
import Quickshell
import Quickshell.Io

/**
 * One repository as the editor sees it: every file git does not ignore, what
 * changed since `base` (M changed, U new, D deleted), and the tree rows to draw.
 * Asks git again every few seconds while the window is on screen, backing off when
 * nothing moves, so files an agent is writing show up by themselves. A folder that
 * is not a repository is listed plainly instead, with no change tracking.
 */
Item {
    id: p

    property string root: ""
    property string base: "HEAD"
    property var files: []
    property var changes: ({})
    property var open: ({})
    property var rows: []
    property string active: ""
    property int activeRow: -1          // where `active` sits in rows, for the tree's cursor
    readonly property string name: p.root.length ? p.root.split("/").pop() : ""
    property bool loaded: false
    property bool repo: true            // a plain folder is listed without change tracking
    property bool awake: true           // the window is on screen: keep asking git
    // What git ignores (.env, build output, node_modules) is still reachable: listed faint, a folder only one level
    // at a time when it is opened (ignoredKids), so a huge node_modules costs nothing until asked for.
    property var ignored: []            // paths; a folder ends in "/"
    property var ignoredKids: ({})      // folder -> [{ name, dir }]
    // a row being named before it exists: { parent, kind: "file" | "folder" }
    property var draft: null
    property var made: []               // folders made here this session: git lists no empty folder

    property string _all: ""
    property string _diff: ""
    property string _sig: ""
    property var _seen: ({})

    function refresh() {
        if (!p.root.length || plainLs.running || lsAll.running || diffProc.running || untracked.running || ignoredProc.running) return;
        if (p.repo) lsAll.running = true;
        else plainLs.running = true;
    }
    // back to the short interval: something just happened worth watching
    function quicken() { poll.interval = 3000; p.refresh(); }

    function setRoot(dir) {
        p.root = dir; p.files = []; p.changes = ({}); p.open = ({}); p._seen = ({}); p._sig = ""; p.rows = []; p.loaded = false;
        p.repo = true; p.activeRow = -1; p.ignored = []; p.ignoredKids = ({}); p.draft = null; p.made = [];
        poll.interval = 3000;
        if (p.root.length) isRepo.running = true;
    }

    function toggle(dir) {
        const o = Object.assign({}, p.open); o[dir] = !o[dir]; p.open = o;
        if (o[dir] && p.isIgnoredDir(dir) && !p.ignoredKids[dir]) p.listIgnored(dir);
        p.rebuild();
    }
    function isIgnoredDir(dir) {
        if (p.ignored.indexOf(dir + "/") >= 0) return true;
        for (const k in p.ignoredKids) for (const e of p.ignoredKids[k]) if (e.dir && k + "/" + e.name === dir) return true;
        return false;
    }
    function listIgnored(dir) {
        p.exec(["find", p.root + "/" + dir, "-mindepth", "1", "-maxdepth", "1", "-printf", "%y\\t%f\\0"], (code, out) => {
            const kids = out.split("\0").filter(x => x.length).map(x => ({ name: x.substring(2), dir: x.charAt(0) === "d" }));
            const k = Object.assign({}, p.ignoredKids); k[dir] = kids; p.ignoredKids = k;
            p.rebuild();
        });
    }

    // Naming a new file or folder happens in its row, where it will live.
    function startDraft(parent, kind) {
        if (parent.length) { const o = Object.assign({}, p.open), parts = parent.split("/");
            for (let j = 1; j <= parts.length; j++) o[parts.slice(0, j).join("/")] = true; p.open = o; }
        p.draft = { parent: parent, kind: kind };
        p.rebuild();
    }
    function endDraft() { if (p.draft) { p.draft = null; p.rebuild(); } }

    // One short command, its exit code and output to `cb`.
    function exec(argv, cb) { execComp.createObject(p, { command: argv, cb: cb, running: true }); }

    function reveal(rel) {
        const o = Object.assign({}, p.open), parts = rel.split("/");
        for (let j = 1; j < parts.length; j++) o[parts.slice(0, j).join("/")] = true;
        p.open = o; p.active = rel; p.rebuild();
    }

    // The flattened rows for the list: folders first, a folder holding only one
    // folder drawn as one row (a/b/c), changed counts carried up to the folders.
    // Ignored files and folders come in faint; a draft (a file being named) sits first in its folder.
    property var extraFiles: []         // ignored files known so far, for Ctrl+P
    property var fresh: ({})
    function keyOf(r) { return (r.draft ? "draft:" : "") + r.path + (r.dir ? "/" : ""); }
    Timer { id: freshEnds; interval: 500; onTriggered: p.fresh = ({}) }
    function rebuild() {
        const tree = { dirs: {}, files: {}, changed: 0, path: "" };
        const nodeFor = (parts, count) => {
            let node = tree;
            for (let i = 0; i < parts.length - 1; i++) {
                const key = parts[i];
                if (!node.dirs[key]) node.dirs[key] = { dirs: {}, files: {}, changed: 0, path: parts.slice(0, i + 1).join("/") };
                node = node.dirs[key];
                if (count) node.changed++;
            }
            return node;
        };
        const add = (path, kind) => {
            const parts = path.split("/");
            nodeFor(parts, kind === "M" || kind === "U" || kind === "D").files[parts[parts.length - 1]] = kind || "";
        };
        const addDir = path => {
            const parts = path.split("/");
            const node = nodeFor(parts.concat([""]), false);
            node.ignored = true;
        };
        const extra = [];
        for (const f of p.files) add(f, p.changes[f]);
        for (const f in p.changes) if (p.changes[f] === "D") add(f, "D");
        for (const f of p.ignored) {
            if (f.endsWith("/")) addDir(f.substring(0, f.length - 1));
            else { add(f, "I"); extra.push(f); }
        }
        for (const k in p.ignoredKids) for (const e of p.ignoredKids[k]) {
            if (e.dir) addDir(k + "/" + e.name);
            else { add(k + "/" + e.name, "I"); extra.push(k + "/" + e.name); }
        }
        for (const d of p.made) nodeFor(d.split("/").concat([""]), false);
        p.extraFiles = extra;
        const draftAt = p.draft ? p.draft.parent : null;
        const out = [];
        const byName = (a, b) => a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0;
        const walk = (node, depth) => {
            if (draftAt !== null && node.path === draftAt)
                out.push({ dir: p.draft.kind === "folder", draft: true, path: draftAt, name: "", depth: depth, open: false, status: "" });
            for (const key of Object.keys(node.dirs).sort(byName)) {
                let d = node.dirs[key], label = key;
                while (!d.ignored && d.path !== draftAt && Object.keys(d.dirs).length === 1 && Object.keys(d.files).length === 0
                       && !d.dirs[Object.keys(d.dirs)[0]].ignored) {
                    const only = Object.keys(d.dirs)[0]; label += "/" + only; d = d.dirs[only];
                }
                const isOpen = !!p.open[d.path];
                out.push({ dir: true, path: d.path, name: label, depth: depth, open: isOpen, status: d.changed > 0 ? "M" : "", ignored: !!d.ignored });
                if (isOpen) walk(d, depth + 1);
            }
            for (const key of Object.keys(node.files).sort(byName)) {
                const path = node.path.length ? node.path + "/" + key : key;
                const kind = node.files[key];
                out.push({ dir: false, path: path, name: key, depth: depth, open: false, status: kind === "I" ? "" : kind, ignored: kind === "I" || !!node.ignored });
            }
        };
        walk(tree, 0);
        // what is new since the last rows, read by the tree's rows as they are made (before they are): a folder
        // opened, a file made, the row being named. Not the first listing, not rows scrolled into view later.
        const before = {}, f = {};
        for (const r of p.rows) before[p.keyOf(r)] = true;
        if (p.rows.length) for (const r of out) if (!before[p.keyOf(r)]) f[p.keyOf(r)] = true;
        p.fresh = f;
        freshEnds.restart();
        p.rows = out;
        if (p.active.length) p.activeRow = out.findIndex(r => !r.dir && r.path === p.active);
    }

    function _finish(untrackedText) {
        const ch = {}, parts = p._diff.split("\0").filter(x => x.length);
        let i = 0;
        while (i < parts.length) {
            const code = parts[i].charAt(0);
            if (code === "R" || code === "C") { ch[parts[i + 2]] = "M"; i += 3; }
            else { ch[parts[i + 1]] = code === "D" ? "D" : code === "A" ? "U" : "M"; i += 2; }
        }
        for (const f of untrackedText.split("\0")) if (f.length) ch[f] = "U";
        const sig = p._all + "|" + JSON.stringify(ch) + "|" + p._ignoredText;
        p.loaded = true;
        // nothing moved: ask less often, up to half a minute, until something does
        if (sig === p._sig) { poll.interval = Math.min(30000, poll.interval * 2); return; }
        poll.interval = 3000;
        p._sig = sig;
        p.files = p._all.split("\0").filter(x => x.length);
        p.ignored = p._ignoredText.split("\0").filter(x => x.length);
        p.changes = ch;
        // unfold the way to every changed file the first time it shows up
        const o = Object.assign({}, p.open), seen = Object.assign({}, p._seen);
        for (const f in ch) {
            if (seen[f]) continue;
            seen[f] = true;
            const segs = f.split("/");
            for (let j = 1; j < segs.length; j++) o[segs.slice(0, j).join("/")] = true;
        }
        p._seen = seen; p.open = o;
        p.rebuild();
    }

    // A plain folder (code-file falls back to the file's directory when it is not in a repo):
    // the same rows without the change columns.
    function _finishPlain(t) {
        const files = t.split("\n").filter(x => x.length).sort();
        p.loaded = true;
        const sig = files.join("\n");
        if (sig === p._sig) { poll.interval = Math.min(30000, poll.interval * 2); return; }
        poll.interval = 3000;
        p._sig = sig; p.files = files; p.changes = ({});
        p.rebuild();
    }

    Process {
        id: isRepo
        command: ["git", "-C", p.root, "rev-parse", "--is-inside-work-tree"]
        stdout: StdioCollector { onStreamFinished: { p.repo = this.text.trim() === "true"; p.refresh(); } }
    }
    Process {
        id: plainLs
        workingDirectory: p.root
        command: ["fd", "--type", "f", "--hidden", "--max-depth", "6", "--exclude", ".git", "--strip-cwd-prefix"]
        stdout: StdioCollector { onStreamFinished: p._finishPlain(this.text) }
    }
    Process {
        id: lsAll
        command: ["git", "-C", p.root, "-c", "core.quotePath=false", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
        stdout: StdioCollector { onStreamFinished: { p._all = this.text; diffProc.running = true; } }
    }
    Process {
        id: diffProc
        command: ["git", "-C", p.root, "-c", "core.quotePath=false", "diff", "--relative", "--name-status", "-z", p.base]
        stdout: StdioCollector { onStreamFinished: { p._diff = this.text; untracked.running = true; } }
    }
    Process {
        id: untracked
        command: ["git", "-C", p.root, "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z"]
        stdout: StdioCollector { onStreamFinished: { p._untracked = this.text; ignoredProc.running = true; } }
    }
    property string _untracked: ""
    property string _ignoredText: ""
    Process {
        id: ignoredProc
        command: ["git", "-C", p.root, "-c", "core.quotePath=false", "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
        stdout: StdioCollector { onStreamFinished: { p._ignoredText = this.text; p._finish(p._untracked); } }
    }

    // The file as it was at `base`, for a changed file opened to be typed. Each ask is
    // its own short process; the answer is delivered once its output is complete.
    function before(rel, cb) {
        showComp.createObject(p, { command: ["git", "-C", p.root, "show", p.base + ":./" + rel], cb: cb, running: true });
    }
    Component {
        id: showComp
        Process {
            id: proc
            property var cb
            stdout: StdioCollector { onStreamFinished: proc.cb(this.text) }
            onExited: proc.destroy(1000)
        }
    }
    Component {
        id: execComp
        Process {
            id: ep
            property var cb
            property string out: ""
            property int code: -1
            property int parts: 0
            function finish() { if (++ep.parts === 2) { ep.cb(ep.code, ep.out); ep.destroy(1000); } }
            stdout: StdioCollector { onStreamFinished: { ep.out = this.text; ep.finish(); } }
            onExited: code => { ep.code = code; ep.finish(); }
        }
    }

    Timer { id: poll; interval: 3000; repeat: true; running: p.root.length > 0 && p.awake; onTriggered: p.refresh() }
}
