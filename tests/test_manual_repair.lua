--[[
Purpose: Operator repair actions: clear_fault and release_train through manual_control.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local manual_control = require("src.master.manual_control")
local dispatcher = require("src.master.dispatcher")

local function setup()
  local d = dispatcher.new({
    sensor_guard_min_occupy_ms = 0,
    blocks = { { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = {} } },
    routes = { { id = "R-1", from = "A", to = "B", blocks = { "B1" } } }
  }, { signals = { setAspect = function() return true end }, switches = { setPosition = function() return true end } })
  local audits = {}
  local mc = manual_control.new({ dispatcher = d, network = { send = function() end }, audit_log = { record = function(kind, data) audits[#audits + 1] = { kind = kind, data = data } end } })
  return d, mc, audits
end

return {
  test_clear_fault_action_repairs_the_block_and_is_audited = function()
    local d, mc, audits = setup()
    d.on_sensor_event_by_sensor("SEN-1", "leave")
    assert(d.get_block("B1").state == dispatcher.STATES.FAULT)
    assert(mc.handle({ action = "clear_fault", block_id = "B1" }, "PANEL-1"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE)
    local found = false
    for _, a in ipairs(audits) do if a.kind == "fault_cleared" and a.data.block_id == "B1" and a.data.ok then found = true end end
    assert(found)
  end,

  test_clear_fault_action_reports_why_it_refused = function()
    local _, mc = setup()
    local ok, err = mc.handle({ action = "clear_fault", block_id = "B1" }, "PANEL-1")
    assert(ok == false and tostring(err):find("not in FAULT"))
  end,

  test_release_train_action_frees_the_blocks_of_a_stuck_train = function()
    local d, mc = setup()
    assert(d.reserve_route("T1", "R-1"))
    d.timeout_node("T1")
    assert(d.get_block("B1").reserved_by == "T1")
    assert(mc.handle({ action = "release_train", train_id = "T1" }, "PANEL-1"))
    assert(d.get_block("B1").state == dispatcher.STATES.FREE and d.get_trains().T1 == nil)
    local ok = mc.handle({ action = "release_train", train_id = "T1" }, "PANEL-1")
    assert(ok == false)
  end,

  -- app.lua builds manual_control before the OTA manager, the cargo system and the alert list exist
  test_services_created_after_manual_control_are_found_when_an_action_runs = function()
    local context = { dispatcher = nil, network = { send = function() end } }
    local mc = manual_control.new(context)
    assert(mc.handle({ action = "ota_push" }, "PANEL-1") == false)
    local pushed = {}
    context.ota = { push_runtime = function(opts) pushed[#pushed + 1] = opts; return { ["NODE-1"] = { ok = true } } end }
    context.alerts = { ack = function(key) return key == "a" end, ack_all = function() return 2 end }
    context.cargo = { cancel_order = function() return true end }
    local ok, message = mc.handle({ action = "ota_push", node_id = "NODE-1", version = "v9" }, "PANEL-1")
    assert(ok == true and #pushed == 1 and pushed[1].version == "v9" and pushed[1].nodes[1] == "NODE-1", tostring(message))
    assert(mc.handle({ action = "ack_alert", key = "a" }, "PANEL-1") == true)
    assert(mc.handle({ action = "ack_alert", key = "zzz" }, "PANEL-1") == false)
    assert(mc.handle({ action = "ack_alert", all = true }, "PANEL-1") == true)
    assert(mc.handle({ action = "cargo_cancel", order_id = "O1" }, "PANEL-1") == true)
  end
}
