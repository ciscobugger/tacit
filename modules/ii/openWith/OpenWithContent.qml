pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The "Open with" menu (DialogBridge kind "open.choose"): a dark slab on the window ground with a hairline, centred
 * over the window that asked. The recommended Tacit app is first; the app opened last time is preselected (filled
 * with the accent), else the first Tacit app, else the system default. A click opens, Up/Down move, Enter opens,
 * Escape cancels.
 * Emits done(result) or cancelled(); the window around it talks to the bridge.
 *
 * request: { file, kind, contentType, apps: [{id,name,icon,tacit}], selected, asker: {x,y,w,h,monitor} | null }
 *          (asker in global layout coordinates)
 * result:  { id, always }
 */
Item {
    id: root

    property var request: ({})
    // monitor origin in layout coordinates, to turn the asker's global position into this window's
    property real monitorX: 0
    property real monitorY: 0

    signal done(var result)
    signal cancelled()

    readonly property var apps: request.apps ?? []
    property int index: request.selected ?? 0
    property bool always: false
    readonly property var askRect: {
        const a = request.asker;
        return a ? Qt.rect(a.x - monitorX, a.y - monitorY, a.w, a.h) : null;
    }

    readonly property var glyphs: ({
        "tacit-viewer": "description", "browser": "language", "code": "code", "claude-app": "terminal",
        "quiet-files": "folder", "foot": "terminal"
    })

    // A symbol for Tacit's own apps and for terminals (by id, name or icon); other apps keep their own icon.
    function glyphFor(a): string {
        const g = root.glyphs[a.id.replace(/\.desktop$/, "")];
        if (g) return g;
        return /terminal|console|konsole|kitty|alacritty|wezterm|ghostty/i.test(`${a.name} ${a.icon} ${a.id}`) ? "terminal" : "";
    }
    function open(i: int): void {
        const a = root.apps[i];
        if (a) root.done({ id: a.id, always: root.always });
    }

    focus: true
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) { root.cancelled(); event.accepted = true; }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.open(root.index); event.accepted = true; }
        else if (event.key === Qt.Key_Down) { root.index = Math.min(root.apps.length - 1, root.index + 1); event.accepted = true; }
        else if (event.key === Qt.Key_Up) { root.index = Math.max(0, root.index - 1); event.accepted = true; }
        else if (event.key === Qt.Key_Space) { root.always = !root.always; event.accepted = true; }
    }

    readonly property color slab: Appearance.m3colors.m3surfaceContainerLow
    readonly property color ink: Appearance.colors.colInkMain
    readonly property color ink2: Appearance.colors.colInkSecondary
    readonly property color hair: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.9)
    // primary fill: colPrimary 30 % toward white, dark text on it (Lc 82)
    readonly property color accentFill: ColorUtils.mix(Appearance.colors.colPrimary, "#ffffff", 0.7)
    readonly property color onAccent: Appearance.m3colors.m3surfaceContainerLowest

    // a click outside the menu cancels
    MouseArea { anchors.fill: parent; onClicked: root.cancelled() }

    Rectangle {
        id: menu
        readonly property real areaX: root.askRect?.x ?? 0
        readonly property real areaY: root.askRect?.y ?? 0
        readonly property real areaW: root.askRect?.width ?? root.width
        readonly property real areaH: root.askRect?.height ?? root.height
        width: 340
        height: Math.min(col.implicitHeight + 20, root.height - 24)   // longer lists scroll, the title and the check stay
        x: Math.max(12, Math.min(root.width - width - 12, areaX + (areaW - width) / 2))
        y: Math.max(12, Math.min(root.height - height - 12, areaY + (areaH - height) / 2))
        color: root.slab; radius: 14
        border.width: 1; border.color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.72)

        ColumnLayout {
            id: col
            x: 10; y: 10; width: parent.width - 20; height: parent.height - 20; spacing: 2

            StyledText {
                Layout.fillWidth: true; Layout.leftMargin: 10; Layout.topMargin: 4; Layout.bottomMargin: 6
                elide: Text.ElideMiddle
                text: root.request.file ? qsTr("Open %1 with").arg(root.request.file) : qsTr("Open with")
                font.pixelSize: 14; color: root.ink2
            }

            Flickable {
                id: list
                Layout.fillWidth: true; Layout.fillHeight: true
                Layout.preferredHeight: rows.implicitHeight
                contentWidth: width; contentHeight: rows.implicitHeight
                clip: true; boundsBehavior: Flickable.StopAtBounds
                // keep the chosen row in view when the arrows move it
                Connections {
                    target: root
                    function onIndexChanged() {
                        const top = root.index * 46, bottom = top + 44;
                        if (top < list.contentY) list.contentY = top;
                        else if (bottom > list.contentY + list.height) list.contentY = bottom - list.height;
                    }
                }
            ColumnLayout {
            id: rows
            width: list.width; spacing: 2
            Repeater {
                model: root.apps
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool on: root.index === index
                    readonly property string glyph: root.glyphFor(row.modelData)
                    // the app's own icon when the theme has it, else a plain app symbol
                    readonly property string iconPath: row.glyph.length > 0 || !row.modelData.icon ? "" : Quickshell.iconPath(row.modelData.icon, true)
                    Layout.fillWidth: true; implicitHeight: 44; radius: 10
                    color: on ? root.accentFill : hover.containsMouse ? ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.94) : "transparent"
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 12; spacing: 12
                        // Tacit's own apps and the terminal use the symbol set; any other app keeps its own icon
                        MaterialSymbol {
                            visible: row.glyph.length > 0 || row.iconPath.length === 0
                            text: row.glyph.length > 0 ? row.glyph : "apps"; iconSize: 22; color: row.on ? root.onAccent : root.ink2
                        }
                        IconImage {
                            visible: row.glyph.length === 0 && row.iconPath.length > 0
                            implicitSize: 22
                            source: row.iconPath
                        }
                        StyledText {
                            Layout.fillWidth: true; elide: Text.ElideRight; text: row.modelData.name
                            font.pixelSize: 15; font.weight: row.on ? Font.DemiBold : Font.Normal
                            color: row.on ? root.onAccent : root.ink
                        }
                        StyledText {
                            visible: row.index === 0 && row.modelData.tacit
                            text: qsTr("Recommended"); font.pixelSize: 14
                            color: row.on ? root.onAccent : root.ink2
                        }
                    }
                    MouseArea {
                        id: hover
                        anchors.fill: parent; hoverEnabled: true
                        onClicked: { root.index = row.index; root.open(row.index); }
                    }
                }
            }
            }
            }

            Rectangle { Layout.fillWidth: true; Layout.topMargin: 6; Layout.bottomMargin: 6; implicitHeight: 1; color: root.hair }

            Item {
                Layout.leftMargin: 10; Layout.bottomMargin: 6
                implicitWidth: always.implicitWidth; implicitHeight: 28
                MouseArea { anchors.fill: parent; onClicked: root.always = !root.always }
                Row {
                    id: always
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Rectangle {
                        width: 20; height: 20; radius: 6; anchors.verticalCenter: parent.verticalCenter
                        color: root.always ? Appearance.colors.colPrimary : "transparent"
                        border.width: 2; border.color: root.always ? Appearance.colors.colPrimary : root.ink2
                        MaterialSymbol { anchors.centerIn: parent; visible: root.always; text: "check"; iconSize: 16; color: root.onAccent }
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Always use for %1").arg(root.request.kind ?? "")
                        font.pixelSize: 14; color: root.ink2
                    }
                }
            }
        }
    }
}
