import QtQuick
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

QuickToggleModel {
    property bool auto: Config.options.light.night.automatic

    name: Translation.tr("Night Light")
    statusText: !toggled ? Translation.tr("Off")
        : auto ? Translation.tr("On until %1").arg(Hyprsunset.to)
        : Translation.tr("On")

    toggled: Hyprsunset.temperatureActive
    icon: auto ? "night_sight_auto" : "bedtime"
    mainAction: () => {
        Hyprsunset.toggleTemperature()
    }
    hasMenu: true

    tooltipText: Translation.tr("Night Light | Right-click to configure")
}