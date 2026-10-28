// A session's title, the same in the rail, the header, the window and the notch: its own title, else the first thing
// asked, else the last. Words put around a request are left out (the desktop context; the browser's line and its list
// of pages, where the page on screen names the session when the question itself was cut off); breaks become spaces.
.pragma library

const browser = /^The user asks from their browser[^\n]*(?:\n|$)((?:[ \t]*- [^\n]*(?:\n|$))*)/;

function clean(t) {
    let s = String(t ?? "").replace(/\s*<desktop-context>[\s\S]*$/, "");
    const b = s.match(browser);
    if (b) s = s.slice(b[0].length).trim() || ((b[1].match(/^[ \t]*- (.+?): \S+ \(on screen\)/m) || [])[1] ?? "");
    return s.replace(/\s+/g, " ").trim();
}

function of(s) {
    return clean(s.title) || clean(s.prompt) || clean(s.lastPrompt) || "Untitled";
}
