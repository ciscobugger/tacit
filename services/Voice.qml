pragma Singleton
import QtQuick
import Quickshell

/**
 * One voice for every surface: the notch's peeks, the notification rows, Files' status
 * line and the palette all phrase ages, sizes, counts, reasons and refusals through here,
 * so the desktop sounds like one thing. Short, dry, warm. Facts are joined with " · ";
 * a reason starts with "because"; a refusal starts with "Can't:".
 */
Singleton {
    id: root

    // "now", "2m", "3h", "yesterday", "4d", "Sep 2"
    function age(at, now) {
        const t = now ?? Date.now();
        const s = Math.max(0, t - at) / 1000;
        if (s < 50)
            return "now";
        const m = Math.round(s / 60);
        if (m < 60)
            return `${m}m`;
        const h = Math.round(m / 60);
        if (h < 24 && new Date(at).getDate() === new Date(t).getDate())
            return `${h}h`;
        const d = Math.round(s / 86400);
        if (d <= 1)
            return "yesterday";
        if (d < 7)
            return `${d}d`;
        const dt = new Date(at);
        const month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][dt.getMonth()];
        return dt.getFullYear() === new Date(t).getFullYear() ? `${month} ${dt.getDate()}` : `${month} ${dt.getFullYear()}`;
    }

    // "188 kB", "2.1 MB", "1.2 GB"
    function size(bytes) {
        const b = Number(bytes) || 0;
        if (b < 1000)
            return `${b} B`;
        if (b < 1e6)
            return `${Math.round(b / 1000)} kB`;
        if (b < 1e9)
            return `${(b / 1e6).toFixed(b < 1e7 ? 1 : 0)} MB`;
        return `${(b / 1e9).toFixed(1)} GB`;
    }

    // "3 files", "1 photo", "no items"
    function count(n, noun, plural) {
        if (n === 0)
            return `no ${plural ?? noun + "s"}`;
        return `${n} ${n === 1 ? noun : (plural ?? noun + "s")}`;
    }

    function facts(list) {
        return list.filter(f => (f ?? "").length > 0).join(" · ");
    }

    function because(what, why) {
        return `${what}, because ${why}`;
    }

    function cant(reason) {
        return `Can't: ${reason}`;
    }
}
