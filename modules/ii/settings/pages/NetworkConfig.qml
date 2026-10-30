import QtQuick
import QtQuick.Layouts
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import Quickshell

/**
 * The set-once side of networking; the panel does the moment-to-moment part. It fits
 * without scrolling: what you are on, with its one setting; VPN; then two folded lines,
 * the profiles you have (each with when it was last used, "never joined" said plainly) and
 * the hotspot. Bluetooth has a page of its own.
 * Shapes after caelestia's NetworkPage / NetworkDetailPage, cut down.
 */
ContentPage {
    id: page
    forceWidth: true
    property int tab: 0

    // Three tabs, nothing folded: what you are on and the networks you know; VPN; sharing.
    SecondaryTabBar {
        id: tabBar
        currentIndex: page.tab
        onCurrentIndexChanged: page.tab = currentIndex
        Repeater {
            model: [
                { name: Translation.tr("Wi-Fi"), icon: "wifi" },
                { name: Translation.tr("VPN"), icon: "vpn_key" },
                { name: Translation.tr("Sharing"), icon: "wifi_tethering" }
            ]
            delegate: SecondaryTabButton {
                required property var modelData
                buttonText: modelData.name
                buttonIcon: modelData.icon
            }
        }
    }

    function goTo(term) {
        const t = term.toLowerCase().trim()

        function findTarget(rootItem) {
            for (let i = 0; i < rootItem.children.length; i++) {
                let child = rootItem.children[i]
                if (child.title && child.title.toLowerCase().includes(t)) {
                    return child
                }
            }

            for (let i = 0; i < rootItem.children.length; i++) {
                let found = findTarget(rootItem.children[i])
                if (found) return found
            }
            return null
        }

        let target = findTarget(page.contentItem)
        if (target) {
            let pos = target.mapToItem(page.contentItem, 0, 0)
            page.contentY = Math.max(0, pos.y)
        }
    }

    function ago(ms) {
        if (!(ms > 0))
            return Translation.tr("never joined");
        const d = Date.now() - ms;
        if (d < 3600000)
            return Translation.tr("just now");
        if (d < 86400000)
            return Translation.tr("today");
        if (d < 7 * 86400000)
            return Translation.tr("%1 days ago").arg(Math.floor(d / 86400000));
        return Qt.formatDate(new Date(ms), "d MMM");
    }

    // ================================================================ wi-fi
    // ---------------------------------------------------------------- this connection
    ContentSection {
        id: ipSection
        visible: page.tab === 0
        icon: Network.ethernet ? "lan" : "wifi"
        title: Network.networkName.length > 0 ? Network.networkName : Translation.tr("Not connected")
        shape: MaterialShape.Shape.Pill

        property string conn: Network.networkName
        property string method: "auto"
        property bool loaded: false
        property bool saving: false
        property bool failed: false
        property bool readFailed: false
        readonly property var ap: Network.active
        readonly property string band: {
            const f = ipSection.ap?.frequency ?? 0;
            return f >= 5925 ? "6 GHz" : f >= 4900 ? "5 GHz" : f > 0 ? "2.4 GHz" : "";
        }
        readonly property string facts: [Network.ipAddress, ipSection.band,
            ipSection.ap ? Network.securityLabel(ipSection.ap.security) : (Network.ethernet ? Translation.tr("wired") : "")].filter(x => x.length > 0).join(" · ")
        function load() {
            ipSection.loaded = false;
            ipSection.failed = false;
            ipSection.readFailed = false;
            if (ipSection.conn.length === 0)
                return;
            Network.getIpv4Config(ipSection.conn, cfg => {
                if (!cfg) {
                    ipSection.readFailed = true;
                    return;
                }
                ipSection.method = cfg.method;
                addressField.value = cfg.address;
                gatewayField.value = cfg.gateway;
                dnsField.value = cfg.dns;
                ipSection.loaded = true;
            });
        }
        onConnChanged: ipSection.load()
        Component.onCompleted: ipSection.load()

        GroupedList {
            visible: ipSection.conn.length > 0
            // facts and trust on one line: the same facts the panel row shows
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                StyledText {
                    Layout.fillWidth: true
                    text: ipSection.facts
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnSecondaryContainer
                    elide: Text.ElideRight
                }
                StyledText {
                    visible: ipSection.ap !== null
                    text: Translation.tr("Trusted")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledSwitch {
                    visible: ipSection.ap !== null
                    readonly property bool trusted: Network.isTrusted(ipSection.ap?.ssid ?? "")
                    checked: trusted
                    onClicked: {
                        Network.setTrusted(ipSection.ap.ssid, !trusted);
                        checked = Qt.binding(() => trusted);
                    }
                    StyledToolTip {
                        text: Translation.tr("Home or work: no VPN needed here")
                    }
                }
            }
            // address: automatic, or one field each; the fields appear only when they apply
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    ConfigComboBox {
                        Layout.fillWidth: true
                        buttonIcon: "settings_ethernet"
                        text: Translation.tr("Address")
                        model: [
                            { displayName: Translation.tr("Automatic"), value: "auto" },
                            { displayName: Translation.tr("Automatic, custom DNS"), value: "auto-dns" },
                            { displayName: Translation.tr("Manual"), value: "manual" }
                        ]
                        currentValue: ipSection.method
                        onSelected: newValue => ipSection.method = newValue
                        enabled: ipSection.loaded
                    }
                    SmallAction {
                        label: ipSection.saving ? Translation.tr("Applying") : Translation.tr("Apply")
                        primary: true
                        enabled: ipSection.loaded && !ipSection.saving
                        onClicked: {
                            ipSection.saving = true;
                            ipSection.failed = false;
                            Network.setIpv4Config(ipSection.conn, {
                                method: ipSection.method,
                                address: addressField.value.trim(),
                                gateway: gatewayField.value.trim(),
                                dns: dnsField.value.trim()
                            }, r => {
                                ipSection.saving = false;
                                ipSection.failed = !(r && r.success);
                            });
                        }
                    }
                }
                ConfigTextArea {
                    id: addressField
                    visible: ipSection.method === "manual"
                    Layout.fillWidth: true
                    buttonIcon: "pin"
                    text: Translation.tr("Address, with prefix")
                    placeholderText: "192.168.0.50/24"
                    fieldHeight: 36
                }
                ConfigTextArea {
                    id: gatewayField
                    visible: ipSection.method === "manual"
                    Layout.fillWidth: true
                    buttonIcon: "router"
                    text: Translation.tr("Gateway")
                    placeholderText: "192.168.0.1"
                    fieldHeight: 36
                }
                ConfigTextArea {
                    id: dnsField
                    visible: ipSection.method !== "auto"
                    Layout.fillWidth: true
                    buttonIcon: "dns"
                    text: Translation.tr("DNS servers, comma separated")
                    placeholderText: "1.1.1.1, 9.9.9.9"
                    fieldHeight: 36
                }
                StyledText {
                    visible: ipSection.failed
                    text: Translation.tr("NetworkManager refused that; check the fields")
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colError
                }
                RowLayout {
                    visible: ipSection.readFailed
                    Layout.fillWidth: true
                    spacing: 10
                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Couldn't read this connection's addresses from NetworkManager")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colError
                        wrapMode: Text.Wrap
                    }
                    SmallAction {
                        label: Translation.tr("Retry")
                        onClicked: ipSection.load()
                    }
                }
            }
        }
    }

    ContentSection {
        visible: page.tab === 0
        icon: "bookmarks"
        title: Translation.tr("Known networks")
        shape: MaterialShape.Shape.Cookie4Sided

        GroupedList {
            ColumnLayout {
                id: knownGroup
                property bool open: false
                readonly property var list: [...Network.savedConnections].sort((a, b) => (b.lastUsed - a.lastUsed) || a.name.localeCompare(b.name))
                readonly property int neverCount: list.filter(c => !(c.lastUsed > 0)).length
                Layout.fillWidth: true
                spacing: 10
                ColumnLayout {
                        id: knownRows
                        Layout.fillWidth: true
                        spacing: 8
                        Repeater {
                            model: ScriptModel {
                                values: knownGroup.list
                                objectProp: "name"
                            }
                            delegate: RowLayout {
                                id: netRow
                                required property var modelData
                                readonly property bool current: (Network.active?.ssid ?? "") === modelData.name
                                readonly property bool trusted: Network.isTrusted(modelData.name)
                                readonly property bool never: !(modelData.lastUsed > 0)
                                Layout.fillWidth: true
                                spacing: 10
                                MaterialSymbol {
                                    text: netRow.current ? "wifi" : (netRow.never ? "wifi_off" : "wifi")
                                    iconSize: Appearance.font.pixelSize.larger
                                    color: netRow.current ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                                    opacity: netRow.never ? 0.5 : 1
                                }
                                StyledText {
                                    Layout.fillWidth: true
                                    text: netRow.modelData.name
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOnSecondaryContainer
                                    opacity: netRow.never ? 0.6 : 1
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    text: netRow.current ? Translation.tr("connected") : page.ago(netRow.modelData.lastUsed)
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    color: Appearance.colors.colSubtext
                                }
                                StyledSwitch {
                                    visible: !netRow.never
                                    checked: netRow.trusted
                                    onClicked: {
                                        Network.setTrusted(netRow.modelData.name, !netRow.trusted);
                                        checked = Qt.binding(() => netRow.trusted);
                                    }
                                    StyledToolTip {
                                        text: Translation.tr("Trusted: home or work, no VPN needed here")
                                    }
                                }
                                SmallAction {
                                    label: Translation.tr("Forget")
                                    onClicked: Network.forgetWifiNetwork(netRow.modelData.name)
                                }
                            }
                        }
                        RowLayout {
                            visible: knownGroup.neverCount > 0
                            Layout.fillWidth: true
                            Item {
                                Layout.fillWidth: true
                            }
                            SmallAction {
                                label: Translation.tr("Forget all never joined")
                                onClicked: {
                                    for (const c of knownGroup.list)
                                        if (!(c.lastUsed > 0))
                                            Network.forgetWifiNetwork(c.name);
                                }
                            }
                        }
                }
            }

        }
    }

    // ================================================================ vpn
    // ---------------------------------------------------------------- vpn
    ContentSection {
        visible: page.tab === 1
        icon: "vpn_key"
        title: Translation.tr("VPN")
        shape: MaterialShape.Shape.Sunny

        GroupedList {
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 10
                Repeater {
                    model: ScriptModel {
                        values: Vpn.connections
                        objectProp: "name"
                    }
                    delegate: RowLayout {
                        id: vpnRow
                        required property var modelData
                        readonly property bool auto: Vpn.autoVpn === modelData.name
                        Layout.fillWidth: true
                        spacing: 10
                        MaterialSymbol {
                            text: vpnRow.modelData.active ? "vpn_key" : "vpn_key_off"
                            iconSize: Appearance.font.pixelSize.larger
                            color: vpnRow.modelData.active ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: `${vpnRow.modelData.name}  ·  ${vpnRow.modelData.kind === "wireguard" ? "WireGuard" : "OpenVPN"}` + (vpnRow.modelData.active ? Translation.tr("  ·  up") : "")
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnSecondaryContainer
                            elide: Text.ElideRight
                        }
                        StyledText {
                            text: Translation.tr("On when not trusted")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                        StyledSwitch {
                            checked: vpnRow.auto
                            onClicked: {
                                Vpn.setAuto(vpnRow.modelData.name);
                                checked = Qt.binding(() => vpnRow.auto);
                            }
                        }
                        SmallAction {
                            label: Translation.tr("Forget")
                            onClicked: Vpn.forget(vpnRow.modelData.name)
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    ConfigTextArea {
                        id: vpnFile
                        Layout.fillWidth: true
                        buttonIcon: "upload_file"
                        text: Vpn.connections.length === 0 ? Translation.tr("None yet · add from a file") : Translation.tr("Add from file")
                        description: Translation.tr("A WireGuard .conf or an .ovpn; dropping one on the notch does the same")
                        placeholderText: "~/Downloads/home.conf"
                        fieldHeight: 36
                    }
                    SmallAction {
                        label: Translation.tr("Add")
                        primary: true
                        enabled: vpnFile.value.trim().length > 0
                        onClicked: {
                            Vpn.importFile(vpnFile.value.trim().replace(/^~/, FileUtils.trimFileProtocol(Directories.home)));
                            vpnFile.value = "";
                        }
                    }
                }
            }
        }
    }

    // ================================================================ sharing
    ContentSection {
        visible: page.tab === 2
        icon: "wifi_tethering"
        title: Translation.tr("Share this connection")
        shape: MaterialShape.Shape.Clover4Leaf

        GroupedList {
            ColumnLayout {
                id: hotspotGroup
                readonly property bool ready: (Persistent.states.network.hotspotName ?? "").length > 0 && (Persistent.states.network.hotspotPassword ?? "").length >= 8
                Layout.fillWidth: true
                spacing: 10
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    MaterialSymbol {
                        text: "wifi_tethering"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Network.hotspotActive ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: hotspotSwitch.pending ? Translation.tr("Waiting for NetworkManager…") : (Network.hotspotError.length > 0 ? Network.hotspotError : Network.hotspotActive ? Translation.tr("Hotspot on · %1").arg(Persistent.states.network.hotspotName) : (hotspotGroup.ready ? Translation.tr("Hotspot off · shares the wired link; the Wi-Fi radio serves the hotspot") : Translation.tr("Set a name and a password first")))
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnSecondaryContainer
                    }
                    StyledSwitch {
                        id: hotspotSwitch
                        // NetworkManager answers a moment after the request, so the switch keeps
                        // showing what was asked for until it does, instead of snapping back.
                        property bool pending: false
                        checked: Network.hotspotActive
                        enabled: !hotspotSwitch.pending && (Network.hotspotActive || hotspotGroup.ready)
                        onClicked: {
                            hotspotSwitch.pending = true;
                            hotspotTimeout.restart();
                            if (Network.hotspotActive)
                                Network.hotspotOff();
                            else
                                Network.hotspotOn(Persistent.states.network.hotspotName, Persistent.states.network.hotspotPassword);
                        }

                        function settle() {
                            hotspotSwitch.pending = false;
                            hotspotTimeout.stop();
                            hotspotSwitch.checked = Qt.binding(() => Network.hotspotActive);
                        }

                        Connections {
                            target: Network
                            function onHotspotActiveChanged() {
                                hotspotSwitch.settle();
                            }
                            function onHotspotErrorChanged() {
                                if (Network.hotspotError.length > 0)
                                    hotspotSwitch.settle();
                            }
                        }

                        Timer {
                            id: hotspotTimeout
                            interval: 10000
                            repeat: false
                            onTriggered: hotspotSwitch.settle()
                        }
                    }
                }
                ColumnLayout {
                        id: hotspotFields
                        Layout.fillWidth: true
                        spacing: 8
                        ConfigTextArea {
                            Layout.fillWidth: true
                            buttonIcon: "badge"
                            text: Translation.tr("Name")
                            placeholderText: "book4"
                            fieldHeight: 36
                            value: Persistent.states.network.hotspotName
                            onValueChanged: Persistent.states.network.hotspotName = value
                        }
                        ConfigTextArea {
                            Layout.fillWidth: true
                            buttonIcon: "key"
                            text: Translation.tr("Password, 8 characters or more")
                            placeholderText: "••••••••"
                            fieldHeight: 36
                            value: Persistent.states.network.hotspotPassword
                            onValueChanged: Persistent.states.network.hotspotPassword = value
                        }
                }
            }
        }
    }

    // A small text button on a row, the panel's own shape.
    component SmallAction: RippleButton {
        id: act
        property string label: ""
        property bool primary: false
        implicitHeight: 30
        implicitWidth: actLabel.implicitWidth + 24
        buttonRadius: Appearance.rounding.small
        colBackground: primary ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
        colBackgroundHover: primary ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
        colRipple: primary ? Appearance.colors.colPrimaryActive : Appearance.colors.colLayer2Active
        opacity: enabled ? 1 : 0.5
        contentItem: StyledText {
            id: actLabel
            anchors.centerIn: parent
            text: act.label
            font.pixelSize: Appearance.font.pixelSize.small
            color: act.primary ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
        }
    }
}
