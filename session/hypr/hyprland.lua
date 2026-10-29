-- Tacit's Hyprland session. The session starts Hyprland with this file (--config /usr/share/tacit/hypr/hyprland.lua),
-- so Hyprland finds Tacit's modules here first: `hyprland.*` (the base) and `tacit.*` (Tacit's own choices). The
-- person's own files come from ~/.config/hypr and load after Tacit's, so they win: custom/*.lua (made empty on first
-- start by hyprland.services), monitors.lua, workspaces.lua, and hyprland/shellOverrides (written by the shell).

-- One bad module used to take the whole desktop down: the modules load in order and keybinds are near the end, so an
-- error in any earlier file aborted the chain before a single keybind was registered. safe_require reports a broken
-- module in Hyprland's log, skips it, and everything after it still loads.
local function safe_require(m)
    local ok, err = pcall(require, m)
    if not ok then
        print("[tacit] CONFIG MODULE FAILED: " .. tostring(m) .. " -> " .. tostring(err))
        print("[tacit] continuing so keybinds still load; fix the module above.")
    end
    return ok
end

-- the person's folder, after Tacit's: their own modules have names Tacit's do not use
local home = os.getenv("HOME") or ""
package.path = package.path .. ";" .. home .. "/.config/hypr/?.lua;" .. home .. "/.config/hypr/?/init.lua"
local function theirs(name) return is_file_exists(HOME .. "/.config/hypr/" .. name .. ".lua") end
local function layer(name)
    safe_require("tacit." .. name)
    if theirs("custom/" .. name) then safe_require("custom." .. name) end
end

-- Every shortcut Tacit and the person's own files bind is written down as it is made (hl.bind is wrapped), so the keys
-- the person chose in Settings can move a shortcut to other keys later (tacit/shortcuts.lua). The wrapper changes
-- nothing else: it passes every call through and returns what hl.bind returns.
TACIT_BINDS = {}
do
    hl.__tacit_bind = hl.__tacit_bind or hl.bind
    hl.__tacit_define_submap = hl.__tacit_define_submap or hl.define_submap
    local bind, define = hl.__tacit_bind, hl.__tacit_define_submap
    local inSubmap = false
    hl.bind = function(...)
        local handle = bind(...)
        if not inSubmap then
            local a = { ... }
            TACIT_BINDS[#TACIT_BINDS + 1] = { keys = a[1], dispatcher = a[2], opts = a[3], handle = handle }
        end
        return handle
    end
    -- the keys of a submap belong to that submap: a moved key would land in the main one
    hl.define_submap = function(...)
        local was = inSubmap
        inSubmap = true
        local ok, err = pcall(define, ...)
        inSubmap = was
        if not ok then error(err, 0) end
    end
end

-- Internal stuff --
require("hyprland.lib")
safe_require("hyprland.services")

-- How much of this wallpaper the glass lets through (scripts/colors/seethrough.py, run at every wallpaper change): one
-- scale on every designed see-through amount, 1 on dark wallpapers and less on bright ones, so the grounds stay as dark
-- as on dusk. tacit_glass(o) is a designed opacity with its see-through scaled (the opacity rules, windows not in use).
TACIT_GLASS = 1
do
    local state = os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")
    local f = io.open(state .. "/quickshell/user/generated/seethrough.json", "r")
    if f then
        local s = tonumber(string.match(f:read("a") or "", '"scale"%s*:%s*([%d.]+)'))
        f:close()
        if s and s >= 0 and s <= 1 then TACIT_GLASS = s end
    end
end
function tacit_glass(opacity) return 1 - (1 - opacity) * TACIT_GLASS end

-- Environment variables --
safe_require("hyprland.env")
layer("env")

-- App and shell variables (terminal, browser, the editor): required before execs and keybinds, so a failure in
-- keybinds.lua can no longer leave the shell unstarted.
safe_require("hyprland.variables")
layer("variables")

-- Default configurations --
safe_require("hyprland.execs")
safe_require("hyprland.general")
safe_require("hyprland.rules")
safe_require("hyprland.colors")
-- the colours made from the person's wallpaper (matugen writes ~/.config/hypr/hyprland/colors.lua): `require` finds
-- Tacit's packaged file of the same name first, so the borders never followed the wallpaper
if theirs("hyprland/colors") then
    local ok, err = pcall(dofile, HOME .. "/.config/hypr/hyprland/colors.lua")
    if not ok then print("[tacit] the wallpaper's colours did not load: " .. tostring(err)) end
end
safe_require("hyprland.keybinds")

-- Tacit's choices, then the person's --
layer("execs")
layer("general")
layer("rules")
if is_file_exists("/usr/share/tacit/hypr/tacit/browser.lua") then
    safe_require("tacit.browser")  -- Thyris's sign-in page in the notch (the tacit-thyris package)
end
layer("keybinds")
-- the keys the person chose in Settings > Keyboard & touchpad > Shortcuts, over Tacit's and their own files: a bad file
-- or entry is skipped and says so in the log, the keys before it stay as they were
if theirs("hyprland/shellOverrides/shortcuts") then
    local ok, mod = pcall(require, "tacit.shortcuts")
    if ok then
        local ran, err = pcall(mod.apply, HOME .. "/.config/hypr/hyprland/shellOverrides/shortcuts.lua")
        if not ran then print("[tacit] the chosen shortcuts did not load: " .. tostring(err)) end
    else
        print("[tacit] the chosen shortcuts did not load: " .. tostring(mod))
    end
end
-- the capture submap Settings enters while it listens for new keys (its own watchdog leaves it)
safe_require("tacit.shortcut_capture")

-- nwg-displays support --
if theirs("workspaces") then safe_require("workspaces") end
if theirs("monitors") then safe_require("monitors") end

-- Shell overrides (the person's, written by the shell) --
if theirs("hyprland/shellOverrides/main") then safe_require("hyprland.shellOverrides.main") end

-- windows not in use as the person set them (Settings, shellOverrides), with this wallpaper's scale on their see-through
local inactive = hl.get_config("decoration:inactive_opacity")
if type(inactive) == "number" then hl.config({ decoration = { inactive_opacity = tacit_glass(inactive) } }) end
