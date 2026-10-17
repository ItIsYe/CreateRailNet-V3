--[[
Purpose: Trains panel touch mapping must follow the real monitor height and must not leak globals.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local trains_panel = require("src.master.ui.panels.trains")

local function fake_monitor(w, h)
  return setmetatable({ getSize = function() return w, h end }, { __index = function() return function() end end })
end

return {
  test_action_row_follows_monitor_height = function()
    local handled = {}
    local registry = { list = function() return { ["T-1"] = { state = "RUNNING" } } end, get = function() return { route_id = "R1" } end }
    local panel = trains_panel.new(registry, { handle = function(payload) handled[#handled + 1] = payload; return true end })
    local height = 30
    panel.draw(fake_monitor(51, height))
    panel.touch(5, 3)
    assert(panel.selected == "T-1", "touching the first list row selects the train")
    panel.draw(fake_monitor(51, height))
    panel.touch(2, height - 2)
    assert(#handled == 1 and handled[1].action == "hold_train", "action row sits two rows above the bottom of a 30 line monitor")
  end,

  test_panel_does_not_leak_globals = function()
    trains_panel.new({ list = function() return {} end }, nil)
    assert(rawget(_G, "u_size_or") == nil)
  end
}
