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

    // The phone, when one is connected and reachable (services/PhoneLink.qml), by name.
    readonly property string phoneId: PhoneLink.phoneId
    readonly property string phoneName: PhoneLink.phoneName
    readonly property bool phoneReachable: PhoneLink.phoneReachable

    // [{ id, label, glyph, run }]
    function actions(path) {
        const t = root.describe(path);
        const list = [];
        if (root.isLauncher(path)) {
            list.push({ "id": "start", "label": "Start", "glyph": "play_arrow", "run": () => root.start(path) });
            list.push({ "id": "open", "label": "Open as text", "glyph": "code", "run": () => root.openInCode(path, false) });
        } else {
            list.push({ "id": "open", "label": "Open", "glyph": "open_in_new", "run": () => root.open(path) });
        }
        // The desktop's own editor, from wherever you met the file: a folder opens as a project,
        // a file at its first line - the two entry points the Claude app's rows already use.
        if (t.kind === "folder" || t.kind === "code" || t.kind === "text" || t.kind === "file")
            list.push({ "id": "code", "label": "Open in Graphis", "glyph": "code", "run": () => root.openInCode(path, t.kind === "folder") });
        list.push({ "id": "show", "label": "Show in Files", "glyph": "folder_open", "run": () => root.reveal(path) });
        // Not a folder: the daemon sends files. Before a phone is connected it leads to the phone's page in Files.
        if (t.kind !== "folder")
            list.push({ "id": "phone", "label": PhoneLink.menuWords, "glyph": "smartphone", "run": () => root.toPhone(path) });
        if (!DropShelf.items.includes(path))
            list.push({ "id": "park", "label": "Park on the shelf", "glyph": "stacks", "run": () => DropShelf.addItems(["file://" + path]) });
        list.push({ "id": "hand", "label": "Hand to Praxis", "glyph": "smart_toy", "run": () => root.hand(path) });
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
    // A launcher (a .desktop file) double-clicked starts its app when it is marked as a program (the executable bit, as
    // GNOME and KDE ask): one that came from a download opens as text in Graphis until then (no app opens a launcher
    // for xdg-open). Start in its menu runs it either way.
    function open(path) {
        if (root.isLauncher(path)) {
            launcherCheck.path = path;
            launcherCheck.running = true;
            return;
        }
        root.openFile(path);
    }
    Process {
        id: launcherCheck
        property string path: ""
        command: ["test", "-x", launcherCheck.path]
        onExited: code => code === 0 ? root.start(launcherCheck.path) : root.openInCode(launcherCheck.path, false)
    }
    function isLauncher(path) {
        return /\.desktop$/i.test(path ?? "");
    }
    // its app in its own scope, as the dock and the launcher start apps (AppScope), and detached as they are: a watched
    // process takes the app it started down with it when it ends. Without the runner, as it is
    function start(path) {
        const name = path.split("/").pop().replace(/\.desktop$/i, "");
        Quickshell.execDetached(["bash", "-c", '[ -x "$0" ] && exec "$0" "$@"; shift; exec "$@"', AppScope.runner, name, "gio", "launch", path]);
    }
    function openFile(path) {
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
        PhoneLink.send([path]);
    }
    function copyPath(path) {
        Quickshell.execDetached(["bash", "-c", `printf '%s' '${StringUtils.shellSingleQuoteEscape(path)}' | wl-copy`]);
    }
}
