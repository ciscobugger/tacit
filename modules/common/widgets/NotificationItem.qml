import qs
import qs.modules.common
import qs.services
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Services.Notifications

Item { // Notification item area
    id: root
    // Close, mute and copy show on the row the pointer is on; at rest a row carries only the
    // app's own actions.
    HoverHandler { id: toolsHover }
    readonly property bool toolsShown: toolsHover.hovered
    property var notificationObject
    property bool expanded: false
    property bool onlyNotification: false
    property bool heightAnimated: true   // off while a popup that arrives expanded takes its place
    property real fontSize: Appearance.font.pixelSize.small
    property real padding: onlyNotification ? 0 : 8
    property real summaryElideRatio: 0.85
    readonly property bool message: NotificationUtils.isMessage(notificationObject)

    property real dragConfirmThreshold: 70 // Drag further to discard notification
    property real dismissOvershoot: notificationIcon.implicitWidth + 20 // Account for gaps and bouncy animations
    property var qmlParent: root?.parent?.parent // There's something between this and the parent ListView
    property var parentDragIndex: qmlParent?.dragIndex ?? -1
    property var parentDragDistance: qmlParent?.dragDistance ?? 0
    property var dragIndexDiff: Math.abs(parentDragIndex - index)
    property real xOffset: dragIndexDiff == 0 ? parentDragDistance : 
        Math.abs(parentDragDistance) > dragConfirmThreshold ? 0 :
        dragIndexDiff == 1 ? (parentDragDistance * 0.3) :
        dragIndexDiff == 2 ? (parentDragDistance * 0.1) : 0

    implicitHeight: background.implicitHeight

    function destroyWithAnimation(left = false) {
        root.qmlParent.resetDrag()
        background.anchors.leftMargin = background.anchors.leftMargin; // Break binding
        destroyAnimation.left = left;
        destroyAnimation.running = true;
    }

    TextMetrics {
        id: summaryTextMetrics
        font.pixelSize: root.fontSize
        text: root.notificationObject?.summary || ""
    }

    SequentialAnimation { // Drag finish animation
        id: destroyAnimation
        property bool left: true
        running: false

        NumberAnimation {
            target: background.anchors
            property: "leftMargin"
            to: (root.width + root.dismissOvershoot) * (destroyAnimation.left ? -1 : 1)
            duration: Appearance.animation.elementMove.duration
            easing.type: Appearance.animation.elementMove.type
            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
        }
        onFinished: () => {
            Notifications.discardNotification(notificationObject?.notificationId);
        }
    }

    DragManager { // Drag manager
        id: dragManager
        anchors.fill: root
        anchors.leftMargin: root.expanded ? -notificationIcon.implicitWidth : 0
        interactive: expanded
        automaticallyReset: false
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        property bool dragged: false   // a drag that moved is not a click
        onPressed: dragged = false
        onClicked: (mouse) => {
            if (dragged)
                return;
            if (mouse.button === Qt.MiddleButton) {
                root.destroyWithAnimation();
                return;
            }
            if (mouse.button === Qt.LeftButton) {
                const actions = notificationObject?.actions ?? [];
                const action = actions.find(a => a.identifier === "default") ?? (actions.length === 1 ? actions[0] : null);
                if (action) {
                    // the app takes the action but cannot raise its own window on Wayland (it has no activation
                    // token): the window comes forward from here, then the app shows what was clicked
                    Notifications.focusApp(notificationObject);
                    Notifications.attemptInvokeAction(notificationObject?.notificationId, action.identifier);
                }
                else if (Notifications.open(notificationObject))   // no action: its link, else the app
                    root.destroyWithAnimation();
                else if (root.expanded && notificationObject?.hasInlineReply)   // a chat: the reply is the action
                    replyField.forceActiveFocus();
            }
        }

        onDraggingChanged: () => {
            if (dragging) {
                root.qmlParent.dragIndex = root.index ?? root.parent.children.indexOf(root);
            }
        }

        onDragDiffXChanged: () => {
            if (Math.abs(dragDiffX) > 8)
                dragged = true;
            root.qmlParent.dragDistance = dragDiffX;
        }

        onDragReleased: (diffX, diffY) => {
            if (Math.abs(diffX) > root.dragConfirmThreshold)
                root.destroyWithAnimation(diffX < 0);
            else 
                dragManager.resetDrag();
        }
    }

    NotificationAppIcon { // App icon
        id: notificationIcon
        // a row's own picture in an opened stack; the app's glyph is the stack's icon already
        opacity: (!onlyNotification && (notificationObject?.image ?? "") !== "" && (notificationObject?.iconKind ?? "") !== "glyph" && expanded) ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }

        // ?? "": the Notif is destroyed a frame before this delegate, and undefined here lands in
        // NotificationAppIcon's string property, which Qt refuses - the disc then draws nothing
        image: notificationObject?.image ?? ""
        anchors.right: background.left
        anchors.top: background.top
        anchors.rightMargin: 10
    }

    Rectangle { // Background of notification item
        id: background
        width: parent.width
        anchors.left: parent.left
        radius: Appearance.rounding.small
        anchors.leftMargin: root.xOffset

        Behavior on anchors.leftMargin {
            enabled: !dragManager.dragging
            NumberAnimation {
                duration: Appearance.animation.elementMoveSmall.duration
                easing.type: Appearance.animation.elementMove.type
                easing.bezierCurve: Appearance.animationCurves.expressiveFastSpatial
            }
        }

        // An opened notification is raised the way an "on" pill is in the control panel (the text
        // colour at 8 %); colLayer3 is opaque and read darker than the frost around it, sunk.
        color: (expanded && !onlyNotification) ? 
            (notificationObject?.urgency == NotificationUrgency.Critical) ? 
                ColorUtils.mix(Appearance.colors.colSecondaryContainer, Appearance.colors.colLayer2, 0.35) :
                ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92) :
            ColorUtils.transparentize(Appearance.colors.colLayer3)

        implicitHeight: expanded ? (contentColumn.implicitHeight + padding * 2) : summaryRow.implicitHeight
        // One motion per row: the fast spatial curve (350ms), not the 500ms default. The
        // margins and spacing below snap; two or three stacked tweens read as sluggish.
        Behavior on implicitHeight {
            enabled: root.heightAnimated
            animation: Appearance.animation.elementMoveSmall.numberAnimation.createObject(this)
        }

        ColumnLayout { // Content column
            id: contentColumn
            anchors.fill: parent
            anchors.margins: expanded ? root.padding : 0
            spacing: 3

            RowLayout { // Summary row
                id: summaryRow
                visible: !root.onlyNotification || !root.expanded
                Layout.fillWidth: true
                // a lone notification's text may take two lines (its title is the group's header)
                implicitHeight: Math.max(summaryText.visible ? summaryText.implicitHeight : 0, collapsedBody.visible ? collapsedBody.implicitHeight : 0)
                StyledText {
                    id: summaryText
                    Layout.fillWidth: summaryTextMetrics.width >= root.width * root.summaryElideRatio
                    visible: !root.onlyNotification
                    font.pixelSize: root.fontSize
                    // critical: the summary carries the error colour; nothing else in the row shouts
                    color: notificationObject?.urgency == NotificationUrgency.Critical ? Appearance.colors.colError : Appearance.colors.colOnLayer3
                    font.weight: root.message ? Font.Medium : Font.Normal
                    elide: Text.ElideRight
                    text: root.notificationObject?.summary || ""
                }
                StyledText {
                    id: collapsedBody
                    opacity: !root.expanded ? 1 : 0
                    visible: opacity > 0
                    Layout.fillWidth: true
                    Behavior on opacity {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    font.pixelSize: root.fontSize
                    color: root.message ? Appearance.colors.colOnLayer2 : Appearance.colors.colSubtext   // what a person wrote is the content
                    elide: Text.ElideRight
                    wrapMode: Text.Wrap // Needed for proper eliding????
                    // two lines alone, as phones show before a row is opened; one in a stack, after its title
                    maximumLineCount: root.onlyNotification ? 2 : 1
                    textFormat: Text.StyledText
                    text: {
                        return NotificationUtils.processNotificationBody(notificationObject?.body, notificationObject?.appName || notificationObject?.summary).replace(/\n/g, "<br/>")
                    }
                }
            }

            ColumnLayout { // Expanded content
                id: expandedContentColumn
                Layout.fillWidth: true
                opacity: root.expanded ? 1 : 0
                // Counts for layout as soon as the row is expanded, while it still fades in:
                // the popup list measures a row once, when it places it, so a row that arrives
                // expanded must already be its full height then (or it overlaps the row below).
                visible: root.expanded || opacity > 0

                // The row shape used everywhere else: text left, the actions small at the right of the
                // same line - and under the text when the line would otherwise wrap around them.
                GridLayout {
                    id: bodyGrid
                    Layout.fillWidth: true
                    columnSpacing: 10
                    rowSpacing: 6
                    readonly property bool inline: notificationBodyText.implicitWidth + actionsBlock.implicitWidth + columnSpacing <= width
                    columns: inline ? 2 : 1
                    StyledText { // Notification body (expanded)
                        id: notificationBodyText
                        Behavior on opacity {
                            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                        }
                        Layout.fillWidth: true
                        font.pixelSize: root.fontSize
                        color: root.message ? Appearance.colors.colOnLayer2 : Appearance.colors.colSubtext
                        wrapMode: Text.Wrap
                        elide: Text.ElideRight
                        textFormat: Text.RichText
                        text: {
                            return `<style>img{max-width:${expandedContentColumn.width}px;}</style>` + 
                                `${NotificationUtils.preview(NotificationUtils.processNotificationBody(notificationObject?.body, notificationObject?.appName || notificationObject?.summary)).replace(/\n/g, "<br/>")}`
                        }

                        onLinkActivated: (link) => {
                            Notifications.openLink(link)   // opens, then brings the browser forward
                            GlobalStates.notificationCenterOpen = false
                            root.destroyWithAnimation()
                        }
                        
                        PointingHandLinkHover {}
                    }
                    Item {
                        id: actionsBlock
                        // under the text, where the row's words start
                        Layout.alignment: Qt.AlignBottom | Qt.AlignLeft
                        // beside the text it yields to it; on its own line it may use the whole row
                        Layout.maximumWidth: bodyGrid.inline ? Math.round(root.width * 0.8) : bodyGrid.width
                        // sized by the button row itself: a Flickable has no implicit width
                        Layout.preferredWidth: actionRowLayout.implicitWidth
                        implicitWidth: actionRowLayout.implicitWidth
                        implicitHeight: actionRowLayout.implicitHeight

                        // A plain clip: the offscreen mask layer re-rendered the strip every frame
                        // of the expand and was the heaviest part of it.
                        clip: true

                        ScrollEdgeFade {
                            target: actionsFlickable
                            vertical: false
                        }

                        StyledFlickable { // Notification actions
                            id: actionsFlickable
                            anchors.fill: parent
                            implicitHeight: actionRowLayout.implicitHeight
                            contentWidth: actionRowLayout.implicitWidth

                            Behavior on opacity {
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            Behavior on height {
                                enabled: root.heightAnimated
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }
                            Behavior on implicitHeight {
                                enabled: root.heightAnimated
                                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                            }

                            RowLayout {
                                id: actionRowLayout
                                Layout.alignment: Qt.AlignBottom
                                spacing: 4

                                NotificationActionButton {
                                    Layout.fillWidth: false
                                    visible: root.toolsShown
                                    buttonText: Translation.tr("Close")
                                    urgency: notificationObject?.urgency ?? ""

                                    onClicked: {
                                        root.destroyWithAnimation()
                                    }

                                    implicitHeight: 26
                                    leftPadding: 8
                                    rightPadding: 8
                                    contentItem: MaterialSymbol {
                                        iconSize: Appearance.font.pixelSize.larger
                                        horizontalAlignment: Text.AlignHCenter
                                        color: (notificationObject?.urgency == NotificationUrgency.Critical) ? 
                                            Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                        text: "close"
                                    }
                                }

                                Repeater {
                                    id: actionRepeater
                                    model: notificationObject?.actions
                                    NotificationActionButton {
                                        id: notifAction
                                        required property var modelData
                                        Layout.fillWidth: false
                                        buttonText: modelData.text
                                        urgency: notificationObject?.urgency ?? ""
                                        onClicked: {
                                            Notifications.attemptInvokeAction(notificationObject?.notificationId, modelData.identifier);
                                        }
                                    }
                                }

                                // Open: the downloaded file, else the body's link, else the sender's
                                // window (a reply, when the sender is a person)
                                NotificationActionButton {
                                    id: openButton
                                    Layout.fillWidth: false
                                    readonly property string file: Notifications.fileFor(notificationObject)
                                    readonly property string link: Notifications.linkFor(notificationObject)
                                    readonly property string glyph: file !== "" ? "file_open" : link !== "" ? "link" : root.message ? "reply" : "open_in_new"
                                    visible: file !== "" || link !== "" || Notifications.windowFor(notificationObject) !== null
                                    urgency: notificationObject?.urgency ?? ""
                                    onClicked: {
                                        Notifications.open(notificationObject);
                                        GlobalStates.notificationCenterOpen = false;
                                        root.destroyWithAnimation();
                                    }
                                    implicitHeight: 26
                                    leftPadding: 8
                                    rightPadding: 8
                                    contentItem: MaterialSymbol {
                                        iconSize: Appearance.font.pixelSize.larger
                                        horizontalAlignment: Text.AlignHCenter
                                        color: (notificationObject?.urgency == NotificationUrgency.Critical) ?
                                            Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                        text: openButton.glyph
                                    }
                                }
                                // Show the downloaded file in its folder
                                NotificationActionButton {
                                    Layout.fillWidth: false
                                    visible: openButton.file !== ""
                                    urgency: notificationObject?.urgency ?? ""
                                    onClicked: {
                                        Notifications.revealFile(openButton.file);
                                        GlobalStates.notificationCenterOpen = false;
                                        root.destroyWithAnimation();
                                    }
                                    implicitHeight: 26
                                    leftPadding: 8
                                    rightPadding: 8
                                    contentItem: MaterialSymbol {
                                        iconSize: Appearance.font.pixelSize.larger
                                        horizontalAlignment: Text.AlignHCenter
                                        color: (notificationObject?.urgency == NotificationUrgency.Critical) ?
                                            Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                        text: "folder_open"
                                    }
                                }
                                // Mute this app: its notifications go to the centre only. Not when the app
                                // brought its own Mute (a phone chat does): one mute per row.
                                NotificationActionButton {
                                    Layout.fillWidth: false
                                    visible: root.toolsShown && !(notificationObject?.actions ?? []).some(a => /^mute$/i.test((a.text ?? "").trim()))
                                    urgency: notificationObject?.urgency ?? ""
                                    onClicked: Notifications.toggleMute(notificationObject?.appName)
                                    implicitHeight: 26
                                    leftPadding: 8
                                    rightPadding: 8
                                    contentItem: MaterialSymbol {
                                        iconSize: Appearance.font.pixelSize.larger
                                        horizontalAlignment: Text.AlignHCenter
                                        color: (notificationObject?.urgency == NotificationUrgency.Critical) ?
                                            Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                        text: Notifications.isMuted(notificationObject?.appName) ? "notifications_active" : "notifications_off"
                                    }
                                }
                                NotificationActionButton {
                                    Layout.fillWidth: false
                                    visible: root.toolsShown
                                    urgency: notificationObject?.urgency ?? ""

                                    onClicked: {
                                        Quickshell.clipboardText = notificationObject?.body
                                        copyIcon.text = "inventory"
                                        copyIconTimer.restart()
                                    }

                                    Timer {
                                        id: copyIconTimer
                                        interval: 1500
                                        repeat: false
                                        onTriggered: {
                                            copyIcon.text = "content_copy"
                                        }
                                    }

                                    contentItem: MaterialSymbol {
                                        id: copyIcon
                                        iconSize: Appearance.font.pixelSize.larger
                                        horizontalAlignment: Text.AlignHCenter
                                        color: (notificationObject?.urgency == NotificationUrgency.Critical) ? 
                                            Appearance.m3colors.m3onSurfaceVariant : Appearance.m3colors.m3onSurface
                                        text: "content_copy"
                                    }
                                }
                                
                            }
                        }
                    }
                }
                // Inline reply, when the app offers it (chat apps): type, Enter sends.
                ToolbarTextField {
                    id: replyField
                    visible: notificationObject?.hasInlineReply ?? false
                    Layout.fillWidth: true
                    // the same shape, colour and height as the buttons above it: one family
                    colBackground: Appearance.colors.colLayer4
                    radius: Appearance.rounding.small
                    implicitHeight: 30
                    padding: 8
                    leftPadding: 10
                    rightPadding: 10
                    // the server hands the action's label ("Reply") as the placeholder when the
                    // app set none; a person's name says more
                    placeholderText: {
                        const given = (notificationObject?.inlineReplyPlaceholder ?? "").trim();
                        if (given.length > 0 && !/^reply$/i.test(given))
                            return given;
                        return root.message ? Translation.tr("Reply to %1").arg(notificationObject?.summary) : Translation.tr("Reply");
                    }
                    // A popup being typed into does not time out; the clock resumes when focus leaves.
                    onActiveFocusChanged: {
                        if (notificationObject)
                            notificationObject.replyActive = activeFocus;
                        if (!notificationObject?.popup)
                            return;
                        if (activeFocus)
                            Notifications.cancelTimeout(notificationObject?.notificationId);
                        else
                            // Not timeoutNotification: that dismisses on the spot, taking a
                            // half-typed reply with it. The popup's own clock is what was stopped,
                            // so restarting it is what "resumes" means. A notification that never
                            // had a clock keeps standing, as it does anyway.
                            notificationObject?.timer?.restart();
                    }
                    Keys.onEscapePressed: focus = false
                    onAccepted: {
                        if (text.trim().length === 0)
                            return;
                        notificationObject?.reply(text);
                        text = "";
                        root.destroyWithAnimation();
                    }
                }
            }
        }
    }
}