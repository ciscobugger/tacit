pragma Singleton
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

/**
 * A nice wrapper for date and time strings.
 */
Singleton {
    id: root

    property alias inhibit: idleInhibitor.enabled
    inhibit: false

    // Whether readyChanged is still to come depends on which of the two was built first: this
    // is a lazy singleton, and a Persistent that loaded before it would never signal again.
    Component.onCompleted: {
        if (Persistent.ready) {
            root.inhibit = Persistent.states.idle.inhibit;
        }
    }
    Connections {
        target: Persistent
        function onReadyChanged() {
            root.inhibit = Persistent.states.idle.inhibit;
        }
    }

    // qs -c tacit ipc call idle toggle
    IpcHandler {
        target: "idle"

        function toggle(): void {
            root.toggleInhibit();
        }
    }

    // Stay awake until the next start; not written to Persistent.
    function inhibitForSession() {
        root.inhibit = true;
    }

    function toggleInhibit(active = null) {
        if (active !== null) {
            root.inhibit = active;
        } else {
            root.inhibit = !root.inhibit;
        }
        Persistent.states.idle.inhibit = root.inhibit;
    }

    IdleInhibitor {
        id: idleInhibitor
        window: PanelWindow {
            // Inhibitor requires a "visible" surface
            // Actually not lol
            implicitWidth: 0
            implicitHeight: 0
            color: "transparent"
            // Just in case...
            anchors {
                right: true
                bottom: true
            }
            // Make it not interactable
            mask: Region {
                item: null
            }
        }
    }
}