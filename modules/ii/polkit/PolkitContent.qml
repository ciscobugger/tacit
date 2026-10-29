import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.modules.ii.lock

/**
 * The password request, drawn as the notch opening down into it. Shape, frost, strip and type are
 * the notch's (IslandContent.qml, IslandHeader.qml, IslandAsk.qml); the password dots, the confirm
 * disc and "Incorrect password" are the lock's (LockSurface.qml), because it is the same password.
 * The window is a full-screen overlay (FullscreenPolkitWindow.qml) so the request holds the
 * keyboard; the real notch stays closed underneath it.
 */
Item {
    id: root
    readonly property bool usePasswordChars: !(PolkitService.flow?.responseVisible ?? false)
    // False while the window stays up for the fold back into the notch.
    readonly property bool shown: PolkitService.active && root.entered
    property bool entered: false
    property bool submitted: false
    property bool failed: false
    readonly property bool checking: root.submitted && !PolkitService.interactionAvailable

    // pkexec says "Authentication is needed to run `CMD' as the super user" (or "as user NAME");
    // everything else is shown as polkit words it.
    readonly property var request: {
        const m = PolkitService.cleanMessage.match(/^Authentication is needed to run [`'](.+)[`'] as (the super user|user (.+))$/);
        if (m)
            return { "title": m[3] ? `Run as ${m[3]}` : "Run as administrator", "detail": m[1] };
        return { "title": PolkitService.cleanMessage, "detail": "" };
    }

    function submit() {
        if (!PolkitService.interactionAvailable)
            return;
        root.submitted = true;
        if (field.text.length === 0)
            console.warn("[Polkit] empty answer sent");
        PolkitService.submit(field.text);
    }

    Component.onCompleted: {
        root.entered = true;
        field.forceActiveFocus();
    }
    Connections {
        target: PolkitService
        // A new request while the last one folds away reuses this content.
        function onFlowChanged() {
            root.failed = false;
            root.submitted = false;
            field.text = "";
        }
        function onInteractionAvailableChanged() {
            if (!PolkitService.interactionAvailable)
                return;
            if (root.submitted) {
                root.failed = true;
                shake.restart();
            }
            root.submitted = false;
            field.text = "";
            field.forceActiveFocus();
        }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape)
            PolkitService.cancel();
    }

    // WindowDialog's dim. Clicks outside do nothing, so a stray click cannot answer or cancel.
    Rectangle {
        anchors.fill: parent
        color: ColorUtils.transparentize(Appearance.colors.colScrim, 0.5)
        opacity: root.shown ? 1 : 0
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        MouseArea {
            anchors.fill: parent
            onPressed: field.forceActiveFocus()
        }
    }

    // The notch's closed and open geometry (IslandController.geometryFor, IslandContent.qml:162).
    readonly property var closedGeometry: IslandController.geometryFor(IslandController.transientShowing ? IslandController.transientState : "idle")
    readonly property real openWidth: 560

    Item {
        id: sheet
        readonly property real fillet: 6
        width: root.shown ? root.openWidth : root.closedGeometry.w
        height: root.shown ? 34 + body.implicitHeight : 34
        property real cornerRadius: root.shown ? 24 : root.closedGeometry.r
        x: (root.width - width) / 2
        y: Config.options.island.topMargin

        // Open on the notch's spring curve, fold back on its close curve (IslandContent.qml:153-158).
        readonly property int duration: root.shown ? Appearance.animationCurves.expressiveDefaultSpatialDuration : 450
        readonly property list<real> curve: root.shown ? Appearance.animationCurves.expressiveDefaultSpatial : Appearance.animationCurves.emphasizedDecel
        Behavior on width {
            NumberAnimation { duration: sheet.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: sheet.curve }
        }
        Behavior on height {
            NumberAnimation { duration: sheet.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: sheet.curve }
        }
        Behavior on cornerRadius {
            NumberAnimation { duration: sheet.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: sheet.curve }
        }

        DockedRect {
            anchors.fill: parent
            cornerRadius: sheet.cornerRadius
            fillet: sheet.fillet
            color: IslandController.bodyColor
        }

        // The strip: the time where it always is (IslandHeader.qml:85-87).
        StyledText {
            width: parent.width
            height: 34
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: DateTime.time
            font.family: Appearance.font.family.numbers
            font.pixelSize: 16
            color: Appearance.colors.colOnLayer0
        }

        Item {
            anchors.fill: parent
            anchors.topMargin: 34
            clip: true

            ColumnLayout {
                id: body
                x: 20
                width: root.openWidth - 40
                spacing: 12
                opacity: root.shown ? 1 : 0
                Behavior on opacity {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }

                RowLayout {
                    Layout.topMargin: 8
                    Layout.fillWidth: true
                    spacing: 12
                    MaterialSymbol {
                        Layout.alignment: Qt.AlignVCenter
                        text: "security"
                        iconSize: 26
                        color: Appearance.colors.colPrimary
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        StyledText {
                            Layout.fillWidth: true
                            text: root.request.title
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            font.pixelSize: Appearance.font.pixelSize.large
                            color: Appearance.colors.colOnLayer0
                        }
                        StyledText {
                            Layout.fillWidth: true
                            visible: text.length > 0
                            text: root.request.detail
                            elide: Text.ElideMiddle
                            font.family: Appearance.font.family.monospace
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9)
                }

                // The lock's password row (LockSurface.qml:309-404).
                RowLayout {
                    Layout.fillWidth: true
                    implicitHeight: 46
                    spacing: 6

                    ToolbarTextField {
                        id: field
                        Layout.fillWidth: true
                        Layout.leftMargin: 0
                        padding: 0
                        colBackground: "transparent"
                        focus: true
                        enabled: PolkitService.interactionAvailable
                        placeholderText: root.failed ? "Incorrect password" : PolkitService.cleanPrompt
                        font.pixelSize: Appearance.font.pixelSize.large
                        echoMode: root.usePasswordChars ? TextInput.Password : TextInput.Normal
                        inputMethodHints: Qt.ImhSensitiveData
                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, root.usePasswordChars ? 1 : 0)
                        selectedTextColor: root.usePasswordChars ? "transparent" : Appearance.colors.colOnSecondaryContainer
                        selectionColor: root.usePasswordChars ? "transparent" : Appearance.colors.colSecondaryContainer
                        opacity: root.checking ? 0.6 : 1
                        onAccepted: root.submit()
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape)
                                PolkitService.cancel();
                        }

                        Loader {
                            active: root.usePasswordChars
                            anchors.fill: parent
                            sourceComponent: PasswordChars {
                                length: field.text.length
                                selectionStart: field.selectionStart
                                selectionEnd: field.selectionEnd
                                cursorPosition: field.cursorPosition
                                charSize: 26
                                color: Appearance.colors.colOnSurface
                            }
                        }
                        ErrorShakeAnimation {
                            id: shake
                            target: field
                        }
                    }

                    Disc {
                        glyph: "arrow_right_alt"
                        checking: root.checking
                        opacity: root.checking ? 0.6 : 1
                        onActivated: root.submit()
                    }
                }

                StyledText {
                    Layout.bottomMargin: 14
                    text: root.failed ? "Try again, or Esc to cancel" : "Enter allows · Esc cancels"
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.failed ? Appearance.colors.colError : Appearance.colors.colSubtext
                }
            }
        }
    }

    // The lock's confirm disc (LockSurface.qml:476-504), always filled.
    component Disc: RippleButton {
        id: disc
        property string glyph: ""
        property bool checking: false
        signal activated
        implicitWidth: 44
        implicitHeight: 44
        padding: 0
        buttonRadius: Appearance.rounding.full
        colBackground: Appearance.colors.colPrimary
        colBackgroundHover: Appearance.colors.colPrimary
        colRipple: Appearance.colors.colPrimaryActive
        releaseAction: () => disc.activated()
        contentItem: MaterialSymbol {
            text: disc.checking ? "progress_activity" : disc.glyph
            iconSize: 22
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: Appearance.colors.colOnPrimary
            RotationAnimation on rotation {
                running: disc.checking
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
            }
        }
    }
}
