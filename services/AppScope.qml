pragma Singleton

import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * Starting apps, each in its own systemd scope (~/.local/bin/app-scope), instead of as a
 * child of the shell. The kernel and systemd-oomd then see apps one by one: memory is
 * taken from the app in the background, an app can be stopped without the desktop, and
 * focus-priority can favour the app in front. The way GNOME and KDE start apps.
 */
Singleton {
    id: root

    readonly property string runner: `${Quickshell.env("TACIT_BIN") || Quickshell.env("HOME") + "/.local/bin"}/app-scope`

    /** A DesktopEntry or one of its DesktopActions. A terminal app keeps the caller's own path. */
    function launch(entry) {
        if (!entry)
            return;
        const command = entry.command ?? [];
        if (command.length === 0) {
            entry.execute();
            return;
        }
        // The runner lives outside this repo, and execDetached fails silently when it is not
        // there, so every dock, taskbar, launcher and palette launch did nothing at all on a
        // machine without it. Tested at launch time rather than once at startup because the
        // first click can come before any probe has answered; positional, so nothing is quoted
        // twice. Without the runner the app starts as it did before scopes, unisolated.
        const context = { command: ["bash", "-c", '[ -x "$0" ] && exec "$0" "$@"; shift; exec "$@"',
            root.runner, entry.id || command[0]].concat(command) };
        if ((entry.workingDirectory ?? "").length)
            context.workingDirectory = entry.workingDirectory;
        Quickshell.execDetached(context);
    }

    // shell.qml loads this at start, so Apps' apps can report before anything was launched from here
    function load() {}

    // Apps' apps (scripts/store/bundle.py run) report here: one being made ready after a system update before it starts
    // (a download, where a start used to look like nothing at all), and one that stopped. One that stopped with an error
    // before any window showed is said in the notch, with Try again; its errors are in ~/.cache/tacit-bundle/<app>.log.
    // Discord 2026-11-04: "Discord isn't opening", and nothing on screen or on disk said why.
    signal startFailed(string entryId)
    function entryOf(app) {
        return DesktopEntries.applications.values.find(e => (e.command ?? [])[1] === "run" && (e.command ?? [])[2] === app) ?? null;
    }
    function hasWindow(entry) {
        return ToplevelManager.toplevels.values.some(t => DesktopEntries.heuristicLookup(t.appId)?.id === entry.id);
    }
    IpcHandler {
        target: "apps"

        function preparing(app: string, bytes: int): void {
            const mb = Math.round(bytes / 1048576);
            IslandController.request("window", {
                "text": `Getting ${root.entryOf(app)?.name ?? app} ready` + (mb > 0 ? ` · ${mb} MB` : ""),
                "icon": "downloading",
                "app": app,
                "hold": 180000
            }, 65);
        }
        function ready(app: string): void {
            if (IslandController.transientState === "window" && IslandController.payload?.app === app)
                IslandController.dismiss();
        }
        function exited(app: string, code: int, seconds: int): void {
            const entry = root.entryOf(app);
            // 0: closed, or a second start that handed its link to the first; 130 and 143: asked to stop; past a minute it
            // had opened
            if ([0, 130, 143].includes(code) || seconds > 60 || !entry || root.hasWindow(entry))
                return;
            root.startFailed(entry.id);
            IslandController.request("window", {
                "text": `${entry.name} didn't open`,
                "icon": "error",
                "pill": "Try again",
                "run": () => root.launch(entry),
                "hold": 10000
            }, 65);
        }
    }
}
