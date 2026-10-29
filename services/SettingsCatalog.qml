pragma Singleton

import QtQuick
import Quickshell

/**
 * The Settings app's pages: key, name, glyph, the cluster it sits in on the rail, one line of what
 * it covers, and the words its settings answer to. Read by the app (tacit-settings.qml) and by the
 * palette, whose Settings results open these pages, so the two cannot list different things.
 */
Singleton {
    readonly property var categories: [
        { key: "look",     name: "Appearance",    glyph: "palette",        cluster: 0, note: "Wallpaper, colours, type and how much shows through", words: "wallpaper change slideshow folder lock screen picture colours colors palette accent theme gtk qt kde terminal transparency see through blur font type interface monospace" },
        { key: "notch",    name: "Notch",         glyph: "call_to_action", cluster: 0, note: "What the notch shows, and for how long", words: "notch island hover full-screen hello greeting notifications volume brightness battery network workspace timers downloads screenshots agents claude jobs music waveform paused reminders unsaved work git pull requests" },
        { key: "desktop",  name: "Desktop",       glyph: "desktop_windows", cluster: 0, note: "The corners, the overview and widgets", words: "corners hot corner overview workspaces super tab grid widgets clock weather openweather city fahrenheit calendar notes todo osd on-screen volume brightness pop-up" },
        { key: "windows",  name: "Windows",       glyph: "select_window",  cluster: 0, note: "Tiling, gaps, corners and motion", words: "tiling layout split main master scrolling dwindle gaps space border rounding corners opacity transparent inactive blur animations" },
        { key: "notifications", name: "Notifications", glyph: "notifications", cluster: 0, note: "Do not disturb, and how pop-ups behave", words: "do not disturb dnd quiet silent pop-up popup position timeout" },
        { key: "network",  name: "Network",       glyph: "wifi",           cluster: 1, note: "Wi-Fi, VPN and sharing", words: "wifi wi-fi wireless join password saved forget trusted vpn internet" },
        { key: "bluetooth",name: "Bluetooth",     glyph: "bluetooth",      cluster: 1, note: "The adapter and the devices you have kept", words: "pair devices headphones headset speaker connect forget visible" },
        { key: "sound",    name: "Sound",         glyph: "volume_up",      cluster: 1, note: "Output, input and what the keys do", words: "volume output speakers headphones input microphone mic ear protection alert sounds" },
        { key: "display",  name: "Display & power", glyph: "brightness_6", cluster: 2, note: "Brightness, scale, night light and battery", words: "brightness scale resolution refresh rate monitor screen external mirror arrange night light warmth colour temperature battery power mode saver performance sleep suspend" },
        { key: "input",    name: "Keyboard & touchpad", glyph: "keyboard", cluster: 2, note: "Layout, repeat, scrolling, pointer and dictation", words: "keyboard layout language num lock repeat touchpad trackpad natural scrolling tap to click right-click scroll speed pointer mouse speed focus follows dictation flow words copilot key" },
        { key: "lock",     name: "Lock & sleep",  glyph: "lock",           cluster: 2, note: "What happens when you step away", words: "lock screen blur clock password shut down keyring idle timeout screen off sleep login hyprlock music media" },
        { key: "access",   name: "Accessibility", glyph: "accessibility_new", cluster: 2, note: "Text size, motion and the pointer", words: "accessibility text size larger font reduce motion animations cursor size pointer" },
        { key: "apps",     name: "Apps & services", glyph: "apps",         cluster: 3, note: "What opens at login, and which app opens what", words: "startup login autostart default apps browser files terminal mail pictures images video music pdf text editor screenshots recordings folder" },
        { key: "palette",  name: "Palette & search", glyph: "search",      cluster: 3, note: "What the palette finds, and its shortcuts", words: "search launcher sections files calculator clipboard emoji symbols actions keyboard shortcuts dictations claude shell commands web search typos prefix" },
        { key: "time",     name: "Language & time", glyph: "translate",    cluster: 3, note: "Language, clock, date format and time zone", words: "language translation locale date time clock 24-hour 12-hour format time zone timezone automatic ntp" },
        { key: "account",  name: "Your account",  glyph: "account_circle", cluster: 3, note: "Your name, picture and password", words: "name user picture avatar photo password" },
        { key: "accounts", name: "Accounts",      glyph: "key",            cluster: 3, note: "Sign-ins and keys for Claude Code, Codex, pi and opencode", words: "claude anthropic codex openai chatgpt pi opencode openrouter google gemini copilot zen api key sign in log in login subscription plan account work personal provider install agent model keyring" },
        { key: "about",    name: "About",         glyph: "info",           cluster: 3, note: "This machine, this desktop and its updates", words: "version model processor cpu graphics gpu memory ram storage disk system kernel hostname uptime updates" }
    ]
}
