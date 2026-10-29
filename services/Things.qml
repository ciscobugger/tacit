pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets   // DropShelf

/**
 * The one object every surface shows: a file (or folder) as the desktop knows it. Given a
 * path, `describe` says what it is (kind, glyph), what to call it (its origin title over its
 * file name), and what is true of it (origin, age); `actions` lists what can be done with it
 * here, in the same order everywhere: open, open in Graphis, show in Files, park on the shelf,
 * hand to Claude, send to the phone, copy the path, forget where it came from. The notch's rows, a
 * notification's file, a palette result and a Files row all ask this, so a download is the
 * same thing with the same actions wherever you meet it.
 */
Singleton {
    id: root

    readonly property var kinds: ({
        "image": ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "avif", "heic", "tiff", "tif"],
        "video": ["mp4", "mkv", "webm", "mov", "avi", "m4v"],
        "audio": ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"],
        "pdf": ["pdf"],
        "doc": ["doc", "docx", "odt", "rtf", "xls", "xlsx", "ods", "ppt", "pptx", "odp", "epub"],
        "archive": ["zip", "tar", "gz", "xz", "zst", "bz2", "7z", "rar", "iso"],
        "code": ["qml", "js", "ts", "py", "sh", "fish", "lua", "c", "h", "cpp", "rs", "go", "java", "kt", "swift", "css", "html", "json", "toml", "yaml", "yml", "nix"],
        "text": ["txt", "md", "log", "conf", "ini", "cfg", "csv"]
    })

    function kindOf(path) {
        if ((path ?? "").endsWith("/"))
            return "folder";
        const ext = (path.split("/").pop().split(".").pop() ?? "").toLowerCase();
        for (const k in root.kinds)
            if (root.kinds[k].includes(ext))
                return k;
        return "file";
    }

    function glyphFor(kind) {
        switch (kind) {
        case "folder": return "folder";
        case "image": return "image";
        case "video": return "movie";
        case "audio": return "music_note";
        case "pdf": return "picture_as_pdf";
        case "doc": return "description";
        case "archive": return "folder_zip";
        case "code": return "code";
        case "text": return "notes";
        }
        return "draft";
    }

    // { path, name, kind, glyph, title, origin, from, at }
    function describe(path) {
        const p = path ?? "";
        const name = p.replace(/\/$/, "").split("/").pop();
        const kind = root.kindOf(p);
        const origin = Origins.originFor(p);
        const title = origin?.title ?? "";
        return {
            "path": p,
            "name": name,
            "kind": kind,
            "glyph": root.glyphFor(kind),
            "title": title.length > 0 ? title : name,
            "origin": origin,
            "from": Origins.describe(p),
            "at": origin?.at ?? 0
        };
    }

    // The phone, when one is paired and reachable (kdeconnect-cli -a), by name.
    property string phoneId: ""
    property string phoneName: ""
    readonly property bool phoneReachable: root.phoneId.length > 0
    Process {
        id: phoneProc
        command: ["bash", "-c", "kdeconnect-cli -a 2>/dev/null | sed -n 's/^- \\(.*\\): \\([0-9a-f]*\\) .*/\\2\\t\\1/p' | head -1"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.trim().split("\t");
                root.phoneId = f.length === 2 ? f[0] : "";
                root.phoneName = f.length === 2 ? f[1] : "";
            }
        }
    }
    Timer {
        interval: 60000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: phoneProc.running = true
    }

    // [{ id, label, glyph, run }]
    function actions(path) {
        const t = root.describe(path);
        const list = [];
        list.push({ "id": "open", "label": "Open", "glyph": "open_in_new", "run": () => root.open(path) });
        // The desktop's own editor, from wherever you met the file: a folder opens as a project,
        // a file at its first line - the two entry points the Claude app's rows already use.
        if (t.kind === "folder" || t.kind === "code" || t.kind === "text" || t.kind === "file")
            list.push({ "id": "code", "label": "Open in Graphis", "glyph": "code", "run": () => root.openInCode(path, t.kind === "folder") });
        list.push({ "id": "show", "label": "Show in Files", "glyph": "folder_open", "run": () => root.reveal(path) });
        if (!DropShelf.items.includes(path))
            list.push({ "id": "park", "label": "Park on the shelf", "glyph": "stacks", "run": () => DropShelf.addItems(["file://" + path]) });
        list.push({ "id": "hand", "label": "Hand to Praxis", "glyph": "smart_toy", "run": () => root.hand(path) });
        if (root.phoneReachable)
            list.push({ "id": "phone", "label": `To ${root.phoneName}`, "glyph": "smartphone", "run": () => root.toPhone(path) });
        if (t.kind === "image")
            list.push({ "id": "wallpaper", "label": "Set as wallpaper", "glyph": "wallpaper", "run": () => Wallpapers.apply(path) });
        list.push({ "id": "path", "label": "Copy path", "glyph": "content_copy", "run": () => root.copyPath(path) });
        if (t.origin)
            list.push({ "id": "forget", "label": "Forget where it came from", "glyph": "visibility_off", "run": () => Origins.forget(path) });
        return list;
    }

    // Nothing may be able to open a file: no application declares its type, a symlink dangles,
    // a file cannot be read. Detached, xdg-open's exit was never seen and a double-click that
    // did nothing looked like a click that never registered - so one open at a time is watched
    // and whoever asked is told why.
    signal openFailed(string path, string reason)
    function open(path) {
        if (openProc.running) {   // a second open while one is in flight: nothing to watch it with
            Quickshell.execDetached(["xdg-open", path]);
            return;
        }
        openProc.path = path;
        openProc.running = true;
    }
    Process {
        id: openProc
        property string path: ""
        command: ["xdg-open", openProc.path]
        stderr: StdioCollector { id: openErr }
        onExited: code => {
            if (code === 0)
                return;
            const name = openProc.path.split("/").pop();
            const e = openErr.text.toLowerCase();
            root.openFailed(openProc.path, code === 2 ? `${name} is gone`
                : /permission denied|not permitted/.test(e) ? `No permission to open ${name}`
                : `Nothing here opens ${name}`);
        }
    }
    function reveal(path) {
        Files.reveal(path);
    }
    function openInCode(path, asProject) {
        Quickshell.execDetached(asProject ? [`${Directories.tacitBin}/code-open`, path.replace(/\/$/, "")]
            : [`${Directories.tacitBin}/code-file`, path, "0"]);
    }
    function hand(path) {
        // A new session, opened where the file actually is: a tarball in Downloads is not a
        // question about whichever repo happened to be open last. The notch says it started,
        // and the session's own row appears there a moment later through the hook.
        const dir = path.replace(/\/[^/]*$/, "") || FileUtils.trimFileProtocol(Directories.home);
        Recents.launch(dir, `Look at ${path}. What is this, and what should I do about it?`);
        IslandController.request("copied", { "icon": "smart_toy", "text": `Handed to Praxis · ${path.split("/").pop()}` }, 70);
    }
    function toPhone(path) {
        if (!root.phoneReachable)
            return;
        Quickshell.execDetached(["kdeconnect-cli", "-d", root.phoneId, "--share", path]);
        IslandController.request("copied", { "icon": "smartphone", "text": `To ${root.phoneName} · ${path.split("/").pop()}` }, 70);
    }
    function copyPath(path) {
        Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(path)}' | wl-copy`]);
    }
}
