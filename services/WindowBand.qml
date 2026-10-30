pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.modules.common
import qs.modules.common.functions

// The window band (tacit-frame, Tacit's Hyprland plugin) in the shell: what a gesture did, said in the notch with the
// way back (Reopen, Show, Undo); the hint, until each gesture has been used once; the menu a right click on a
// window's top edge asks for. Without the plugin no tacitgrip events come, and none of this shows.
Singleton {
    id: root

    // the menu while it is open: { address, monitor, x, y } (logical, on that monitor)
    property var menu: null
    // the window held by the hand, its program, and where it is heading (none, close, hide, left, right)
    property string dragAddress: ""
    property string dragApp: ""
    property string zone: "none"
    // the dock up for the band: while a window is held over the bottom, and while one lands in its button
    property bool holdDock: false
    // the program whose button takes the window (PaletteDock lights it and says where it is)
    property string dropInto: ""
    // the gestures the person has used (close, hide, side), kept across restarts: the hint stops once all are known
    property var used: ({})
    property real hintedAt: 0
    readonly property int hintEvery: 10 * 60 * 1000
    readonly property string filePath: FileUtils.trimFileProtocol(`${Directories.state}/user/window-band.json`)

    function command(verb, address) {
        Quickshell.execDetached(["hyprctl", "tacitgrip", verb, address]);
    }
    // several windows back at once (the plugin brings them in the reverse of the order they went, the last one in front)
    function reopenAll(addresses) {
        const a = addresses.filter(x => /^0x[0-9a-fA-F]+$/.test(x));
        // a plugin from before reopen-all answers without "back": then one at a time
        if (a.length > 0)
            Quickshell.execDetached(["sh", "-c", `hyprctl tacitgrip reopen-all ${a.join(" ")} | grep -q back || for x in ${a.join(" ")}; do hyprctl tacitgrip reopen $x; done`]);
    }
    // the menu's rows and the notch's pill
    function act(verb, address) {
        root.menu = null;
        root.command(verb, address);
    }

    // a window the band holds away, by the plugin's special workspaces: "hidden", "closed" (closed after a few seconds
    // unless reopened), or "" for any other
    // the windows the plugin holds away, by address: "hidden" or "closed". Kept from the plugin's own events (and asked
    // for once at start), not from Hyprland's workspaces: the places it holds windows in are its own, and the shell's
    // view of their workspace was not reliable (a dock click found nothing to bring back, 2026-10-29)
    property var held: ({})
    function setHeld(address, kind) {
        const h = Object.assign({}, root.held);
        if (kind)
            h[root.norm(address)] = kind;
        else
            delete h[root.norm(address)];
        root.held = h;
    }
    // A window can go away without a "restored" (closed for good, quit while hidden, crashed). Clearing only on
    // "restored" left its address in `held`; a later window reusing that address was then drawn as hidden/closed and
    // the dock could not focus or reopen it.
    function forget(address) {
        if (!address || address.length === 0)
            return;
        const a = root.norm(address);
        if ((root.held[a] ?? "").length > 0)
            root.setHeld(a, "");
        if (root.norm(root.dragAddress) === a) {
            root.dragAddress = "";
            root.holdDock = false;
            root.dropInto = "";
            root.zone = "none";
            foldWatchdog.stop();
        }
    }
    function norm(a) {
        return (a ?? "").replace(/^0x/, "");
    }
    function heldAs(toplevel) {
        const a = Hyprland.toplevels.values.find(x => x.wayland === toplevel)?.address ?? "";
        return a.length > 0 ? (root.held[root.norm(a)] ?? "") : "";
    }
    Process {
        id: heldQuery
        property int tries: 0
        running: true
        command: ["hyprctl", "tacitgrip", "held"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const h = {};
                    for (const w of JSON.parse(this.text))
                        h[root.norm(w.address)] = w.kind;
                    root.held = h;
                    heldQuery.tries = 0;
                } catch (e) {
                    // The plugin was not answering yet (or not loaded). Ask again rather than starting with an empty
                    // set: a hidden window it already holds would otherwise be lost until the next event.
                    if (heldQuery.tries < 3) {
                        heldQuery.tries++;
                        heldRetry.restart();
                    }
                }
            }
        }
    }
    Timer {
        id: heldRetry
        interval: 2000
        onTriggered: if (!heldQuery.running) heldQuery.running = true
    }
    // One more ask after the first events have settled: a window caught mid-fold is not in "held" the instant the
    // shell starts, and this is the only start-up source (events keep it current afterwards).
    Timer {
        id: heldRefresh
        interval: 3000
        running: true
        onTriggered: if (!heldQuery.running) heldQuery.running = true
    }
    function addressOf(toplevel) {
        const a = Hyprland.toplevels.values.find(x => x.wayland === toplevel)?.address ?? "";
        return a.length === 0 || a.startsWith("0x") ? a : `0x${a}`;
    }

    function toplevelAt(address) {
        const a = (address ?? "").replace(/^0x/, "");
        return Hyprland.toplevels.values.find(t => (t.address ?? "").replace(/^0x/, "") === a) ?? null;
    }
    // The dock's id for a window's class. TaskbarApps lower-cases and aliases ("browser-cef" -> "thyris"), while the
    // plugin's window says the raw id; the button that takes a window is looked up by the dock's id, so the band must
    // send it too (before, an X11 window sent "" and Thyris sent "browser-cef", and no button ever lit).
    function dockId(cls) {
        const c = String(cls ?? "").toLowerCase();
        return TaskbarApps.aliases[c] ?? c;
    }
    function appIdOf(address) {
        const t = root.toplevelAt(address);
        return root.dockId(t?.wayland?.appId ?? t?.lastIpcObject?.class ?? "");
    }
    function screenOf(address) {
        const name = root.toplevelAt(address)?.monitor?.name ?? Hyprland.focusedMonitor?.name ?? "";
        return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
    }
    // the button lit for the window that lands in it (PaletteDock), when it lands
    signal landed(string appId)
    // the right button that opened the window's menu let go (WindowMenu: held, moved and let go picks a place)
    signal menuReleased(string address)

    // where the held window goes, for the plugin's flight: the dock's button (on the dock's screen, from PaletteDock)
    // or the notch as it is (it goes in under their glass)
    function reportHide(x, y, w, h) {
        if (root.dragAddress.length === 0)
            return;
        const s = root.screenOf(root.dragAddress);
        Quickshell.execDetached(["hyprctl", "tacitgrip", "target", root.dragAddress, "hide",
                                 `${s.x + x}`, `${s.y + y}`, `${w}`, `${h}`]);
    }
    function reportClose(address = root.dragAddress) {
        if (address.length === 0)
            return;
        const s = root.screenOf(address);
        const g = IslandController.geometryFor("window");
        Quickshell.execDetached(["hyprctl", "tacitgrip", "target", address, "close",
                                 `${s.x + (s.width - g.w) / 2}`, `${s.y + Config.options.island.topMargin}`, `${g.w}`, `${g.h}`]);
    }
    // again once the notch has grown to say "Close <app>", so the window goes into the notch as it then is
    Timer {
        id: closeReport
        interval: 300
        onTriggered: if (root.zone === "close") root.reportClose()
    }
    Timer {
        id: dockRetreat
        interval: 1100
        onTriggered: {
            root.holdDock = false;
            root.dropInto = "";
        }
    }
    // A fold that never reports "hidden" (the client died, the plugin lost the window) used to leave the dock up and
    // its button in the "taking" state forever. Armed only after the window has been let go (fold), never while the
    // hand is still carrying it.
    Timer {
        id: foldWatchdog
        interval: 6000
        onTriggered: {
            if (!root.holdDock)
                return;
            root.holdDock = false;
            root.dropInto = "";
            root.dragAddress = "";
            root.zone = "none";
        }
    }
    function watchFold() {
        foldWatchdog.restart();
    }

    // the names the dock gives Tacit's own programs (PaletteDock.known), so the notch and the dock say the same
    readonly property var known: ({ "org.quickshell": "Pinax", "praxis": "Praxis", "browser": "Thyris", "browser-cef": "Thyris",
                                    "thyris": "Thyris", "viewer": "Viewer", "graphis": "Graphis", "settings": "Settings",
                                    "foot": "Terminal" })
    function nameFor(cls) {
        if (root.known[cls])
            return root.known[cls];
        const e = DesktopEntries.byId(cls) ?? DesktopEntries.heuristicLookup(cls);
        return e?.name || (cls.length > 0 ? cls.charAt(0).toUpperCase() + cls.slice(1) : "Window");
    }
    function say(text, icon, pill, verb, address, hold) {
        IslandController.request("window", {
            "text": text,
            "icon": icon,
            "pill": pill,
            "verb": verb,
            "address": address,
            "hold": hold
        }, 65);
    }
    function mark(gesture) {
        if (root.used[gesture])
            return;
        const u = Object.assign({}, root.used);
        u[gesture] = true;
        root.used = u;
        bandFile.setText(JSON.stringify({ "used": u }));
    }
    function hint() {
        if (root.used.close && root.used.hide)
            return;
        const now = Date.now();
        if (now - root.hintedAt < root.hintEvery)
            return;
        root.hintedAt = now;
        IslandController.request("window", {
            "text": "Drag up to close · down to hide",
            "icon": "swipe_vertical",
            "hold": 4000
        }, 40);
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // A window destroyed or closed for good: forget anything the shell still held for its address (the plugin
            // sends no "restored" for these, and addresses are reused).
            if (event.name === "closewindow" || event.name === "destroywindow") {
                root.forget((event.data ?? "").trim());
                return;
            }
            if (event.name !== "tacitgrip")
                return;
            const f = event.data.split(",");
            switch (f[0]) {
            case "lift":
                dockRetreat.stop();
                foldWatchdog.stop();
                root.dragAddress = f[1];
                root.dragApp = root.appIdOf(f[1]);
                root.zone = "none";
                IslandController.closeRequested();      // a sheet opened by an earlier hover would cover the band
                break;
            case "zone":
                root.zone = f[2] ?? "none";
                if (root.zone === "hide") {
                    root.dropInto = root.dragApp;
                    root.holdDock = true;
                } else {
                    root.dropInto = "";
                    root.holdDock = false;
                }
                if (root.zone === "close") {
                    root.reportClose();
                    closeReport.restart();
                    const t = root.toplevelAt(f[1]);
                    IslandController.request("window", {
                        "text": `Close ${root.nameFor(t?.wayland?.appId ?? t?.lastIpcObject?.class ?? "")}`,
                        "icon": "close",
                        "hold": 60000,
                        "prompt": true
                    }, 65);
                } else if (IslandController.transientState === "window" && IslandController.payload?.prompt) {
                    IslandController.dismiss();
                }
                break;
            // a window on its way into the dock or the notch, however it was sent (the hand, a flick, the menu, a key): the
            // dock rises for it and its button tells the plugin where it is; the notch's place is named at once
            case "fold":
                if (f[2] === "hide") {
                    dockRetreat.stop();
                    foldWatchdog.restart();
                    root.dragAddress = f[1];
                    root.dragApp = root.appIdOf(f[1]);
                    root.dropInto = root.dragApp;
                    root.holdDock = true;
                } else if (f[2] === "close") {
                    root.reportClose(f[1]);
                }
                break;
            case "drop":
                foldWatchdog.stop();
                // a window let go over the bottom flies into its button: the dock stays to take it (hidden, below)
                if (root.zone !== "hide") {
                    root.holdDock = false;
                    root.dropInto = "";
                } else {
                    dockRetreat.restart();
                }
                if (root.zone !== "close" && IslandController.transientState === "window" && IslandController.payload?.prompt)
                    IslandController.dismiss();
                root.zone = "none";
                root.dragAddress = "";
                break;
            case "closed":
                foldWatchdog.stop();
                root.setHeld(f[1], "closed");
                root.mark("close");
                root.say(`${root.nameFor(f[2] ?? "")} closed`, "close", "Reopen", "reopen", f[1], 7000);
                break;
            case "hidden":
                foldWatchdog.stop();
                root.setHeld(f[1], "hidden");
                root.landed(root.dropInto);
                root.dragAddress = "";
                dockRetreat.restart();
                root.mark("hide");
                root.say(`${root.nameFor(f[2] ?? "")} hidden`, "minimize", "Show", "reopen", f[1], 3500);
                break;
            case "side":
                foldWatchdog.stop();
                root.mark("side");
                root.say(`${root.nameFor(f[3] ?? "")} on the ${f[2]}`, f[2] === "left" ? "splitscreen_left" : "splitscreen_right",
                         "Undo", "unside", f[1], 6000);
                break;
            case "restored":
                foldWatchdog.stop();
                root.setHeld(f[1], "");
                if (IslandController.transientState === "window" && IslandController.payload?.address === f[1])
                    IslandController.dismiss();
                break;
            case "hover":
                root.hint();
                break;
            case "menuup":
                root.menuReleased(f[1]);
                break;
            case "menu":
                root.menu = { "address": f[1], "monitor": f[2], "x": Number(f[3]), "y": Number(f[4]) };
                break;
            }
        }
    }

    FileView {
        id: bandFile
        path: Qt.resolvedUrl(root.filePath)
        onLoaded: {
            try {
                root.used = JSON.parse(bandFile.text()).used ?? ({});
            } catch (e) {
                root.used = ({});
            }
        }
        onLoadFailed: error => {
            if (error == FileViewError.FileNotFound)
                bandFile.setText(JSON.stringify({ "used": {} }));
        }
    }
}
