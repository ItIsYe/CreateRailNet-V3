--[[
Purpose: Tool tests for config check and diagnosis report.
Public API: returns table of tests.
]]

local check_config = require("src.tools.check_config")
local diagnose = require("src.tools.diagnose_config")

return {
  test_full_example_config_is_valid = function()
    local ok, errors = check_config.check("configs/templates/network.full.example.json")
    assert(ok, table.concat(errors or {}, "\n"))
  end,

  test_diagnose_builds_report = function()
    local lines, ok = diagnose.build("configs/templates/network.full.example.json")
    assert(ok)
    assert(#lines > 5)
    assert(string.find(lines[1], "CreateRailNet Diagnosis"))
  end
}
