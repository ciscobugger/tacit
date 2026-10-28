import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.services
import QtQuick
import Quickshell.Services.Notifications

// A notification's action, as Praxis draws its answers (modules/claude/PermissionCard.qml): a soft
// onSurface wash, full rounding, 30 high, 13 px; an urgent notification's take the stronger wash.
RippleButton {
    id: button
    property string buttonText
    property string urgency
    // What an icon-only button does, in words, on hover.
    property string tip: ""
    readonly property real tone: urgency == NotificationUrgency.Critical ? 0.86 : 0.93
    implicitHeight: 30
    leftPadding: 12
    rightPadding: 12
    buttonRadius: Appearance.rounding.full
    colBackground: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, tone)
    colBackgroundHover: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, tone - 0.05)
    StyledToolTip {
        text: button.tip
        extraVisibleCondition: button.tip.length > 0
    }
    contentItem: StyledText {
        horizontalAlignment: Text.AlignHCenter
        text: buttonText
        font.pixelSize: 14
        font.weight: button.urgency == NotificationUrgency.Critical ? Font.DemiBold : Font.Normal
        color: Appearance.colors.colOnLayer0
    }
}
