import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    name: Translation.tr("Internet")
    tooltipText: Translation.tr("%1 | Right-click to configure").arg(Network.networkName)
    icon: Network.materialSymbol

    // wifiEnabled is the radio, which is what the click acts on; wifiStatus also reads
    // "disabled" while the device is merely unavailable, so the pill used to render OFF with
    // the radio already on and turn it off when clicked. wifiRadioPending holds the wanted
    // state until NetworkManager agrees.
    toggled: Network.wifiRadioPending ? Network.wifiRadioWanted : Network.wifiEnabled
    busy: Network.wifiConnecting
    statusText: Network.wifiConnecting ? Translation.tr("Connecting…") : Network.networkName
    mainAction: () => Network.toggleWifi()
    hasMenu: true
}
