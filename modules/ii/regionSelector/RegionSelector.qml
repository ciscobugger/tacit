pragma ComponentBehavior: Bound
import qs
import qs.modules.common
import qs.modules.common.functions
import qs.services
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Scope {
    id: root

    function dismiss() {
        GlobalStates.regionSelectorOpen = false
    }

    property var action: RegionSelection.SnipAction.Copy
    property var selectionMode: RegionSelection.SelectionMode.RectCorners
    property bool recordWindow: false

    // the notch's recording choice: an area or a window to pick here (IslandController.chooseRecord)
    Connections {
        target: GlobalStates
        function onRecordPickChanged() {
            if (GlobalStates.recordPick === "")
                return;
            root.recordWindow = GlobalStates.recordPick === "window";
            GlobalStates.recordPick = "";
            root.action = RegionSelection.SnipAction.Record;
            root.selectionMode = RegionSelection.SelectionMode.RectCorners;
            GlobalStates.regionSelectorOpen = true;
        }
    }

    // The selector freezes the screen behind it. Restored after an unlock it would be a stale
    // picture of the pre-lock desktop swallowing every click, so the lock ends the selection.
    Connections {
        target: GlobalStates
        function onScreenLockedChanged() {
            if (GlobalStates.screenLocked) root.dismiss();
        }
    }
    
    // Layer boxes are read once per open; fetching before the Loaders create the windows gives
    // the fetch a head start and keeps the previous open's boxes from showing.
    Connections {
        target: GlobalStates
        function onRegionSelectorOpenChanged() {
            if (GlobalStates.regionSelectorOpen) HyprlandData.updateLayers();
        }
    }

    Variants {
        model: Quickshell.screens
        delegate: Loader {
            id: regionSelectorLoader
            required property var modelData
            active: GlobalStates.regionSelectorOpen && !GlobalStates.screenLocked

            sourceComponent: RegionSelection {
                screen: regionSelectorLoader.modelData
                onDismiss: root.dismiss()
                action: root.action
                selectionMode: root.selectionMode
                recordWindow: root.recordWindow
            }
        }
    }

    function screenshot() {
        if (Persistent.states.record.enable) {
            const saveDir = Config.options.screenSnip.savePath !== "" ? Config.options.screenSnip.savePath : "";
            if (saveDir !== "") {
                // The notch parks saved screenshots on its shelf and says so; a notification on
                // top of that would announce the same thing twice.
                const notchParks = Config.options.island.enable && Config.options.island.states.download;
                const announce = notchParks ? "" : ` && notify-send "Screenshot Saved" "Saved to $filePath" -a "Screen Snip" -i "image-x-generic"`;
                const dirQ = StringUtils.shellSingleQuoteEscape(saveDir);
                const cmd = `mkdir -p '${dirQ}' && filePath='${dirQ}'"/screenshot-$(date '+%Y-%m-%d_%H.%M.%S').png" && grim -g "$(slurp)" "$filePath" && cat "$filePath" | wl-copy` + announce;
                Quickshell.execDetached(["bash", "-c", cmd]);
            } else {
                const cmd = `grim -g "$(slurp)" - | wl-copy && notify-send "Screenshot Copied" "Copied to clipboard" -a "Screen Snip" -i "image-x-generic"`;
                Quickshell.execDetached(["bash", "-c", cmd]);
            }
            return;
        }
        root.action = RegionSelection.SnipAction.Copy
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    function search() {
        root.action = RegionSelection.SnipAction.Search
        if (Config.options.search.imageSearch.useCircleSelection) {
            root.selectionMode = RegionSelection.SelectionMode.Circle
        } else {
            root.selectionMode = RegionSelection.SelectionMode.RectCorners
        }
        GlobalStates.regionSelectorOpen = true
    }

    function ocr() {
        root.action = RegionSelection.SnipAction.CharRecognition
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    // draw a box, and it lands in the Claude app on the session you have open
    function claude() {
        root.action = RegionSelection.SnipAction.Claude
        root.selectionMode = RegionSelection.SelectionMode.RectCorners
        GlobalStates.regionSelectorOpen = true
    }

    // the notch asks what to record (or stops the one running); without the notch, the area picker
    function record() {
        IslandController.openRecord();
    }

    function recordWithSound() {
        Persistent.states.record.sound = "system";
        IslandController.openRecord();
    }

    IpcHandler {
        target: "region"

        function screenshot() {
            root.screenshot()
        }
        function search() {
            root.search()
        }
        function ocr() {
            root.ocr()
        }
        function record() {
            root.record()
        }
        function recordWithSound() {
            root.recordWithSound()
        }
        function claude() {
            root.claude()
        }
    }

    CompositorGlobalShortcut {
        name: "regionScreenshot"
        description: "Takes a screenshot of the selected region"
        onPressed: root.screenshot()
    }
    CompositorGlobalShortcut {
        name: "regionSearch"
        description: "Searches the selected region"
        onPressed: root.search()
    }
    CompositorGlobalShortcut {
        name: "regionOcr"
        description: "Recognizes text in the selected region"
        onPressed: root.ocr()
    }
    CompositorGlobalShortcut {
        name: "regionClaude"
        description: "Sends the selected region to the Claude app"
        onPressed: root.claude()
    }
    CompositorGlobalShortcut {
        name: "regionRecord"
        description: "Records the selected region"
        onPressed: root.record()
    }
    CompositorGlobalShortcut {
        name: "regionRecordWithSound"
        description: "Records the selected region with sound"
        onPressed: root.recordWithSound()
    }
}