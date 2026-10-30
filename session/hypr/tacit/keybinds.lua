hl.bind("CTRL+SUPER+ALT+Slash", hl.dsp.exec_cmd("xdg-open ~/.config/hypr/custom/keybinds.lua"), {description = "Keys: Edit your own keys"} )

-- book4 overlay (keybinds.append.lua)
-- Book4 Edge: palette and settings keys.
-- Appended to ~/.config/hypr/custom/keybinds.lua, loaded after hyprland/keybinds.lua.
-- Shortcut names are the fork's CompositorGlobalShortcut names:
--   quickshell:searchToggleRelease -> claimed by modules/ii/commandPalette/CommandPalette.qml
--   quickshell:sessionToggle       -> modules/ii/sessionScreen/SessionScreen.qml

-- Super + Escape -> the session menu (lock, log out, restart, shut down). Nothing binds this
-- combination upstream (only CTRL + SHIFT + Escape, the task manager). Settings keeps Super + I.
hl.bind("SUPER + Escape", hl.dsp.global("quickshell:sessionToggle"),
    { description = "Shell: Session (lock, log out, power)" })

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

-- Super alone raises the dock when it is let go; Super with another key must not.
--
-- Quickshell's GlobalShortcut.onReleased fires whether or not another key was pressed while Super was
-- held, so Super + W opened the browser and the dock as well. The shell takes
-- quickshell:searchToggleReleaseInterrupt for exactly this, to cancel the release that would raise the
-- dock, but nothing sent it: it was written for a catch-all bind, which Hyprland 0.57 only allows inside
-- a submap, and a submap would have to repeat every Super bind to keep those keys working. So the keyboard
-- is watched here instead: this event fires for every key before its own bind runs, and an interrupt sent
-- on that press reaches the shell well before Super is released.
if not TACIT_SUPER_RELEASE_WATCH then
    TACIT_SUPER_RELEASE_WATCH = true

    local SUPER_KEYCODES = { [133] = true, [134] = true } -- xkb keycodes, not evdev: Super_L, Super_R
    local superHeld = false

    hl.on("input.keyboard.key", function(keycode, _time, state)
        local pressed = state == 1 -- wl_keyboard_key_state: 1 pressed, 0 released
        if SUPER_KEYCODES[keycode] then
            superHeld = pressed
        elseif pressed and superHeld then
            hl.dispatch(hl.dsp.global("quickshell:searchToggleReleaseInterrupt"))
        end
    end)
end

-- The same for Super with the mouse: dragging, resizing, the scratchpad button and Super + wheel produce no
-- key event, so the watcher above never sees them. Extra binds on these combinations send the interrupt;
-- Hyprland runs every bind on a combination, so the drag, resize and workspace binds still fire.
for _, combo in ipairs({ "SUPER + mouse:272", "SUPER + mouse:273", "SUPER + mouse:274", "SUPER + mouse:275",
                         "SUPER + mouse_up", "SUPER + mouse_down", "CTRL + SUPER + mouse_up", "CTRL + SUPER + mouse_down" }) do
    hl.bind(combo, hl.dsp.global("quickshell:searchToggleReleaseInterrupt"))
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

-- Alt + Tab -> the window switcher: the workspace overview with a ring on the window you were in before; Tab and
-- Shift + Tab move it, letting go of Alt focuses it (modules/ii/overview/Overview.qml). Hyprland sees the keys before
-- any window, so the open overview does not need to hold them.
hl.bind("ALT + Tab", hl.dsp.global("quickshell:altTabNext"), { description = "Shell: Switch windows" })
hl.bind("ALT + SHIFT + Tab", hl.dsp.global("quickshell:altTabPrev"), { description = "Shell: Switch windows, back" })
hl.bind("ALT + Escape", hl.dsp.global("quickshell:altTabCancel"), { description = "Shell: Leave the window switcher" })

-- Letting go of Alt ends the switch. Release binds on ALT_L and ALT_R never fired when Alt came up before Tab, as on a
-- quick tap: the switcher stayed open on the next window (Discord, 2026-10-30). The keyboard is watched instead, as for
-- Super above; the shell does nothing with it unless a switch is going.
if not TACIT_ALT_RELEASE_WATCH then
    TACIT_ALT_RELEASE_WATCH = true

    local ALT_KEYCODES = { [64] = true, [108] = true } -- xkb keycodes, not evdev: Alt_L, Alt_R

    hl.on("input.keyboard.key", function(keycode, _time, state)
        if ALT_KEYCODES[keycode] and state == 0 then
            hl.dispatch(hl.dsp.global("quickshell:altTabEnd"))
        end
    end)
end
