--[[
Purpose: Tests for V3.16-V3.18 validation, manual panel actions, and dispatcher deadlock metadata.
Public API: returns table of tests.
]]

local validate = require("src.shared.validate")
local panel_state = require("src.domain.panel_state")
local dispatcher = require("src.master.dispatcher")

local function base_config()
  return {
    v = 1,
    channel = 777,
    master_id = "MASTER-1",
    nodes = {
      { id = "MASTER-1", role = "master" },
      { id = "SIG-1", role = "signal" },
      { id = "SIG-2", role = "signal" },
      { id = "SEN-1", role = "sensor" },
      { id = "TRAIN-1", role = "train", train_id = "TRAIN-1", service_plan = "SP1" }
    },
    blocks = {
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = {} }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = { "B1" }, priority = 1 }
    },
    service_plans = {
      { id = "SP1", train_id = "TRAIN-1", stops = { { route_id = "R1", dwell_seconds = 1 } } }
    }
  }
end

return {
  test_validate_accepts_service_plan = function()
    local ok, errors = validate.validate_config(base_config())
    assert(ok, table.concat(errors, "\n"))
  end,

  test_validate_rejects_unknown_service_route = function()
    local cfg = base_config()
    cfg.service_plans[1].stops[1].route_id = "NOPE"
    local ok, errors = validate.validate_config(cfg)
    assert(not ok)
    assert(string.find(table.concat(errors, "\n"), "unknown route"))
  end,

  test_panel_action_at_manual_row = function()
    local state = panel_state.new({ nodes = { { id = "PANEL-1", role = "panel", pages = { "manual" }, manual_actions = { { label = "Hold T1", action = "hold_train", train_id = "TRAIN-1" } } } } }, "PANEL-1")
    local action = state.action_at(7)
    assert(action.action == "hold_train")
    assert(action.train_id == "TRAIN-1")
    assert(state.snapshot().last_action == "Hold T1")
  end,

  test_dispatcher_records_deadlock_after_retries = function()
    local cfg = {
      blocks = {
        { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = {} }
      },
      routes = {
        { id = "R1", from = "A", to = "B", blocks = { "B1" }, priority = 1 }
      }
    }
    local d = dispatcher.new(cfg, { signals = { setAspect = function() return true end } })
    assert(d.reserve_route("TRAIN-A", "R1"))
    d.request_route("TRAIN-B", "R1")
    d.process_queue(1)
    d.process_queue(1)
    d.process_queue(1)
    assert(d.get_deadlocks()["TRAIN-B"])
    assert(d.get_deadlocks()["TRAIN-B"].route_id == "R1")
  end
}
