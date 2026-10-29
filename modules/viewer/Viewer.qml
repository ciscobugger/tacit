import QtQuick
import QtMultimedia
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import QtQuick.Pdf
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import "Info.js" as Info

// The viewer's surface. One motion carries everything:
//   Roll  - the open file framed, its neighbours (of any kind) peeking in at both edges, a caption under
//           it and one row of ticks. Horizontal swipe or an arrow steps to the next file.
//   Bare  - when stepping stops (a short dwell, a click or Enter) the framed file grows to fill the window
//           and the chrome shrinks to plain text; the next swipe or arrow shrinks it back into the roll.
//   Fold  - the roll pulled back to the whole folder (Tab or a pinch).
// `settle` (0 roll .. 1 bare) and `fold` are the only things that animate the layout; every frame and
// every caption derives from them and from `pos`, the roll's place in files, so nothing jumps.
Item {
    id: vw

    // ---- tokens
    property color ground: "#1D1A19"          // the window's own colour, opaque
    readonly property color main: Appearance.colors.colInkMain
    readonly property color sec: Appearance.colors.colInkSecondary
    readonly property color meta: Appearance.colors.colInkMeta
    readonly property color faint: Appearance.colors.colInkFaint
    readonly property color hair: Appearance.colors.colInkDivider
    readonly property color hit: Appearance.m3colors.m3primary    // search matches on the dark ground (ticks, ruler, strip)
    property bool animate: true               // off for stills of one frame of the motion
    property bool muted: false
    property real volume: 0.8
    readonly property real dimOthers: 0.55 * (1 - fold) + 0.35 * fold

    // ---- what is open
    property string folder: ""
    property string wantPath: ""
    property var entries: []                  // [{ path, name, kind, size, at }]
    property int cur: 0                       // the framed file
    property int landed: -1                   // the file the player and reader belong to
    property real pos: 0                      // the roll's place in files; = cur at rest
    property real settle: 0
    property real fold: 0
    property real facts: 0
    property bool factsOn: false
    property bool folded: false
    property bool touching: false
    readonly property var entry: entries[landed] ?? null
    readonly property string kind: entry?.kind ?? ""
    readonly property bool bare: settle > 0.5

    Behavior on pos { enabled: vw.animate && !vw.touching; Anim { type: Anim.SlowEffects } }
    Behavior on settle { enabled: vw.animate; Anim { type: Anim.Emphasized } }
    Behavior on fold { enabled: vw.animate; Anim { type: Anim.Emphasized } }
    Behavior on facts { enabled: vw.animate; Anim { type: Anim.DefaultEffects } }
    onFactsOnChanged: facts = factsOn ? 1 : 0
    onFoldedChanged: fold = folded ? 1 : 0

    // ---- size, as the mocks measured them at 1544 x 944
    readonly property real cx: width / 2
    readonly property real capW: width * 0.74
    readonly property real ry: Math.round(Math.max(height * (0.051 + 0.203 * fold), height >= 560 ? 64 : 0))   // room for the controls' line above the frames
    readonly property real factsW: Math.min(830, width - 48)
    readonly property real rhRest: Math.min(height * 0.805, height - 120 - height * 0.051)   // leaves the caption its own row above the ticks
    readonly property real rhFacts: Math.max(height * 0.32, Math.min(height * 0.572, height - height * 0.051 - 70 - rollFacts.implicitHeight - 84))
    property real searchLift: searchOpen && kind === "pdf" ? 1 : 0
    Behavior on searchLift { enabled: vw.animate; Anim { type: Anim.DefaultEffects } }
    readonly property real rh: lerp(lerp(rhRest, rhFacts, facts), height * 0.403, fold) - 64 * searchLift
    function lerp(a, b, t) { return a + (b - a) * t; }

    // ---- geometry of the roll
    function aspectOf(i) {
        const e = entries[i];
        if (!e) return 1;
        aspectVer;
        return aspects[e.path] ?? (e.kind === "pdf" ? 0.707 : e.kind === "video" ? 1.778 : e.kind === "audio" ? 1 : 1.5);
    }
    // one map by path, changed in place (a copy per picture is O(folder)); `aspectVer` is what bindings watch
    readonly property var aspects: ({})
    property int aspectVer: 0
    function setAspectOf(path, a) {
        if (a > 0 && Math.abs((aspects[path] ?? 0) - a) > 0.001) { aspects[path] = a; aspectVer++; }
    }
    function setImageSize(path, w, h) { setAspectOf(path, w / h); }
    function rollSize(i) {
        const e = entries[i];
        if (!e) return Qt.size(0, 0);
        if (e.kind === "audio") { const q = rh * lerp(0.8, 1, fold); return Qt.size(q, q); }
        const a = aspectOf(i);
        let w = a * rh, h = rh;
        const cap = capW + fold * 4 * width;
        if (w > cap) { w = cap; h = w / a; }
        return Qt.size(w, h);
    }
    // centre of file i from the window's centre, with the roll at `pos`
    function rollOffset(i) {
        const n = entries.length, f = Math.max(0, Math.min(n - 1, Math.floor(pos))), t = pos - f, gap = lerp(18, 22, fold);
        let d = 0;
        if (i >= f) for (let k = f; k < i; k++) d += (rollSize(k).width + rollSize(k + 1).width) / 2 + gap;
        else for (let k = f; k > i; k--) d -= (rollSize(k).width + rollSize(k - 1).width) / 2 + gap;
        const next = f + 1 < n ? (rollSize(f).width + rollSize(f + 1).width) / 2 + gap : 0;
        return d - t * next;
    }
    readonly property int curF: Math.max(0, Math.min(entries.length - 1, Math.floor(pos)))
    readonly property real curT: pos - curF
    readonly property real curW: entries.length ? lerp(rollSize(curF).width, rollSize(Math.min(entries.length - 1, curF + 1)).width, curT) : 0
    readonly property real curH: entries.length ? lerp(rollSize(curF).height, rollSize(Math.min(entries.length - 1, curF + 1)).height, curT) : 0
    readonly property real fx: cx - curW / 2
    // 1 while the roll rests on a file, 0 half way between two: what is written about a file dips as the roll passes
    readonly property real still: Math.max(0, 1 - 2 * Math.abs(pos - cur)) * (landed === cur ? 1 : 0)
    readonly property real rollOp: Math.max(0, 1 - settle * 1.8) * Math.max(0, 1 - 2.5 * fold)
    // a PDF: one page is fitted to the window's height; pages in a column to its width, up to a reading width
    readonly property real stripW: 104
    readonly property real pdfLeft: kind === "pdf" && pdfMulti ? stripW : 0
    readonly property real pdfRight: leafW * leafK
    property real pdfBase: 600
    function relayPdf() {
        pdfBase = pdfMulti ? Math.min(900, width - stripW - 24 - 34) : Math.min((height - pdfHead - 36) * pdfAspect, width - 24 - 34);
    }
    onWidthChanged: relayPdf()
    onHeightChanged: relayPdf()
    onPdfMultiChanged: relayPdf()
    onPdfAspectChanged: relayPdf()
    Component.onCompleted: relayPdf()
    readonly property real pdfPageW: Math.min(width - pdfLeft - pdfRight - 24, pdfBase * pdfZoom)
    readonly property real pdfHead: 104
    // the framed file's width over height; set by handlers, so the layout does not read what its own frames report
    property real pdfAspect: 0.707
    property bool pdfMulti: false
    onPdfPagesChanged: Qt.callLater(() => pdfMulti = pdfPages > 1)   // after the reader that reports it has finished laying out
    function syncAspect() { if (landed >= 0) pdfAspect = aspectOf(landed); }
    onAspectVerChanged: syncAspect()
    onLandedChanged: syncAspect()
    readonly property real leafW: 388
    readonly property real leafK: kind !== "audio" ? facts * Math.min(1, Math.max(0, (settle - 0.5) * 2)) : 0
    function bareRect(kind) {
        if (kind === "audio") { const q = Math.min(0.3 * width, 0.5 * height); return Qt.rect(0.097 * width, 0.201 * height, q, q); }
        if (kind === "pdf") return Qt.rect(pdfLeft + (width - pdfLeft - pdfRight - pdfPageW) / 2, pdfHead - 8, pdfPageW, pdfPageW / Math.max(0.3, pdfAspect));
        return Qt.rect(0, 0, width, height);     // the leaf lies over the picture, as in the mock
    }

    // ---- opening
    function urlOf(path) { return "file://" + path.split("/").map(encodeURIComponent).join("/"); }
    function open(path) {
        const dir = path.replace(/\/[^\/]*$/, "") || "/";
        wantPath = path;
        loadOrigins();
        folder = dir;
        const url = urlOf(dir);
        if (entriesFor.folder.toString() === url) { if (entriesFor.status === FolderListModel.Ready) relist(); }
        else entriesFor.folder = url;
    }
    FolderListModel {
        id: entriesFor
        showDirs: false
        showDotAndDotDot: false
        showHidden: false
        caseSensitive: false
        sortField: FolderListModel.Name
        nameFilters: Info.patterns()
        onStatusChanged: if (status === FolderListModel.Ready) vw.relist()
        onCountChanged: if (status === FolderListModel.Ready) relistLater.restart()
    }
    // a big folder reports its count in many steps; read it once it has stopped growing
    Timer { id: relistLater; interval: 120; onTriggered: vw.relist() }
    // the list again, keeping the framed file framed; a file the filters miss is added in its place
    function relist() {
        const keep = wantPath.length ? wantPath : (entries[cur]?.path ?? "");
        const list = [];
        for (let i = 0, n = Math.min(entriesFor.count, 5000); i < n; i++) {
            const p = entriesFor.get(i, "filePath") + "";
            list.push({ path: p, name: p.split("/").pop(), kind: Info.kindOf(p), size: entriesFor.get(i, "fileSize"), at: entriesFor.get(i, "fileModified") });
        }
        // a file the filters miss is added in its place, but only for the open that asked for it:
        // a framed file that has since been deleted or renamed is not kept as a ghost
        if (wantPath.length && !list.some(e => e.path === keep) && keep.startsWith(folder + "/")) {
            const e = { path: keep, name: keep.split("/").pop(), kind: Info.kindOf(keep), size: -1, at: new Date() };
            let at = list.findIndex(x => x.name.toLowerCase() > e.name.toLowerCase());
            list.splice(at < 0 ? list.length : at, 0, e);
        }
        const wasFirst = landed < 0;
        const found = list.findIndex(e => e.path === keep);
        const gone = found < 0 && !wasFirst && !wantPath.length && landed >= 0;   // the framed file went away
        entries = list;
        const i = found >= 0 ? found : Math.max(0, Math.min(list.length - 1, cur));   // else its nearest neighbour
        const moved = wasFirst || i !== cur || gone;
        cur = i;
        if (gone) landed = -1;
        if (wantPath.length) {
            wantPath = "";
            const on = animate;
            animate = false;
            pos = i;
            settle = 1;
            animate = on;
            land();
            if (kind === "video" || kind === "audio") wantPlay = true;
        } else if (moved) { pos = i; land(); }
        if (!bare) dwell.restart();
    }

    function land() {
        if (landed === cur && entry) return;
        zoomEase = false; zoom = 1; zoomTo = 1; zoomEase = true; panX = 0; panY = 0; rotEase = false; rot = 0; rotEase = true;
        pdfPage = 0; pdfPages = 0; pdfCounts = []; pdfMarks = []; pdfZoom = 1; pdfTop = 0; pdfSpan = 1;
        pdfPaper = ""; lockedDoc = null;
        query = ""; searchOpen = false; played = false;
        mediaError = "";
        peaks = [];
        landed = cur;     // after the resets: a PDF's reader reports its pages the moment it exists
        for (let k = Math.max(0, cur - 2); k <= Math.min(entries.length - 1, cur + 2); k++) ensureProbe(entries[k].path);
        if (kind === "audio") { peaksProc.command = ["python3", probeScript, "peaks", entry.path, "120"]; peaksProc.running = false; peaksProc.running = true; }
        forceActiveFocus();
    }

    // ---- stepping
    function step(d) {
        if (entries.length < 2) return;
        const t = Math.max(0, Math.min(entries.length - 1, cur + d));
        if (t === cur) return;
        settle = 0;
        goTo(t);
    }
    function goTo(i) {
        i = Math.max(0, Math.min(entries.length - 1, i));
        if (folded === false && settle > 0) settle = 0;
        if (i !== cur && searchOpen) closeSearch();
        cur = i;
        pos = i;
        dwell.restart();
    }
    onPosChanged: if (!touching && pos === cur) land()
    // stepping has stopped: the framed file fills the window
    Timer {
        id: dwell
        interval: 900
        onTriggered: if (!vw.touching && !vw.folded && !vw.bare && vw.landed === vw.cur && !vw.searchOpen && !vw.factsOn && vw.pos === vw.cur) vw.settleNow(false)
    }
    function settleNow(play) {
        if (folded) folded = false;
        dwell.stop();
        if (landed !== cur) land();
        if (kind === "pdf" && reader && query.length === 0 && settle < 0.5) reader.goTo(pdfPage, false);   // the page the frame shows
        settle = 1;
        if (play && (kind === "video" || kind === "audio")) { if (player.mediaStatus === MediaPlayer.LoadedMedia || player.mediaStatus === MediaPlayer.BufferedMedia) player.play(); else wantPlay = true; }
        showChrome();
    }
    function unsettle() { settle = 0; zoomTo = 1; zoom = 1; panX = 0; panY = 0; rotEase = false; rot = 0; rotEase = true; }
    function toggleFold() { folded = !folded; if (folded) { settle = 0; dwell.stop(); } else dwell.restart(); }

    // ---- touchpad: the roll follows the fingers, then settles on the nearest file, leaning with the flick
    property var swipeSamples: []
    function swipe(dx, phase, now) {
        if (folded) folded = false;
        if (phase === Qt.ScrollBegin || !touching) {
            if (settle > 0) unsettle();
            touching = true;
            swipeSamples = [];
            dwell.stop();
        }
        swipeIdle.restart();
        if (dx !== 0) {
            const stride = Math.max(200, curW + 18);
            pos = Math.max(-0.4, Math.min(entries.length - 0.6, pos - dx * 1.6 / stride));
            cur = Math.round(Math.max(0, Math.min(entries.length - 1, pos)));
            swipeSamples = swipeSamples.filter(s => now - s[0] <= 80).concat([[now, dx]]);
        }
        if (phase === Qt.ScrollEnd) swipeEnd();
    }
    function swipeEnd() {
        if (!touching) return;
        const rec = swipeSamples;
        const span = rec.length > 1 ? Math.max(16, rec[rec.length - 1][0] - rec[0][0]) : 0;
        const vel = span > 0 ? rec.reduce((a, s) => a + s[1], 0) / span : 0;   // px per ms, fingers' direction
        const lean = Math.max(-1.5, Math.min(1.5, -vel * 140 * 1.6 / Math.max(200, curW + 18)));
        touching = false;
        swipeSamples = [];
        goTo(Math.round(Math.max(0, Math.min(entries.length - 1, pos + lean))));
    }
    Timer { id: swipeIdle; interval: 150; onTriggered: vw.swipeEnd() }

    // ---- pinch: out pulls the roll back to the folder, in opens it; on a picture or a page it zooms
    property real zoomAtPinch: 1
    property bool pinching: false
    function pinch(scale, active) {
        if (active && !pinching) { pinching = true; zoomAtPinch = kind === "pdf" ? pdfZoom : zoom; }
        if (!active) { pinching = false; return; }
        const z = zoomAtPinch * scale;
        if (!folded && (bare || z > 1.15) && (kind === "image" || kind === "pdf") && !(scale < 0.8 && zoomAtPinch <= 1.01)) {
            if (!bare) settleNow(false);
            if (kind === "pdf") pdfZoom = Math.max(0.6, Math.min(1.8, z)); else setZoom(z);
        } else if (!folded && scale < 0.8) { folded = true; settle = 0; dwell.stop(); }
        else if (folded && scale > 1.2) { folded = false; dwell.restart(); }
    }

    // ---- pictures: zoom and pan
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    property real zoomTo: 1                   // where `zoom` is going: clicks compound from this, not from the eased value
    property bool zoomEase: true
    Behavior on zoom { enabled: vw.animate && !vw.pinching && vw.zoomEase; Anim { type: Anim.DefaultEffects } }
    function setZoom(z) {
        zoomTo = Math.max(1, Math.min(8, z));
        zoom = zoomTo;
        if (zoom <= 1) { panX = 0; panY = 0; } else clampPan();
    }
    function clampPan() {
        panX = Math.max(-(zoom - 1) * width / 2, Math.min((zoom - 1) * width / 2, panX));
        panY = Math.max(-(zoom - 1) * height / 2, Math.min((zoom - 1) * height / 2, panY));
    }

    // turning a picture turns the view only; the file is never written
    property int rot: 0                       // quarter turns, in degrees, counted on (so 270 -> 360 keeps turning)
    property bool rotEase: true
    property real rotAnim: rot
    Behavior on rotAnim { enabled: vw.animate && vw.rotEase; Anim { type: Anim.Emphasized } }

    // ---- what the title row does (the same as the keys)
    function zoomBy(dir) {
        if (kind === "pdf") { if (!bare) settleNow(false); pdfZoom = Math.max(0.6, Math.min(1.8, pdfZoom + dir * 0.15)); }
        else if (kind === "image") { if (!bare) settleNow(false); setZoom(dir > 0 ? zoomTo * 1.25 : zoomTo / 1.25); }
        showChrome();
    }
    function fit() {
        if (kind === "pdf") { if (!bare) settleNow(false); pdfZoom = 1; if (reader) reader.goTo(pdfPage, true); }
        else if (kind === "image") { if (!bare) settleNow(false); setZoom(1); }
        showChrome();
    }
    function turn() { if (kind !== "image") return; if (!bare) settleNow(false); rot += 90; showChrome(); }
    function toggleInfo() { factsOn = !factsOn; if (factsOn) dwell.stop(); showChrome(); }
    // the file onto the clipboard as a file (text/uri-list) and, for a picture, as the picture too
    function copyFile() {
        if (!entry) return;
        Quickshell.execDetached(["nice", "-n", "10", "sh", copyScript, entry.path, kind]);
        toast("Copied");
    }
    readonly property string copyScript: FileUtils.trimFileProtocol(Qt.resolvedUrl("../../scripts/viewer/viewer-copy"))
    function copyPath() {
        if (!entry) return;
        Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", entry.path]);
        toast("Path copied");
    }
    function showInPinax() { if (entry) Quickshell.execDetached(["qs", "-p", Directories.shellFile, "ipc", "call", "files", "reveal", entry.path]); }
    // Open with: the applications that take this file's type, the default first; nothing is remembered
    function openWith(x, y) {
        if (!entry) return;
        openMenu.menuX = Math.max(12, Math.min(width - 260, x - 248));
        openMenu.menuY = y;
        openProbe.path = entry.path;
        openProbe.running = true;
    }
    Process {
        id: openProbe
        property string path: ""
        command: ["bash", "-c", `p="$1"; t=$(xdg-mime query filetype "$p" 2>/dev/null); d=$(xdg-mime query default "$t" 2>/dev/null); printf 'TYPE\t%s\n' "$t"; { for dir in ~/.local/share/applications /usr/share/applications; do [ -n "$t" ] && [ -n "$d" ] && [ -f "$dir/$d" ] && { echo "$dir/$d"; break; }; done; [ -n "$t" ] && grep -lsE "^MimeType=(.*;)?$(printf %s "$t" | sed 's#[^[:alnum:]_/-]#\\\\&#g')(;|$)" ~/.local/share/applications/*.desktop /usr/share/applications/*.desktop 2>/dev/null; } | awk '!seen[$0]++' | while read -r f; do [ "$(basename "$f")" = "$d" ] || { grep -qE '^(NoDisplay|Hidden)=true' "$f" && continue; }; n=$(grep -m1 '^Name=' "$f" | cut -d= -f2-); g=$(grep -m1 '^GenericName=' "$f" | cut -d= -f2-); i=$(grep -m1 '^Icon=' "$f" | cut -d= -f2-); printf '%s\t%s\t%s\t%s\t%s\n' "$([ "$(basename "$f")" = "$d" ] && echo 1 || echo 0)" "$n" "$i" "$f" "$g"; done | sort -r`, "sh", openProbe.path]
        stdout: StdioCollector {
            onStreamFinished: {
                let apps = [], type = "";
                for (const l of text.split("\n").filter(l => l.length > 0)) {
                    const f = l.split("\t");
                    if (f[0] === "TYPE") { type = f[1]; continue; }
                    if (f.length < 4 || f[3].endsWith("/viewer.desktop")) continue;   // not this window again
                    apps.push({ file: f[3], label: /^[a-z0-9-]+$/.test(f[1]) && (f[4] ?? "").length ? f[4] : f[1], def: f[0] === "1", icon: f[2] });   // a command name like imv-dir reads as its kind
                }
                if (apps.length === 0) apps = [{ file: "", label: "Nothing else opens this", icon: "" }];
                openMenu.apps = apps;
                openMenu.path = openProbe.path;
                openMenu.open();
            }
        }
    }

    // ---- PDF
    property int pdfPage: 0
    property int pdfPages: 0
    property var pdfCounts: []
    property var pdfMarks: []
    property real pdfTop: 0
    property real pdfSpan: 1
    property real pdfZoom: 1
    property string pdfPaper: ""
    property var reader: null
    property string query: ""
    property bool searchOpen: false
    property var fallback: ({})
    property var fallbackFailed: ({})         // paths poppler could not render either
    function fallbackPages(path) { return fallback[path] ?? []; }
    function needFallback(path) {
        if (fallback[path] !== undefined) return;
        const n = Object.assign({}, fallback); n[path] = []; fallback = n;
        pagesProc.target = path;
        pagesProc.command = ["python3", probeScript, "pages", path, "60"];
        pagesProc.running = true;
    }
    function pdfGoTo(p) { if (reader) reader.goTo(p, true); else pdfPage = p; if (!bare && !searchOpen) pdfPage = p; }
    function pdfGoToFraction(f) { if (reader) reader.scrollTo(f * reader.total - reader.head - reader.list.height * 0.4 + 8, false); }
    function openSearch() {
        if (kind !== "pdf" || !reader || !reader.searchable) return;
        searchOpen = true;
        dwell.stop();
        searchField.forceActiveFocus();
        searchField.selectAll();
    }
    function setQuery(t) { searchField.text = t; }
    function closeSearch() { searchOpen = false; query = ""; searchField.text = ""; forceActiveFocus(); showChrome(); }

    // ---- media
    property Item videoSink: null
    property bool wantPlay: false
    property bool played: false               // a video frame has been drawn: the poster steps aside
    property string mediaError: ""
    property var peaks: []
    property real rate: 1
    readonly property bool mediaOn: kind === "video" || kind === "audio"
    readonly property real position: player.position
    readonly property real duration: Math.max(1, player.duration)
    readonly property bool playing: player.playbackState === MediaPlayer.PlayingState
    readonly property bool subtitleOn: player.activeSubtitleTrack >= 0
    // the output the system has chosen, kept current: an AudioOutput left without a device keeps the one that was the
    // default when Viewer started (Bluetooth headphones connected later still got the laptop speakers)
    MediaDevices { id: mediaDevices }
    MediaPlayer {
        id: player
        source: vw.mediaOn && vw.landed === vw.cur ? vw.urlOf(vw.entry.path) : ""
        videoOutput: vw.videoSink
        audioOutput: AudioOutput { device: mediaDevices.defaultAudioOutput; volume: vw.volume; muted: vw.muted }
        playbackRate: vw.rate
        onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia && vw.wantPlay) { vw.wantPlay = false; play(); }
        onPlaybackStateChanged: if (playbackState === MediaPlayer.PlayingState) vw.played = true
        onErrorOccurred: (e, text) => vw.mediaError = text
    }
    function togglePlay() {
        if (!mediaOn) return;
        if (playing) player.pause(); else { if (player.mediaStatus === MediaPlayer.EndOfMedia) player.position = 0; player.play(); }
        showChrome();
    }
    function pause() { if (playing) player.pause(); }
    function seekTo(f) { player.position = Math.max(0, Math.min(1, f)) * duration; showChrome(); }
    function seekBy(ms) { player.position = Math.max(0, Math.min(duration, player.position + ms)); toast(Info.clock(player.position)); }
    function setVolume(x) { volume = Math.max(0, Math.min(1, x)); muted = false; toast("Volume " + Math.round(volume * 100)); }
    function toggleMute() { muted = !muted; toast(muted ? "Muted" : "Volume " + Math.round(volume * 100)); }
    function cycleRate() {
        const r = [0.5, 0.75, 1, 1.25, 1.5, 2], i = r.indexOf(rate);
        rate = r[(i + 1) % r.length];
        toast(rate + "×");
    }
    function cycleSubtitles() {
        const n = player.subtitleTracks.length;
        if (n === 0) { toast("No subtitles"); return; }
        const next = player.activeSubtitleTrack + 1 >= n ? -1 : player.activeSubtitleTrack + 1;
        player.activeSubtitleTrack = next;
        toast(next < 0 ? "Subtitles off" : "Subtitles " + (player.subtitleTracks[next]?.stringValue(MediaMetaData.Language) ?? (next + 1)));
    }
    function cycleAudioTrack() {
        const n = player.audioTracks.length;
        if (n < 2) { toast("One audio track"); return; }
        player.activeAudioTrack = (player.activeAudioTrack + 1) % n;
        toast("Audio track " + (player.activeAudioTrack + 1) + " of " + n);
    }

    // ---- what is known about each file: probe.py (EXIF, ffprobe, posters), the origins index
    property var probed: ({})
    property var probeQueue: []
    readonly property string probeScript: FileUtils.trimFileProtocol(Qt.resolvedUrl("../../scripts/viewer/probe.py"))
    function ensureProbe(path) {
        if (probed[path] !== undefined) return;
        const n = Object.assign({}, probed); n[path] = null; probed = n;
        probeQueue = probeQueue.concat([path]);
        pump();
    }
    function pump() {
        if (probe.running || probeQueue.length === 0) return;
        probe.command = ["nice", "-n", "10", "python3", probeScript, "facts", probeQueue[0]];
        probeQueue = probeQueue.slice(1);
        probe.running = true;
    }
    Process {
        id: probe
        stdout: StdioCollector {
            onStreamFinished: {
                try { const r = JSON.parse(text); const n = Object.assign({}, vw.probed); n[r.path] = r; vw.probed = n; } catch (e) {}
            }
        }
        onExited: vw.pump()
    }
    Process {
        id: peaksProc
        stdout: StdioCollector { onStreamFinished: { try { vw.peaks = JSON.parse(text).peaks ?? []; } catch (e) {} } }
    }
    Process {
        id: pagesProc
        property string target: ""
        stdout: StdioCollector {
            onStreamFinished: {
                let pages = [];
                try { pages = JSON.parse(text).pages.map(p => "file://" + p); } catch (e) {}
                if (pages.length > 0) { const n = Object.assign({}, vw.fallback); n[pagesProc.target] = pages; vw.fallback = n; }
                else { const n = Object.assign({}, vw.fallbackFailed); n[pagesProc.target] = true; vw.fallbackFailed = n; }
            }
        }
    }
    function metaOf(path) { return probed[path] ?? null; }
    function thumbOf(path) { const t = probed[path]?.thumb; return t ? "file://" + t : ""; }
    function dimsOf(path) { const m = probed[path]; return m && m.w ? [m.w, m.h] : null; }

    property var originMap: ({})
    FileView { id: originsFile; path: `${Directories.state}/user/files/origins.json`; blockLoading: true; printErrors: false }
    function loadOrigins() { try { originMap = JSON.parse(originsFile.text() || "{}"); } catch (e) { originMap = ({}); } }
    // services/Origins.qml's appName, for the one place that needs it here
    function appName(id) {
        const a = (id ?? "").toLowerCase();
        if (a.startsWith("zen")) return "zen";
        if (a.includes("firefox")) return "firefox";
        if (a.includes("chrom") || a.includes("thorium")) return a.includes("thorium") ? "thorium" : "chromium";
        return a.split(".").pop();
    }
    function infoFor(e) {
        const m = metaOf(e.path);
        return { m: m, o: { home: Quickshell.env("HOME"), origin: originMap[e.path] ?? null, appName: appName, dims: dimsOf(e.path),
                 pages: e.path === entry?.path ? pdfPages : 0, paper: e.path === entry?.path ? pdfPaper : "" } };
    }
    readonly property var info: entry ? Info.facts(entry, metaOf(entry.path), infoFor(entry).o) : ({ lines: [], more: [] })
    readonly property string lineText: entry ? Info.line(entry, metaOf(entry.path), infoFor(entry).o) : ""
    readonly property string titleText: entry ? Info.title(entry.name, entry.kind, entry.at) : ""
    readonly property string kindText: entry ? Info.kindWord(entry, metaOf(entry.path), infoFor(entry).o) : ""
    readonly property string pageText: kind === "pdf" ? Info.pageCounter(pdfPage, pdfPages) : ""
    property bool moreOn: false
    function detailOf(i) {
        const e = entries[i];
        if (!e) return "";
        const m = metaOf(e.path);
        if (e.kind === "video" || e.kind === "audio") return m ? Info.clock((m.duration ?? 0) * 1000) : "";
        if (e.kind === "image") { const d = dimsOf(e.path); return d ? d[0] + " × " + d[1] : ""; }
        if (e.kind === "pdf") return e.path === entry?.path && pdfPages > 1 ? Info.pagesOf(pdfPages) : "PDF";
        return "";
    }
    readonly property var tags: probed[entry?.path ?? ""]?.tags ?? ({})
    readonly property string folderTitle: Info.folderTitle(folder)
    readonly property string folderWhere: { const h = Quickshell.env("HOME"); return folder.indexOf(h) === 0 ? "~" + folder.slice(h.length) : folder; }

    // ---- chrome on demand (bare): plain text, shown by any movement and gone after a pause
    property bool chromeOn: true
    // only the wish for chrome eases; what shows is that times `settle`, so it leaves and returns with the picture
    property real hold: chromeOn || (mediaOn && !playing) || searchOpen || factsOn ? 1 : 0
    Behavior on hold { enabled: vw.animate; Anim { type: Anim.DefaultEffects } }
    readonly property real chrome: settle * hold
    function showChrome() { chromeOn = true; chromeIdle.restart(); }
    Timer { id: chromeIdle; interval: 2600; onTriggered: if (top.held || ctl.hovered || openMenu.shown) restart(); else vw.chromeOn = false }
    property string note: ""
    function toast(t) { note = t; noteTimer.restart(); }
    Timer { id: noteTimer; interval: 1400; onTriggered: vw.note = "" }

    // ---- keys
    focus: true
    signal closeRequested()
    function hide() { closeRequested(); }
    function key(e) {
        const shift = (e.modifiers & Qt.ShiftModifier) !== 0, ctrl = (e.modifiers & Qt.ControlModifier) !== 0;
        showChrome();
        switch (e.key) {
        case Qt.Key_Left:
            if (shift && mediaOn) seekBy(-5000); else if (shift && kind === "pdf") { if (reader) reader.goTo(pdfPage - 1, true); } else step(-1);
            break;
        case Qt.Key_Right:
            if (shift && mediaOn) seekBy(5000); else if (shift && kind === "pdf") { if (reader) reader.goTo(pdfPage + 1, true); } else step(1);
            break;
        case Qt.Key_Home: goTo(0); break;
        case Qt.Key_End: goTo(entries.length - 1); break;
        case Qt.Key_Return: case Qt.Key_Enter:
            if (!bare || folded) settleNow(true); break;
        case Qt.Key_Up:
            if (mediaOn) setVolume(volume + 0.05); else if (kind === "pdf") { settleNow(false); if (reader) reader.scrollBy(-90); } else if (zoom > 1) { panY += 60; clampPan(); }
            break;
        case Qt.Key_Down:
            if (mediaOn) setVolume(volume - 0.05); else if (kind === "pdf") { settleNow(false); if (reader) reader.scrollBy(90); } else if (zoom > 1) { panY -= 60; clampPan(); }
            break;
        case Qt.Key_PageUp: if (kind === "pdf") { settleNow(false); if (reader) reader.goTo(pdfPage - 1, true); } break;
        case Qt.Key_PageDown: if (kind === "pdf") { settleNow(false); if (reader) reader.goTo(pdfPage + 1, true); } break;
        case Qt.Key_Space:
            if (mediaOn) togglePlay(); else if (kind === "pdf") { settleNow(false); if (reader) reader.scrollBy(reader.list.height * 0.85); }
            break;
        case Qt.Key_Tab: toggleFold(); break;
        case Qt.Key_I: toggleInfo(); break;
        case Qt.Key_Slash: openSearch(); break;
        case Qt.Key_F: if (ctrl) openSearch(); break;
        case Qt.Key_N: if (reader && query.length) reader.next(shift ? -1 : 1); break;
        case Qt.Key_C: if (ctrl && reader) reader.copy(); else if (!ctrl) cycleSubtitles(); break;
        case Qt.Key_A: cycleAudioTrack(); break;
        case Qt.Key_M: toggleMute(); break;
        case Qt.Key_BracketLeft: rate = Math.max(0.5, rate - 0.25); toast(rate + "×"); break;
        case Qt.Key_BracketRight: rate = Math.min(2, rate + 0.25); toast(rate + "×"); break;
        case Qt.Key_Plus: case Qt.Key_Equal:
            zoomBy(1); break;
        case Qt.Key_Minus: zoomBy(-1); break;
        case Qt.Key_0: fit(); break;
        case Qt.Key_Escape:
            if (openMenu.shown) openMenu.close();
            else if (searchOpen) closeSearch();
            else if (factsOn) factsOn = false;
            else if (zoom > 1) setZoom(1);
            else if (folded) { folded = false; dwell.restart(); }
            else hide();
            break;
        case Qt.Key_Q: hide(); break;
        default: return;
        }
        e.accepted = true;
    }
    Keys.onPressed: e => key(e)

    // ---- pointer
    HoverHandler { onPointChanged: if (vw.bare) vw.showChrome() }
    MouseArea {
        id: bg
        anchors.fill: parent
        z: -1
        hoverEnabled: false
        property real lx: 0
        property real ly: 0
        // A touchpad gesture keeps the direction it starts with until the fingers lift, as a browser
        // does: a two-finger scroll down a page is never quite straight, and a sideways sample would
        // otherwise swipe the roll mid-read. Reading a page column or a zoomed picture, sideways must
        // be clearly sideways.
        property string axis: ""
        property real ax: 0
        property real ay: 0
        Timer { id: axisIdle; interval: 150; onTriggered: { bg.axis = ""; bg.ax = 0; bg.ay = 0; } }
        onClicked: {
            vw.forceActiveFocus();
            if (vw.folded) return;
            if (vw.bare) { if (vw.mediaOn) vw.togglePlay(); else vw.chromeOn = !vw.chromeOn; }
        }
        onPressed: m => { lx = m.x; ly = m.y; }
        onPositionChanged: m => { if (pressed && vw.zoom > 1) { vw.panX += m.x - lx; vw.panY += m.y - ly; vw.clampPan(); } lx = m.x; ly = m.y; }
        onDoubleClicked: if (vw.kind === "image") vw.setZoom(vw.zoom > 1 ? 1 : 2.5)
        onWheel: w => {
            const px = w.pixelDelta, ang = w.angleDelta;
            let dx = px.x !== 0 ? px.x : ang.x / 120 * 80, dy = px.y !== 0 ? px.y : ang.y / 120 * 80;
            const touch = w.phase !== Qt.NoScrollPhase || px.x !== 0 || px.y !== 0;
            let sideways = Math.abs(dx) > Math.abs(dy);
            if (touch) {
                if (w.phase === Qt.ScrollBegin) { axis = ""; ax = 0; ay = 0; }
                axisIdle.restart();
                if (axis === "") {
                    ax += dx; ay += dy;
                    if (Math.abs(ax) + Math.abs(ay) < 6 && w.phase !== Qt.ScrollEnd) { w.accepted = true; return; }
                    const strict = vw.bare && (vw.kind === "pdf" || vw.zoom > 1);
                    axis = Math.abs(ax) > Math.abs(ay) * (strict ? 2 : 1) ? "x" : "y";
                    dx = ax; dy = ay;   // what was held back while the direction was open
                }
                sideways = axis === "x";
                if (w.phase === Qt.ScrollEnd) { axisIdle.stop(); axis = ""; ax = 0; ay = 0; }
            }
            if ((w.modifiers & Qt.ControlModifier) && vw.kind === "image") { if (!vw.bare) vw.settleNow(false); vw.setZoom(vw.zoom * Math.pow(1.002, dy)); }
            else if ((w.modifiers & Qt.ControlModifier) && vw.kind === "pdf") vw.pdfZoom = Math.max(0.6, Math.min(1.8, vw.pdfZoom * Math.pow(1.002, dy)));
            else if (sideways) {
                if (vw.zoom > 1) { vw.panX += dx; vw.clampPan(); }
                else if (touch) vw.swipe(dx, w.phase, Date.now());
                else vw.step(dx > 0 ? -1 : 1);
            } else if (dy !== 0) vw.inside(dy, touch);
            w.accepted = true;
        }
    }
    // vertical is inside the file: a page column scrolls, a picture pans, a recording scrubs
    function inside(dy, touch) {
        if (folded) return;
        if (kind === "pdf") { if (!bare) settleNow(false); if (reader) reader.scrollBy(-dy); }
        else if (kind === "image") { if (zoom > 1) { panY += dy; clampPan(); } }
        else if (mediaOn) { if (touch) seekBy(-dy * 30); else seekBy(dy > 0 ? -5000 : 5000); }
    }
    PinchHandler {
        target: null
        onActiveChanged: vw.pinch(1, active)
        onActiveScaleChanged: if (active) vw.pinch(activeScale, true)
    }
    DragHandler {
        target: null
        enabled: false
    }

    // ================================================================ the frames
    // only the files near the roll (what Frame shows is within 5 of pos) and the landed one have a frame
    readonly property int centre: Math.max(0, Math.min(entries.length - 1, Math.round(pos)))
    readonly property var windowed: {
        const w = [], n = entries.length;
        for (let i = Math.max(0, centre - 5); i <= Math.min(n - 1, centre + 5); i++) w.push(i);
        if (landed >= 0 && landed < n && w.indexOf(landed) < 0) { w.push(landed); w.sort((a, b) => a - b); }
        return w;
    }
    property int framesMade: 0
    Repeater {
        model: ScriptModel { values: vw.windowed }
        Frame { v: vw }
    }

    // ================================================================ the roll's own text
    // caption: the name and one line of facts under the frame; for audio, the track
    Item {
        id: caption
        x: vw.fx
        y: vw.ry + vw.curH + 22 + 4 * vw.facts + 34 * vw.searchLift
        width: vw.curW
        opacity: vw.rollOp * vw.still * Math.max(0, 1 - 3 * vw.settle)
        visible: opacity > 0.01 && vw.entry !== null && vw.kind !== "audio"
        VT { id: nameT; width: Math.max(80, parent.width - lineT.implicitWidth - 24); elide: Text.ElideMiddle; text: vw.titleText; font.pixelSize: vw.lerp(vw.lerp(16, 20, vw.facts), 13, vw.searchLift); font.weight: vw.searchLift > 0.5 ? Font.Normal : Font.DemiBold; ink: vw.searchLift > 0.5 ? 2 : 0 }
        VT { id: lineT; x: parent.width - width; y: 1; ink: 2; opacity: 1 - vw.facts; text: vw.searchLift > 0.5 ? "Page " + (vw.pdfPage + 1) + " of " + vw.pdfPages : vw.lineText }
        VT { x: parent.width - width; y: 4; ink: 2; opacity: vw.facts; text: (vw.landed + 1) + " of " + vw.entries.length }
    }
    Item {
        x: vw.fx
        y: vw.ry + vw.curH + 24
        width: vw.curW
        opacity: vw.rollOp * vw.still
        visible: opacity > 0.01 && vw.kind === "audio"
        VT { text: vw.tags.title || vw.titleText; font.pixelSize: 28; font.weight: Font.DemiBold; width: parent.width; elide: Text.ElideRight }
        VT { y: 40; ink: 1; font.pixelSize: 16; width: parent.width; elide: Text.ElideRight; text: Info.join([vw.tags.artist, vw.tags.album, vw.tags.date]) }
        VT { y: 72; ink: 2; font.pixelSize: 13; width: parent.width; elide: Text.ElideRight; text: vw.lineText }
    }
    // facts pulled up under the frame (i)
    Facts {
        id: rollFacts
        x: Math.max(24, Math.min(vw.width - vw.factsW - 24, vw.fx))
        y: vw.ry + vw.curH + 26 + 44
        colWidth: Math.min(420, vw.factsW)
        info: vw.kind === "audio" ? ({ lines: [], more: [] }) : vw.info
        moreOn: vw.moreOn
        onMoreToggled: vw.moreOn = !vw.moreOn
        onCopyPath: vw.copyPath()
        opacity: vw.facts * vw.facts * vw.rollOp * vw.still
        visible: opacity > 0.01
    }
    // one row of ticks, whose meaning follows the file
    FileTicks {
        v: vw
        x: vw.cx - width / 2
        y: vw.height - 52
        opacity: vw.rollOp * vw.still * (vw.kind === "image" || vw.kind === "file" || vw.kind === "" ? 1 : 0)
        visible: opacity > 0.01
    }
    PdfTicks {
        v: vw
        x: vw.fx
        width: vw.curW
        y: vw.height - 72
        opacity: vw.rollOp * vw.still * (vw.kind === "pdf" && vw.pdfPages > 1 ? 1 : 0)
        visible: opacity > 0.01
    }

    // ================================================================ one transport for video and audio, roll to bare
    Rectangle {
        // under the bare video transport: the picture's own bottom edge fades to the ground
        x: 0
        y: vw.height - 190
        width: vw.width
        height: 190
        opacity: vw.hold * Math.min(1, vw.settle * 2.5) * (vw.kind === "video" ? 1 : 0)
        visible: opacity > 0.01
        gradient: Gradient {
            GradientStop { position: 0; color: "transparent" }
            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.7) }
        }
    }
    Transport {
        v: vw
        audio: vw.kind === "audio"
        readonly property real brx: vw.kind === "audio" ? vw.bareRect("audio").x : 0
        x: vw.lerp(vw.fx, brx, vw.settle)
        y: vw.kind === "audio" ? vw.lerp(vw.height - 124, vw.height * 0.805, vw.settle) : vw.height - 86
        width: vw.lerp(vw.curW, vw.width - 2 * brx, vw.settle)
        pad: vw.kind === "audio" ? 0 : 28 * vw.settle
        opacity: vw.mediaOn ? Math.max(vw.rollOp * vw.still, vw.hold * Math.min(1, vw.settle * 2.5) * (vw.landed === vw.cur ? 1 : 0)) : 0
        visible: opacity > 0.01
    }

    // ================================================================ the search: the caption turns into it
    Item {
        id: search
        // bare: centred, 420 wide, but never over the controls or their counter; narrower and to the left when the window is
        readonly property real room: ctl.x - 16
        readonly property real bw: Math.max(200, Math.min(420, room - 24 - 120))
        readonly property real bx: Math.max(24, Math.min((vw.width - bw) / 2, room - bw))
        x: vw.lerp(vw.fx, bx, vw.settle)
        y: vw.lerp(vw.ry + vw.curH + 20, 24, vw.settle)
        width: vw.lerp(vw.curW, bw, vw.settle)
        height: 40
        opacity: vw.searchOpen ? 1 : 0
        visible: opacity > 0.01
        z: 25
        Behavior on opacity { enabled: vw.animate; Anim { type: Anim.FastEffects } }
        VGlyph { y: 3; text: "search"; ink: 2 }
        TextInput {
            id: searchField
            x: 32
            y: 3
            width: parent.width - 32 - 130
            color: vw.main
            selectionColor: vw.hit
            selectedTextColor: vw.ground
            font.family: Appearance.font.family.main
            font.pixelSize: 18
            clip: true
            cursorDelegate: Rectangle { width: 1.5; color: vw.main }
            onTextChanged: vw.query = text
            Keys.onPressed: e => {
                if (e.key === Qt.Key_Escape) { vw.closeSearch(); e.accepted = true; }
                else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && vw.reader) { vw.reader.next((e.modifiers & Qt.ShiftModifier) ? -1 : 1); e.accepted = true; }
            }
        }
        VT {
            x: parent.width - width
            y: 6
            ink: 1
            text: vw.query.length === 0 ? "" : !vw.reader || vw.reader.search.count === 0 ? "No matches" : (vw.reader.search.currentResult + 1) + " of " + vw.reader.search.count
        }
        Rectangle { y: 36; width: parent.width; height: 1; color: vw.hair; opacity: vw.settle }
    }

    // ================================================================ bare chrome
    // v1's: plain text over a soft fade, shown by any movement and gone after a pause. The controls sit at
    // the right end of its line; in the roll, with no fade, they stay.
    readonly property alias titleBar: top   // the stills reach its buttons
    Item {
        id: top
        readonly property alias controls: ctlRow
        readonly property bool held: hov.hovered
        // where the right-hand text ends: left of the controls, and left of the leaf when it is open
        readonly property real rx: Math.min(ctl.x - 14, vw.width - vw.leafW * vw.leafK - 32)
        readonly property bool searching: vw.searchOpen && vw.bare
        readonly property real lim: (counterT.visible ? counterT.x : rx) - 16
        width: vw.width
        height: 100
        opacity: vw.chrome
        visible: opacity > 0.01
        z: 20
        // eases out to nothing, in the window's own dark: over a page it holds long enough to hide the
        // pages scrolled under the line, over a picture it only lifts the text
        Scrim {
            width: parent.width
            height: vw.kind === "pdf" ? vw.pdfHead - 8 : 170     // a page's fade ends where the first page starts
            tint: vw.ground
            strength: vw.kind === "pdf" ? 0.97 : 0.55
            hold: vw.kind === "pdf" ? 0.55 : 0
        }
        Item { id: headLine; width: parent.width; height: 56; HoverHandler { id: hov; onHoveredChanged: if (hovered) vw.showChrome() } }
        VT {
            id: topName
            x: 32
            y: 26
            width: Math.min(implicitWidth, Math.max(60, Math.min(top.lim, top.searching ? search.x - 16 : top.lim) - 32))
            elide: Text.ElideRight
            text: vw.titleText
            font.weight: Font.DemiBold
            font.pixelSize: 15
            ink: vw.kind === "pdf" ? 1 : 0
        }
        VT {
            x: 32 + topName.width + 14
            y: 27
            width: Math.max(0, Math.min(top.lim, top.searching ? search.x - 16 : top.lim) - x)
            elide: Text.ElideRight
            ink: 1
            visible: vw.kind !== "pdf" && width > 40
            text: vw.lineText
        }
        VT {
            id: counterT
            x: top.rx - width
            y: 27
            ink: 1
            // the file the title names (landed), not the one the roll is heading to
            text: vw.kind === "pdf" ? (vw.pdfPages > 1 ? "Page " + Info.pageCounter(vw.pdfPage, vw.pdfPages) : "") : (vw.landed + 1) + " of " + vw.entries.length
            visible: text.length > 0 && !(top.searching && x < search.x + search.width + 12)
        }
    }
    // the controls: quiet glyphs, the same actions as the keys
    Item {
        id: ctl
        readonly property bool hovered: hovC.hovered
        width: ctlRow.width
        height: 32
        x: vw.width - 14 - width
        y: 20      // one place in the roll and bare alike, on the title's line, so stepping never moves it
        z: 35
        // in the roll they stay, above the frames; a window too short to leave that room has none until Bare
        opacity: Math.min(1, (1 - vw.settle) * Math.max(0, Math.min(1, (vw.ry - 56) / 8)) + vw.chrome)
        visible: opacity > 0.01
        HoverHandler { id: hovC; onHoveredChanged: if (hovered) vw.showChrome() }
        // eats clicks, so a click on a button never turns the chrome off or plays a video
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: w => w.accepted = true }
        Row {
            id: ctlRow
            readonly property bool pic: vw.kind === "image"
            readonly property bool paged: vw.kind === "pdf"
            // each action has one place: here zoom, Previous and Next, and Info; turning, copying, opening
            // and showing in Pinax are in the Info leaf. The row keeps one width, so the arrows never move; a
            // zoom slot with nothing to do fades. The folder view has no zoom or turn; a narrow window searching gives the room to the search
            readonly property bool inFile: vw.fold < 0.5 && !(top.searching && vw.width < 1000)
            VBtn { opacity: (ctlRow.inFile && (ctlRow.pic || ctlRow.paged)) ? 1 : 0; enabled: ctlRow.inFile && (ctlRow.pic || ctlRow.paged); glyph: "remove"; tip: "Zoom out"; onClicked: vw.zoomBy(-1) }
            VBtn { opacity: (ctlRow.inFile && (ctlRow.pic || ctlRow.paged)) ? 1 : 0; enabled: ctlRow.inFile && (ctlRow.pic || ctlRow.paged); glyph: "fit_screen"; tip: "Fit to window"; onClicked: vw.fit() }
            VBtn { opacity: (ctlRow.inFile && (ctlRow.pic || ctlRow.paged)) ? 1 : 0; enabled: ctlRow.inFile && (ctlRow.pic || ctlRow.paged); glyph: "add"; tip: "Zoom in"; onClicked: vw.zoomBy(1) }
            Item { width: 8; height: 1 }
            VBtn { glyph: "chevron_left"; tip: "Previous file"; live: vw.cur > 0; onClicked: vw.step(-1) }
            VBtn { glyph: "chevron_right"; tip: "Next file"; live: vw.cur < vw.entries.length - 1; onClicked: vw.step(1) }
            Item { width: 8; height: 1 }
            VBtn { glyph: "info"; tip: vw.factsOn ? "Hide info" : "Info"; on: vw.factsOn; onClicked: vw.toggleInfo() }
        }
    }
    // the mock's actions at the foot of the leaf: a glyph and plain words, nothing boxed
    component Actions: Column {
        spacing: 6
        Repeater {
            model: (vw.kind === "image" ? [["restart", "Turn the picture"]] : []).concat([["open_in_new", "Open with…"], ["folder_open", "Show in Pinax"], ["content_copy", "Copy"]])
            Item {
                id: act
                required property var modelData
                required property int index
                width: actRow.width
                height: 28
                Row {
                    id: actRow
                    spacing: 12
                    anchors.verticalCenter: parent.verticalCenter
                    VGlyph { text: act.modelData[0]; iconSize: 18; ink: actHov.hovered ? 1 : 2; anchors.verticalCenter: parent.verticalCenter }
                    VT { text: act.modelData[1]; ink: actHov.hovered ? 0 : 1; anchors.verticalCenter: parent.verticalCenter }
                }
                HoverHandler { id: actHov; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        const g = act.modelData[0];
                        if (g === "open_in_new") { const p = act.mapToItem(vw, 0, act.height + 6); vw.openWith(p.x + act.width, p.y); }
                        else if (g === "folder_open") vw.showInPinax();
                        else if (g === "restart") vw.turn();
                        else vw.copyFile();
                    }
                }
            }
        }
    }
    // a PDF's pages down the left edge, when there is more than one
    Item {
        id: strip
        x: 0
        y: 0
        width: vw.stripW
        height: vw.height
        z: 10
        opacity: vw.settle * vw.settle * vw.settle * (vw.kind === "pdf" && vw.landed === vw.cur && vw.pdfPages > 1 && vw.reader !== null ? 1 : 0)
        visible: opacity > 0.01
        ListView {
            id: thumbs
            anchors.fill: parent
            anchors.topMargin: vw.pdfHead - 8
            anchors.leftMargin: 16
            clip: true
            model: vw.pdfPages
            spacing: 10
            boundsBehavior: Flickable.StopAtBounds
            bottomMargin: 16
            Connections { target: vw; function onPdfPageChanged() { if (!thumbs.dragging) thumbs.positionViewAtIndex(vw.pdfPage, ListView.Contain); } }
            delegate: Item {
                id: th
                required property int index
                readonly property bool cur: index === vw.pdfPage
                readonly property real ratio: vw.reader ? (vw.reader.searchable ? vw.reader.sizeOf(index).height / vw.reader.sizeOf(index).width : vw.reader.firstRatio) : 1.414
                width: 64
                height: 58 * ratio + 24
                Item {
                    width: 58
                    height: 58 * th.ratio
                    opacity: 1
                    Behavior on opacity { enabled: vw.animate; Anim { type: Anim.FastEffects } }
                    Rectangle { anchors.fill: parent; color: "#fbfaf8"; radius: 2 }
                    Loader {
                        anchors.fill: parent
                        sourceComponent: vw.reader && vw.reader.images.length > 0 ? thImg : thPdf
                    }
                    Component { id: thPdf; PdfPageImage { document: vw.reader ? vw.reader.doc : null; currentFrame: th.index; asynchronous: true; fillMode: Image.PreserveAspectFit; sourceSize.width: 128; sourceSize.height: 0 } }
                    Component { id: thImg; Image { source: vw.reader ? (vw.reader.images[th.index] ?? "") : ""; asynchronous: true; fillMode: Image.PreserveAspectFit; smooth: true; sourceSize.width: 128 } }
                    Rectangle { anchors.fill: parent; radius: 2; color: "transparent"; border.width: th.cur ? 2 : 0; border.color: vw.main }
                }
                VT { y: 58 * th.ratio + 4; width: 58; horizontalAlignment: Text.AlignHCenter; text: th.index + 1; font.pixelSize: 12; ink: th.cur ? 0 : 1 }
                Rectangle { visible: (vw.pdfCounts[th.index] ?? 0) > 0; x: 58 + 3; y: 4; width: 6; height: 6; radius: 3; color: vw.hit }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: vw.pdfGoTo(th.index) }
            }
        }
    }
    // the document down the right edge
    PdfRuler {
        v: vw
        x: vw.width - 34 - vw.leafW * vw.leafK
        y: vw.height * 0.12
        height: vw.height * 0.76
        opacity: vw.chrome * (vw.kind === "pdf" && vw.pdfMarks.length > 0 ? 1 : 0)
        visible: opacity > 0.01
        z: 20
    }
    // the facts leaf, as in the mock: plain type on the window's ground at 0.96, one hairline, lying
    // over the picture's right edge
    Item {
        id: leaf
        width: vw.leafW
        height: vw.height
        x: vw.width - width * vw.leafK
        visible: x < vw.width
        z: 30
        Rectangle { anchors.fill: parent; color: Qt.rgba(vw.ground.r, vw.ground.g, vw.ground.b, 0.96) }
        Rectangle { width: 1; height: parent.height; color: vw.hair; opacity: 0.6 }
        Facts {
            x: 32; y: 92
            colWidth: 388 - 64
            info: vw.info
            moreOn: vw.moreOn
            onMoreToggled: vw.moreOn = !vw.moreOn
            onCopyPath: vw.copyPath()
        }
        Actions { x: 32; y: parent.height - 150 - (vw.kind === "image" ? 34 : 0) }
    }
    // audio, bare: the track beside its cover
    Item {
        x: vw.width * 0.447
        y: vw.height * 0.227
        width: vw.width * 0.447 - 60
        opacity: vw.kind === "audio" ? vw.settle * vw.still * (vw.landed === vw.cur ? 1 : 0) : 0
        visible: opacity > 0.01
        VT { width: parent.width; elide: Text.ElideRight; text: vw.tags.title || vw.titleText; font.pixelSize: 44; font.weight: Font.DemiBold }
        VT { y: 62; width: parent.width; elide: Text.ElideRight; ink: 1; font.pixelSize: 22; text: vw.tags.artist ?? "" }
        VT { y: 98; width: parent.width; elide: Text.ElideRight; ink: 2; font.pixelSize: 16; text: Info.join([vw.tags.album, vw.tags.date]) }
        Facts {
            id: songFacts
            y: 150
            colWidth: 360
            opacity: vw.facts
            visible: opacity > 0.01
            info: vw.info
            moreOn: vw.moreOn
            onMoreToggled: vw.moreOn = !vw.moreOn
            onCopyPath: vw.copyPath()
        }
        Actions { y: 150 + songFacts.height + 28; opacity: vw.facts; visible: opacity > 0.01 }
    }

    // ================================================================ the folder, pulled back
    Item {
        opacity: vw.fold
        visible: opacity > 0.01
        VT { x: 52; y: 52; text: vw.folderTitle; font.pixelSize: 20; font.weight: Font.DemiBold }
        VT { x: 52; y: 82; ink: 2; text: vw.entries.length + (vw.entries.length === 1 ? " file" : " files") }
    }

    // ================================================================ small things
    VT {
        visible: vw.note.length > 0
        x: (vw.width - width) / 2
        y: vw.height - 150
        z: 40
        font.pixelSize: 16
        text: vw.note
    }
    // Open with: the applications that take this file, the system's default first
    Item {
        id: openMenu
        property var apps: []
        property string path: ""
        property bool shown: false
        property real menuX: 0
        property real menuY: 0
        function open() { shown = true; }
        function close() { shown = false; }
        anchors.fill: parent
        z: 60
        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { enabled: vw.animate; Anim { type: Anim.FastEffects } }
        MouseArea { anchors.fill: parent; enabled: openMenu.shown; onPressed: openMenu.close() }
        Rectangle {
            x: openMenu.menuX
            y: openMenu.menuY
            width: 236 + 12
            height: appList.implicitHeight + 12
            radius: Appearance.rounding.card
            color: Appearance.m3colors.m3surfaceContainerHigh
            border.width: 1
            border.color: Appearance.colors.colLayer0Border
            Column {
                id: appList
                x: 6; y: 6
                spacing: 1
                Repeater {
                    model: openMenu.apps
                    delegate: Item {
                        required property var modelData
                        width: 236
                        height: 34
                        Rectangle {
                            anchors.fill: parent
                            radius: Appearance.rounding.verysmall
                            color: pick.pressed ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.78)
                                 : pick.containsMouse && modelData.file.length ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.90) : "transparent"
                        }
                        readonly property string iconFile: modelData.icon.length > 0 ? Quickshell.iconPath(modelData.icon, true) : ""
                        IconImage {
                            anchors.left: parent.left
                            anchors.leftMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            visible: parent.iconFile.length > 0
                            implicitSize: 20
                            source: parent.iconFile
                        }
                        // an app with no icon in the theme gets a Tacit symbol, never a placeholder dot
                        VGlyph { anchors.left: parent.left; anchors.leftMargin: 9; anchors.verticalCenter: parent.verticalCenter; visible: modelData.file.length > 0 && parent.iconFile.length === 0; text: "apps"; iconSize: 20; ink: 1 }
                        VT {
                            anchors.left: parent.left
                            anchors.leftMargin: modelData.file.length > 0 ? 38 : 12
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: modelData.label
                            elide: Text.ElideRight
                            ink: modelData.file.length ? 0 : 2
                            font.pixelSize: 15
                        }
                        MouseArea {
                            id: pick
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: modelData.file.length > 0
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { openMenu.close(); Quickshell.execDetached(["gio", "launch", modelData.file, openMenu.path]); }
                        }
                    }
                }
            }
        }
    }
    // a locked PDF
    property var lockedDoc: null
    Item {
        id: lock
        readonly property bool shown: vw.kind === "pdf" && vw.lockedDoc !== null
        visible: shown
        anchors.centerIn: parent
        width: 360
        height: 80
        z: 50
        VT { text: "This file is locked"; font.pixelSize: 16; font.weight: Font.DemiBold }
        TextInput {
            id: pass
            y: 36
            width: parent.width
            color: vw.main
            echoMode: TextInput.Password
            font.family: Appearance.font.family.main
            font.pixelSize: 18
            cursorDelegate: Rectangle { width: 1.5; color: vw.main }
            onAccepted: { if (vw.lockedDoc) vw.lockedDoc.password = text; text = ""; }
            Keys.onEscapePressed: vw.forceActiveFocus()
        }
        Rectangle { y: 66; width: parent.width; height: 1; color: vw.hair }
        onShownChanged: if (shown) pass.forceActiveFocus()
    }
    VT {
        visible: vw.entries.length === 0
        anchors.centerIn: parent
        ink: 2
        text: "Nothing to show"
    }

    function state() {
        return JSON.stringify({ path: entry?.path ?? "", kind: kind, index: cur, count: entries.length, mode: folded ? "fold" : bare ? "bare" : "roll",
            settle: settle, page: pdfPage, pages: pdfPages, query: query, matches: reader?.search.count ?? 0,
            position: player.position, duration: player.duration, playing: playing });
    }
}
