import QtQuick
import Qt5Compat.GraphicalEffects
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * The third column: what the selection is, and what can be done with it. A picture shows
 * itself; anything else shows its glyph. Under it: the name, the facts (kind, size, when,
 * where it came from, path), then the actions - the same list the right-click gives, laid
 * out as rows. With nothing selected it describes the folder. Opens on its own when the
 * window is wide enough to afford it; Space toggles it otherwise.
 */
Item {
    id: preview

    property string path: ""            // "" = the folder itself
    property string folder: ""
    property bool isDir: false
    property double size: 0
    property date modified: new Date(0)
    property int count: 0
    property double folderBytes: 0
    property var actions: []
    property int many: 0            // more than one selected: a sum, not a file
    property double manyBytes: 0

    readonly property bool hasFile: preview.path.length > 0
    property bool showLook: true          // the Gallery shows the picture itself: here only what it is
    readonly property var thing: Things.describe(preview.hasFile ? preview.path + (preview.isDir ? "/" : "") : preview.folder + "/")
    readonly property bool picture: preview.hasFile && preview.thing.kind === "image"
    readonly property string name: preview.many > 0 ? Voice.count(preview.many, "item") : (preview.hasFile ? preview.thing.name : Files.placeName(preview.folder))

    function kindWord(k) {
        switch (k) {
        case "folder": return "Folder";
        case "image": return "Picture";
        case "video": return "Video";
        case "audio": return "Audio";
        case "pdf": return "PDF";
        case "doc": return "Document";
        case "archive": return "Archive";
        case "code": return "Code";
        case "text": return "Text";
        }
        return "File";
    }
    function when(d) {
        const t = d.getTime();
        if (t <= 0)
            return "";
        const age = Voice.age(t);
        const full = Qt.formatDateTime(d, "d MMM yyyy, HH:mm");
        return age === "now" ? full : `${full} · ${age}`;
    }

    // the divider
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Appearance.colors.colOutlineVariant
        opacity: 0.5
    }

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 20
        anchors.rightMargin: 8
        anchors.topMargin: 12
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: column
            width: parent.width
            spacing: 14

            // the look: a picture shows itself; anything else is said by a small tile beside its name (below)
            Item {
                width: parent.width
                visible: preview.picture && preview.showLook
                height: preview.picture && preview.showLook ? Math.min(width * 0.75, 260) : 0
                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: Appearance.colors.colLayer1
                    visible: !preview.picture || big.status !== Image.Ready
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: preview.many > 0 ? "select_all" : preview.thing.glyph
                        fill: preview.thing.kind === "folder" ? 1 : 0
                        iconSize: 56
                        color: preview.thing.kind === "folder" ? Appearance.colors.colPrimary : Tacit.inkSec
                    }
                }
                Image {
                    id: big
                    anchors.fill: parent
                    visible: preview.picture && preview.many === 0 && status === Image.Ready
                    source: preview.picture ? "file://" + preview.path : ""
                    asynchronous: true
                    cache: false
                    autoTransform: true
                    sourceSize.width: 640
                    sourceSize.height: 640
                    fillMode: Image.PreserveAspectCrop
                    layer.enabled: true
                    layer.effect: OpacityMask {
                        maskSource: Rectangle { width: big.width; height: big.height; radius: 14 }
                    }
                }
            }

            // the name, then its origin title when it has one; beside them, for anything but a picture, its glyph
            Row {
                width: parent.width
                spacing: 12
            Rectangle {
                visible: !preview.picture || !preview.showLook
                width: 44
                height: 44
                radius: 10
                color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.92)
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: preview.many > 0 ? "select_all" : preview.thing.glyph
                    fill: preview.thing.kind === "folder" ? 1 : 0
                    iconSize: 22
                    color: Tacit.inkSec
                }
            }
            Column {
                width: parent.width - (preview.picture && preview.showLook ? 0 : 56)
                anchors.verticalCenter: preview.picture && preview.showLook ? undefined : parent.verticalCenter
                spacing: 2
                StyledText {
                    width: parent.width
                    text: preview.name
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    font.pixelSize: Tacit.size.section
                    font.weight: Font.DemiBold
                    color: Tacit.inkMain
                }
                StyledText {
                    width: parent.width
                    visible: preview.hasFile && preview.thing.from.length > 0
                    text: preview.thing.from
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font.pixelSize: 14
                    color: Tacit.inkSec
                }
            }

            }
            // the facts
            Column {
                width: parent.width
                spacing: 6
                component Fact: Row {
                    property string label: ""
                    property string value: ""
                    width: parent.width
                    visible: value.length > 0
                    spacing: 10
                    StyledText {
                        width: 64
                        text: label
                        font.pixelSize: Tacit.size.meta
                        font.weight: Font.DemiBold
                        color: Tacit.inkMeta
                    }
                    StyledText {
                        width: parent.width - 74
                        text: value
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideMiddle
                        font.pixelSize: 14
                        color: Tacit.inkMain
                    }
                }
                Fact { label: "Kind"; value: preview.many > 0 ? "Selection" : preview.hasFile ? preview.kindWord(preview.thing.kind) : "Folder" }
                Fact { label: "Size"; value: preview.many > 0 ? (preview.manyBytes > 0 ? Voice.size(preview.manyBytes) : "") : preview.hasFile ? (preview.isDir ? "" : Voice.size(preview.size)) : Voice.facts([Voice.count(preview.count, "item"), preview.folderBytes > 0 ? Voice.size(preview.folderBytes) : ""]) }
                Fact { label: "Modified"; value: preview.many === 0 && preview.hasFile ? preview.when(preview.modified) : "" }
                // a path breaks only after a slash
                Fact { label: "Where"; value: (preview.many > 0 ? preview.folder.replace(Files.home, "~") : preview.hasFile ? preview.path.replace(Files.home, "~") : preview.folder.replace(Files.home, "~")).replace(/\//g, "/\u200b") }
            }

            // the actions, one clean list; Tacit's kit only by meaning (2026-10-08): what Enter does first, its word in
            // the accent and its key at the row's end; the ones that risk something in the risk colour with a warning
            Column {
                width: parent.width
                spacing: 2
                Repeater {
                    model: preview.actions.filter(a => a.id === "open" || a.id === "restore").concat(preview.actions.filter(a => a.id !== "open" && a.id !== "restore"))
                    delegate: Item {
                        required property var modelData
                        readonly property bool risky: modelData.id === "trash" || modelData.id === "delete"
                        readonly property bool enter: modelData.id === "open" || modelData.id === "restore"
                        width: parent.width
                        height: 34
                        Rectangle {
                            anchors.fill: parent
                            radius: 8
                            color: actArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.90) : "transparent"
                        }
                        MaterialSymbol {
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: parent.risky ? "warning" : modelData.glyph
                            iconSize: 18
                            color: parent.risky ? Tacit.risk : parent.enter ? Tacit.accent : Tacit.inkSec
                        }
                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: 36
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            elide: Text.ElideRight
                            font.pixelSize: Tacit.size.row
                            font.weight: parent.enter ? Font.DemiBold : Font.Normal
                            color: parent.risky ? Tacit.risk : parent.enter ? Tacit.accent : Tacit.inkMain
                        }
                        // Enter's row: its key at the end
                        Rectangle {
                            visible: parent.enter
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            height: 18
                            width: 22
                            radius: 5
                            color: ColorUtils.transparentize(Tacit.accent, 0.84)
                            StyledText { anchors.centerIn: parent; text: "↵"; font.pixelSize: 11; font.weight: Font.DemiBold; color: Tacit.accent }
                        }
                        MouseArea {
                            id: actArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: modelData.run()
                        }
                    }
                }
            }
        }
    }
}
