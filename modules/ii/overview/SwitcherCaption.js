.pragma library

// The line under the Alt+Tab cards: the app's name once. Tacit's own apps are named as the dock names them
// (PaletteDock.known); a window title that is only the app's generic one ("Files", "Browser") gives way to
// that name, and a title that already says the name is not followed by it again.
const tacitNames = {
    "org.quickshell": "Pinax",
    "praxis": "Praxis",
    "browser": "Thyris",
    "browser-cef": "Thyris",
    "thyris": "Thyris",
    "viewer": "Viewer",
    "graphis": "Graphis",
    "settings": "Settings",
    "foot": "Terminal"
};
const genericTitles = ["files", "browser"];

// title/cls: the window's; entryName: its desktop entry's Name ("" when none was found)
function caption(title, cls, entryName) {
    title = title ?? "";
    cls = cls ?? "";
    const own = tacitNames[cls];
    // every shell window carries the class org.quickshell, so the desktop entry says nothing about which app it is
    const app = own ?? (entryName || (cls.length > 0 ? cls.charAt(0).toUpperCase() + cls.slice(1) : ""));
    if (title.length === 0)
        return app;
    if (own && genericTitles.includes(title.toLowerCase()))
        return app;
    if (cls === "org.quickshell" || app.length === 0 || title.toLowerCase().includes(app.toLowerCase()))
        return title;
    return title + " · " + app;
}
