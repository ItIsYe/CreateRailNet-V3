--[[
Purpose: Tests for safe Create station schedule test tool.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local tool = require("src.tools.create_station_schedule_test")

return {
  test_build_test_schedule = function()
    local schedule = tool.build_test_schedule("ST-B", 7)
    assert(schedule.cyclic == false)
    assert(schedule.entries[1].instruction.id == "create:destination")
    assert(schedule.entries[1].instruction.data.text == "ST-B")
    assert(schedule.entries[1].conditions[1][1].data.value == 7)
  end,

  test_apply_requires_confirm = function()
    local ok, err = tool.apply_test_schedule("Create_Station_0", "ST-B", 5, false)
    assert(not ok)
    assert(err == "refusing to apply schedule without confirm=true")
  end
}
