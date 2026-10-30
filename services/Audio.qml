pragma Singleton
pragma ComponentBehavior: Bound
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

/**
 * A nice wrapper for default Pipewire audio sink and source.
 */
Singleton {
    id: root

    // Misc props
    property bool ready: Pipewire.defaultAudioSink?.ready ?? false
    property PwNode sink: Pipewire.defaultAudioSink
    property PwNode source: Pipewire.defaultAudioSource
    readonly property real hardMaxValue: 2.00 // People keep joking about setting volume to 5172% so...
    property string audioTheme: Config.options.sounds.theme
    property real value: sink?.audio.volume ?? 0
    
    function friendlyDeviceName(node) {
        return (node.nickname || node.description || Translation.tr("Unknown"));
    }
    function appNodeDisplayName(node) {
        return (node.properties["application.name"] || node.description || node.name)
    }

    // Lists
    function correctType(node, isSink) {
        return (node.isSink === isSink) && node.audio
    }
    function appNodes(isSink) {
        return Pipewire.nodes.values.filter((node) => { // Should be list<PwNode> but it breaks ScriptModel
            return root.correctType(node, isSink) && node.isStream
        })
    }
    function devices(isSink) {
        return Pipewire.nodes.values.filter(node => {
            return root.correctType(node, isSink) && !node.isStream
        })
    }
    readonly property list<var> outputAppNodes: root.appNodes(true)
    readonly property list<var> inputAppNodes: root.appNodes(false)
    readonly property list<var> outputDevices: root.devices(true)
    readonly property list<var> inputDevices: root.devices(false)

    // Signals
    signal sinkProtectionTriggered(string reason);

    // Controls
    // The default sink is null between a sink disappearing and the next one arriving, and a
    // volume key pressed in that window must do nothing rather than throw.
    function toggleMute() {
        if (!Audio.sink?.audio) return;
        Audio.sink.audio.muted = !Audio.sink.audio.muted
    }

    function toggleMicMute() {
        if (!Audio.source?.audio) return;
        Audio.source.audio.muted = !Audio.source.audio.muted
    }

    function incrementVolume() {
        if (!Audio.sink?.audio) return;
        const currentVolume = Audio.value;
        const step = currentVolume < 0.1 ? 0.01 : 0.02;
        Audio.sink.audio.volume = Math.max(0, Math.min(1, Audio.sink.audio.volume + step));
    }
    
    function decrementVolume() {
        if (!Audio.sink?.audio) return;
        const currentVolume = Audio.value;
        const step = currentVolume < 0.1 ? 0.01 : 0.02;
        Audio.sink.audio.volume = Math.max(0, Math.min(1, Audio.sink.audio.volume - step));
    }

    function setDefaultSink(node) {
        Pipewire.preferredDefaultAudioSink = node;
    }

    // ---------------------------------------------------------------- headphones that arrive
    // A pinned default beats WirePlumber's own switching, and this desk pins the tuned speaker
    // chain (EQ, limiter, echo canceller). So a headset could connect, get a working sink, and
    // every app would carry on playing to the laptop speakers. Hand the output to a Bluetooth
    // sink when one appears, and give it back to whatever was playing before when it leaves.
    property PwNode sinkBeforeBluetooth: null
    readonly property var bluetoothSink: {
        for (const n of Pipewire.nodes.values)
            if (n.isSink && !n.isStream && (n.name + "").startsWith("bluez_output."))
                return n;
        return null;
    }
    onBluetoothSinkChanged: {
        if (root.bluetoothSink) {
            // The pin reads null whenever its configured name resolves to no live node, so fall
            // back to the effective default; and never memorise a Bluetooth node, or one headset
            // of two leaving would hand the output to the other instead of the speakers.
            const previous = Pipewire.preferredDefaultAudioSink ?? Pipewire.defaultAudioSink;
            if (previous && !((previous.name + "").startsWith("bluez_output.")))
                root.sinkBeforeBluetooth = previous;
            Pipewire.preferredDefaultAudioSink = root.bluetoothSink;
        } else {
            // Release the pin even with nothing memorised: leaving it on a departed headset is
            // what strands the default away from the tuned chain.
            Pipewire.preferredDefaultAudioSink = root.sinkBeforeBluetooth;
            root.sinkBeforeBluetooth = null;
        }
    }

    function setDefaultSource(node) {
        Pipewire.preferredDefaultAudioSource = node;
    }

    // Internals
    PwObjectTracker {
        objects: [sink, source, root.bluetoothSink, root.sinkBeforeBluetooth]
    }

    Connections { // Protection against sudden volume changes
        target: sink?.audio ?? null
        property bool lastReady: false
        property real lastVolume: 0
        // A new default sink starts from its own level, not the old device's
        onTargetChanged: {
            lastReady = false;
            lastVolume = 0;
        }
        function onVolumeChanged() {
            if (!Config.options.audio.protection.enable) return;
            const newVolume = sink.audio.volume;
            // when resuming from suspend, we should not write volume to avoid pipewire volume reset issues
            if (isNaN(newVolume) || newVolume === undefined || newVolume === null) {
                lastReady = false;
                lastVolume = 0;
                return;
            }
            if (!lastReady) {
                lastVolume = newVolume;
                lastReady = true;
                return;
            }
            const maxAllowedIncrease = Config.options.audio.protection.maxAllowedIncrease / 100; 
            const maxAllowed = Config.options.audio.protection.maxAllowed / 100;

            if (newVolume - lastVolume > maxAllowedIncrease) {
                sink.audio.volume = lastVolume;
                root.sinkProtectionTriggered(Translation.tr("a jump over %1%").arg(Config.options.audio.protection.maxAllowedIncrease));
            } else if (newVolume > maxAllowed || newVolume > root.hardMaxValue) {
                root.sinkProtectionTriggered(Translation.tr("the limit is %1%").arg(Config.options.audio.protection.maxAllowed));
                sink.audio.volume = Math.min(lastVolume, maxAllowed);
            }
            lastVolume = sink.audio.volume;
        }
    }

    function playSystemSound(soundName) {
        const ogaPath = `/usr/share/sounds/${root.audioTheme}/stereo/${soundName}.oga`;
        const oggPath = `/usr/share/sounds/${root.audioTheme}/stereo/${soundName}.ogg`;

        // Try playing .oga first
        let command = [
            "ffplay",
            "-nodisp",
            "-autoexit",
            ogaPath
        ];
        Quickshell.execDetached(command);

        // Also try playing .ogg (ffplay will just fail silently if file doesn't exist)
        command = [
            "ffplay",
            "-nodisp",
            "-autoexit",
            oggPath
        ];
        Quickshell.execDetached(command);
    }
}
