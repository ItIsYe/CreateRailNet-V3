--[[
Purpose: Route integration tests for train/station/depot events.
Public API: returns table of tests.
]]

local route_integration = require("src.master.route_integration")

local function fake_network()
  local sent = {}
  return sent, {
    send = function(msg_type, dst, payload)
      table.insert(sent, { type = msg_type, dst = dst, payload = payload })
      return { id = "msg-test" }
    end
  }
end

local function fake_train_registry()
  local trains = { ["TRAIN-1"] = { id = "TRAIN-1", node_id = "TRAIN-NODE-1" } }
  return {
    get = function(id) return trains[id] end,
    update_status = function(id, patch)
      trains[id] = trains[id] or { id = id, node_id = id }
      for k, v in pairs(patch or {}) do trains[id][k] = v end
    end,
    data = trains
  }
end

return {
  test_train_request_authorizes_when_dispatcher_reserves = function()
    local sent, network = fake_network()
    local trains = fake_train_registry()
    local integration = route_integration.new({
      network = network,
      train_registry = trains,
      dispatcher = { request_route = function() return true, "reserved" end }
    })
    local ok = integration.handle_train_request({ train_id = "TRAIN-1", route_id = "R1", to = "ST-B" }, "TRAIN-NODE-1")
    assert(ok)
    assert(sent[1].dst == "TRAIN-NODE-1")
    assert(sent[1].payload.cmd == "depart_authorized")
    assert(trains.data["TRAIN-1"].state == "ROUTE_ASSIGNED")
  end,

  test_train_request_holds_when_queued = function()
    local sent, network = fake_network()
    local trains = fake_train_registry()
    local integration = route_integration.new({
      network = network,
      train_registry = trains,
      dispatcher = { request_route = function() return false, "queued" end }
    })
    local ok = integration.handle_train_request({ train_id = "TRAIN-1", route_id = "R1" }, "TRAIN-NODE-1")
    assert(not ok)
    assert(sent[1].payload.cmd == "hold_position")
    assert(trains.data["TRAIN-1"].state == "WAITING_FOR_ROUTE")
  end,

  test_depot_request_updates_track = function()
    local sent, network = fake_network()
    local depot_patch = nil
    local integration = route_integration.new({
      network = network,
      train_registry = fake_train_registry(),
      dispatcher = { request_route = function() return true, "reserved" end },
      depot_registry = {
        enqueue = function() end,
        update_track = function(_, _, patch) depot_patch = patch end
      }
    })
    local ok = integration.handle_depot_request({ depot_id = "DEPOT-1", track_id = "D1", train_id = "TRAIN-1", route_id = "R1" }, "DEPOT-1")
    assert(ok)
    assert(depot_patch.state == "DEPARTING")
    assert(sent[1].payload.cmd == "depart_authorized")
  end,

  test_station_ready_updates_platform = function()
    local sent, network = fake_network()
    local platform_patch = nil
    local integration = route_integration.new({
      network = network,
      train_registry = fake_train_registry(),
      dispatcher = { request_route = function() return false, "queued" end },
      station_registry = {
        update_platform = function(_, _, patch) platform_patch = patch end
      }
    })
    local ok = integration.handle_station_ready({ station_id = "ST-A", platform_id = "P1", train_id = "TRAIN-1", route_id = "R1" }, "ST-A")
    assert(not ok)
    assert(platform_patch.state == "READY_TO_DEPART")
    assert(sent[1].payload.cmd == "hold_position")
  end
}
