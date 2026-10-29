hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Keys: Edit your own keys"} )

-- book4 overlay (keybinds.append.lua)
-- Book4 Edge: palette and settings keys.
-- Appended to ~/.config/hypr/custom/keybinds.lua, loaded after hyprland/keybinds.lua.
-- Shortcut names are the fork's CompositorGlobalShortcut names:
--   quickshell:searchToggleRelease -> claimed by modules/ii/commandPalette/CommandPalette.qml
--   quickshell:settingsToggle      -> modules/ii/settings/Settings.qml

-- Super + Escape -> shell settings. Nothing binds this combination upstream
-- (only CTRL + SHIFT + Escape, the task manager), so there is nothing to displace.
hl.bind("SUPER + Escape", hl.dsp.global("quickshell:settingsToggle"),
    { description = "Shell: Settings" })

-- Super (release) -> palette.
--
-- hyprland/keybinds.lua already binds SUPER + SUPER_L and SUPER + SUPER_R to
-- quickshell:searchToggleRelease, and the palette claims that shortcut name, so Super
-- opens the palette with no bind from this file. Hyprland appends binds rather than
-- replacing them and the Lua API has no unbind, so declaring the same key here would
-- dispatch the toggle twice - open, then immediately close.
--
-- Set this to true ONLY if you also delete lines 12-15 of hyprland/keybinds.lua.
local REBIND_SUPER_PALETTE = false

if REBIND_SUPER_PALETTE then
    hl.bind("SUPER + SUPER_L", hl.dsp.global("quickshell:searchToggleRelease"),
        { description = "Shell: Toggle palette" }) -- # [hidden] (switched off above)
    hl.bind("SUPER + SUPER_R", hl.dsp.global("quickshell:searchToggleRelease")) -- # [hidden]
end

-- Escape -> collapse the Dynamic Island.
--
-- Bound NON-CONSUMING, which is the only form that is safe here: Hyprland still
-- delivers the Escape keypress to the focused window, so Escape keeps working in
-- every application, and the compositor merely also fires the global shortcut.
-- A plain (consuming) `hl.bind("Escape", ...)` would swallow Escape system-wide -
-- no dismissing dialogs, no leaving vim insert mode, nothing. Do not remove the
-- non_consuming flag.
--
-- `quickshell:islandCollapse` is a CompositorGlobalShortcut in the shell. If the
-- shell is not running, nothing claims the name and the dispatch is a no-op, so
-- this bind cannot strand the keyboard.
hl.bind("Escape", hl.dsp.global("quickshell:islandCollapse"),
    { non_consuming = true, description = "Shell: Close the notch" })

-- Super + Space -> the notch's sheet, with the keyboard: arrows over the rows, Enter does what
-- a click does, Esc closes. Nothing binds this combination upstream.
hl.bind("SUPER + Space", hl.dsp.exec_cmd("qs -p $TACIT_SHELL ipc call island open"), { description = "Shell: Open the notch" })

-- Super + Shift + Space -> Ask in the notch: a quick Claude chat (the screen, a window, a file)
hl.bind("SUPER + SHIFT + Space", hl.dsp.global("quickshell:islandAsk"), { description = "Shell: Ask Claude in the notch" })

-- Flow: hold to dictate anywhere, tap twice for hands-free (services/Dictation.qml, ~/.local/bin/flowd).
-- The Copilot key sends Super+Shift+F23.
hl.bind("SUPER + SHIFT + F23", hl.dsp.global("quickshell:flowHold"), { description = "Flow: hold to dictate" })

-- While Flow listens or writes, the shell enters this submap: Esc cancels and goes no further (a
-- plain Esc would also reach the app, and in Claude Code it stops a running turn). The shell
-- leaves it when the dictation ends; Esc leaves it by itself too, so it cannot strand the
-- keyboard. Other binds are off for those seconds.
hl.define_submap("flow", function()
    hl.bind("Escape", function()
        hl.dispatch(hl.dsp.global("quickshell:flowCancel"))
        hl.dispatch(hl.dsp.submap("reset"))
    end, { description = "Flow: cancel" })
    hl.bind("SUPER + SHIFT + F23", hl.dsp.global("quickshell:flowHold"), { description = "Flow: hold to dictate" }) -- # [hidden] (the same key inside the flow submap)
end)
