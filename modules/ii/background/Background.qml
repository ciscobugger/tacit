pragma ComponentBehavior: Bound

import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.widgets.widgetCanvas
import qs.modules.common.functions as CF
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

import qs.modules.ii.background.widgets
import qs.modules.ii.background.widgets.clock
import qs.modules.ii.background.widgets.weather
import qs.modules.ii.background.widgets.media
import qs.modules.ii.background.widgets.images
import qs.modules.ii.background.widgets.resources
import qs.modules.ii.background.widgets.visualizer
import qs.modules.ii.background.widgets.calendar
import qs.modules.ii.background.widgets.worldclock
import qs.modules.ii.background.widgets.usercard
import qs.modules.ii.background.widgets.notes
import qs.modules.ii.background.widgets.todo
import qs.modules.ii.background.widgets.timers

Variants {
    id: root
    model: Quickshell.screens

    function getShapeFromName(name) {
        switch (name) {
            case "Circle":        return MaterialShape.Shape.Circle
            case "Square":        return MaterialShape.Shape.Square
            case "Slanted":       return MaterialShape.Shape.Slanted
            case "Arch":          return MaterialShape.Shape.Arch
            case "Fan":           return MaterialShape.Shape.Fan
            case "Arrow":         return MaterialShape.Shape.Arrow
            case "SemiCircle":    return MaterialShape.Shape.SemiCircle
            case "Oval":          return MaterialShape.Shape.Oval
            case "Pill":          return MaterialShape.Shape.Pill
            case "Triangle":      return MaterialShape.Shape.Triangle
            case "Diamond":       return MaterialShape.Shape.Diamond
            case "ClamShell":     return MaterialShape.Shape.ClamShell
            case "Pentagon":      return MaterialShape.Shape.Pentagon
            case "Gem":           return MaterialShape.Shape.Gem
            case "Sunny":         return MaterialShape.Shape.Sunny
            case "VerySunny":     return MaterialShape.Shape.VerySunny
            case "Cookie4Sided":  return MaterialShape.Shape.Cookie4Sided
            case "Cookie6Sided":  return MaterialShape.Shape.Cookie6Sided
            case "Cookie7Sided":  return MaterialShape.Shape.Cookie7Sided
            case "Cookie9Sided":  return MaterialShape.Shape.Cookie9Sided
            case "Cookie12Sided": return MaterialShape.Shape.Cookie12Sided
            case "Ghostish":      return MaterialShape.Shape.Ghostish
            case "Clover4Leaf":   return MaterialShape.Shape.Clover4Leaf
            case "Clover8Leaf":   return MaterialShape.Shape.Clover8Leaf
            case "Burst":         return MaterialShape.Shape.Burst
            case "SoftBurst":     return MaterialShape.Shape.SoftBurst
            case "Boom":          return MaterialShape.Shape.Boom
            case "SoftBoom":      return MaterialShape.Shape.SoftBoom
            case "Flower":        return MaterialShape.Shape.Flower
            case "Puffy":         return MaterialShape.Shape.Puffy
            case "PuffyDiamond":  return MaterialShape.Shape.PuffyDiamond
            case "PixelCircle":   return MaterialShape.Shape.PixelCircle
            case "PixelTriangle": return MaterialShape.Shape.PixelTriangle
            case "Bun":           return MaterialShape.Shape.Bun
            case "Heart":         return MaterialShape.Shape.Heart
            default:              return MaterialShape.Shape.Cookie7Sided
        }
    }

    function getColorFromName(name) {
        switch (name) {
            case "primary":            return Appearance.colors.colPrimary
            case "secondary":          return Appearance.colors.colSecondary
            case "tertiary":           return Appearance.colors.colTertiary
            case "primaryContainer":   return Appearance.colors.colPrimaryContainer
            case "secondaryContainer": return Appearance.colors.colSecondaryContainer
            case "tertiaryContainer":  return Appearance.colors.colTertiaryContainer
            case "layer0":             return Appearance.colors.colLayer0
            case "layer1":             return Appearance.colors.colLayer1
            default:                  return Appearance.colors.colPrimaryContainer
        }
    }

    PanelWindow {
        id: bgRoot

        required property var modelData
        property string currentWallpaperSource: Config.options.background.wallpaperPath
        property string previousWallpaperSource: Config.options.background.wallpaperPath
        property bool videoRevealed: false

        readonly property real splitFraction: {
            switch (Config.options.background.splitRatio) {
                case "25": return 0.28
                case "50": return 0.54
                default:   return 1.0
            }
        }
        readonly property bool overviewBlurActive: Config.options.overview.style === "niri" && GlobalStates.overviewOpen && Config.options.overview.enable
        readonly property bool userBlurActive: Config.options.background.showBlur && !bgRoot.wallpaperIsVideo
        readonly property bool blurFullScreen: bgRoot.overviewBlurActive || bgRoot.splitFraction >= 1.0

        //centered Wallpaper
        property bool centeredWallpaperEnabled: Config.options.background.centeredWallpaper && (!Config.options.background.centeredWallpaperOnlyWhenLocked || GlobalStates.screenLocked)
        property int centeredWallpaperShape: getShapeFromName(Config.options.background.centeredWallpaperShape)
        property int centeredWallpaperSize: Config.options.background.centeredWallpaperSize
        property color centeredWallpaperColor: root.getColorFromName(Config.options.background.centeredWallpaperColor)

        property var shaderList: ["circlePit", "circleSelect", "magic", "Doom", "Peel", "transition", "pixelate", "stripes", "crt", "dissolve", "glitch", "ripple", "shatter"]
        property string currentShader: "pixelate"
        property string wallpaperAnimation: Config.options.background.wallpaperAnimation ?? "random"

        property list<HyprlandWorkspace> workspacesForMonitor: Hyprland.workspaces.values.filter(workspace => workspace.monitor && workspace.monitor.name == monitor.name)
        property var activeWorkspaceWithFullscreen: workspacesForMonitor.filter(workspace => ((workspace.toplevels.values.filter(window => window.wayland?.fullscreen)[0] != undefined) && workspace.active))[0]
        visible: true

        readonly property bool hiddenForFullscreen: !GlobalStates.screenLocked
            && (activeWorkspaceWithFullscreen != undefined)
            && Config?.options.background.hideWhenFullscreen

        property HyprlandMonitor monitor: Hyprland.monitorFor(modelData)

        property string effectiveWallpaperPath: {
            if (GlobalStates.screenLocked && Config.options.background.lockWall !== "")
                return Config.options.background.lockWall;
            return Wallpapers.previewPath || Wallpapers.confirmedPath || Config.options.background.wallpaperPath;
        }

        property bool wallpaperIsVideo: bgRoot.effectiveWallpaperPath.endsWith(".mp4") || bgRoot.effectiveWallpaperPath.endsWith(".webm") || bgRoot.effectiveWallpaperPath.endsWith(".mkv") || bgRoot.effectiveWallpaperPath.endsWith(".avi") || bgRoot.effectiveWallpaperPath.endsWith(".mov")
        property string wallpaperPath: wallpaperIsVideo ? Config.options.background.thumbnailPath : bgRoot.effectiveWallpaperPath
        property bool wallpaperSafetyTriggered: {
            const enabled = Config.options.workSafety.enable.wallpaper;
            const sensitiveWallpaper = (CF.StringUtils.stringListContainsSubstring(wallpaperPath.toLowerCase(), Config.options.workSafety.triggerCondition.fileKeywords));
            const sensitiveNetwork = (CF.StringUtils.stringListContainsSubstring(Network.networkName.toLowerCase(), Config.options.workSafety.triggerCondition.networkNameKeywords));
            return enabled && sensitiveWallpaper && sensitiveNetwork;
        }

        property bool shouldBlur: (GlobalStates.screenLocked && Config.options.lock.blur.enable)
        property color dominantColor: Appearance.colors.colPrimary
        property bool dominantColorIsDark: dominantColor.hslLightness < 0.5
        property color colText: {
            if (wallpaperSafetyTriggered)
                return CF.ColorUtils.mix(Appearance.colors.colOnLayer0, Appearance.colors.colPrimary, 0.75);
            return (GlobalStates.screenLocked && shouldBlur) ? Appearance.colors.colOnLayer0 : CF.ColorUtils.colorWithLightness(Appearance.colors.colPrimary, (dominantColorIsDark ? 0.8 : 0.12));
        }
        Behavior on colText {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        property real transitionProgress: 1.0

        screen: modelData
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: (GlobalStates.screenLocked && !scaleAnim.running) ? WlrLayer.Overlay : WlrLayer.Bottom
        WlrLayershell.namespace: "quickshell:background"
        WlrLayershell.keyboardFocus: GlobalStates.desktopWidgetKeyboardFocus
            ? WlrKeyboardFocus.OnDemand
            : WlrKeyboardFocus.None
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: {
            if (!bgRoot.wallpaperSafetyTriggered || bgRoot.wallpaperIsVideo)
                return "transparent";
            return CF.ColorUtils.mix(Appearance.colors.colLayer0, Appearance.colors.colPrimary, 0.75);
        }
        Behavior on color {
            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
        }

        Component.onCompleted: {
            previousWallpaper.source = ""
            wallpaper.source = bgRoot.wallpaperSafetyTriggered ? "" : bgRoot.wallpaperPath
            bgRoot.currentWallpaperSource = bgRoot.wallpaperPath
            bgRoot.previousWallpaperSource = ""
            bgRoot.transitionProgress = 1.0
            if (bgRoot.wallpaperAnimation !== "") {
                bgRoot.currentShader = bgRoot.wallpaperAnimation === "random"
                    ? bgRoot.shaderList[Math.floor(Math.random() * bgRoot.shaderList.length)]
                    : bgRoot.wallpaperAnimation
            }
            bgRoot.videoRevealed = bgRoot.wallpaperIsVideo
        }

        onWallpaperPathChanged: {
            bgRoot.videoRevealed = false
            if (wallpaperSafetyTriggered) {
                previousWallpaper.source = ""
                wallpaper.source = ""
                bgRoot.transitionProgress = 1.0
                return
            }
            if (bgRoot.wallpaperAnimation === "") {
                wallpaper.source = wallpaperPath
                bgRoot.currentWallpaperSource = wallpaperPath
                if (!bgRoot.wallpaperIsVideo) return
                bgRoot.videoRevealed = true
                return
            }

            previousWallpaper.source = bgRoot.currentWallpaperSource
            wallpaper.source = wallpaperPath
            bgRoot.currentWallpaperSource = wallpaperPath
            if (bgRoot.wallpaperAnimation === "random") {
                bgRoot.currentShader = bgRoot.shaderList[Math.floor(Math.random() * bgRoot.shaderList.length)]
            } else {
                bgRoot.currentShader = bgRoot.wallpaperAnimation
            }
            bgRoot.transitionProgress = 0.0
            // The new picture can already be in Qt's cache (the drag preview loaded it a moment
            // ago, or it was the wallpaper before): then no status change follows, the crossfade
            // never starts, and the OLD picture stays on screen for good while everything else
            // reports the new one. Start the transition here when the image is already loaded.
            if (wallpaper.status === Image.Ready)
                transitionAnim.restart()
        }

        // A picture Qt cannot decode (missing, truncated, an unknown format, or past Qt's image
        // allocation limit) never reaches Image.Ready, so the crossfade would sit at 0 forever
        // with a full-screen shader on top of it. Keep what is on screen and say what failed.
        function abortWallpaperTransition(failedSource) {
            const keep = String(previousWallpaper.source);
            transitionAnim.stop();
            bgRoot.transitionProgress = 1.0;
            if (keep.length > 0) {
                wallpaper.source = keep;
                bgRoot.currentWallpaperSource = keep;
            }
            previousWallpaper.source = "";
            bgRoot.previousWallpaperSource = "";
            Wallpapers.reportUnloadable(CF.FileUtils.trimFileProtocol(String(failedSource)));
        }

        Timer {
            id: transitionWatchdog
            // Neither Ready nor Error arriving would leave the transition shader repainting for
            // the rest of the session; finish the change without the crossfade instead.
            interval: 5000
            running: bgRoot.wallpaperAnimation !== "" && bgRoot.transitionProgress < 1.0 && !transitionAnim.running
            onTriggered: {
                previousWallpaper.source = "";
                bgRoot.transitionProgress = 1.0;
            }
        }

        NumberAnimation {
            id: transitionAnim
            target: bgRoot
            property: "transitionProgress"
            from: 0.0
            to: 1.0
            duration: 1200
            easing.type: Easing.InOutCubic
            onFinished: {
                previousWallpaper.source = ""
                bgRoot.previousWallpaperSource = ""
                bgRoot.transitionProgress = 1.0
                bgRoot.videoRevealed = bgRoot.wallpaperIsVideo
            }
        }

        Connections {
            target: mediaLoader
            // The media widget asks for a reset by switching its loader off; it comes back once
            // the fade has actually unloaded it. Off and on inside one tick loads nothing new.
            function onActiveChanged() {
                if (!mediaLoader.active && !mediaLoader.enableLoading)
                    mediaLoader.enableLoading = true
            }
        }

        Connections {
            target: GlobalStates
            function onScreenLockedChanged() {
                if (!GlobalStates.screenLocked) {
                    bgRoot.videoRevealed = bgRoot.wallpaperIsVideo
                }
            }
        }

        Item {
            anchors.fill: parent
            opacity: bgRoot.hiddenForFullscreen ? 0 : 1
            enabled: !bgRoot.hiddenForFullscreen

            Behavior on opacity {
                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
            }

            Image {
                id: previousWallpaper
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                cache: true
                mipmap: true
                smooth: true
                asynchronous: true
                layer.enabled: true
                visible: false
                // PreserveAspectCrop can never show more than the panel's own pixels. Without
                // this a high-megapixel picture decodes at native size, and during a crossfade
                // both copies are resident at once.
                sourceSize.width: bgRoot.screen.width * bgRoot.screen.devicePixelRatio
                sourceSize.height: bgRoot.screen.height * bgRoot.screen.devicePixelRatio
            }

            StyledImage {
                id: wallpaper
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                cache: true
                smooth: true
                mipmap: true
                asynchronous: true
                layer.enabled: blurLoader.active
                visible: !blurLoader.active && !bgRoot.centeredWallpaperEnabled && !bgRoot.videoRevealed
                    && (bgRoot.wallpaperAnimation === "" || bgRoot.transitionProgress >= 1.0)
                sourceSize.width: bgRoot.screen.width * bgRoot.screen.devicePixelRatio
                sourceSize.height: bgRoot.screen.height * bgRoot.screen.devicePixelRatio
                onStatusChanged: {
                    if (status === Image.Ready && bgRoot.transitionProgress === 0.0) {
                        transitionAnim.restart()
                    } else if (status === Image.Error) {
                        bgRoot.abortWallpaperTransition(wallpaper.source)
                    }
                }
            }

            ShaderEffect {
                id: transitionEffect
                anchors.fill: parent
                layer.enabled: blurLoader.active
                visible: !blurLoader.active && !bgRoot.centeredWallpaperEnabled && !bgRoot.videoRevealed
                    && bgRoot.wallpaperAnimation !== "" && bgRoot.transitionProgress < 1.0

                property var fromImage: previousWallpaper
                property var toImage: wallpaper
                property var source1: previousWallpaper
                property var source2: wallpaper
                property real time: 0.0
                property real progress: bgRoot.transitionProgress
                property real aspectX: width / height
                property real aspectY: 1.0
                property vector2d aspectRatio: Qt.vector2d(aspectX, aspectY)
                property vector2d origin: Qt.vector2d(0.5, 0.5)

                fragmentShader: bgRoot.wallpaperAnimation !== ""
                    ? Qt.resolvedUrl(`shaders/${bgRoot.currentShader}.frag.qsb`)
                    : ""

                Timer {
                    interval: 16
                    repeat: true
                    running: transitionEffect.visible && transitionAnim.running
                    onTriggered: transitionEffect.time += interval / 1000.0
                }
                onVisibleChanged: if (!visible) transitionEffect.time = 0.0
            }

            Loader {
                id: blurLoader
                active: Config.options.lock.blur.enable && (GlobalStates.screenLocked || scaleAnim.running)
                    && !(bgRoot.userBlurActive || bgRoot.overviewBlurActive)
                anchors.fill: parent
                scale: GlobalStates.screenLocked ? Config.options.lock.blur.extraZoom : 1
                Behavior on scale {
                    NumberAnimation {
                        id: scaleAnim
                        duration: 400
                        easing.type: Easing.BezierSpline
                        easing.bezierCurve: Appearance.animationCurves.expressiveDefaultSpatial
                    }
                }
                sourceComponent: GaussianBlur {
                    source: bgRoot.wallpaperAnimation === "" || bgRoot.transitionProgress >= 1.0 ? wallpaper : transitionEffect
                    // Qt builds the kernel from samples/2 and switches to an undersampled
                    // fallback shader for anything wider, which is what banded while still
                    // costing a full-screen pass. Ask for no more than the samples can draw.
                    radius: GlobalStates.screenLocked
                        ? Math.min(Config.options.lock.blur.radius, Math.floor(Config.options.lock.blur.size / 2))
                        : 0
                    samples: Config.options.lock.blur.size
                    Rectangle {
                        opacity: GlobalStates.screenLocked ? 1 : 0
                        anchors.fill: parent
                        color: CF.ColorUtils.transparentize(Appearance.colors.colLayer0, 0.7)
                    }
                }
            }

            Loader {
                id: fastBlurLoader
                active: (bgRoot.userBlurActive || bgRoot.overviewBlurActive)
                    && (!bgRoot.centeredWallpaperEnabled || bgRoot.blurFullScreen)
                anchors.fill: parent
                sourceComponent: Item {
                    id: blurRoot
                    anchors.fill: parent

                    readonly property real fadeWidth: 140
                    readonly property real blurRadius: 48
                    readonly property bool alignRight: Config.options.background.splitSide === "right"
                    property real coreWidth: bgRoot.blurFullScreen ? blurRoot.width : blurRoot.width * bgRoot.splitFraction

                    Behavior on coreWidth {
                        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
                    }

                    FastBlur {
                        id: blurLayer
                        anchors.fill: parent
                        source: bgRoot.wallpaperAnimation === "" || bgRoot.transitionProgress >= 1.0 ? wallpaper : transitionEffect
                        radius: blurRoot.blurRadius

                        layer.enabled: !bgRoot.blurFullScreen
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: blurLayer.width
                                height: blurLayer.height
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: blurRoot.alignRight ? 1 - (blurRoot.coreWidth / blurRoot.width) : Math.max(0, (blurRoot.coreWidth - blurRoot.fadeWidth) / blurRoot.width); color: blurRoot.alignRight ? "transparent" : "white" }
                                    GradientStop { position: blurRoot.alignRight ? Math.min(1, 1 - (blurRoot.coreWidth - blurRoot.fadeWidth) / blurRoot.width) : Math.min(1, blurRoot.coreWidth / blurRoot.width); color: blurRoot.alignRight ? "white" : "transparent" }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: centeredWallpaperBg
                anchors.fill: parent
                color: bgRoot.centeredWallpaperColor
                opacity: bgRoot.centeredWallpaperEnabled ? 1 : 0
                visible: opacity > 0

                Behavior on opacity {
                    animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
                }
            }

            MaterialShape {
                id: centeredWallpaperShapeItem
                anchors.centerIn: parent
                width: bgRoot.centeredWallpaperSize
                height: bgRoot.centeredWallpaperSize
                color: bgRoot.centeredWallpaperColor
                shape: bgRoot.centeredWallpaperShape
                transformOrigin: Item.Center
                visible: opacity > 0

                state: bgRoot.centeredWallpaperEnabled ? "shown" : "hidden"

                states: [
                    State {
                        name: "shown"
                        PropertyChanges { target: centeredWallpaperShapeItem; scale: 1; opacity: 1 }
                    },
                    State {
                        name: "hidden"
                        PropertyChanges { target: centeredWallpaperShapeItem; scale: 1.4; opacity: 0 }
                    }
                ]

                transitions: [
                    Transition {
                        to: "shown"
                        ParallelAnimation {
                            NumberAnimation { target: centeredWallpaperShapeItem; property: "scale"; from: 0; duration: Appearance.animation.elementMove.duration; easing.type: Easing.InOutCubic }
                            NumberAnimation { target: centeredWallpaperShapeItem; property: "opacity"; duration: Appearance.animation.elementMove.duration; easing.type: Easing.InOutCubic }
                        }
                    },
                    Transition {
                        to: "hidden"
                        ParallelAnimation {
                            NumberAnimation { target: centeredWallpaperShapeItem; property: "scale"; duration: Appearance.animation.elementMove.duration; easing.type: Easing.InOutCubic }
                            NumberAnimation { target: centeredWallpaperShapeItem; property: "opacity"; duration: Appearance.animation.elementMove.duration; easing.type: Easing.InOutCubic }
                        }
                    }
                ]

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: MaterialShape {
                        width: centeredWallpaperShapeItem.width
                        height: centeredWallpaperShapeItem.height
                        shape: bgRoot.centeredWallpaperShape
                    }
                }

                StyledImage {
                    anchors.fill: parent
                    source: bgRoot.wallpaperPath
                    fillMode: Image.PreserveAspectCrop
                    cache: false
                    mipmap: true
                    antialiasing: true
                    sourceSize.width: parent.width
                    sourceSize.height: parent.height
                }
            }

            DropArea {
                id: wallpaperDropArea
                anchors.fill: parent
                keys: ["text/uri-list"]

                // A picture held over the desktop for a second previews as the wallpaper and
                // becomes it when let go (the notch offers Undo). A quick drop parks it on the
                // shelf like anything else: nothing changes by a slip of the hand.
                property string picture: ""
                property bool armed: false
                Timer {
                    id: dwellTimer
                    interval: 1000
                    onTriggered: {
                        wallpaperDropArea.armed = true
                        Wallpapers.startPreview(wallpaperDropArea.picture)
                    }
                }
                function settle() {
                    dwellTimer.stop()
                    if (wallpaperDropArea.armed)
                        Wallpapers.stopPreview()
                    wallpaperDropArea.armed = false
                    wallpaperDropArea.picture = ""
                }

                onEntered: (drag) => {
                    drag.accepted = drag.hasUrls
                    const one = drag.hasUrls && drag.urls.length === 1
                        ? CF.FileUtils.trimFileProtocol(decodeURIComponent(drag.urls[0].toString())) : ""
                    const oneExt = one.split(".").pop().toLowerCase()
                    wallpaperDropArea.picture = (one.length > 0 && Wallpapers.extensions.includes(oneExt)) ? one : ""
                    if (wallpaperDropArea.picture.length > 0)
                        dwellTimer.restart()
                }

                onExited: wallpaperDropArea.settle()

                onDropped: (drop) => {
                    if (!drop.hasUrls) {
                        drop.accepted = false
                        wallpaperDropArea.settle()
                        return
                    }
                    if (wallpaperDropArea.armed) {
                        IslandController.wallpaperSet(wallpaperDropArea.picture)
                    } else {
                        const globalPos = wallpaperDropArea.mapToGlobal(drop.x, drop.y)
                        DropShelf.show(drop.urls, globalPos.x, globalPos.y)
                    }
                    drop.accept()
                    wallpaperDropArea.settle()
                }

                // The desktop as a drop target: a dashed frame and one chip, never a wash over
                // the whole screen. While a picture is armed the wallpaper preview is showing
                // underneath, and covering it would hide the very thing being previewed.
                Item {
                    id: dropOverlay
                    anchors.fill: parent
                    visible: wallpaperDropArea.containsDrag
                    opacity: visible ? 1 : 0
                    Behavior on opacity {
                        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                    }

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 10
                        radius: 22
                        color: "transparent"
                        border.width: 2
                        border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.35)
                    }

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 64
                        implicitWidth: chip.implicitWidth + 34
                        implicitHeight: 46
                        radius: Appearance.rounding.full
                        color: CF.ColorUtils.transparentize(Appearance.m3colors.m3surfaceContainer, 0.08)
                        border.width: 1
                        border.color: CF.ColorUtils.transparentize(Appearance.colors.colPrimary, 0.6)

                        RowLayout {
                            id: chip
                            anchors.centerIn: parent
                            spacing: 9
                            MaterialSymbol {
                                text: wallpaperDropArea.armed ? "wallpaper" : "stacks"
                                iconSize: 20
                                color: Appearance.colors.colPrimary
                            }
                            StyledText {
                                text: wallpaperDropArea.armed ? Translation.tr("Let go to set as wallpaper")
                                    : wallpaperDropArea.picture.length > 0 ? Translation.tr("Drop to park it · hold for wallpaper")
                                    : Translation.tr("Drop to park it on the shelf")
                                font.pixelSize: Appearance.font.pixelSize.normal
                                color: Appearance.colors.colOnLayer1
                            }
                        }
                    }
                }
            }

            WidgetCanvas {
                id: widgetCanvas
                anchors.fill: parent

                transitions: Transition {
                    PropertyAnimation {
                        properties: "width,height"
                        duration: Appearance.animation.elementMove.duration
                        easing.type: Appearance.animation.elementMove.type
                        easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                    }
                    AnchorAnimation {
                        duration: Appearance.animation.elementMove.duration
                        easing.type: Appearance.animation.elementMove.type
                        easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.visualizer.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: VisualizerWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.customImage.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: CustomImage {
                        screenWidth:        bgRoot.screen.width
                        screenHeight:       bgRoot.screen.height
                        scaledScreenWidth:  bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale:     1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.calendar.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: CalendarWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.weather.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: WeatherWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.clock.enable
                        && (GlobalStates.screenLocked
                            || Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: ClockWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperSafetyTriggered: bgRoot.wallpaperSafetyTriggered
                        wallpaperItem: wallpaper
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.notes.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: NotesWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    id: mediaLoader
                    property bool enableLoading: true
                    shown: Config.options.background.widgets.media.enable && enableLoading
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: MediaWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper 
                    }
                    onLoaded: {
                        if (item && item.requestReset) {
                            item.requestReset.connect(() => {
                                mediaLoader.enableLoading = false
                            })
                        }
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.images.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: ImageConverterWidget {
                        screenWidth:        bgRoot.screen.width
                        screenHeight:       bgRoot.screen.height
                        scaledScreenWidth:  bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale:     1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.resources.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: ResourcesWidget {
                        screenWidth:        bgRoot.screen.width
                        screenHeight:       bgRoot.screen.height
                        scaledScreenWidth:  bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale:     1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.worldClock.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: WorldClockWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.userCard.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: UserCardWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.todo.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: TodoWidget {
                        screenWidth: bgRoot.screen.width
                        screenHeight: bgRoot.screen.height
                        scaledScreenWidth: bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale: 1
                        wallpaperItem: wallpaper 
                    }
                }
                FadeLoader {
                    shown: Config.options.background.widgets.timers.enable
                        && (Config.options.background.screenList.length === 0
                            || Config.options.background.screenList.includes(bgRoot.screen.name))
                    sourceComponent: TimerWidget {
                        screenWidth:        bgRoot.screen.width
                        screenHeight:       bgRoot.screen.height
                        scaledScreenWidth:  bgRoot.screen.width
                        scaledScreenHeight: bgRoot.screen.height
                        wallpaperScale:     1
                        wallpaperItem: wallpaper 
                    }
                }
            }

            MouseArea {
                id: desktopRightClickArea
                anchors.fill: parent
                z: -2
                acceptedButtons: Qt.RightButton
                onClicked: (mouse) => {
                    GlobalStates.desktopMenuScreen = bgRoot.screen
                    GlobalStates.desktopMenuX = mouse.x
                    GlobalStates.desktopMenuY = mouse.y
                    GlobalStates.desktopMenuOpen = true
                }
            }
        }
    }
}
