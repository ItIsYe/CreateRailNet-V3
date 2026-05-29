--[[
Purpose: Tests for safe ingame inspection tools.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local inspector = require("src.tools.peripheral_inspector")
local binding_report = require("src.tools.hardware_binding_report")
local redstone_report = require("src.tools.redstone_side_report")
local create_finder = require("src.tools.create_method_finder")

return {
  test_peripheral_inspector_scan_shape = function()
    local report = inspector.scan()
    assert(type(report.generated_at) == "number")
    assert(type(report.peripherals) == "table")
  end,

  test_peripheral_find_methods_no_peripherals_safe = function()
    local matches = inspector.find_methods({ "schedule" })
    assert(type(matches) == "table")
  end,

  test_hardware_binding_report_builds = function()
    local report = binding_report.build("configs/templates/network.full.example.json")
    assert(type(report.rows) == "table")
    assert(#report.rows > 0)
  end,

  test_redstone_side_report_builds = function()
    local report = redstone_report.build("configs/templates/network.full.example.json")
    assert(type(report.rows) == "table")
    assert(#report.rows > 0)
  end,

  test_create_method_finder_safe = function()
    local matches = create_finder.find({ patterns = { "train", "schedule" } })
    assert(type(matches) == "table")
  end
}
