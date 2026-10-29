import QtQuick
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets

/**
 * Renaming many at once: replace a piece of text in every name, or number them ("Holiday 01.jpg", "Holiday
 * 02.jpg" ... in the folder's order, each keeping its own extension). The first names show what they become; a
 * name that would clash (with another file here, or with another new name) is said in the risk colour, and
 * Rename waits until none does. Enter renames, Esc leaves. Nothing moves until the job has checked every name.
 */
Rectangle {
    id: sheet

    property var paths: []                // in the folder's order
    property var takenNames: ({})         // every name in the folder now
    signal apply(var pairs)               // [[path, newName], ...]
    signal cancelled()

    property string mode: "replace"       // "replace" | "number"
    width: Math.min(560, (parent ? parent.width : 560) - 32)
    height: body.implicitHeight + 36
    radius: Tacit.radius.panel
    color: Appearance.m3colors.m3surfaceContainerHigh
    border.width: 1
    border.color: Tacit.hairline

    function open(list) {
        sheet.paths = list;
        sheet.mode = "replace";
        find.text = "";
        replaceWith.text = "";
        base.text = list.length ? list[0].split("/").pop().replace(/\.[A-Za-z0-9]{1,5}$/, "").replace(/[\s_-]*\d+$/, "") : "";
        sheet.visible = true;
        appear.restart();
        (sheet.mode === "replace" ? find : base).focusIn();
    }
    function close() { sheet.visible = false; sheet.cancelled(); }
    function preset(m, a, b) {                     // for scripted checks: what the fields would hold
        sheet.mode = m;
        if (m === "replace") { find.text = a; replaceWith.text = b; } else base.text = a;
    }

    readonly property var plan: {
        const out = [];
        const digits = String(sheet.paths.length).length;
        const fresh = {};
        for (let i = 0; i < sheet.paths.length; i++) {
            const p = sheet.paths[i];
            const old = p.split("/").pop();
            let name = old;
            if (sheet.mode === "replace") {
                if (find.text.length > 0) name = old.split(find.text).join(replaceWith.text);
            } else {
                const m = /^(.+?)(\.[A-Za-z0-9]{1,5})?$/.exec(old);
                const ext = m && m[2] ? m[2] : "";
                name = `${base.text.trim()} ${String(i + 1).padStart(Math.max(2, digits), "0")}${ext}`;
            }
            name = name.trim();
            let bad = "";
            if (!name.length) bad = "no name";
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
        sheet.visible = false;
        sheet.apply(sheet.plan.filter(r => r.name !== r.old).map(r => [r.path, r.name]));
    }

    ParallelAnimation {
        id: appear
        Anim { target: sheet; property: "opacity"; from: 0; to: 1; type: Anim.FastEffects }
        Anim { target: sheet; property: "scale"; from: 0.97; to: 1; type: Anim.FastSpatial }
    }
    Keys.onEscapePressed: sheet.close()

    component Field: Rectangle {
        id: fld
        property alias text: input.text
        property alias input: input
        property string hint: ""
        width: parent.width
        height: 38
        radius: 10
        color: ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.95)
        border.width: 1
        border.color: input.activeFocus ? ColorUtils.transparentize(Tacit.accent, 0.15) : ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.93)
        Behavior on border.color { ColorAnimation { duration: 120 } }
        function focusIn() { input.forceActiveFocus(); input.selectAll(); }
        TextInput {
            id: input
            anchors { left: parent.left; right: parent.right; leftMargin: 12; rightMargin: 12; verticalCenter: parent.verticalCenter }
            font.pixelSize: 15
            font.family: Appearance.font.family.main
            color: Tacit.inkMain
            selectionColor: ColorUtils.transparentize(Tacit.accent, 0.6)
            clip: true
            Keys.onReturnPressed: sheet.go()
            Keys.onEnterPressed: sheet.go()
            Keys.onEscapePressed: sheet.close()
            Keys.onTabPressed: event => { event.accepted = false; }
        }
        StyledText {
            anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
            visible: input.text.length === 0
            text: fld.hint
            font.pixelSize: 15
            color: Tacit.inkFaint
        }
    }
    component ModeWord: StyledText {
        id: mw
        property string value: ""
        text: ""
        font.pixelSize: 15
        font.weight: sheet.mode === mw.value ? Font.Medium : Font.Normal
        color: sheet.mode === mw.value || mwArea.containsMouse ? Tacit.inkMain : Tacit.inkSec
        Rectangle {
            visible: sheet.mode === mw.value
            anchors { left: parent.left; right: parent.right; top: parent.bottom; topMargin: 4 }
            height: 2
            radius: 1
            color: Tacit.accent
        }
        MouseArea {
            id: mwArea
            anchors { fill: parent; margins: -6 }
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { sheet.mode = mw.value; (mw.value === "replace" ? find : base).focusIn(); }
        }
    }

    Column {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
        spacing: 14

        StyledText {
            text: `Rename ${Voice.count(sheet.paths.length, "item")}`
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: Tacit.inkMain
        }
        Row {
            spacing: 22
            ModeWord { value: "replace"; text: "Replace text" }
            ModeWord { value: "number"; text: "Number them" }
        }
        Column {
            width: parent.width
            spacing: 8
            visible: sheet.mode === "replace"
            Field { id: find; hint: "Find" }
            Field { id: replaceWith; hint: "Replace with" }
        }
        Column {
            width: parent.width
            spacing: 8
            visible: sheet.mode === "number"
            Field { id: base; hint: "Name, then a number" }
        }
        // what the first ones become
        Column {
            width: parent.width
            spacing: 4
            Repeater {
                model: sheet.plan.slice(0, 5)
                delegate: Row {
                    required property var modelData
                    width: parent.width
                    spacing: 8
                    StyledText {
                        width: (parent.width - 30) / 2
                        text: modelData.old
                        elide: Text.ElideMiddle
                        font.pixelSize: 13
                        color: Tacit.inkMeta
                    }
                    StyledText { text: "→"; font.pixelSize: 13; color: Tacit.inkFaint }
                    StyledText {
                        width: (parent.width - 30) / 2
                        text: modelData.bad ? `${modelData.name || "…"} · ${modelData.bad}` : modelData.name
                        elide: Text.ElideMiddle
                        font.pixelSize: 13
                        font.weight: modelData.name !== modelData.old ? Font.Medium : Font.Normal
                        color: modelData.bad ? Tacit.risk : modelData.name !== modelData.old ? Tacit.inkMain : Tacit.inkMeta
                    }
                }
            }
            StyledText {
                visible: sheet.plan.length > 5
                text: `and ${sheet.plan.length - 5} more`
                font.pixelSize: 13
                color: Tacit.inkMeta
            }
        }
        Item {
            width: parent.width
            height: 40
            Row {
                anchors.right: parent.right
                spacing: 10
                Slab { text: "Cancel"; onPicked: sheet.close() }
                Slab {
                    text: sheet.changes > 0 ? `Rename ${sheet.changes}` : "Rename"
                    tone: "default"
                    opacity: sheet.clean ? 1 : 0.45
                    enabled: sheet.clean
                    onPicked: sheet.go()
                }
            }
        }
    }
}
