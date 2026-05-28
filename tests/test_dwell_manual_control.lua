--[[
Purpose: Dwell scheduler, queue notification, and manual control tests.
Public API: returns table of tests.
]]

local service_plans = require("src.domain.service_plans")
local route_integration = require("src.master.route_integration")
local manual_control = require("src.master.manual_control")

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
  test_arrival_schedules_dwell_departure = function()
    local sent, network = fake_network()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = {
      { from = "A", to = "B", route_id = "R1", dwell_seconds = 0 },
      { from = "B", to = "C", route_id = "R2", dwell_seconds = 5 }
    } } } })
    local integration = route_integration.new({ network = network, train_registry = fake_train_registry(), service_plan_registry = plans, dispatcher = { request_route = function() return true, "reserved" end } })
    integration.handle_train_arrival({ train_id = "TRAIN-1", station = "B" }, "TRAIN-NODE-1")
    assert(sent[1].payload.cmd == "set_destination")
    assert(sent[2].payload.cmd == "hold_position")
    assert(integration.get_pending_departures()["TRAIN-1"])
  end,

  test_process_due_authorizes_after_dwell = function()
    local sent, network = fake_network()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = {
      { from = "A", to = "B", route_id = "R1", dwell_seconds = 0 },
      { from = "B", to = "C", route_id = "R2", dwell_seconds = 0 }
    } } } })
    local integration = route_integration.new({ network = network, train_registry = fake_train_registry(), service_plan_registry = plans, dispatcher = { request_route = function(_, route_id) assert(route_id == "R2"); return true, "reserved" end } })
    integration.handle_train_arrival({ train_id = "TRAIN-1", station = "B" }, "TRAIN-NODE-1")
    local fired = integration.process_due(os.clock() + 1)
    assert(#fired == 1)
    assert(sent[#sent].payload.cmd == "depart_authorized")
  end,

  test_process_queue_notifies_authorized_train = function()
    local sent, network = fake_network()
    local integration = route_integration.new({
      network = network,
      train_registry = fake_train_registry(),
      dispatcher = {
        routes = { R1 = { id = "R1", to = "B" } },
        process_queue = function() return { { train_id = "TRAIN-1", route_id = "R1", ok = true } } end
      }
    })
    integration.process_queue()
    assert(sent[1].payload.cmd == "depart_authorized")
    assert(sent[1].payload.route_id == "R1")
  end,

  test_manual_control_hold_train = function()
    local sent, network = fake_network()
    local trains = fake_train_registry()
    local manual = manual_control.new({ network = network, train_registry = trains })
    local ok = manual.handle({ action = "hold_train", train_id = "TRAIN-1", reason = "test" }, "PANEL-1")
    assert(ok)
    assert(sent[1].payload.cmd == "hold_position")
    assert(trains.data["TRAIN-1"].state == "WAITING_DEPARTURE")
  end,

  test_manual_control_set_signal = function()
    local aspect = nil
    local manual = manual_control.new({ dispatcher = { adapters = { signals = { setAspect = function(_, value) aspect = value; return true end } } } })
    local ok = manual.handle({ action = "set_signal", signal_id = "SIG-1", aspect = "GREEN" }, "PANEL-1")
    assert(ok)
    assert(aspect == "GREEN")
  end
}
