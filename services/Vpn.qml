pragma Singleton
import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * VPN as NetworkManager sees it: every wireguard or vpn connection profile, which one is up,
 * up/down/forget, and import from a file (a WireGuard .conf or an OpenVPN .ovpn is the
 * whole "add VPN" form). One rule: the VPN marked `autoVpn` comes up on a Wi-Fi network
 * that is not marked trusted, and goes down on one that is. Status follows `nmcli monitor`
 * (caelestia VPN.qml does the same); no provider daemons, no shell commands to configure.
 */
Singleton {
    id: root

    property var connections: []   // [{name, kind ("wireguard"|"openvpn"|...), active}]
    readonly property var active: root.connections.find(c => c.active) ?? null
    readonly property bool connected: root.active !== null
    property bool busy: false
    property string lastError: ""
    readonly property string autoVpn: Persistent.states.network.autoVpn ?? ""
    signal imported(string name)
    signal importFailed(string path, string reason)

    function refresh(): void {
        listProc.running = false;
        listProc.running = true;
    }
    function connect(name: string): void {
        if (root.busy)
            return;
        root.start(["nmcli", "connection", "up", name]);
    }
    function disconnect(): void {
        if (!root.active || root.busy)
            return;
        root.start(["nmcli", "connection", "down", root.active.name]);
    }
    // One way into the shared Process, so busy is set and the wait is bounded wherever the
    // command comes from.
    function start(cmd: var): void {
        root.busy = true;
        waitTimer.restart();
        actionProc.exec(cmd);
    }
    // `nmcli connection up` can sit for its own 90 s timeout (an OpenVPN profile waiting on auth)
    // and busy is cleared in one handler only, so the whole section stayed disabled with no cancel
    // and the pill answered nothing. Stop waiting first and say so; the command is left to finish,
    // as BluetoothSection's waitTimer leaves a pairing.
    Timer {
        id: waitTimer
        interval: 30000
        onTriggered: {
            root.lastError = Translation.tr("No answer after 30 seconds. It may still come up.");
            root.busy = false;
        }
    }
    property string pendingConnect: ""
    function toggle(name: string): void {
        if (root.busy)
            return;
        if (root.active && root.active.name === name) {
            root.disconnect();
        } else if (root.active) {
            // one tunnel at a time: down first, then the other up (actionProc.onExited)
            root.pendingConnect = name;
            root.disconnect();
        } else {
            root.connect(name);
        }
    }
    // Same guard as its siblings: all three share one Process, so a Forget on top of a connect
    // SIGTERMed the `nmcli connection up` and then let the dead run's exit clear busy, refresh and
    // fire pendingConnect - a Forget that silently cancelled a connect and could start a tunnel.
    function forget(name: string): void {
        if (root.busy)
            return;
        if (root.autoVpn === name)
            Persistent.states.network.autoVpn = "";
        root.start(["nmcli", "connection", "delete", name]);
    }
    function setAuto(name: string): void {
        Persistent.states.network.autoVpn = (root.autoVpn === name) ? "" : name;
        root.applyRule();
    }
    // A .conf with [Interface] is WireGuard; .ovpn is OpenVPN (needs networkmanager-openvpn).
    function importFile(path: string): void {
        const p = (path + "").replace(/^file:\/\//, "");
        importProc.path = p;
        importProc.exec(["bash", "-c", 'f="$1"; if grep -qi "^\\[Interface\\]" "$f"; then t=wireguard; elif [[ "$f" == *.ovpn ]] || grep -qiE "^(client|remote) " "$f"; then t=openvpn; else echo "not a VPN file" >&2; exit 2; fi; out=$(nmcli connection import type "$t" file "$f" 2>&1) || { echo "$out" >&2; exit 1; }; n=$(echo "$out" | sed -nE "s/.*Connection .([^\']+). .*/\\1/p"); [ -n "$n" ] && nmcli connection modify "$n" connection.autoconnect no >/dev/null 2>&1; echo "$n"', "_", p]);
    }
    function isVpnFile(path: string): bool {
        return /\.(conf|ovpn)$/i.test(path + "");
    }

    // ---- the rule: untrusted Wi-Fi -> auto VPN up; trusted or wired -> down
    property bool ruleSkipped: false
    function applyRule(): void {
        if (root.autoVpn.length === 0)
            return;
        if (root.busy) {
            root.ruleSkipped = true;
            return;
        }
        const wifi = Network.active;
        const wired = Network.ethernet;
        const trusted = wired || (wifi && Network.isTrusted(wifi.ssid));
        const online = wired || wifi !== null;
        const ours = root.active && root.active.name === root.autoVpn;
        if (online && !trusted && !root.active)
            root.connect(root.autoVpn);
        else if (trusted && ours)
            root.disconnect();
    }
    Connections {
        target: Network
        function onActiveChanged() { ruleLater.restart(); }
        function onEthernetChanged() { ruleLater.restart(); }
    }
    Timer {
        id: ruleLater
        interval: 2500   // let the link settle before the tunnel goes up over it
        onTriggered: root.applyRule()
    }

    Process {
        id: listProc
        running: true
        command: ["nmcli", "-t", "-f", "NAME,TYPE,ACTIVE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = [];
                for (const line of text.split("\n")) {
                    const parts = Network.splitTerse(line);
                    if (parts.length < 3)
                        continue;
                    const type = parts[parts.length - 2], active = parts[parts.length - 1];
                    const name = parts.slice(0, parts.length - 2).join(":");
                    if (type === "wireguard")
                        list.push({ name: name, kind: "wireguard", active: active === "yes" });
                    else if (type === "vpn")
                        list.push({ name: name, kind: "openvpn", active: active === "yes" });
                }
                root.connections = list;
            }
        }
    }
    Process {
        id: monitor
        running: true
        command: ["nmcli", "monitor"]
        stdout: SplitParser {
            onRead: refreshLater.restart()
        }
    }
    Timer {
        id: refreshLater
        interval: 400
        onTriggered: root.refresh()
    }
    Process {
        id: actionProc
        environment: ({ LANG: "C", LC_ALL: "C" })
        stderr: StdioCollector {
            onStreamFinished: root.lastError = text.trim()
        }
        onExited: {
            waitTimer.stop();
            root.busy = false;
            root.refresh();
            if (root.ruleSkipped) {   // a network change that came in while busy was skipped
                root.ruleSkipped = false;
                ruleLater.restart();
            }
            if (root.pendingConnect.length > 0) {
                const next = root.pendingConnect;
                root.pendingConnect = "";
                root.connect(next);
            }
        }
    }
    Process {
        id: importProc
        property string path: ""
        property string out: ""
        stdout: StdioCollector {
            onStreamFinished: importProc.out = text.trim()
        }
        stderr: StdioCollector {
            onStreamFinished: root.lastError = text.trim()
        }
        onExited: (code) => {
            if (code === 0) {
                root.refresh();
                root.imported(importProc.out);
            } else {
                root.importFailed(importProc.path, root.lastError);
            }
        }
    }
}
