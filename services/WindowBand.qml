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
    // several windows back at once, one after another in the order given: the last one ends in front
    function reopenAll(addresses) {
        const a = addresses.filter(x => /^0x[0-9a-fA-F]+$/.test(x));
        if (a.length > 0)
            Quickshell.execDetached(["sh", "-c", a.map(x => `hyprctl tacitgrip reopen ${x}`).join("; ")]);
    }
    // the menu's rows and the notch's pill
    function act(verb, address) {
        root.menu = null;
        root.command(verb, address);
    }

    // a window the band holds away, by the plugin's special workspaces: "hidden", "closed" (closed after a few seconds
    // unless reopened), or "" for any other
    function heldAs(toplevel) {
        const h = Hyprland.toplevels.values.find(x => x.wayland === toplevel);
        const ws = h?.workspace?.name ?? "";
        return ws === "special:tacit-hidden" ? "hidden" : ws === "special:tacit-closed" ? "closed" : "";
    }
    function addressOf(toplevel) {
        const a = Hyprland.toplevels.values.find(x => x.wayland === toplevel)?.address ?? "";
        return a.length === 0 || a.startsWith("0x") ? a : `0x${a}`;
    }

    function toplevelAt(address) {
        const a = (address ?? "").replace(/^0x/, "");
        return Hyprland.toplevels.values.find(t => (t.address ?? "").replace(/^0x/, "") === a) ?? null;
    }
    function screenOf(address) {
        const name = root.toplevelAt(address)?.monitor?.name ?? Hyprland.focusedMonitor?.name ?? "";
        return Quickshell.screens.find(s => s.name === name) ?? Quickshell.screens[0];
    }
    // the button lit for the window that lands in it (PaletteDock), when it lands
    signal landed(string appId)

    // where the held window goes, for the plugin's flight: the dock's button (on the dock's screen, from PaletteDock)
    // or the notch as it is (it goes in under their glass)
    function reportHide(x, y, w, h) {
        if (root.dragAddress.length === 0)
            return;
        const s = root.screenOf(root.dragAddress);
        Quickshell.execDetached(["hyprctl", "tacitgrip", "target", root.dragAddress, "hide",
                                 `${s.x + x}`, `${s.y + y}`, `${w}`, `${h}`]);
    }
    function reportClose() {
        if (root.dragAddress.length === 0)
            return;
        const s = root.screenOf(root.dragAddress);
        const g = IslandController.geometryFor("window");
        Quickshell.execDetached(["hyprctl", "tacitgrip", "target", root.dragAddress, "close",
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

    function nameFor(cls) {
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
            if (event.name !== "tacitgrip")
                return;
            const f = event.data.split(",");
            switch (f[0]) {
            case "lift":
                dockRetreat.stop();
                root.dragAddress = f[1];
                root.dragApp = root.toplevelAt(f[1])?.wayland?.appId ?? "";
                root.zone = "none";
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
            case "drop":
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
                root.mark("close");
                root.say(`${root.nameFor(f[2] ?? "")} closed`, "close", "Reopen", "reopen", f[1], 7000);
                break;
            case "hidden":
                root.landed(root.dropInto);
                dockRetreat.restart();
                root.mark("hide");
                root.say(`${root.nameFor(f[2] ?? "")} hidden`, "minimize", "Show", "reopen", f[1], 3500);
                break;
            case "side":
                root.mark("side");
                root.say(`${root.nameFor(f[3] ?? "")} on the ${f[2]}`, f[2] === "left" ? "splitscreen_left" : "splitscreen_right",
                         "Undo", "unside", f[1], 6000);
                break;
            case "restored":
                if (IslandController.transientState === "window" && IslandController.payload?.address === f[1])
                    IslandController.dismiss();
                break;
            case "hover":
                root.hint();
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
