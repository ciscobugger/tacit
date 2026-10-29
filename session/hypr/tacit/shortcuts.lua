-- The shortcuts the person changed in Settings > Keyboard & touchpad > Shortcuts. Settings writes
-- ~/.config/hypr/hyprland/shellOverrides/shortcuts.lua, a table of data (nothing in it runs):
--   moves = { { "SUPER+X", "SUPER+E" }, { "SUPER+E", "" } }   what is on the first keys goes to the second ("" = no keys)
--   apps  = { { name = "Viewer", run = "gtk-launch viewer", keys = "SUPER+B" } }
-- It is read after Tacit's keys and the person's own, from the list hyprland.lua keeps of every bind made (TACIT_BINDS).
-- New keys are bound before the old ones are removed, and each entry stands alone: a bad entry is skipped and logged,
-- and a file that cannot be read changes nothing, so a mistake never leaves the person without their keys.
local M = {}

local ORDER = { "SUPER", "CTRL", "ALT", "SHIFT" }
local ALIAS = { MOD4 = "SUPER", WIN = "SUPER", LOGO = "SUPER", CONTROL = "CTRL", MOD1 = "ALT" }

-- "SUPER + shift + S" -> "SUPER+SHIFT+s": one spelling per combination (nil when it is not one); then Hyprland's
-- spelling of it, "SUPER + SHIFT + S"
function M.normalize(s)
    if type(s) ~= "string" or s == "" then return nil end
    local mods, key, shown = {}, nil, nil
    for raw in s:gmatch("[^+]+") do
        local part = raw:match("^%s*(.-)%s*$")
        local up = part:upper()
        up = ALIAS[up] or up
        if up == "SUPER" or up == "CTRL" or up == "ALT" or up == "SHIFT" then mods[up] = true
        elseif part ~= "" and not key then key, shown = part:lower(), part
        else return nil end
    end
    if not key then return nil end
    local out = {}
    for _, m in ipairs(ORDER) do if mods[m] then out[#out + 1] = m end end
    local pretty = {}
    for _, m in ipairs(out) do pretty[#pretty + 1] = m end
    out[#out + 1] = key
    pretty[#pretty + 1] = shown
    return table.concat(out, "+"), table.concat(pretty, " + ")
end

function M.apply(path)
    local chunk, err = loadfile(path, "t", {})
    if not chunk then print("[tacit] shortcuts file not read: " .. tostring(err)); return end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then print("[tacit] shortcuts file not read: " .. tostring(data)); return end

    local bind = hl.__tacit_bind or hl.bind
    -- what is bound now, by combination
    local by = {}
    for _, rec in ipairs(TACIT_BINDS or {}) do
        local k = M.normalize(rec.keys)
        if k then by[k] = by[k] or {}; table.insert(by[k], rec) end
    end

    local remove = {}
    for i, m in ipairs(type(data.moves) == "table" and data.moves or {}) do
        local good, why = pcall(function()
            local from = M.normalize(m[1])
            local to, toKeys = M.normalize(m[2])
            if not from or from == to then return end
            if to then
                for _, rec in ipairs(by[from] or {}) do
                    if rec.opts ~= nil then bind(toKeys, rec.dispatcher, rec.opts)
                    else bind(toKeys, rec.dispatcher) end
                end
                -- the keys it takes were somebody's: they have no shortcut now
                for _, rec in ipairs(by[to] or {}) do remove[#remove + 1] = rec end
            end
            for _, rec in ipairs(by[from] or {}) do remove[#remove + 1] = rec end
        end)
        if not good then print("[tacit] shortcut " .. i .. " skipped: " .. tostring(why)) end
    end
    local gone = {}
    for _, rec in ipairs(remove) do
        if gone[rec] then goto continue end
        gone[rec] = true
        local good, why = pcall(function() rec.handle:remove() end)
        if not good then print("[tacit] a shortcut could not be moved: " .. tostring(why)) end
        ::continue::
    end

    for i, a in ipairs(type(data.apps) == "table" and data.apps or {}) do
        local good, why = pcall(function()
            local k, keys = M.normalize(a.keys)
            if not k or type(a.run) ~= "string" or a.run == "" then return end
            bind(keys, hl.dsp.exec_cmd(a.run), { description = "App: " .. tostring(a.name or a.run) })
        end)
        if not good then print("[tacit] app shortcut " .. i .. " skipped: " .. tostring(why)) end
    end
end

return M
