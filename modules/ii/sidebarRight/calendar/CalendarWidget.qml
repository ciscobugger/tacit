import qs.services
import qs.modules.common
import qs.modules.common.widgets
import "calendar_layout.js" as CalendarLayout
import QtQuick
import QtQuick.Layouts

Item {
    id: calendar
    // Layout.topMargin: 10
    anchors.topMargin: 10
    property int monthShift: 0
    // The week strip: an optional one-row calendar (the current week alone) with an
    // expand button in the header that unfolds the full month. Off by default, so the
    // users that want the month straight away (Background) see it unchanged.
    property bool expandable: false
    property bool expanded: false
    // A new Date() inside the layout helpers is not a QML dependency, so the grid has to be
    // bound to the clock to survive midnight. Midnight of the clock's day, not the clock
    // itself: the grid depends on the day, not on every tick.
    readonly property date today: {
        const d = DateTime.clock.date;
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }
    property var viewingDate: CalendarLayout.getDateInXMonthsTime(monthShift, today)
    property var calendarLayout: CalendarLayout.getCalendarLayout(viewingDate, monthShift === 0)
    // The row of the grid that carries today: the week strip is that one row.
    readonly property int todayRow: {
        for (let r = 0; r < 6; r++)
            for (let c = 0; c < 7; c++)
                if (calendarLayout[r][c].today === 1)
                    return r;
        return 0;
    }
    width: calendarColumn.width
    implicitHeight: calendarColumn.height + 10 * 2
    // The fold: the week strip unfolds to the month and folds back with the
    // emphasized curve; while it moves the surplus rows are clipped, so the same
    // motion reads as unfolding, not as a jump.
    clip: true
    Behavior on implicitHeight {
        Anim {
            type: Anim.Emphasized
        }
    }

    MouseArea {
        anchors.fill: parent
        onWheel: (event) => {
            if (!expandable || expanded) {
                if (event.angleDelta.y > 0) {
                    monthShift--;
                } else if (event.angleDelta.y < 0) {
                    monthShift++;
                }
            }
        }
    }

    ColumnLayout {
        id: calendarColumn
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 10
        spacing: 5

        // Calendar header
        RowLayout {
            Layout.fillWidth: true
            spacing: 5
            CalendarHeaderButton {
                clip: true
                buttonText: `${monthShift != 0 ? "• " : ""}${viewingDate.toLocaleDateString(Qt.locale(), "MMMM yyyy")}`
                tooltipText: (monthShift === 0) ? "" : Translation.tr("Jump to current month")
                downAction: () => {
                    monthShift = 0;
                }
            }
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: false
            }
            CalendarHeaderButton {
                visible: expanded || !expandable
                forceCircle: true
                downAction: () => {
                    monthShift--;
                }
                contentItem: MaterialSymbol {
                    text: "chevron_left"
                    iconSize: Appearance.font.pixelSize.larger
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.colOnLayer1
                }
            }
            CalendarHeaderButton {
                visible: expanded || !expandable
                forceCircle: true
                downAction: () => {
                    monthShift++;
                }
                contentItem: MaterialSymbol {
                    text: "chevron_right"
                    iconSize: Appearance.font.pixelSize.larger
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.colOnLayer1
                }
            }
            // The week strip's toggle: fold the month out, fold it back in.
            CalendarHeaderButton {
                visible: expandable
                forceCircle: true
                downAction: () => {
                    monthShift = 0;
                    expanded = !expanded;
                }
                contentItem: MaterialSymbol {
                    text: expanded ? "expand_more" : "expand_less"
                    iconSize: Appearance.font.pixelSize.larger
                    horizontalAlignment: Text.AlignHCenter
                    color: Appearance.colors.colOnLayer1
                }
            }
        }

        // Week days row
        RowLayout {
            id: weekDaysRow
            Layout.alignment: Qt.AlignHCenter
            Layout.fillHeight: false
            spacing: 5
            Repeater {
                model: CalendarLayout.weekDays
                delegate: CalendarDayButton {
                    day: Translation.tr(modelData.day)
                    isToday: modelData.today
                    bold: true
                    enabled: false
                }
            }
        }

        // Real week rows: the whole month, or the strip's one row (the week carrying
        // today). In the strip the week is the user's place, so a day that falls in
        // another month keeps the ordinary ink — the week, not the month, is the unit.
        Repeater {
            id: calendarRows
            model: expanded || !expandable ? 6 : 1
            delegate: RowLayout {
                readonly property int row: expanded || !expandable ? modelData : calendar.todayRow
                Layout.alignment: Qt.AlignHCenter
                Layout.fillHeight: false
                spacing: 5
                Repeater {
                    model: Array(7).fill(row)
                    delegate: CalendarDayButton {
                        day: calendarLayout[modelData][index].day
                        isToday: expanded || !expandable ? calendarLayout[modelData][index].today
                            : (calendarLayout[modelData][index].today === 1 ? 1 : 0)
                    }
                }
            }
        }
    }
}