--[[
Purpose: A passenger train from the timetable to the proven clearance of its tail, through the fleet pair, the master's fleet bridge and dispatcher, and the station (Gesamtkonzept Kap. 24.1 end to end; tests C-01, C-03, E2E).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local fleet_world = require("tests.harness.fleet_world")
local A = fleet_world.A

local function with_world(opts, fn)
  opts = opts or {}
  opts.real_master = true
  local w = fleet_world.new(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function trip_of(w) return w.nodes[A].engine.trips()[1] end

local function enter_leave(w, block, sensor, leave)
  assert(w.dispatcher.on_sensor_event(block, "enter", sensor), block)
  w.run(1500)
  if leave then assert(w.dispatcher.on_sensor_event(block, "leave", sensor), block) end
end

return {
  test_the_whole_trip_with_a_real_dispatcher = function()
    with_world({ proof = true }, function(w)
      for _, id in ipairs({ "B1", "B2", "BP1", "BP2" }) do assert(w.dispatcher.observe_block(id, "FREE_PROVEN", "observer", { at = 1 })) end
      w.run(130000)
      local trip = trip_of(w)
      assert(trip and trip.state == "TRAIN_CANDIDATE", trip and trip.state)
      -- the station tells the master which train stands where: the master tells the fleet
      w.bridge.on_station_event({ type = "train_arrived_station", train_id = "TRAIN-1", train_name = "Sued 1", platform_id = "N1" }, "NORD")
      w.run(15000)
      assert(trip.state == "SCHEDULE_APPLIED", trip.state)
      assert(w.dispatcher.get_trains()["TRAIN-1"].route == "R-NS" and w.dispatcher.get_block("B1").reserved_by == "TRAIN-1", "the master holds the reservation")
      assert(w.station.count() == 1 and w.station.inbox[1].platform == "P1", "the schedule was given once, for platform P1 of SUED")
      -- the train drives
      enter_leave(w, "B1", "SEN-1", true)
      assert(trip.state == "DEPARTURE_OBSERVED" or trip.state == "EN_ROUTE", trip.state)
      enter_leave(w, "B2", "SEN-2", true)
      enter_leave(w, "BP1", "SEN-3", false)
      assert(trip.state == "ARRIVAL_OBSERVED", trip.state)
      assert(w.dispatcher.on_sensor_event("BP1", "leave", "SEN-3"))
      w.run(5000)
      assert(trip.state == "COMPLETE", trip.state)
      assert(w.station.count() == 1, "still one schedule call")
      assert(w.dispatcher.get_trains()["TRAIN-1"].phase == "RELEASED_PROVEN")
    end)
  end,

  test_a_block_that_is_not_proven_free_keeps_the_trip_waiting_and_nothing_is_given = function()
    with_world({ proof = true }, function(w)
      w.run(130000)
      local trip = trip_of(w)
      w.bridge.on_station_event({ type = "train_arrived_station", train_id = "TRAIN-1", train_name = "Sued 1", platform_id = "N1" }, "NORD")
      w.run(15000)
      assert(trip.state == "WAITING" or trip.state == "STATION_CONFIRMED", trip.state)
      assert(w.station.count() == 0 and w.dispatcher.get_trains()["TRAIN-1"] == nil, "no platform proven free: no route, no schedule")
    end)
  end,

  test_a_route_the_dispatcher_refuses_is_asked_again_and_goes_through_when_the_blocks_are_proven = function()
    with_world({ seed = 5 }, function(w)
      w.dispatcher.observe_block("BP1", "FREE_PROVEN", "observer", { at = 1 })
      w.dispatcher.observe_block("BP2", "FREE_PROVEN", "observer", { at = 1 })
      -- proof mode off in this dispatcher: the route is given as long as the blocks are free; occupy B2 with another train to force a refusal
      w.dispatcher.reserve_route("OTHER", "R-NS")
      w.run(130000)
      local trip = trip_of(w)
      w.bridge.on_station_event({ type = "train_arrived_station", train_id = "TRAIN-1", train_name = "Sued 1", platform_id = "N1" }, "NORD")
      w.run(12000)
      assert(trip.state == "WAITING" and trip.reason:find("busy", 1, true), trip.state .. " " .. tostring(trip.reason))
      w.dispatcher.release_route("OTHER", "R-NS")
      w.run(40000)
      assert(trip.state == "SCHEDULE_APPLIED", trip.state)
    end)
  end
}
