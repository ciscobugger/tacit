pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.models
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Widgets

/**
 * One palette row, one line: a 34 px tile (a symbol, the app's icon, or the picture itself),
 * the title on the left, and what it is or where it lives at the row's end in the meta ink (the
 * name stands alone; a path crowded against it was hard to read). The chosen row shows its verbs there instead, the
 * active one in the sand wash that marks what Enter will do; → and ← step through them. A
 * symbol tile turns sand on the chosen row for the same reason. The palette draws the row's
 * wash itself and slides it between rows (SearchWidget.qml).
 */
MouseArea {
    id: root

    property LauncherSearchResult entry
    // Driven by the ListView's currentIndex, not by focus: the input keeps keyboard focus.
    property bool current: false
    // Which verb Enter runs on the chosen row: 0 = the row's own, n = its nth action
    property int verbIndex: 0
    signal picked
    signal verbPicked(int index)
    // the pointer is over a verb: it becomes the one the sand wash marks, so the button under the
    // pointer is the one Enter and a click run
    signal verbHovered(int index)
    // the pointer moved over the row (not the row moving under a resting pointer)
    signal pointerMoved(point at)

    onPositionChanged: mouse => root.pointerMoved(root.mapToGlobal(mouse.x, mouse.y))
    readonly property string itemName: entry?.name ?? ""
    readonly property string itemComment: entry?.comment ?? ""
    readonly property string itemType: entry?.type ?? ""
    readonly property var iconType: entry?.iconType ?? LauncherSearchResult.IconType.None
    readonly property string iconName: entry?.iconName ?? ""
    readonly property string cliphistRawString: entry?.rawValue ?? ""

    readonly property bool isKeybind: root.itemType === PaletteSearch.sectionTitles.keybinds
    readonly property bool isClipImage: root.itemType === PaletteSearch.sectionTitles.clipboard && root.cliphistRawString !== "" && Cliphist.entryIsImage(root.cliphistRawString)
    // A picture shows itself in the tile: files found or opened recently, by extension
    readonly property bool isPicture: (root.itemType === PaletteSearch.sectionTitles.files || root.itemType === PaletteSearch.sectionTitles.recent)
        && /\.(png|jpe?g|webp|gif|bmp|avif|svg)$/i.test(root.cliphistRawString)

    // A clipboard row says what it holds in its tile, and an image says it is one
    readonly property bool isClip: root.itemType === PaletteSearch.sectionTitles.clipboard
    readonly property string clipGlyph: {
        const text = root.itemName.trim();
        if (/^https?:\/\//.test(text))
            return "link";
        if (/^(~|\/)[^\s]*$/.test(text) || /^file:\/\//.test(text))
            return "description";
        return "content_copy";
    }
    readonly property string titleText: {
        if (root.isClipImage) {
            const size = /(\d+)x(\d+)/.exec(root.itemName);
            return size ? `${Translation.tr("Picture")} · ${size[1]}×${size[2]}` : Translation.tr("Picture");
        }
        return root.itemName;
    }

    readonly property var verbs: {
        const own = (root.entry?.verb ?? "").length > 0 ? root.entry.verb : Translation.tr("Open");
        return [own].concat((root.entry?.actions ?? []).map(action => action.name).filter(name => name !== own));
    }

    // The grey word: what the row is, or where it lives, in one short phrase
    readonly property string word: {
        if (root.isKeybind)
            return "";
        const type = root.itemType;
        if (type === PaletteSearch.sectionTitles.apps)
            return "";                   // its icon says it is a program
        if (type === PaletteSearch.sectionTitles.files && root.itemComment.length > 0) {
            const home = FileUtils.trimFileProtocol(Directories.home);
            const dir = root.itemComment.slice(0, root.itemComment.lastIndexOf("/"));
            return dir === home ? "~" : dir.startsWith(home + "/") ? `~/${dir.slice(home.length + 1)}` : dir;
        }
        if (type === PaletteSearch.sectionTitles.claude)
            return Translation.tr("Ask Praxis");
        if (type === PaletteSearch.sectionTitles.web)
            return Translation.tr("search the web");
        if (type === PaletteSearch.sectionTitles.command)
            return Translation.tr("run in a shell");
        if (root.itemComment.length > 0 && root.itemComment.length <= 48 && !root.isClipImage)
            return root.itemComment;
        // one kind on screen: naming it on every row would only repeat it
        if (PaletteSearch.activeSectionTitle === type)
            return "";
        return type.toLowerCase();
    }

    readonly property color colWash: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
    readonly property color colSandWash: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.78)
    // Secondary text is colSubtext (onSurfaceVariant, about 7:1 on the frost); outline is a border
    // colour, under 3:1 as text (Appearance.qml), and the other verbs were hard to read in it.
    // Tacit's inks: the title in the main ink, the verbs in the secondary, the word at the end in the meta
    readonly property color colQuiet: Tacit.inkSec

    implicitHeight: 52
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.picked()

    // the tile: only the piece a row needs is created (rows are rebuilt on every letter)
    Rectangle {
        id: tile
        x: 22
        anchors.verticalCenter: parent.verticalCenter
        width: 34
        height: 34
        radius: 11
        readonly property bool sand: root.current && root.iconType === LauncherSearchResult.IconType.Material && !root.isPicture
        readonly property bool showsPicture: root.isPicture || root.isClipImage
        color: tile.showsPicture ? "transparent" : (tile.sand ? Appearance.colors.colPrimary : root.colWash)
        // declared, not created at runtime per row: rows are rebuilt on every letter
        Behavior on color {
            ColorAnimation {
                duration: Appearance.animationCurves.expressiveEffectsDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveEffects
            }
        }

        Loader {
            anchors.fill: parent
            active: tile.showsPicture
            sourceComponent: ClippingRectangle {
                radius: 11
                color: root.colWash
                Image {
                    visible: root.isPicture
                    anchors.fill: parent
                    source: root.isPicture ? `file://${root.cliphistRawString}` : ""
                    sourceSize: Qt.size(68, 68)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                }
                Loader {
                    active: root.isClipImage
                    anchors.fill: parent
                    sourceComponent: CliphistImage {
                        entry: root.cliphistRawString
                        maxWidth: 34
                        maxHeight: 34
                        blur: root.entry?.blurImage ?? false
                    }
                }
            }
        }
        Loader {
            anchors.centerIn: parent
            active: !tile.showsPicture && root.iconType === LauncherSearchResult.IconType.System
            sourceComponent: IconImage {
                source: Quickshell.iconPath(root.iconName, "image-missing")
                implicitSize: 22
                asynchronous: true
            }
        }
        MaterialSymbol {
            anchors.centerIn: parent
            visible: !tile.showsPicture && (root.iconType === LauncherSearchResult.IconType.Material || (root.isClip && root.iconType === LauncherSearchResult.IconType.None))
            text: visible ? (root.isClip && root.iconType === LauncherSearchResult.IconType.None ? root.clipGlyph : root.iconName) : ""
            iconSize: 18
            color: tile.sand ? Appearance.colors.colOnPrimary : Tacit.inkSec
        }
        StyledText {
            anchors.centerIn: parent
            visible: root.iconType === LauncherSearchResult.IconType.Text
            text: visible ? root.iconName : ""
            font.pixelSize: 19
            font.family: "Noto Color Emoji"
            font.variableAxes: ({})
        }
    }

    // the title on the left; what it is or where it lives at the end (the verbs take that place on the chosen row)
    readonly property real endRoom: verbRow.visible ? verbRow.width + 34 : (keyChip.visible ? keyChip.width + 34 : (wordText.text.length ? wordText.width + 34 : 24))
    StyledText {
        id: title
        x: 72
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - 72 - root.endRoom
        elide: Text.ElideRight
        text: root.titleText
        font.pixelSize: Tacit.size.body
        font.family: root.entry?.fontType === LauncherSearchResult.FontType.Monospace ? Appearance.font.family.monospace : Appearance.font.family.main
        font.weight: root.current ? Font.Medium : Font.Normal
        color: Tacit.inkMain
    }
    StyledText {
        id: wordText
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        visible: !verbRow.visible && !keyChip.visible
        // at most two fifths of the row: the name keeps the room
        width: Math.min(implicitWidth, (parent.width - 72) * 0.4)
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideMiddle
        text: root.word
        font.pixelSize: 14
        color: Tacit.inkMeta
    }

    // a keybind's keys, where other rows have their verbs
    Rectangle {
        id: keyChip
        visible: root.isKeybind && !root.current
        anchors.right: parent.right
        anchors.rightMargin: 24
        anchors.verticalCenter: parent.verticalCenter
        implicitHeight: 20
        implicitWidth: keyLabel.implicitWidth + 12
        radius: 6
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
        StyledText {
            id: keyLabel
            anchors.centerIn: parent
            text: root.itemComment
            font.pixelSize: 13
            color: Tacit.inkSec
        }
    }

    // the chosen row's verbs: the active one in the sand wash; → while there are more
    Row {
        id: verbRow
        // fades in on the chosen row rather than appearing at once
        opacity: root.current ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animationCurves.expressiveEffectsDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.expressiveEffects
            }
        }
        anchors.right: parent.right
        anchors.rightMargin: 22
        anchors.verticalCenter: parent.verticalCenter
        spacing: 4

        Repeater {
            // The row's own verb and up to two more; the active one always shows. Built for the
            // chosen row only.
            model: root.current ? root.verbs.slice(0, Math.max(3, root.verbIndex + 1)) : []
            Rectangle {
                id: verbChip
                required property string modelData
                required property int index
                readonly property bool active: index === root.verbIndex
                implicitWidth: verbLabel.implicitWidth + 22
                // The button is the row's whole height. A 28 px pill left 12 px of row above and
                // below it, and a click there ran the row's own verb: Delete copied.
                implicitHeight: root.height
                color: "transparent"
                Rectangle {
                    id: verbPill
                    anchors.centerIn: parent
                    implicitWidth: verbChip.implicitWidth
                    implicitHeight: 28
                    radius: 14
                    color: verbChip.active && root.verbs.length > 1 ? root.colSandWash : "transparent"
                    Behavior on color {
                        ColorAnimation {
                            duration: Appearance.animationCurves.expressiveEffectsDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Appearance.animationCurves.expressiveEffects
                        }
                    }
                }
                StyledText {
                    id: verbLabel
                    anchors.centerIn: parent
                    text: verbChip.modelData
                    font.pixelSize: 14
                    font.weight: verbChip.active ? Font.Medium : Font.Normal
                    color: verbChip.active ? Tacit.inkMain : root.colQuiet
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onContainsMouseChanged: if (containsMouse) root.verbHovered(verbChip.index)
                    // a press picks the verb too: the pointer may have arrived by a warp, which
                    // sends no hover
                    onPressed: root.verbHovered(verbChip.index)
                    onClicked: root.verbPicked(verbChip.index)
                }
            }
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 20
            implicitWidth: chipLabel.implicitWidth + 12
            radius: 6
            color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.9)
            StyledText {
                id: chipLabel
                anchors.centerIn: parent
                text: root.verbIndex < root.verbs.length - 1 ? "→" : "↵"
                font.pixelSize: 13
                color: Tacit.inkSec
            }
        }
    }
}
