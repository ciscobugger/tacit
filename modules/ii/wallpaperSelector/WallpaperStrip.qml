import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * The wallpaper selector (CTRL+SUPER+T): a strip docked into the bottom edge, and behind it the
 * whole screen showing the picture pointed at. Enter or a click keeps it (switchwall.sh recolours
 * the desktop from it); Esc, or a click outside the strip, puts back what you had.
 * Dragging the picture on the screen moves the part of it that is shown (kept with the wallpaper, Wallpapers.setFocus).
 * Sources: Yours (pictures used as the wallpaper before, Wallpapers.used), Pictures and Downloads
 * (newest first), Online (OnlineWallpapers; the full picture is downloaded when kept).
 * The palette's edge and shape (SearchWidget.qml) on a near-opaque ground, as WindowDialog.qml's
 * box: the picture behind changes and is often bright.
 */
Item {
    id: root
    signal closeRequested()

    property bool shown: false
    property string source: "yours"
    property int pointed: 0
    property bool darkMode: Appearance.m3colors.darkmode
    property bool searching: false
    property string filter: ""
    readonly property var sources: [
        { "key": "yours", "label": "Yours" },
        { "key": "pictures", "label": "Pictures" },
        { "key": "downloads", "label": "Downloads" },
        { "key": "online", "label": "Online" }
    ]

    // ------------------------------------------------------------------ the pictures
    property var picturesList: []
    property var downloadsList: []
    property string onlineState: ""   // "", "looking", or what went wrong
    readonly property var localList: root.source === "yours" ? Wallpapers.used
        : root.source === "pictures" ? root.picturesList
        : root.source === "downloads" ? root.downloadsList : []
    readonly property var items: {
        if (root.source === "online")
            return OnlineWallpapers.results.map(r => ({ "thumb": r.thumb, "online": r }));
        const f = root.filter.toLowerCase();
        const list = f.length > 0 ? root.localList.filter(p => p.split("/").pop().toLowerCase().includes(f)) : root.localList;
        return list.map(p => ({ "path": p }));
    }
    readonly property var current: root.items[root.pointed] ?? null
    readonly property string previewSource: !root.current ? ""
        : root.current.path ? FileUtils.fileUrl(root.current.path) : (root.current.thumb ?? "")
    readonly property string pointedName: {
        const c = root.current;
        if (!c)
            return "";
        if (c.online)
            return `${c.online.provider} · ${c.online.id}`;
        const parts = c.path.split("/");
        return `${parts.pop()} · ${parts.pop() ?? ""}`;
    }
    // the part of the pointed picture the screen shows, 0..1 (0.5 = the middle); a picture online has none to choose
    readonly property string currentPath: root.current?.path ?? ""
    property real panX: 0.5
    property real panY: 0.5
    function storedFocus() {
        return root.currentPath.length > 0 ? Wallpapers.focusFor(root.currentPath) : Qt.point(0.5, 0.5);
    }
    onCurrentPathChanged: {
        root.panX = root.storedFocus().x;
        root.panY = root.storedFocus().y;
    }
    readonly property string wallpaperNow: Config.options.background.wallpaperPath ?? ""

    // Newest first; Screenshots and Martida (screen captures and review sheets) are not wallpapers.
    Process {
        id: picturesScan
        command: ["bash", "-c", 'find "$1" -maxdepth 3 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) -not -path "*/.*" -not -path "$1/Screenshots/*" -not -path "$1/Martida/*" -printf "%T@\\t%p\\n" | sort -rn | head -150 | cut -f2-', "scan",
            FileUtils.trimFileProtocol(Directories.pictures)]
        stdout: StdioCollector {
            onStreamFinished: {
                root.picturesList = text.split("\n").filter(l => l.length > 0);
                root.picturesLoaded = true;
            }
        }
    }
    Process {
        id: downloadsScan
        command: ["bash", "-c", 'find "$1" -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" \\) -printf "%T@\\t%p\\n" | sort -rn | head -150 | cut -f2-', "scan",
            FileUtils.trimFileProtocol(Directories.downloads)]
        stdout: StdioCollector {
            onStreamFinished: {
                root.downloadsList = text.split("\n").filter(l => l.length > 0);
                root.downloadsLoaded = true;
            }
        }
    }
    // the folders are only walked once their tab is first shown
    function scanSource() {
        if (root.source === "pictures" && !picturesScan.running && !root.picturesScanned) {
            root.picturesScanned = true;
            picturesScan.running = true;
        } else if (root.source === "downloads" && !downloadsScan.running && !root.downloadsScanned) {
            root.downloadsScanned = true;
            downloadsScan.running = true;
        }
    }
    property bool picturesScanned: false
    property bool downloadsScanned: false
    property bool picturesLoaded: false
    property bool downloadsLoaded: false
    // the empty message waits for the first scan of the tab being shown
    readonly property bool scanning: (root.source === "pictures" && !root.picturesLoaded) || (root.source === "downloads" && !root.downloadsLoaded)
    Component.onCompleted: {
        root.scanSource();
        root.pointed = Math.max(0, Wallpapers.used.indexOf(root.wallpaperNow));
        strip.forceActiveFocus();
    }

    Connections {
        target: OnlineWallpapers
        function onFetched() {
            root.onlineState = "";
        }
        function onFetchError(message) {
            root.onlineState = "Could not reach " + OnlineWallpapers.provider;
        }
    }
    onSourceChanged: {
        root.scanSource();
        root.pointed = 0;
        root.filter = "";
        root.searching = false;
        if (root.source === "online" && OnlineWallpapers.results.length === 0) {
            root.onlineState = "looking";
            OnlineWallpapers.fetch();
        }
    }

    function move(delta) {
        if (root.items.length === 0)
            return;
        root.pointed = Math.max(0, Math.min(root.items.length - 1, root.pointed + delta));
        list.positionViewAtIndex(root.pointed, ListView.Contain);
        if (root.source === "online" && root.pointed >= root.items.length - 4 && !OnlineWallpapers.loading)
            OnlineWallpapers.nextPage();
    }
    function nextSource(delta) {
        const i = root.sources.findIndex(s => s.key === root.source);
        root.source = root.sources[(i + delta + root.sources.length) % root.sources.length].key;
    }
    function shuffle() {
        if (root.items.length > 1)
            root.pointed = Math.floor(Math.random() * root.items.length);
        list.positionViewAtIndex(root.pointed, ListView.Center);
    }
    function keep() {
        const c = root.current;
        if (!c)
            return;
        if (c.online) {
            Wallpapers.downloadAndApply(c.online, root.darkMode);
        } else if (GlobalStates.wallpaperSelectorTarget === "lockWall") {
            // the old settings panel's "lock screen wallpaper" choice
            Wallpapers.select(c.path, root.darkMode, finalPath => Config.options.background.lockWall = finalPath);
            GlobalStates.wallpaperSelectorTarget = "wallpaper";
        } else {
            const was = root.storedFocus();
            if (Math.abs(root.panX - was.x) > 0.001 || Math.abs(root.panY - was.y) > 0.001)
                Wallpapers.setFocus(c.path, root.panX, root.panY);
            Wallpapers.select(c.path, root.darkMode);
        }
        root.closeRequested();
    }

    // ------------------------------------------------------------------ the screen shows the picture
    Item {
        id: curtain
        anchors.fill: parent
        opacity: root.shown ? 1 : 0
        scale: root.shown ? 1 : 1.03
        Behavior on scale {
            NumberAnimation { duration: Appearance.animationCurves.expressiveSlowSpatialDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveSlowSpatial }
        }
        Behavior on opacity {
            animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
        }
        Rectangle {
            anchors.fill: parent
            color: Appearance.m3colors.m3background
        }
        // two pictures, the new one fading in over the last, so moving along never flashes empty
        property bool useA: true
        // a picture covering the screen, moved inside it to show the chosen part (WallpaperImage.qml does the same
        // for the desktop); the shape is read from a tiny copy first so the real one is decoded at the covering size
        component PanPic: Item {
            id: pane
            property string src: ""
            property real fx: 0.5
            property real fy: 0.5
            readonly property alias status: img.status
            readonly property real coverW: img.width
            readonly property real coverH: img.height
            anchors.fill: parent
            clip: true
            Image {
                id: probe
                visible: false
                asynchronous: true
                source: pane.src
                sourceSize: Qt.size(64, 64)
            }
            Image {
                id: img
                readonly property real aspect: probe.status === Image.Ready && probe.implicitHeight > 0 ? probe.implicitWidth / probe.implicitHeight : 0
                readonly property bool wide: img.aspect > root.width / root.height
                asynchronous: true
                source: img.aspect > 0 ? pane.src : ""
                sourceSize: Qt.size(Math.ceil(width), Math.ceil(height))
                width: img.wide ? root.height * img.aspect : root.width
                height: img.aspect <= 0 ? root.height : img.wide ? root.height : root.width / img.aspect
                x: -(width - root.width) * pane.fx
                y: -(height - root.height) * pane.fy
            }
        }
        PanPic {
            id: picA
            opacity: curtain.useA ? 1 : 0
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
            onStatusChanged: if (status === Image.Ready && !curtain.useA && src === root.previewSource) curtain.useA = true
        }
        PanPic {
            id: picB
            opacity: curtain.useA ? 0 : 1
            Behavior on opacity {
                animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
            }
            onStatusChanged: if (status === Image.Ready && curtain.useA && src === root.previewSource) curtain.useA = false
        }
        Connections {
            target: root
            function onPreviewSourceChanged() {
                if (root.previewSource.length === 0)
                    return;
                const into = curtain.useA ? picB : picA;
                into.fx = root.storedFocus().x;
                into.fy = root.storedFocus().y;
                into.src = root.previewSource;
            }
        }
        Component.onCompleted: {
            picA.fx = root.storedFocus().x;
            picA.fy = root.storedFocus().y;
            picA.src = root.previewSource;
        }
        // a click outside the strip puts back what you had; a drag moves the picture instead
        MouseArea {
            id: dragArea
            property real downX: 0
            property real downY: 0
            property real fx0: 0.5
            property real fy0: 0.5
            property bool moved: false
            anchors.fill: parent
            cursorShape: dragArea.pressed && dragArea.moved ? Qt.ClosedHandCursor : Qt.ArrowCursor
            onPressed: mouse => {
                dragArea.downX = mouse.x;
                dragArea.downY = mouse.y;
                dragArea.fx0 = root.panX;
                dragArea.fy0 = root.panY;
                dragArea.moved = false;
            }
            onPositionChanged: mouse => {
                if (!dragArea.pressed || root.currentPath.length === 0)
                    return;
                if (!dragArea.moved && Math.hypot(mouse.x - dragArea.downX, mouse.y - dragArea.downY) < 6)
                    return;
                dragArea.moved = true;
                const pane = curtain.useA ? picA : picB;
                const spanX = pane.coverW - root.width;
                const spanY = pane.coverH - root.height;
                // the picture follows the pointer, so the part shown moves the other way
                if (spanX > 1)
                    root.panX = Math.max(0, Math.min(1, dragArea.fx0 - (mouse.x - dragArea.downX) / spanX));
                if (spanY > 1)
                    root.panY = Math.max(0, Math.min(1, dragArea.fy0 - (mouse.y - dragArea.downY) / spanY));
                pane.fx = root.panX;
                pane.fy = root.panY;
            }
            onClicked: if (!dragArea.moved) root.closeRequested()
        }
    }

    // ------------------------------------------------------------------ the strip
    Item {
        id: strip
        readonly property real fillet: 12
        readonly property real fullWidth: Math.min(1180, root.width - 96)
        readonly property real fullHeight: 214
        // Grows out of the bottom edge the way the notch opens out of the top one
        // (IslandContent.qml:153-158): the expressive spatial spring to open, the notch's close
        // curve to fold back. The content is laid out at full size and uncovered as it grows.
        width: root.shown ? strip.fullWidth : 360
        height: root.shown ? strip.fullHeight : 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        focus: true
        readonly property int duration: root.shown ? Appearance.animationCurves.expressiveDefaultSpatialDuration : 450
        readonly property list<real> curve: root.shown ? Appearance.animationCurves.expressiveDefaultSpatial : Appearance.animationCurves.emphasizedDecel
        Behavior on width {
            NumberAnimation { duration: strip.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: strip.curve }
        }
        Behavior on height {
            NumberAnimation { duration: strip.duration; easing.type: Easing.BezierSpline; easing.bezierCurve: strip.curve }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                if (root.searching) {
                    root.searching = false;
                    root.filter = "";
                } else {
                    root.closeRequested();
                }
            } else if (event.key === Qt.Key_Left) {
                root.move(-1);
            } else if (event.key === Qt.Key_Right) {
                root.move(1);
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.keep();
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.nextSource(event.key === Qt.Key_Backtab ? -1 : 1);
            } else if (event.text.length === 1 && event.text.trim().length === 1 && !(event.modifiers & Qt.ControlModifier)) {
                root.searching = true;
                searchField.text = event.text;
                searchField.forceActiveFocus();
            } else {
                return;
            }
            event.accepted = true;
        }

        MouseArea {   // the strip keeps its clicks off the curtain
            anchors.fill: parent
            onWheel: wheel => root.move(wheel.angleDelta.y < 0 || wheel.angleDelta.x < 0 ? 1 : -1)
        }

        DockedRect {
            anchors.fill: parent
            edge: "bottom"
            cornerRadius: Appearance.rounding.verylarge
            fillet: strip.fillet
            color: ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.04)
        }

        Item {
            id: clipper
            anchors.fill: parent
            clip: true
        Item {
            id: body
            width: strip.fullWidth
            height: strip.fullHeight
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            opacity: root.shown ? 1 : 0
            Behavior on opacity {
                SequentialAnimation {
                    PauseAnimation { duration: root.shown ? 120 : 0 }
                    NumberAnimation { duration: Appearance.animationCurves.expressiveEffectsDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveEffects }
                }
            }

        // where the pictures come from
        Row {
            x: 24
            y: 16
            height: 26
            spacing: 22
            Repeater {
                model: root.sources
                StyledText {
                    id: tab
                    required property var modelData
                    readonly property bool on: modelData.key === root.source
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.label
                    font.pixelSize: Appearance.font.pixelSize.small
                    font.weight: tab.on ? Font.DemiBold : Font.Normal
                    color: tab.on || tabArea.containsMouse ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                    Rectangle {
                        visible: tab.on
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.bottom
                        anchors.topMargin: 3
                        width: 4
                        height: 4
                        radius: 2
                        color: Appearance.colors.colPrimary
                    }
                    MouseArea {
                        id: tabArea
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.source = tab.modelData.key
                    }
                }
            }
        }

        // the picture pointed at, or the search; then search, shuffle, dark/light
        Row {
            anchors.right: parent.right
            anchors.rightMargin: 22
            y: 16
            height: 26
            spacing: 16
            StyledText {
                visible: !root.searching
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, 420)
                elide: Text.ElideMiddle
                text: root.pointedName
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
            ToolbarTextField {
                id: searchField
                visible: root.searching
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 300
                implicitHeight: 26
                padding: 0
                colBackground: "transparent"
                placeholderText: root.source === "online" ? "Search online, Enter to look" : "Search by name"
                font.pixelSize: Appearance.font.pixelSize.smallie
                onTextChanged: if (root.source !== "online") root.filter = text
                onAccepted: {
                    if (root.source === "online") {
                        OnlineWallpapers.query = text;
                        root.onlineState = "looking";
                        OnlineWallpapers.fetch();
                    }
                    strip.forceActiveFocus();
                }
                Keys.onEscapePressed: {
                    root.searching = false;
                    root.filter = "";
                    strip.forceActiveFocus();
                }
            }
            Repeater {
                model: [
                    { "glyph": "search", "run": () => { root.searching = !root.searching; if (root.searching) searchField.forceActiveFocus(); else { root.filter = ""; strip.forceActiveFocus(); } } },
                    { "glyph": "shuffle", "run": () => root.shuffle() },
                    { "glyph": root.darkMode ? "dark_mode" : "light_mode", "run": () => root.darkMode = !root.darkMode }
                ]
                MaterialSymbol {
                    id: act
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.glyph
                    iconSize: 20
                    color: actArea.containsMouse ? Appearance.colors.colOnLayer0 : Appearance.colors.colSubtext
                    MouseArea {
                        id: actArea
                        anchors.fill: parent
                        anchors.margins: -6
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: act.modelData.run()
                    }
                }
            }
        }

        // the pictures
        ListView {
            id: list
            x: 12
            y: 56
            width: strip.fullWidth - 24
            height: 124
            clip: true
            orientation: ListView.Horizontal
            spacing: 14
            leftMargin: 12
            rightMargin: 12
            model: root.items
            boundsBehavior: Flickable.StopAtBounds
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool isPointed: cell.index === root.pointed
                width: 184
                height: 124
                opacity: 0
                transform: Translate { id: arrive; y: 10 }
                Component.onCompleted: arriveAnim.start()
                SequentialAnimation {
                    id: arriveAnim
                    PauseAnimation { duration: 160 + Math.min(cell.index, 8) * 35 }
                    ParallelAnimation {
                        NumberAnimation { target: cell; property: "opacity"; to: 1; duration: Appearance.animationCurves.expressiveEffectsDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveEffects }
                        NumberAnimation { target: arrive; property: "y"; to: 0; duration: Appearance.animationCurves.expressiveDefaultSpatialDuration; easing.type: Easing.BezierSpline; easing.bezierCurve: Appearance.animationCurves.expressiveDefaultSpatial }
                    }
                }
                Item {
                    id: frame
                    width: 184
                    height: 104
                    anchors.verticalCenter: parent.verticalCenter
                    scale: cell.isPointed ? 1.06 : 1
                    Behavior on scale {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        radius: Appearance.rounding.normal + 3
                        color: "transparent"
                        border.width: cell.isPointed ? 2 : 0
                        border.color: Appearance.colors.colPrimary
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: Appearance.rounding.normal
                        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
                    }
                    Loader {
                        id: picture
                        anchors.fill: parent
                        visible: false
                        // decoded at card size, straight from the picture (JPEG decodes scaled)
                        sourceComponent: Image {
                            source: cell.modelData.path ? FileUtils.fileUrl(cell.modelData.path) : (cell.modelData.thumb ?? "")
                            asynchronous: true
                            sourceSize: Qt.size(368, 208)
                            fillMode: Image.PreserveAspectCrop
                        }
                    }
                    Rectangle {
                        id: pictureMask
                        anchors.fill: parent
                        radius: Appearance.rounding.normal
                        visible: false
                        layer.enabled: true
                    }
                    MultiEffect {
                        anchors.fill: parent
                        source: picture
                        maskEnabled: true
                        maskSource: pictureMask
                    }
                    // the wallpaper you have now
                    Rectangle {
                        visible: (cell.modelData.path ?? "") === root.wallpaperNow
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: 7
                        width: 22
                        height: 22
                        radius: 11
                        color: Appearance.colors.colPrimary
                        MaterialSymbol {
                            anchors.centerIn: parent
                            text: "check"
                            iconSize: 15
                            color: Appearance.colors.colOnPrimary
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.pointed = cell.index
                    onClicked: {
                        root.pointed = cell.index;
                        root.keep();
                    }
                }
            }
        }

        // nothing to show
        StyledText {
            visible: root.items.length === 0 && !root.scanning
            anchors.centerIn: list
            text: root.source === "online"
                ? (root.onlineState === "looking" || OnlineWallpapers.loading ? "Looking…" : root.onlineState || "Nothing found")
                : root.filter.length > 0 ? "No picture is called that" : "No pictures here"
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
        }

        StyledText {
            x: 24
            y: 186
            text: "Enter keeps it · Esc goes back · ← → to look through · Tab for the next source" + (root.currentPath.length > 0 ? " · Drag the picture to choose the part" : "")
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: Appearance.colors.colSubtext
        }
        }
        }
    }
}
