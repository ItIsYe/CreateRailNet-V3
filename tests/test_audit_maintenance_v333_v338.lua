--[[
Purpose: Tests for V3.33-V3.38 audit log and maintenance lockdown.
Public API: returns table of tests.
]]

local audit_log = require("src.domain.audit_log")
local maintenance = require("src.domain.maintenance")
local diagnostics = require("src.domain.diagnostics")
local manual_control = require("src.master.manual_control")
local route_integration = require("src.master.route_integration")

local function fake_network()
  local sent = {}
  return sent, { send = function(msg_type, dst, payload) table.insert(sent, { type = msg_type, dst = dst, payload = payload }); return { id = "msg" } end }
end

local function fake_train_registry()
  local trains = { ["TRAIN-1"] = { id = "TRAIN-1", node_id = "TRAIN-NODE-1" } }
  return {
    get = function(id) return trains[id] end,
    update_status = function(id, patch) trains[id] = trains[id] or { id = id, node_id = id }; for k,v in pairs(patch or {}) do trains[id][k]=v end end,
    data = trains
  }
end

return {
  test_audit_log_records_and_filters = function()
    local audits = audit_log.new(5)
    audits.record("route_request", { train_id = "T1" })
    audits.record("manual_control", { action = "hold_train" })
    assert(#audits.list() == 2)
    assert(#audits.filter("manual_control") == 1)
  end,

  test_maintenance_mode_status = function()
    local m = maintenance.new()
    assert(not m.is_locked())
    m.enable("test", "PANEL-1")
    assert(m.is_locked())
    assert(m.status().reason == "test")
    m.disable("PANEL-1")
    assert(not m.is_locked())
  end,

  test_manual_control_maintenance_blocks_route_request = function()
    local sent, network = fake_network()
    local audits = audit_log.new(10)
    local m = maintenance.new()
    local manual = manual_control.new({
      network = network,
      train_registry = fake_train_registry(),
      maintenance = m,
      audit_log = audits,
      route_integration = { handle_train_request = function() return true end }
    })
    assert(manual.handle({ action = "enter_maintenance", reason = "work" }, "PANEL-1"))
    local ok = manual.handle({ action = "request_route", train_id = "TRAIN-1", route_id = "R1" }, "PANEL-1")
    assert(not ok)
    assert(#audits.filter("manual_rejected") == 1)
  end,

  test_route_integration_lockdown_rejects_departure = function()
    local sent, network = fake_network()
    local audits = audit_log.new(10)
    local m = maintenance.new()
    m.enable("locked", "test")
    local integration = route_integration.new({
      network = network,
      train_registry = fake_train_registry(),
      maintenance = m,
      audit_log = audits,
      dispatcher = { request_route = function() error("should not reserve during maintenance") end }
    })
    local ok, status = integration.handle_train_request({ train_id = "TRAIN-1", route_id = "R1" }, "TRAIN-NODE-1")
    assert(not ok)
    assert(status == "maintenance locked")
    assert(sent[1].payload.cmd == "hold_position")
    assert(#audits.filter("route_rejected") == 1)
  end,

  test_diagnostics_contains_audit_and_maintenance = function()
    local audits = audit_log.new(10)
    local m = maintenance.new()
    m.enable("diag", "test")
    audits.record("manual_control", { action = "enter_maintenance" })
    local diag = diagnostics.build({ audit_log = audits, maintenance = m, config = {}, registry = { all = function() return {} end } })
    assert(diag.maintenance.enabled)
    assert(#diag.recent_audit == 1)
  end
}
