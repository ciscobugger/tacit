-- The submap Settings enters while a shortcut row listens for its new keys: no shortcut of Tacit's is live in it, so the
-- keys pressed reach Settings instead of being run. It cannot strand the keyboard: Esc leaves it (and still reaches
-- Settings, which cancels), Settings leaves it when it is done, and this file leaves it after 30 seconds whatever
-- happened to Settings.
hl.define_submap("tacit-capture", function()
    hl.bind("Escape", hl.dsp.submap("reset"), { non_consuming = true })
end)

-- Each entry gets a number so an earlier entry's timer cannot end a later capture early.
local entry = 0
hl.on("keybinds.submap", function()
    if hl.get_current_submap() ~= "tacit-capture" then return end
    entry = entry + 1
    local mine = entry
    hl.timer(function()
        if entry == mine and hl.get_current_submap() == "tacit-capture" then hl.dispatch(hl.dsp.submap("reset")) end
    end, { timeout = 30000, type = "oneshot" })
end)
