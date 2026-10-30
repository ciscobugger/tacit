import QtQuick
import QtQuick.Controls

// Tacit's login screen: the lock screen's look (BootLockSurface.qml) for SDDM, so signing in looks like unlocking.
// The ground and the colours are the person's, copied at greeter start by tacit-login-ground (theme.conf.user); the
// session is always Tacit's. Values are the lock's: the notch docked at the top, the clock (96) and the date (19) at
// 0.22 of the height, the person bottom left, the password pill docked at the bottom (420 x 58, 23), the power panel
// docked bottom right (44 discs, 30).
Rectangle {
    id: root
    width: 1920
    height: 1080
    color: config.surface

    // a palette colour (a string in theme.conf) at an opacity
    function fade(hex, a) { const c = Qt.darker(hex, 1.0); return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color frost: fade(config.surfaceContainerHigh, 0.76)
    readonly property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    property int shown: userIndex
    readonly property string userName: userModel.data(userModel.index(shown, 0), Qt.UserRole + 1) ?? ""
    readonly property string realName: userModel.data(userModel.index(shown, 0), Qt.UserRole + 2) ?? ""
    property bool failed: false

    // the Tacit session, whatever else is installed
    readonly property int tacitSession: {
        for (let i = 0; i < sessionModel.rowCount(); i++) {
            const file = sessionModel.data(sessionModel.index(i, 0), Qt.UserRole + 2) ?? "";   // SessionModel's FileRole (+1 is the directory, +3 the type)
            if (String(file).endsWith("tacit.desktop")) return i;
        }
        return sessionModel.lastIndex;
    }

    FontLoader { id: symbols; source: config.symbols ? "file://" + config.symbols : "" }

    Image {
        anchors.fill: parent
        source: config.ground ? "file://" + config.ground : ""
        fillMode: Image.PreserveAspectCrop
        visible: status === Image.Ready
    }

    // the notch: the time, docked into the top edge
    Item {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        width: 108
        height: 34
        DockedRect { anchors.fill: parent; edge: "top"; cornerRadius: 14; fillet: 6; color: root.frost }
        Text {
            anchors.centerIn: parent
            text: clock.time
            font.family: "Tacit Sans"
            font.pixelSize: 16
            color: config.onSurface
        }
    }

    QtObject {
        id: clock
        property date now: new Date()
        readonly property string time: Qt.formatTime(now, "HH:mm")
        readonly property string day: Qt.formatDate(now, "dddd d MMMM")
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: clock.now = new Date() }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.22
        spacing: 6
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: clock.time
            font.family: "Tacit Sans"
            font.pixelSize: 96
            color: config.onSurface
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: clock.day
            font.family: "Tacit Sans"
            font.pixelSize: 19
            color: config.onSurfaceVariant
        }
    }

    // the person; with several, a press goes to the next
    Text {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 30
        anchors.bottomMargin: 30
        text: root.realName || root.userName
        font.family: "Tacit Sans"
        font.pixelSize: 16
        color: config.onSurfaceVariant
        MouseArea {
            anchors.fill: parent
            anchors.margins: -8
            enabled: userModel.count > 1
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: { root.shown = (root.shown + 1) % userModel.count; password.text = ""; root.failed = false; password.forceActiveFocus(); }
        }
    }

    Item {
        id: pill
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: 420
        height: 58 + 6
        DockedRect { anchors.fill: parent; edge: "bottom"; cornerRadius: 23; fillet: 6; color: root.frost }
        TextField {
            id: password
            anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16 }
            height: 58
            focus: true
            echoMode: TextInput.Password
            placeholderText: root.failed ? "Incorrect password" : "Password"
            placeholderTextColor: root.failed ? config.error : config.onSurfaceVariant
            color: config.onSurface
            font.family: "Tacit Sans"
            font.pixelSize: 19
            background: null
            verticalAlignment: TextInput.AlignVCenter
            onTextEdited: root.failed = false
            onAccepted: if (text.length) sddm.login(root.userName, text, root.tacitSession)
            Component.onCompleted: forceActiveFocus()
            transform: Translate { id: shake; x: 0 }
        }
    }
    SequentialAnimation {
        id: shakeAnim
        NumberAnimation { target: shake; property: "x"; to: -10; duration: 50 }
        NumberAnimation { target: shake; property: "x"; to: 10; duration: 90 }
        NumberAnimation { target: shake; property: "x"; to: -6; duration: 80 }
        NumberAnimation { target: shake; property: "x"; to: 0; duration: 60 }
    }
    Connections {
        target: sddm
        function onLoginFailed() { root.failed = true; password.text = ""; shakeAnim.restart(); password.forceActiveFocus(); }
    }

    // power, docked into the bottom right corner
    Item {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: 3 * 44 + 2 * 16 + 2 * 20 + 6
        height: 44 + 2 * 20 + 6
        DockedRect { anchors.fill: parent; edge: "bottom-right"; cornerRadius: 30; fillet: 6; color: root.frost }
        Row {
            anchors { left: parent.left; top: parent.top; leftMargin: 6 + 20; topMargin: 6 + 20 }
            spacing: 16
            Disc { glyph: "dark_mode"; enabled: sddm.canSuspend; onActivated: sddm.suspend() }
            Disc { glyph: "restart_alt"; enabled: sddm.canReboot; onActivated: sddm.reboot() }
            Disc { glyph: "power_settings_new"; enabled: sddm.canPowerOff; onActivated: sddm.powerOff() }
        }
    }

    component Disc: Rectangle {
        id: disc
        property string glyph: ""
        signal activated
        width: 44
        height: 44
        radius: 22
        opacity: enabled ? 1 : 0.4
        color: area.containsMouse ? config.primary : root.fade(config.onSurface, 0.08)
        Behavior on color { ColorAnimation { duration: 150 } }
        Text {
            anchors.centerIn: parent
            text: disc.glyph
            font.family: symbols.name
            font.pixelSize: 20
            color: area.containsMouse ? config.surface : config.onSurface
        }
        MouseArea { id: area; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: disc.activated() }
    }
}
