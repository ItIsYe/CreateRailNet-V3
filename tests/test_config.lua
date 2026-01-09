--[[
Purpose: Config validation tests.
Public API: returns table of tests.
]]

local validate = require("src.shared.validate")

return {
  test_valid_config = function()
    local cfg = {
      v = 1,
      channel = 777,
      master_id = "MASTER-1",
      blocks = { { id = "B1", entry_signal = "S1", exit_signal = "S2", sensors = {"SEN"}, switches = {} } },
      routes = { { id = "R1", from = "A", to = "B", blocks = {"B1"}, priority = 1 } },
      nodes = { { id = "MASTER-1", role = "master" } }
    }
    local ok, errors = validate.validate_config(cfg)
    assert(ok, table.concat(errors, ","))
  end,
  test_invalid_config = function()
    local cfg = { v = 2 }
    local ok, errors = validate.validate_config(cfg)
    assert(not ok, "expected invalid config")
    assert(#errors > 0, "expected errors")
  end
}
