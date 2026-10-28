import QtQuick
import qs.services
import Tacit.Kit as K

/**
 * Renaming many at once, as the docked panel's face (kit v0, "A task on the selection"): replace a piece of text in
 * every name, or number them ("Holiday 01.jpg", "Holiday 02.jpg" ... in the folder's order from the number asked, each
 * keeping its own extension). The first names show what they become; a name that would clash (with another file
 * here, or with another new name) is said in the risk ink, and Rename waits until none does. Enter renames, Esc
 * leaves. Nothing moves until the job has checked every name.
 */
Item {
    id: sheet

    property var paths: []                // in the folder's order
    property var takenNames: ({})         // every name in the folder now
    property var dirs: ({})               // the folder's folders, for the sentence's noun
    property bool active: false
    signal apply(var pairs)               // [[path, newName], ...]
    signal cancelled()

    property string mode: "replace"       // "replace" | "number"
    visible: active

    function open(list) {
        sheet.paths = list;
        sheet.mode = "replace";
        find.text = "";
        replaceWith.text = "";
        base.text = list.length ? list[0].split("/").pop().replace(/\.[A-Za-z0-9]{1,5}$/, "").replace(/[\s_-]*\d+$/, "") : "";
        start.text = "";
        sheet.active = true;
        if (sheet.visible)
            sheet.focusFirst();
    }
    function focusFirst() { (sheet.mode === "replace" ? find : base).focusIn(); }
    onVisibleChanged: if (visible) focusFirst()
    function close() { sheet.active = false; sheet.cancelled(); }
    function preset(m, a, b) {                     // for scripted checks: what the fields would hold
        sheet.mode = m;
        if (m === "replace") { find.text = a; replaceWith.text = b; } else { base.text = a; start.text = b ?? ""; }
    }

    readonly property var plan: {
        const out = [];
        const from = start.text.trim();
        const first = from === "" ? 1 : /^\d+$/.test(from) ? parseInt(from, 10) : -1;
        // as wide as the last number, at least two digits, or as many as were typed ("001")
        const digits = Math.max(2, from.length, String(Math.max(first, 0) + sheet.paths.length - 1).length);
        const fresh = {};
        for (let i = 0; i < sheet.paths.length; i++) {
            const p = sheet.paths[i];
            const old = p.split("/").pop();
            let name = old;
            if (sheet.mode === "replace") {
                if (find.text.length > 0) name = old.split(find.text).join(replaceWith.text);
            } else if (first >= 0) {
                const m = /^(.+?)(\.[A-Za-z0-9]{1,5})?$/.exec(old);
                const ext = m && m[2] ? m[2] : "";
                name = `${base.text.trim()} ${String(first + i).padStart(digits, "0")}${ext}`;
            }
            name = name.trim();
            let bad = "";
            if (sheet.mode === "number" && first < 0) bad = "start at a number";
            else if (!name.length) bad = "no name";
            else if (name.includes("/")) bad = "a name can't hold /";
            else if (fresh[name]) bad = "twice";
            else if (name !== old && sheet.takenNames[name] && !sheet.paths.some(q => q.split("/").pop() === name)) bad = "already here";
            fresh[name] = true;
            out.push({ path: p, old: old, name: name, bad: bad });
        }
        return out;
    }
    readonly property int changes: sheet.plan.filter(r => r.name !== r.old).length
    readonly property bool clean: sheet.plan.every(r => !r.bad) && sheet.changes > 0
    function go() {
        if (!sheet.clean) return;
        sheet.active = false;
        sheet.apply(sheet.plan.filter(r => r.name !== r.old).map(r => [r.path, r.name]));
    }
    // "Rename 3 pictures", "Rename 4 files", "Rename 2 folders"
    readonly property string noun: {
        const folders = sheet.paths.filter(p => sheet.dirs[p] === true).length;
        if (folders === sheet.paths.length) return "folder";
        if (folders > 0) return "item";
        return sheet.paths.every(p => Things.kindOf(p) === "image") ? "picture" : "file";
    }

    Keys.onEscapePressed: sheet.close()
    Keys.onReturnPressed: sheet.go()
    Keys.onEnterPressed: sheet.go()

    Column {
        x: K.Kit.tokens.space.xl
        y: K.Kit.tokens.space.xl
        width: parent.width - 2 * K.Kit.tokens.space.xl

        K.TacitText { text: `Rename ${Voice.count(sheet.paths.length, sheet.noun)}`; size: "body"; weight: "medium" }
        Item { width: 1; height: 14 }
        K.Tabs {
            x: -K.Kit.tokens.space.m
            labels: ["Replace text", "Number them"]
            current: sheet.mode === "replace" ? 0 : 1
            onPicked: i => { sheet.mode = i === 0 ? "replace" : "number"; sheet.focusFirst(); }
        }
        Item { width: 1; height: 16 }
        Column {
            width: parent.width
            spacing: 10
            visible: sheet.mode === "replace"
            K.Field { id: find; width: parent.width; hint: "Find"; label: "Find"; onAccepted: sheet.go() }
            K.Field { id: replaceWith; width: parent.width; hint: "Replace with"; label: "Replace with"; onAccepted: sheet.go() }
        }
        Column {
            width: parent.width
            spacing: 10
            visible: sheet.mode === "number"
            K.Field { id: base; width: parent.width; hint: "Name"; label: "Name"; onAccepted: sheet.go() }
            K.Field { id: start; width: parent.width; hint: "Start at 1"; label: "Start at"; onAccepted: sheet.go() }
        }
        Item { width: 1; height: 22 }
        // what the first ones become
        Repeater {
            model: sheet.plan.slice(0, 5)
            Row {
                id: change
                required property var modelData
                readonly property real half: (parent.width - arrow.implicitWidth - 2 * spacing) / 2
                height: 30
                spacing: 10
                K.TacitText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: change.half
                    text: change.modelData.old
                    ink: "sec"
                    elide: Text.ElideMiddle
                }
                K.TacitText { id: arrow; anchors.verticalCenter: parent.verticalCenter; text: "→"; ink: "meta" }
                K.TacitText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: change.half
                    text: change.modelData.bad ? `${change.modelData.name || "…"} · ${change.modelData.bad}` : change.modelData.name
                    ink: change.modelData.bad ? "risk" : change.modelData.name !== change.modelData.old ? "main" : "sec"
                    elide: Text.ElideMiddle
                }
            }
        }
        K.TacitText {
            visible: sheet.plan.length > 5
            height: 30
            verticalAlignment: Text.AlignVCenter
            text: `and ${sheet.plan.length - 5} more`
            ink: "meta"
        }
        Item { width: 1; height: 24 }
        Row {
            spacing: 20
            // Rename waits while a name clashes or nothing changes (the kit's Slab has no unavailable look)
            K.Slab { text: "Rename"; tone: "default"; enabled: sheet.clean; onPicked: sheet.go() }
            K.WordAction {
                anchors.verticalCenter: parent.verticalCenter
                width: cancelWord.implicitWidth
                text: "Cancel"
                onPicked: sheet.close()
                K.TacitText { id: cancelWord; visible: false; text: "Cancel" }
            }
        }
    }
}
