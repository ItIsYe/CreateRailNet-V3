--[[
Purpose: Stability regression tests for API shape consistency and smoke assumptions.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local audit_log = require("src.domain.audit_log")
local diagnostics = require("src.domain.diagnostics")

return {
  test_audit_entries_use_data_field = function()
    local audits = audit_log.new(10)
    audits.record("route_request", { train_id = "TRAIN-1", route_id = "R1" })
    local entry = audits.list()[1]
    assert(entry.data.train_id == "TRAIN-1")
    assert(entry.data.route_id == "R1")
  end,

  test_diagnostics_preserves_recent_audit_data = function()
    local audits = audit_log.new(10)
    audits.record("route_request", { train_id = "TRAIN-1", route_id = "R1" })
    local diag = diagnostics.build({
      config = { nodes = {}, blocks = {}, routes = {}, service_plans = {} },
      registry = { all = function() return {} end },
      audit_log = audits
    })
    assert(#diag.recent_audit == 1)
    assert(diag.recent_audit[1].data.train_id == "TRAIN-1")
  end,

  test_cc_bootstrap_installs_core_globals = function()
    assert(type(fs) == "table")
    assert(type(peripheral) == "table")
    assert(type(textutils) == "table")
    assert(type(os.startTimer) == "function")
  end
}
