--[[
Purpose: Service plan domain and integration tests.
Public API: returns table of tests.
]]

local service_plans = require("src.domain.service_plans")
local route_integration = require("src.master.route_integration")

local function fake_network()
  local sent = {}
  return sent, { send = function(msg_type, dst, payload) table.insert(sent, { type = msg_type, dst = dst, payload = payload }); return { id = "msg" } end }
end

local function fake_train_registry()
  local trains = { ["TRAIN-1"] = { id = "TRAIN-1", node_id = "TRAIN-NODE-1" } }
  return { get = function(id) return trains[id] end, update_status = function(id, patch) trains[id] = trains[id] or { id = id, node_id = id }; for k,v in pairs(patch or {}) do trains[id][k]=v end end, data = trains }
end

return {
  test_service_plan_loads_for_train = function()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = { { from = "A", to = "B", route_id = "R1" } } } } })
    local stop = plans.current_stop("TRAIN-1")
    assert(stop.route_id == "R1")
    assert(stop.to == "B")
  end,

  test_service_plan_advance_completes = function()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = { { from = "A", to = "B" } } } } })
    local next_stop, plan = plans.advance("TRAIN-1")
    assert(next_stop == nil)
    assert(plan.state == "COMPLETE")
  end,

  test_integration_uses_service_plan_when_request_empty = function()
    local sent, network = fake_network()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = { { from = "A", to = "B", route_id = "R1" } } } } })
    local integration = route_integration.new({
      network = network,
      train_registry = fake_train_registry(),
      service_plan_registry = plans,
      dispatcher = { request_route = function(_, route_id) assert(route_id == "R1"); return true, "reserved" end }
    })
    local ok = integration.handle_train_request({ train_id = "TRAIN-1" }, "TRAIN-NODE-1")
    assert(ok)
    assert(sent[1].payload.cmd == "depart_authorized")
    assert(sent[1].payload.route_id == "R1")
  end,

  test_integration_advances_on_arrival = function()
    local sent, network = fake_network()
    local plans = service_plans.new({ service_plans = { { id = "SP1", train_id = "TRAIN-1", stops = { { from = "A", to = "B", route_id = "R1" }, { from = "B", to = "C", route_id = "R2" } } } } })
    local integration = route_integration.new({ network = network, train_registry = fake_train_registry(), service_plan_registry = plans })
    integration.handle_train_arrival({ train_id = "TRAIN-1", station = "B" }, "TRAIN-NODE-1")
    assert(sent[1].payload.cmd == "set_destination")
    assert(sent[1].payload.route_id == "R2")
    assert(sent[1].payload.destination == "C")
  end
}
