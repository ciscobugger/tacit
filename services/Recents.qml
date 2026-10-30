pragma Singleton
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland

/**
 * "Just happened": the last things that arrived on this machine - copies, screenshots,
 * downloads - as one stream for the notch's sheet. Each item knows what it is (url, colour,
 * path, command, error, secret, text, image, file) and which window it was copied from, so a
 * row can do the one obvious thing on click, be dragged anywhere, and take you back to where
 * it came from. Items leave the stream after maxAgeMinutes; cliphist keeps the full history.
 *
 * Order is not "newest first": what you have not seen comes first, then arrivals (files,
 * errors, links) before copies, then time. Plain text and commands are capped at two rows
 * each so a burst of copying cannot bury a screenshot. Secrets are never shown, only named.
 *
 * Clipboard changes arrive through Cliphist (wl-paste --watch -> `cliphistService update`
 * -> entries); files through IslandController.onDownloaded.
 */
Singleton {
    id: root

    property var items: []  // newest first
    property real now: Date.now()
    readonly property int maxAgeMinutes: 15
    readonly property var fresh: root.items.filter(i => root.now - i.at < root.maxAgeMinutes * 60000)

    // The rows the sheet shows: unseen first, then weight, then time; two plain copies and
    // two commands at most.
    // A function, not a binding: the sheet snapshots it at open, so nothing needs to react.
    function ranked() {
        // what is still arriving comes first: a growing download is a row that updates live
        const jobs = Jobs.running.map(j => ({ "key": j.id, "kind": "downloading", "text": j.kind === "job" ? Jobs.label(j) : j.name, "entry": "", "path": "", "app": "", "address": "", "at": j.at ?? j.started ?? Date.now(), "seen": true }));
        const sorted = jobs.concat(root.fresh.slice().sort((a, b) => ((b.seen ? 0 : 1) - (a.seen ? 0 : 1)) || (root.weight(b) - root.weight(a)) || (b.at - a.at)));
        let plain = 0;
        let commands = 0;
        return sorted.filter(i => {
            if (i.kind === "text")
                return ++plain <= 2;
            if (i.kind === "command")
                return ++commands <= 2;
            return true;
        });
    }
    readonly property int unseenCount: root.fresh.filter(i => !i.seen).length

    function weight(i) {
        switch (i.kind) {
        case "screenshot":
        case "download":
        case "error":
            return 3;
        case "url":
        case "path":
        case "color":
        case "image":
            return 2;
        case "command":
            return 1;
        }
        return 0;  // text, secret
    }

    function markSeen() {
        if (root.items.every(i => i.seen))
            return;
        root.items = root.items.map(i => Object.assign({}, i, { "seen": true }));
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = Date.now()
    }

    // ------------------------------------------------------------------ clipboard
    property string lastEntryId: ""
    property string selfCopy: ""  // what activate() just put back; the watcher must skip it
    property real lastShotAt: 0   // a screenshot saves a file AND copies the image: one row
    Connections {
        target: Cliphist
        function onEntriesChanged() {
            root.onClipboard();
        }
    }
    function onClipboard() {
        const entry = Cliphist.entries[0] ?? "";
        if (!entry)
            return;
        const id = entry.split("\t")[0];
        if (id === root.lastEntryId)
            return;
        const first = root.lastEntryId === "";
        root.lastEntryId = id;
        if (first)  // the shell just started: what was already on the clipboard is not news
            return;
        const preview = entry.substring(entry.indexOf("\t") + 1);
        if (preview.trim().length === 0)   // whitespace is not news
            return;
        if (root.selfCopy.length > 0 && preview === root.selfCopy) {
            root.selfCopy = "";
            return;
        }
        const isImage = Cliphist.entryIsImage(entry);
        if (isImage && Date.now() - root.lastShotAt < 3000)
            return;
        // A file copied or cut in Files arrives as a uri-list: show it as a path, not as file:///...
        let text = preview;
        if (/^file:\/\/\S+(\n\s*file:\/\/\S+)*$/.test(preview.trim())) {
            const home = FileUtils.trimFileProtocol(Directories.home);
            text = preview.trim().split("\n").map(u => decodeURIComponent(u.trim().replace(/^file:\/\//, "")).replace(home, "~")).join("\n");
        }
        const top = ToplevelManager.activeToplevel;
        root.add({
            "key": "clip:" + id,
            "kind": isImage ? "image" : root.kindOf(text),
            "text": text,
            "entry": entry,
            "path": "",
            "app": top?.appId ?? "",
            "address": top?.HyprlandToplevel?.address ? `0x${top.HyprlandToplevel.address}` : "",
            "at": Date.now(),
            "seen": false
        });
    }

    function kindOf(t) {
        const s = (t + "").trim();
        if (root.isSecret(s))
            return "secret";
        if (/^https?:\/\/\S+$/i.test(s))
            return "url";
        if (/^#[0-9a-f]{3,8}$/i.test(s))  // only what Qt can paint; rgb() text stays text
            return "color";
        if (/^(~|\/)[^\s]+$/.test(s))
            return "path";
        // an error is a line that says so, a file:line reference, or a stack frame
        if (/^(error|fatal|panic|traceback|exception|warning)\b/im.test(s) || /\b[\w./-]+\.\w+:\d+(:\d+)?\b/.test(s)
            || /^\s+at .+\(.+:\d+\)/m.test(s) || /File ".+", line \d+/.test(s))
            return "error";
        if (/^(sudo|git|npm|pacman|yay|make|systemctl|hyprctl|qs|cd|ls|cat|curl|ssh|rsync|docker|python3?|node)\b/.test(s) || /\s\|\s/.test(s) || /^\$ /.test(s))
            return "command";
        return "text";
    }

    // Tokens, keys, password lines. Better a masked commit hash than a shown key.
    function isSecret(s) {
        if (/-----BEGIN [A-Z ]*PRIVATE KEY/.test(s))
            return true;
        if (/\b(sk|ghp|gho|ghu|github_pat|xox[abpr]|AKIA|AIza|glpat)[-_][A-Za-z0-9_-]{10,}/.test(s))
            return true;
        if (/\b(passw(or)?d|passphrase|secret|token|api[_-]?key)\b\s*[:=]\s*\S+/i.test(s))
            return true;
        if (/sudo -S\b/.test(s) && /printf|echo/.test(s))
            return true;
        // one long base64-ish blob with mixed case and digits (not a plain hex hash)
        const blob = s.match(/(^|\s)([A-Za-z0-9+\/=_-]{32,})(\s|$)/);
        if (blob && /[a-z]/.test(blob[2]) && /[A-Z]/.test(blob[2]) && /\d/.test(blob[2]) && !/^[0-9a-f]+$/i.test(blob[2]))
            return true;
        return false;
    }

    // ------------------------------------------------------------------ files
    function addFile(path, isShot) {
        if (isShot)
            root.lastShotAt = Date.now();
        // The shelf is that file's place; a row as well would be the same thing twice.
        if (DropShelf.items.includes(path))
            return;
        root.add({
            "key": "file:" + path,
            "kind": isShot ? "screenshot" : "download",
            "text": path.split("/").pop(),
            "entry": "",
            "path": path,
            "app": Origins.originFor(path)?.app ?? "",   // the page or window it came from
            "address": "",
            "at": Date.now(),
            "seen": false
        });
    }

    function add(item) {
        // The same text copied twice refreshes one row.
        root.items = [item].concat(root.items.filter(i => i.key !== item.key && !(i.kind === item.kind && i.text === item.text))).slice(0, 16);
    }

    function remove(item) {
        root.items = root.items.filter(i => i.key !== item.key);
    }

    // ------------------------------------------------------------------ what a row shows
    function glyphFor(kind) {
        switch (kind) {
        case "url":
            return "link";
        case "color":
            return "palette";
        case "path":
            return "draft";
        case "command":
            return "terminal";
        case "error":
            return "bug_report";
        case "secret":
            return "key";
        case "image":
            return "image";
        case "screenshot":
            return "screenshot_monitor";
        case "download":
            return "download_done";
        case "downloading":
            return "downloading";
        }
        return "notes";
    }

    function label(item) {
        if (item.kind === "secret")
            return `secret · ${(item.text + "").trim().length} chars`;
        if (item.kind === "downloading") {
            const job = Jobs.byId[item.key];   // live: the snapshot holds the key, the size moves
            return job ? Jobs.label(job) : item.text;
        }
        if (item.kind === "url")
            return item.text.replace(/^https?:\/\//i, "").replace(/\/$/, "");
        if (item.kind === "image")
            return (item.text.match(/\d+x\d+/) ?? ["image"])[0] + " image";
        // a file leads with what it is, then where it came from: "tiger.jpg · Tiger wallpapers 4k"
        if (item.kind === "download" || item.kind === "screenshot") {
            const from = Origins.titleFor(item.path);
            return from.length > 0 && from !== item.text ? `${item.text} · ${from}` : item.text;
        }
        const first = (item.text + "").split("\n")[0].trim();
        // an error row leads with the message; the file:line is what the eye can spare
        if (item.kind === "error") {
            const m = first.match(/\b(?:error|fatal|warning|panic)\s*:\s*(.+)$/i);
            if (m)
                return m[1].trim();
        }
        return first;
    }

    // ------------------------------------------------------------------ the one action
    // click: open what opens, put back on the clipboard what pastes.
    function activate(item) {
        const home = FileUtils.trimFileProtocol(Directories.home);
        switch (item.kind) {
        case "url":
            Quickshell.execDetached(["xdg-open", item.text.trim()]);
            return;
        case "path":
            Things.open(item.text.trim().replace(/^~/, home));
            return;
        case "screenshot":
        case "download":
            // Things, not a bare xdg-open: the same open every other surface uses, and the only
            // one that says why when nothing on this machine opens the file.
            Things.open(item.path);
            return;
        }
        if (item.entry.length > 0) {
            root.selfCopy = item.text;
            Cliphist.copy(item.entry);
            IslandController.request("copied", {
                "icon": "content_copy",
                "text": item.kind === "secret" ? "Copied" : `Copied · ${root.label(item).substring(0, 40)}`
            }, 70);
        }
    }

    // The explicit side actions, never on a plain click.
    // "run" types the command into a new terminal's prompt; you press Enter.
    function run(item) {
        const cmd = (item.text + "").trim().replace(/^\$ /, "");
        // the text travels in the environment, never as fish source: a quote or backslash in it cannot run anything
        Quickshell.execDetached(["env", `__notch_cmd=${cmd}`, "foot", "fish", "-C",
            "function __notch_prefill --on-event fish_prompt; commandline -r -- $__notch_cmd; functions -e __notch_prefill; set -e __notch_cmd; end"]);
    }

    // ------------------------------------------------------------------ hand to Claude
    // ONE door to an agent, whatever came in: a row's button, text dropped on the notch. A new
    // Claude session opens in the folder of the session the thing came from, else the one you
    // used last, with the thing as its first message.
    function folderFor(address) {
        const byWindow = (address + "").length > 0
            ? AgentSessions.sessions.find(s => s.address === address && (s.cwd + "").length > 0) : null;
        const last = byWindow ?? AgentSessions.sessions.slice().sort((a, b) => b.since - a.since).find(s => (s.cwd + "").length > 0);
        // a session on a thread hands off in the thread's place
        const thread = last ? Threads.forSession(last.id) : null;
        if (thread && (thread.place ?? "").length > 0)
            return thread.place;
        return last ? last.cwd : FileUtils.trimFileProtocol(Directories.home);
    }
    function promptFor(item) {
        const t = (item.text + "").trim();
        const look = "What is this, and what should I do about it?";
        if ((item.path + "").length > 0)
            return `Look at ${item.path}. ${look}`;
        switch (item.kind) {
        case "url":
            return `Look at ${t}. What matters here for me?`;
        case "path":
            return `Look at ${t.replace(/^~/, FileUtils.trimFileProtocol(Directories.home))}. ${look}`;
        case "error":
        case "command":
            return `${t}\n\n${look}`;
        }
        return t;  // plain text is the task itself
    }
    function hand(item) {
        root.launch(root.folderFor(item.address), root.promptFor(item));
    }
    function handText(text) {
        const t = (text + "").trim();
        const prompt = /^https?:\/\/\S+$/i.test(t) ? `Look at ${t}. What matters here for me?` : t;
        root.launch(root.folderFor(""), prompt);
    }
    // Into the Claude app (claude-hand starts it if needed and falls back to foot + claude).
    function launch(cwd, prompt) {
        Claude.hand("new", cwd, prompt);
    }
    function canHand(item) {
        return item.kind !== "secret" && item.kind !== "image" && item.kind !== "command" && item.kind !== "downloading";
    }

    function back(item) {
        if ((item.address + "").length > 0)
            Hyprland.dispatch(`hl.dsp.focus({ window = "address:${item.address}" })`);
    }

    function age(item) {
        return item.kind === "downloading" ? "now" : Voice.age(item.at, root.now);
    }
}
