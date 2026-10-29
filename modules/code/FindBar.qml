import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

/**
 * Find, replace and go to line in the open file: a strip under the text, drawn like the
 * Finder's field so the two read as the same thing. Enter is the next match, Shift+Enter
 * the one before, Esc closes and hands the keyboard back to the editor. Replace is hidden
 * until asked for, and both Replace buttons refuse while a change is being typed out.
 */
Item {
    id: bar

    property var doc: null
    property string mode: "find"          // "find" | "line"
    property bool replacing: false
    property bool caseSensitive: false
    readonly property int matches: bar.doc && bar.mode === "find" ? bar.doc.matchCount(needle.text, bar.caseSensitive) : 0
    signal closed()

    visible: false
    implicitHeight: 40 + (bar.replacing && bar.mode === "find" ? 40 : 0)

    function open(m, seed) {
        bar.mode = m;
        if (m === "line") bar.replacing = false;
        if (seed && seed.length && !seed.includes("\n")) needle.text = seed;
        bar.visible = true;
        needle.forceActiveFocus();
        needle.selectAll();
    }
    function close() { bar.visible = false; bar.replacing = false; bar.closed(); }
    function step(back) {
        if (!bar.doc) return;
        if (bar.mode === "line") { bar.doc.goToLine(parseInt(needle.text) || 0); bar.close(); return; }
        bar.doc.findNext(needle.text, back, bar.caseSensitive);
    }

    Rectangle {
        id: field
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 4 }
        height: 32
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer2

        MaterialSymbol {
            id: glyph
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            text: bar.mode === "line" ? "tag" : "search"
            iconSize: 18
            color: Tacit.inkMeta
        }
        TextInput {
            // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)
            font.hintingPreference: Font.PreferNoHinting
            id: needle
            anchors { left: glyph.right; leftMargin: 8; right: count.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
            font.family: bar.mode === "line" ? Appearance.font.family.numbers : Appearance.font.family.monospace
            font.pixelSize: 14
            color: Tacit.inkMain
            selectionColor: Appearance.colors.colSecondaryContainer
            clip: true
            onAccepted: bar.step(false)
            Keys.onEscapePressed: bar.close()
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return && (event.modifiers & Qt.ShiftModifier)) { bar.step(true); event.accepted = true; }
                else if (event.key === Qt.Key_Tab && bar.replacing) { replacement.forceActiveFocus(); event.accepted = true; }
            }
        }
        StyledText {
            anchors { left: glyph.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
            visible: needle.text.length === 0
            text: bar.mode === "line" ? "Go to line" : "Find in this file"
            font.pixelSize: 14
            color: Tacit.inkFaint
        }
        StyledText {
            id: count
            anchors { right: sensitive.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
            visible: bar.mode === "find" && needle.text.length > 0
            text: bar.matches === 0 ? "No matches" : bar.matches === 1 ? "1 match" : `${bar.matches} matches`
            font.pixelSize: 13
            font.family: Appearance.font.family.numbers
            color: bar.matches === 0 ? Tacit.risk : Tacit.inkMeta
        }
        BarButton {
            id: sensitive
            anchors { right: prev.left; rightMargin: 2; verticalCenter: parent.verticalCenter }
            visible: bar.mode === "find"
            glyph: "match_case"
            on: bar.caseSensitive
            tip: "Match case"
            onPressed: bar.caseSensitive = !bar.caseSensitive
        }
        BarButton {
            id: prev
            anchors { right: nxt.left; rightMargin: 2; verticalCenter: parent.verticalCenter }
            visible: bar.mode === "find"
            glyph: "keyboard_arrow_up"
            tip: "Previous (Shift+Enter)"
            onPressed: bar.step(true)
        }
        BarButton {
            id: nxt
            anchors { right: swap.left; rightMargin: 2; verticalCenter: parent.verticalCenter }
            visible: bar.mode === "find"
            glyph: "keyboard_arrow_down"
            tip: "Next (Enter)"
            onPressed: bar.step(false)
        }
        BarButton {
            id: swap
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            visible: bar.mode === "find"
            glyph: "find_replace"
            on: bar.replacing
            tip: "Replace"
            onPressed: { bar.replacing = !bar.replacing; if (bar.replacing) replacement.forceActiveFocus(); }
        }
    }

    Rectangle {
        anchors { left: field.left; right: field.right; top: field.bottom; topMargin: 4 }
        height: 32
        visible: bar.replacing && bar.mode === "find"
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer2

        MaterialSymbol {
            id: swapGlyph
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            text: "edit"
            iconSize: 18
            color: Tacit.inkMeta
        }
        TextInput {
            // as StyledText: letters as designed, nothing snapped (fontconfig's full hinting widened Tacit Sans)
            font.hintingPreference: Font.PreferNoHinting
            id: replacement
            anchors { left: swapGlyph.right; leftMargin: 8; right: one.left; rightMargin: 10; verticalCenter: parent.verticalCenter }
            font.family: Appearance.font.family.monospace
            font.pixelSize: 14
            color: Tacit.inkMain
            selectionColor: Appearance.colors.colSecondaryContainer
            clip: true
            onAccepted: if (bar.doc) bar.doc.replaceCurrent(needle.text, replacement.text, bar.caseSensitive)
            Keys.onEscapePressed: bar.close()
        }
        StyledText {
            anchors { left: swapGlyph.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
            visible: replacement.text.length === 0
            text: "Replace with"
            font.pixelSize: 14
            color: Tacit.inkFaint
        }
        // The buttons say what they do: nothing is written while the file is being typed out.
        TextButton {
            id: one
            anchors { right: all.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
            label: "Replace"
            enabled: !!bar.doc && !bar.doc.held && bar.matches > 0
            onPressed: bar.doc.replaceCurrent(needle.text, replacement.text, bar.caseSensitive)
        }
        TextButton {
            id: all
            anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
            label: "All"
            enabled: !!bar.doc && !bar.doc.held && bar.matches > 0
            onPressed: bar.doc.replaceAll(needle.text, replacement.text, bar.caseSensitive)
        }
    }

    component BarButton: Item {
        id: btn
        property string glyph: ""
        property string tip: ""
        property bool on: false
        signal pressed()
        width: 26; height: 26
        Rectangle {
            anchors.fill: parent
            radius: Appearance.rounding.small
            color: btn.on ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.86)
                : (btnArea.containsMouse ? ColorUtils.transparentize(Appearance.m3colors.m3onSurface, 0.94) : "transparent")
            Behavior on color { ColorAnimation { duration: 80 } }
        }
        MaterialSymbol {
            anchors.centerIn: parent
            text: btn.glyph
            iconSize: 17
            color: btn.on ? Tacit.inkMain : Tacit.inkMeta
        }
        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.pressed()
        }
        StyledToolTip { text: btn.tip; extraVisibleCondition: btnArea.containsMouse }
    }

    component TextButton: Rectangle {
        id: tb
        property string label: ""
        signal pressed()
        width: tbText.implicitWidth + 20
        height: 24
        radius: Appearance.rounding.full
        opacity: tb.enabled ? 1 : 0.4
        color: tbArea.containsMouse && tb.enabled ? Appearance.colors.colLayer2Hover : Appearance.colors.colLayer1
        Behavior on color { ColorAnimation { duration: 80 } }
        StyledText {
            id: tbText
            anchors.centerIn: parent
            text: tb.label
            font.pixelSize: 13
            color: Tacit.inkMain
        }
        MouseArea {
            id: tbArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tb.pressed()
        }
    }
}
