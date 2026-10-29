

-- book4 overlay (general.append.lua)
-- Book4 Edge: motion and feel.
-- Appended to ~/.config/hypr/custom/general.lua. hyprland.lua requires custom.general
-- AFTER hyprland.general, so everything here overrides the upstream values. Only the keys
-- named below change; the rest of upstream's general.lua (blur xray, dim_special, border
-- colours from colors.lua, dwindle, misc, cursor, xwayland) is left alone.
--
-- What this file CANNOT set: hyprland.lua loads hyprland.shellOverrides.main last (line 59),
-- and that file is generated from ~/.config/illogical-impulse/config.json by the shell's
-- hyprconfigurator.py, so every key the Settings GUI has written wins over this file. Those
-- keys are gone from here - rounding, blur enabled/size/passes, gaps, border_size,
-- inactive_opacity, kb_layout and the touchpad belong in Settings now. The generator writes
-- only keys the GUI touches, so anything left here dies the day someone moves that slider.

hl.config({
    general = {
        resize_on_border = true,
        snap = {
            enabled = true,
            window_gap = 4,
            monitor_gap = 6,
            respect_gaps = true
        }
    },
    decoration = {
        -- rounding_power 2.0 = true circular corners, matching the island radius language
        rounding_power = 2.0,

        dim_inactive = true,
        dim_strength = 0.04,

        shadow = {
            enabled = true,
            range = 18,
            offset = {0, 3},
            render_power = 4   -- Hyprland 0.57 refuses more than 4 (0.56 took 10 unchecked)
        }
    },
    gestures = {
        -- 15.6" precision touchpad
        workspace_swipe_distance = 500,
        workspace_swipe_cancel_ratio = 0.18,
        workspace_swipe_min_speed_to_force = 4,
        workspace_swipe_direction_lock = true,
        workspace_swipe_create_new = true
    },
    misc = {
        vrr = 0,
        animate_manual_resizes = false
    }
})

-- Curves
hl.curve("islandOvershoot", {
    type = "bezier",
    points = {{0.38, 1.21}, {0.22, 1.00}}
})

-- Layer entry: only the island rides layersIn. The palette and both sidebars are
-- no_anim in custom/rules.lua and draw their own reveal (see shell-fusion-motion-plan.md).
hl.animation({
    leaf = "layersIn",
    enabled = true,
    speed = 2.7,
    bezier = "islandOvershoot",
    style = "popin 93%"
})
hl.animation({
    leaf = "layersOut",
    enabled = true,
    speed = 2.4,
    bezier = "menu_accel",
    style = "popin 94%"
})
hl.animation({
    leaf = "workspaces",
    enabled = true,
    speed = 6,
    bezier = "menu_decel",
    style = "slide"
})
hl.animation({
    leaf = "windowsMove",
    enabled = true,
    speed = 3.4,
    bezier = "emphasizedDecel",
    style = "slide"
})

-- Upstream's 3-finger swipe/pinch and 4-finger up/horizontal gestures are kept.
-- 4-finger down is re-declared to open the palette instead of the overview.
hl.gesture({
    fingers = 4,
    direction = "down",
    action = function()
        hl.dispatch(hl.dsp.global("quickshell:searchToggle"))
    end
})

-- ---------------------------------------------------------------------------
-- Material 3 Expressive frost.
--
-- M3's frosted surfaces are strongly blurred, let colour through, and sit a touch
-- brighter than what is behind them -- that lift is what separates frost from a
-- dark translucent sheet.
--
-- Only the keys the Settings GUI never writes are here; size, passes, enabled and
-- inactive_opacity live in config.json (see the header) and used to be set twice.
hl.config({ decoration = { blur = { vibrancy = 0.62 } } })   -- keep colour from behind
hl.config({ decoration = { blur = { vibrancy_darkness = 0.35 } } })
hl.config({ decoration = { blur = { brightness = 1.06 } } }) -- the M3 luminosity lift
hl.config({ decoration = { blur = { contrast = 0.95 } } })
hl.config({ decoration = { blur = { noise = 0.015 } } })     -- minimal grain, not film grain

-- Pointer: a macOS-style curve (2026-10-02). Slow moves are slower than 1:1 for precise landing, swipes go further;
-- output speed = v * (0.6 + 1.6 * (v / 6)^1.2), v in 0.5 steps. Not in shellOverrides' generator, so set here.
-- Hyprland 0.57 checks input.accel_profile against adaptive/flat/custom and refuses a curve there (its own parser still
-- reads one); a device's own setting is not checked, so each mouse and touchpad gets the curve as its own, at the start
-- and when one is plugged in later. Hyprland before 0.57 (no hl.get_devices) takes it as it always did.
local POINTER_CURVE = "custom 0.5 0 0.341 0.786 1.355 2.056 2.899 3.889 5.033 6.334 7.798 9.428 11.228 13.2"
if hl.get_devices then
    local curved = {}
    local function curvePointers()
        for _, d in ipairs(hl.get_devices()) do
            if d.type == "pointer" and d.name and not curved[d.name] then
                curved[d.name] = true
                hl.device({ name = d.name, accel_profile = POINTER_CURVE })
            end
        end
    end
    hl.on("hyprland.start", curvePointers)
    hl.timer(curvePointers, { timeout = 3000, type = "repeat" })
else
    hl.config({ input = { accel_profile = POINTER_CURVE } })
end
