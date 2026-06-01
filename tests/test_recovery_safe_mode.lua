--[[
Purpose: Safe recovery mode tests.
Public API: returns table of tests.
]]

local runtime_factory = require("src.master.runtime")

local function fake_ui()
  return { mark_dirty = function() end, draw = function() end, handle_touch = function() end }
end

local function fake_network()
  local sent = {}
  return sent, {
    receive = function() return "ok" end,
    ack_for = function() end,
    tick = function() end,
    send = function(msg_type, dst, payload) table.insert(sent, { type = msg_type, dst = dst, payload = payload }); return { id = "msg" } end
  }
end

local function fake_registry()
  return { all = function() return {} end, register = function() end, heartbeat = function() end, mark_down = function() end }
end

local function ctx()
  local sent, network = fake_network()
  local route_requests = 0
  local manual_calls = 0
  local store = {
    load = function() return { blocks = {}, trains = {}, queue = {} }, { saved_at = 1 } end,
    save = function() return true end
  }
  local dispatcher = {
    restore = function() return true end,
    snapshot = function() return { blocks = {}, trains = {}, queue = {} } end,
    get_overview = function() return {} end,
    timeout_node = function() end,
    on_sensor_event_by_sensor = function() return true end
  }
  local context = {
    config = {},
    registry = fake_registry(),
    dispatcher = dispatcher,
    network = network,
    ui = fake_ui(),
    state_store = store,
    route_integration = {
      handle_train_request = function() route_requests = route_requests + 1; return true end,
      process_queue = function() end,
      process_due = function() end
    },
    manual_control = { handle = function() manual_calls = manual_calls + 1; return true end },
    train_registry = { update_status = function() end, register = function() end, list = function() return {} end },
    station_registry = { list = function() return {} end },
    depot_registry = { list = function() return {} end },
    service_plan_registry = { list = function() return {} end }
  }
  return context, sent, function() return route_requests end, function() return manual_calls end
end

return {
  test_restore_enters_recovery_mode = function()
    local context = ctx()
    local rt = runtime_factory.new(context)
    local ok = rt.restore_recovery_state()
    assert(ok)
    assert(rt.recovery.required == true)
    assert(rt.recovery.confirmed == false)
  end,

  test_recovery_blocks_train_departure = function()
    local context, sent, route_count = ctx()
    local rt = runtime_factory.new(context)
    rt.restore_recovery_state()
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "TRAIN-1", payload = { type = "request_departure", train_id = "TRAIN-1", route_id = "R1" } } })
    assert(route_count() == 0)
    assert(sent[1].payload.cmd == "hold_position")
    assert(sent[1].payload.reason == "recovery review required")
  end,

  test_confirm_recovery_allows_train_departure = function()
    local context, sent, route_count = ctx()
    local rt = runtime_factory.new(context)
    rt.restore_recovery_state()
    rt.confirm_recovery("PANEL-1", "checked")
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "TRAIN-1", payload = { type = "request_departure", train_id = "TRAIN-1", route_id = "R1" } } })
    assert(route_count() == 1)
    assert(rt.recovery.required == false)
  end,

  test_recovery_blocks_manual_control_except_confirm = function()
    local context, _, _, manual_count = ctx()
    local rt = runtime_factory.new(context)
    rt.restore_recovery_state()
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "PANEL-1", payload = { type = "manual_control", action = "set_signal" } } })
    assert(manual_count() == 0)
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "event", src = "PANEL-1", payload = { type = "manual_control", action = "confirm_recovery", reason = "operator checked" } } })
    assert(rt.recovery.required == false)
  end
}
