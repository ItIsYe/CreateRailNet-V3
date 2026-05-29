--[[
Purpose: Config loader regression tests.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local config = require("src.shared.config")

return {
  test_config_loads_full_example = function()
    local cfg = config.load("configs/templates/network.full.example.json")
    assert(cfg.master_id == "MASTER-1")
    assert(type(cfg.nodes) == "table")
  end,

  test_config_load_reports_missing_file = function()
    local ok, err = pcall(function() config.load("configs/templates/does-not-exist.json") end)
    assert(not ok)
    assert(string.find(tostring(err), "cannot open"))
  end
}
