pragma Singleton
pragma ComponentBehavior: Bound
import Quickshell
import Quickshell.Io
import qs
import qs.modules.common
import qs.services

Singleton {
    id: root
    
    signal requestCenter(string identifier)

    readonly property list<var> availableWidgets: [
        { identifier: "crosshair", materialSymbol: "point_scan", label: Translation.tr("Crosshair") },
        { identifier: "fpsLimiter", materialSymbol: "animation", label: Translation.tr("FPS limit") },
        { identifier: "floatingImage", materialSymbol: "imagesmode", label: Translation.tr("Image") },
        { identifier: "recorder", materialSymbol: "screen_record", label: Translation.tr("Recorder") },
        { identifier: "resources", materialSymbol: "browse_activity", label: Translation.tr("Resources") },
        { identifier: "notes", materialSymbol: "note_stack", label: Translation.tr("Notes") },
        { identifier: "volumeMixer", materialSymbol: "volume_up", label: Translation.tr("Sound") },
    ]
    
    readonly property bool hasPinnedWidgets: root.pinnedWidgetIdentifiers.length > 0

    property list<string> pinnedWidgetIdentifiers: []
    property list<var> clickableWidgets: []

    function pin(identifier: string, pin = true) {
        if (pin) {
            if (!root.pinnedWidgetIdentifiers.includes(identifier)) {
                root.pinnedWidgetIdentifiers.push(identifier)
            }
        } else {
            root.pinnedWidgetIdentifiers = root.pinnedWidgetIdentifiers.filter(id => id !== identifier)
        }
    }

    function registerClickableWidget(widget: var, clickable = true) {
        if (clickable) {
            if (!root.clickableWidgets.includes(widget)) {
                root.clickableWidgets.push(widget)
            }
        } else {
            root.clickableWidgets = root.clickableWidgets.filter(w => w !== widget)
        }
    }

    // Super+G's picture. Pinax asks in a window of its own, so the overlay and its grab on the
    // keyboard step aside first; the choice comes back to `picked` below, which outlives the
    // widget (closing the overlay throws it away) because this singleton does.
    function pickImage() {
        GlobalStates.overlayOpen = false;
        Files.pick(Directories.pictures, Directories.shellFile, "floatingImage",
            Translation.tr("A picture for the overlay"), false);
    }

    IpcHandler {
        target: "floatingImage"

        // Files hands its choice back here, as a JSON list (padded with a space each side: see
        // Files.pickDone); a cancel arrives as an empty list.
        function picked(json: string): void {
            let paths;
            try { paths = JSON.parse(json); } catch (e) { paths = json; }
            if (typeof paths === "string")
                paths = paths.split("\n");
            const path = (paths ?? []).map(p => String(p).trim()).find(p => p.length > 0);
            if (path === undefined)
                return;
            Config.options.overlay.floatingImage.imageSource = path;
            GlobalStates.overlayOpen = true;
        }
    }
}
