import QtQuick
import QtQuick.Pdf
import QtQuick.Shapes
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.tacit

// The reading view: the pages in one column on the window ground. Search, selection and links are
// QtQuick.Pdf's (PDFium); a file PDFium refused arrives as poppler's page pngs in `images`, readable
// but without search, selection or links.
Item {
    id: rd
    property var doc: null              // a ready PdfDocument, or null with `images`
    property var images: []             // poppler fallback: page png urls
    property string query: ""
    property real pw: 600               // page width at zoom 1
    property real zoom: 1
    property real topInset: 0           // the title row above the pages
    property real leftInset: 0          // the page strip
    property real rightInset: 0         // the info leaf
    readonly property real pageW: Math.min(width - leftInset - rightInset - 24, pw * zoom)
    readonly property int count: images.length > 0 ? images.length : (doc?.pageCount ?? 0)
    readonly property bool searchable: doc !== null && images.length === 0
    readonly property alias list: lv
    readonly property alias search: sm
    readonly property real gap: 16
    readonly property real head: 104 - topInset    // the first page starts 104 px down the window, whatever the inset
    property int page: 0
    property var hs: []                 // page heights in px
    property var tops: []               // page tops in content coordinates
    property real total: 0
    property var counts: []             // matches on each page
    property var marks: []              // each match's place in the document, 0..1
    property int seen: -1               // matches counted so far
    property int stamp: 0               // counts up whenever the matches changed, for the page overlays
    readonly property real fracTop: total > 0 ? Math.max(0, (lv.contentY + rd.head) / total) : 0
    readonly property real fracSpan: total > 0 ? Math.min(1, lv.height / total) : 1
    property var activeSel: null
    readonly property real firstRatio: first.status === Image.Ready && first.implicitWidth > 0 ? first.implicitHeight / first.implicitWidth : 1.414

    Image { id: first; visible: false; source: rd.images[0] ?? ""; asynchronous: true }

    // Page sizes in points, read from PDFium once per document and in chunks (a native call per page
    // on the UI thread stalls a long file); a page not read yet is taken to be as big as page 0.
    // `measured` counts what is read, for bindings that follow the sizes.
    property var sizes: []
    property int measured: 0
    function sizeOf(p) { measured; return sizes[p] ?? sizes[0] ?? Qt.size(612, 792); }
    function measure(n) {
        if (!rd.searchable) return;
        const end = Math.min(rd.count, rd.measured + n);
        for (let p = rd.measured; p < end; p++) rd.sizes[p] = rd.doc.pagePointSize(p);
        rd.measured = end;
        rd.relayout();
        if (end < rd.count) measureMore.restart();
    }
    function resetSizes() { measureMore.stop(); rd.sizes = []; rd.measured = 0; rd.measure(40); }
    Timer { id: measureMore; interval: 16; onTriggered: rd.measure(200) }
    onDocChanged: resetSizes()

    function relayout() {
        const h = [], t = [];
        let y = 0;
        for (let p = 0; p < rd.count; p++) {
            const s = rd.searchable ? rd.sizeOf(p) : null;
            const ph = rd.pageW * (s ? s.height / s.width : rd.firstRatio);
            h.push(ph); t.push(y); y += ph + rd.gap;
        }
        rd.hs = h; rd.tops = t; rd.total = y;
    }
    onPageWChanged: relayout()
    onCountChanged: { if (rd.searchable && rd.measured === 0) rd.measure(40); else relayout(); }
    onFirstRatioChanged: if (images.length) relayout()
    Component.onCompleted: { if (rd.searchable) resetSizes(); else relayout(); goTo(0, false); }

    function pageAt(y) {
        let lo = 0, hi = rd.tops.length - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (rd.tops[mid] <= y) lo = mid; else hi = mid - 1;
        }
        return Math.max(0, lo);
    }
    Connections { target: lv; function onContentYChanged() { rd.page = rd.pageAt(lv.contentY + lv.height * 0.4); } }

    function goTo(p, animate) {
        p = Math.max(0, Math.min(rd.count - 1, p));
        rd.scrollTo((rd.tops[p] ?? 0) - rd.head + 8, animate);
    }
    function scrollTo(y, animate) {
        const max = Math.max(-lv.topMargin, rd.total - lv.height + lv.bottomMargin - rd.head);
        jump.stop();
        y = Math.max(-lv.topMargin, Math.min(max, y));
        if (animate) { jump.to = y; jump.start(); } else lv.contentY = y;
    }
    function scrollBy(dy) { jump.stop(); rd.scrollTo(lv.contentY + dy, false); }

    // match counts per page and the places for the ruler; the model fills in over a second or two
    // Each pass reads only the matches that arrived since the last one, at most 400, and asks for another.
    property var tally: []
    property var spots: []
    property int scanned: 0
    Timer { id: scan; interval: 120; onTriggered: rd.rescan() }
    Timer { interval: 200; repeat: true; running: rd.searchable && rd.query.length > 0; onTriggered: if (sm.count !== rd.seen) { rd.seen = sm.count; scan.restart(); } }
    onQueryChanged: { seen = -1; scanned = 0; tally = []; spots = []; scan.restart(); if (query.length === 0) { counts = []; marks = []; } }
    function rescan() {
        rd.stamp++;
        if (!rd.searchable || rd.query.length === 0 || sm.count === 0) { rd.scanned = 0; rd.counts = []; rd.marks = []; return; }
        if (sm.count < rd.scanned) { rd.scanned = 0; rd.tally = []; rd.spots = []; }
        if (rd.tally.length !== rd.count) { rd.tally = new Array(rd.count).fill(0); rd.scanned = 0; rd.spots = []; }
        const c = rd.tally, m = rd.spots, end = Math.min(sm.count, 3000, rd.scanned + 400);
        for (let i = rd.scanned; i < end; i++) {
            const row = sm.index(i, 0), p = sm.data(row, 256), at = sm.data(row, 258);   // Role.Page, Role.Location
            c[p]++;
            m.push((p + at.y / rd.sizeOf(p).height) / rd.count);
        }
        rd.scanned = end;
        rd.counts = c.slice(); rd.marks = m.slice();
        if (sm.currentResult < 0) sm.currentResult = 0;
        if (end < Math.min(sm.count, 3000)) scan.restart();
    }
    function next(dir) {
        if (sm.count > 0) sm.currentResult = (Math.max(0, sm.currentResult) + dir + sm.count) % sm.count;
    }
    Connections {
        target: sm
        function onCurrentResultChanged() {
            if (sm.currentResult < 0) return;
            const s = rd.sizeOf(sm.currentPage), r = sm.currentResultBoundingRect;
            rd.scrollTo((rd.tops[sm.currentPage] ?? 0) + r.y * rd.pageW / s.width - lv.height * 0.3, true);
        }
    }
    PdfSearchModel { id: sm; document: rd.searchable ? rd.doc : null; searchString: rd.query }

    // the polygons of the matches on a page; the model fills in over a second or two, so it reads `count`
    function polysOn(p) { return rd.searchable && rd.query.length > 0 ? sm.boundingPolygonsOnPage(p) : []; }
    function copy() { if (rd.activeSel) rd.activeSel.copyToClipboard(); }
    // a link in a file we do not trust opens only as a web or mail address
    function open(u) { const s = u.toString(); if (/^(https?|mailto):/i.test(s)) Qt.openUrlExternally(s); }

    Anim { id: jump; target: lv; property: "contentY"; type: Anim.DefaultEffects }

    ListView {
        id: lv
        anchors.fill: parent
        anchors.topMargin: rd.topInset
        anchors.leftMargin: rd.leftInset
        anchors.rightMargin: rd.rightInset
        clip: true
        topMargin: rd.head
        bottomMargin: 60
        model: rd.count
        boundsBehavior: Flickable.StopAtBounds
        cacheBuffer: 1600
        interactive: false
        delegate: Item {
            id: pg
            required property int index
            width: lv.width
            height: (rd.hs[index] ?? 0) + rd.gap
            readonly property size pts: rd.searchable ? rd.sizeOf(index) : Qt.size(1, 1)
            readonly property real k: rd.searchable ? rd.pageW / pts.width : 1
            Item {
                id: paper
                x: (parent.width - rd.pageW) / 2
                width: rd.pageW
                height: rd.hs[pg.index] ?? 0
                Rectangle { anchors.fill: parent; color: "#fbfaf8"; radius: 2 }
                Loader {
                    anchors.fill: parent
                    sourceComponent: rd.images.length > 0 ? imgC : pdfC
                }
                Component {
                    id: pdfC
                    PdfPageImage {
                        document: rd.doc
                        currentFrame: pg.index
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: rd.pageW * Screen.devicePixelRatio
                        sourceSize.height: 0
                    }
                }
                Component {
                    id: imgC
                    Image {
                        source: rd.images[pg.index] ?? ""
                        asynchronous: true
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        mipmap: true
                    }
                }
                // matches: soft amber, the current one stronger and outlined
                Shape {
                    anchors.fill: parent
                    ShapePath {
                        strokeWidth: -1
                        fillColor: Qt.rgba(Appearance.m3colors.m3primary.r, Appearance.m3colors.m3primary.g, Appearance.m3colors.m3primary.b, 0.55)
                        scale: Qt.size(pg.k, pg.k)
                        PathMultiline {
                            id: hl
                            function refresh() { paths = rd.polysOn(pg.index); }
                            Component.onCompleted: refresh()
                            property var follow: Connections { target: rd; function onStampChanged() { hl.refresh(); } }
                        }
                    }
                    ShapePath {
                        strokeWidth: sm.currentPage === pg.index ? 1.5 : -1
                        strokeColor: Appearance.m3colors.m3primaryContainer
                        fillColor: sm.currentPage === pg.index ? Qt.rgba(Appearance.m3colors.m3primary.r, Appearance.m3colors.m3primary.g, Appearance.m3colors.m3primary.b, 0.9) : "transparent"
                        scale: Qt.size(pg.k, pg.k)
                        PathMultiline { paths: rd.searchable && sm.currentResult >= 0 && sm.currentPage === pg.index ? sm.currentResultBoundingPolygons : [] }
                    }
                }
                // links, selection: PDFium's, so only for a file PDFium opened
                Loader {
                    anchors.fill: parent
                    active: rd.searchable
                    sourceComponent: Item {
                        Repeater {
                            model: linkModel
                            PdfLinkDelegate {
                                x: rectangle.x * pg.k
                                y: rectangle.y * pg.k
                                width: rectangle.width * pg.k
                                height: rectangle.height * pg.k
                                onTapped: link => { if (link.page >= 0) rd.goTo(link.page, true); else rd.open(link.url); }
                            }
                        }
                        PdfLinkModel { id: linkModel; document: rd.doc; page: pg.index }
                        PdfSelection {
                            id: sel
                            anchors.fill: parent
                            document: rd.doc
                            page: pg.index
                            renderScale: pg.k
                            from: drag.centroid.pressPosition
                            to: drag.centroid.position
                            hold: !drag.active && !tap.pressed
                        }
                        DragHandler {
                            id: drag
                            target: null
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.Stylus
                            onActiveChanged: if (active) { if (rd.activeSel && rd.activeSel !== sel) rd.activeSel.clear(); rd.activeSel = sel; }
                        }
                        TapHandler { id: tap; acceptedDevices: PointerDevice.Mouse | PointerDevice.Stylus }
                    }
                }
            }
        }
    }
    // a touchpad scrolls the page column as the browser does; mostly sideways it is left to the roll
    GlideWheel { view: lv }
}
