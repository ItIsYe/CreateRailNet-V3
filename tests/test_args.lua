--[[
Purpose: Shared args parser tests.
Public API: returns table of tests.
]]

local args = require("src.shared.args")

return {
  test_parse_config_and_id = function()
    local parsed = args.parse({ "--config", "network.json", "--id", "NODE-1" }, { config = {}, id = {} })
    assert(parsed.config == "network.json")
    assert(parsed.id == "NODE-1")
  end,

  test_missing_value_fails = function()
    local ok = pcall(function()
      args.parse({ "--config" }, { config = {} })
    end)
    assert(not ok, "expected missing value to fail")
  end
}
