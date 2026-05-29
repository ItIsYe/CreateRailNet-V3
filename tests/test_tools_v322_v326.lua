--[[
Purpose: Tests for safe tooling added in V3.22-V3.26.
Public API: returns table of tests.
]]

local system_check = require("src.tools.system_check")
local inspector = require("src.tools.peripheral_inspector")
local debug_events = require("src.tools.debug_events")

return {
  test_system_check_module_exists = function()
    assert(type(system_check.run) == "function")
  end,

  test_peripheral_inspector_module_exists = function()
    assert(type(inspector.inspect) == "function")
    assert(type(inspector.run) == "function")
  end,

  test_debug_events_unknown_kind_fails_safely = function()
    local ok, err = debug_events.run({ kind = "unknown", config = "configs/templates/network.full.example.json" })
    assert(not ok)
    assert(err)
  end
}
