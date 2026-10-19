--[[
Purpose: The plan builder (src/setup/plan_builder.lua): from the description of a network to the whole network plan -- blocks with their signals
  and detectors, switch ladders at stations with several platforms, routes for every pair of platforms, stations, depots, trains with their
  service plans and the panel. The structure and the names are pinned here; that the dispatcher can really drive every route is in
  tests/test_plan_builder_sim.lua.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local layout = require("src.setup.layout")
local plan_builder = require("src.setup.plan_builder")
local netplan = require("src.setup.netplan")
local validate = require("src.shared.validate")

local function build(text)
  local l, errors = layout.parse(text)
  assert(l, table.concat(errors or {}, "\n"))
  local plan, meta = plan_builder.build(l)
  assert(plan, "build failed: " .. table.concat(meta or {}, "\n"))
  return plan, meta
end

local function by_id(list)
  local map = {}
  for _, item in ipairs(list) do map[item.id] = item end
  return map
end

local function ids(list)
  local out = {}
  for _, item in ipairs(list) do out[#out + 1] = item.id end
  return out
end

local function join(list) return table.concat(list, ",") end

local SIMPLE = "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 2\nzug TRAIN-1 ST-A ST-B ST-A\n"
local THREE = [[
bahnhof ST-A "Station A" passenger
bahnhof ST-B "Station B" mixed 2
bahnhof ST-C "Station C"
depot DEPOT-1 "Depot 1" 2
strecke ST-A ST-B 2
strecke ST-B ST-C 1
strecke ST-B DEPOT-1 1 depot
zug TRAIN-1 "Regio 1" ST-A ST-B:1 ST-C ST-B:2 ST-A
]]

return {
  test_two_stations_one_line_two_blocks = function()
    local plan = build(SIMPLE)
    assert(plan.v == 1 and plan.channel == 777 and plan.master_id == "MASTER-1")
    local blocks = by_id(plan.blocks)
    assert(join(ids(plan.blocks)) == "B-A-B-1,B-A-B-2,B-B-A-1,B-B-A-2", join(ids(plan.blocks)))
    local b = blocks["B-A-B-2"]
    assert(b.entry_signal == "SIG-A-B-2-IN" and b.exit_signal == "SIG-A-B-2-OUT" and join(b.sensors) == "SEN-A-B-2" and #b.switches == 0)
    assert(join(ids(plan.routes)) == "R-A-B,R-B-A")
    local route = by_id(plan.routes)["R-A-B"]
    assert(route.from == "ST-A" and route.to == "ST-B" and join(route.blocks) == "B-A-B-1,B-A-B-2" and route.kind == "passenger" and route.priority == 10)
    assert(join(route.conflict_groups) == "PLAT-ST-A-P1,PLAT-ST-B-P1", join(route.conflict_groups))
    assert(join(by_id(plan.routes)["R-B-A"].blocks) == "B-B-A-1,B-B-A-2")
  end,

  test_every_block_has_its_own_signals_and_detector_as_computers_of_the_plan = function()
    local plan = build(SIMPLE)
    local nodes = by_id(plan.nodes)
    for _, id in ipairs({ "SIG-A-B-1-IN", "SIG-A-B-1-OUT", "SIG-B-A-2-IN", "SIG-B-A-2-OUT" }) do assert(nodes[id] and nodes[id].role == "signal", id) end
    for _, id in ipairs({ "SEN-A-B-1", "SEN-A-B-2", "SEN-B-A-1", "SEN-B-A-2" }) do assert(nodes[id] and nodes[id].role == "sensor", id) end
    -- the hardware the wizard of that computer starts from
    assert(nodes["SIG-A-B-1-IN"].adapter == "peripheral" and nodes["SIG-A-B-1-IN"].peripheral == "Create_Signal_0")
    assert(nodes["SEN-A-B-1"].adapter == "peripheral" and nodes["SEN-A-B-1"].peripheral == "Create_TrainObserver_0")
    local count = 0
    for _, node in ipairs(plan.nodes) do if node.role == "signal" then count = count + 1 end end
    assert(count == 8, count)
  end,

  test_the_plan_is_valid_and_survives_the_file_round_trip = function()
    for _, text in ipairs({ SIMPLE, THREE }) do
      local plan = build(text)
      local ok, errors = validate.validate_config(plan)
      assert(ok, table.concat(errors or {}, "\n"))
      local parsed, problems = netplan.parse(netplan.encode(plan))
      assert(parsed and not problems, table.concat(problems or {}, "\n"))
      assert(#parsed.blocks == #plan.blocks and #parsed.routes == #plan.routes and #parsed.nodes == #plan.nodes)
    end
  end,

  test_the_master_the_panel_the_trains_stations_and_depots_are_nodes = function()
    local plan = build(THREE)
    local nodes = by_id(plan.nodes)
    assert(nodes["MASTER-1"].role == "master" and nodes["PANEL-1"].role == "panel" and nodes["TRAIN-1"].role == "train")
    local train = nodes["TRAIN-1"]
    assert(train.train_id == "TRAIN-1" and train.display_name == "Regio 1" and train.service_plan == "SP-TRAIN-1" and train.create_station == "Create_Station_0")
    local station = nodes["ST-B"]
    assert(station.role == "station" and station.station_type == "mixed" and station.display_name == "Station B" and station.create_station_name == "Station B")
    assert(#station.platforms == 2 and station.platforms[1].id == "P1" and station.platforms[2].id == "P2" and station.platforms[2].kind == "mixed")
    local depot = nodes["DEPOT-1"]
    assert(depot.role == "depot" and depot.display_name == "Depot 1" and #depot.tracks == 2 and depot.tracks[1].id == "D1" and depot.tracks[1].kind == "storage")
    -- the panel can hold and stop every train
    local actions = {}
    for _, a in ipairs(nodes["PANEL-1"].manual_actions) do actions[a.action .. ":" .. tostring(a.train_id)] = true end
    assert(actions["hold_train:TRAIN-1"] and actions["emergency_stop:TRAIN-1"])
  end,

  test_no_panel_when_none_is_wanted = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\npanel nein\n")
    assert(by_id(plan.nodes)["PANEL-1"] == nil)
  end,

  test_channel_and_master_follow_the_description = function()
    local plan = build("kanal 1234\nmaster M-9\nbahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\n")
    assert(plan.channel == 1234 and plan.master_id == "M-9" and by_id(plan.nodes)["M-9"].role == "master")
  end,

  -- ── stations with several platforms: switch ladders ──────────────────────────────────────────────────────────────

  test_a_station_with_two_platforms_gets_approach_blocks_with_a_switch = function()
    local plan = build(THREE)
    local blocks = by_id(plan.blocks)
    local one, two = blocks["B-B-ARR-1"], blocks["B-B-ARR-2"]
    assert(one and two, "one approach block per platform of B, shared by the lines")
    assert(#one.switches == 1 and one.switches[1].id == "SW-B-ARR-1" and one.switches[1].position == "STRAIGHT")
    assert(#two.switches == 1 and two.switches[1].id == "SW-B-ARR-1" and two.switches[1].position == "DIVERGING")
    assert(by_id(plan.nodes)["SW-B-ARR-1"].role == "switch" and by_id(plan.nodes)["SW-B-ARR-1"].adapter == "redstone")
    -- A has one platform: nothing extra
    assert(blocks["B-A-ARR-1"] == nil and blocks["B-A-DEP-1"] == nil)
  end,

  test_routes_exist_for_every_pair_of_platforms = function()
    local plan = build(THREE)
    local routes = by_id(plan.routes)
    -- A (1 platform) -> B (2 platforms)
    assert(join(routes["R-A.1-B.1"].blocks) == "B-A-B-1,B-A-B-2,B-B-ARR-1", join(routes["R-A.1-B.1"].blocks))
    assert(join(routes["R-A.1-B.2"].blocks) == "B-A-B-1,B-A-B-2,B-B-ARR-2")
    -- B has two platforms: a departure block per platform, then the first block of the line
    assert(join(routes["R-B.2-C.1"].blocks) == "B-B-DEP-2,B-B-C-1", join(routes["R-B.2-C.1"].blocks))
    assert(routes["R-B.1-A.1"] and routes["R-B.2-A.1"] and routes["R-B.1-C.1"] and routes["R-C.1-B.1"] and routes["R-C.1-B.2"])
    assert(routes["R-B.1-DEPOT-1.2"] and routes["R-B.2-DEPOT-1.1"], "depot tracks are berths too")
    assert(join(routes["R-C.1-B.1"].blocks) == "B-C-B-1,B-B-ARR-1", "arriving from C shares the approach block of the platform")
    assert(routes["R-A-B"] == nil, "no short name when a station has several platforms")
  end,

  test_the_departure_ladder_selects_the_outgoing_line_on_the_first_block_of_each_line = function()
    local plan = build(THREE)
    local blocks = by_id(plan.blocks)
    local function positions(block)
      local out = {}
      for _, s in ipairs(block.switches) do out[#out + 1] = s.id .. "=" .. s.position end
      return join(out)
    end
    -- B has three lines out of it (A, C, DEPOT-1): two switches, the line is chosen by the positions
    assert(positions(blocks["B-B-A-1"]) == "SW-B-DEP-1=STRAIGHT", positions(blocks["B-B-A-1"]))
    assert(positions(blocks["B-B-C-1"]) == "SW-B-DEP-1=DIVERGING,SW-B-DEP-2=STRAIGHT", positions(blocks["B-B-C-1"]))
    assert(positions(blocks["B-B-DEPOT-1-1"]) == "SW-B-DEP-1=DIVERGING,SW-B-DEP-2=DIVERGING", positions(blocks["B-B-DEPOT-1-1"]))
    -- the second block of a line carries nothing
    assert(#blocks["B-A-B-2"].switches == 0)
    -- the departure blocks of the platforms carry no switch
    assert(#blocks["B-B-DEP-1"].switches == 0 and #blocks["B-B-DEP-2"].switches == 0)
    local routes = by_id(plan.routes)
    assert(join(routes["R-B.1-DEPOT-1.2"].blocks) == "B-B-DEP-1,B-B-DEPOT-1-1,B-DEPOT-1-ARR-2", join(routes["R-B.1-DEPOT-1.2"].blocks))
  end,

  test_three_platforms_make_a_ladder_of_two_switches = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B 3\nstrecke ST-A ST-B\n")
    local blocks = by_id(plan.blocks)
    local function positions(block)
      local out = {}
      for _, s in ipairs(block.switches) do out[#out + 1] = s.id .. "=" .. s.position end
      return join(out)
    end
    assert(positions(blocks["B-B-ARR-1"]) == "SW-B-ARR-1=STRAIGHT")
    assert(positions(blocks["B-B-ARR-2"]) == "SW-B-ARR-1=DIVERGING,SW-B-ARR-2=STRAIGHT")
    assert(positions(blocks["B-B-ARR-3"]) == "SW-B-ARR-1=DIVERGING,SW-B-ARR-2=DIVERGING")
    local switches = 0
    for _, node in ipairs(plan.nodes) do if node.role == "switch" then switches = switches + 1 end end
    assert(switches == 2, "p - 1 switches")
  end,

  test_a_station_that_is_only_left_has_no_arrival_switches = function()
    -- two platforms, but every line leads away from it: nothing arrives, so the ladder of the approach is not built
    local plan = build("bahnhof ST-A 2\nbahnhof ST-B\nstrecke ST-A ST-B 1 passenger einrichtung\n")
    assert(by_id(plan.nodes)["SW-A-ARR-1"] == nil and by_id(plan.blocks)["B-A-ARR-1"] == nil)
    assert(by_id(plan.blocks)["B-A-DEP-1"] and by_id(plan.blocks)["B-A-DEP-2"], "but the platforms have their departure blocks")
    -- the other way round: nothing leaves, the ladder of the approach exists
    local arrive = build("bahnhof ST-A\nbahnhof ST-B 2\nstrecke ST-A ST-B 1 passenger einrichtung\n")
    assert(by_id(arrive.nodes)["SW-B-ARR-1"] and by_id(arrive.nodes)["SW-B-DEP-1"] == nil)
  end,

  test_one_platform_and_one_line_each_way_needs_no_switch_at_all = function()
    local plan = build(SIMPLE)
    for _, node in ipairs(plan.nodes) do assert(node.role ~= "switch") end
    for _, block in ipairs(plan.blocks) do assert(#block.switches == 0) end
  end,

  test_a_station_with_one_platform_and_two_lines_out_has_the_ladder_on_the_first_blocks = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B\nbahnhof ST-C\nstrecke ST-A ST-B\nstrecke ST-A ST-C\n")
    local blocks = by_id(plan.blocks)
    assert(blocks["B-A-DEP-1"] == nil, "one platform: no departure block of its own")
    assert(blocks["B-A-B-1"].switches[1].id == "SW-A-DEP-1" and blocks["B-A-B-1"].switches[1].position == "STRAIGHT")
    assert(blocks["B-A-C-1"].switches[1].id == "SW-A-DEP-1" and blocks["B-A-C-1"].switches[1].position == "DIVERGING")
    -- arrivals at A from two lines merge: no approach blocks, no switch
    assert(blocks["B-A-ARR-1"] == nil)
    assert(join(by_id(plan.routes)["R-A-C"].blocks) == "B-A-C-1")
  end,

  test_platforms_and_depot_tracks_exclude_each_other_by_conflict_groups = function()
    local plan = build(THREE)
    local routes = by_id(plan.routes)
    assert(join(routes["R-A.1-B.2"].conflict_groups) == "PLAT-ST-A-P1,PLAT-ST-B-P2")
    assert(join(routes["R-B.1-DEPOT-1.2"].conflict_groups) == "PLAT-ST-B-P1,PLAT-DEPOT-1-D2", join(routes["R-B.1-DEPOT-1.2"].conflict_groups))
  end,

  -- ── one-way lines, kinds and priorities ───────────────────────────────────────────────────────────────────────────

  test_a_one_way_line_has_only_one_set_of_blocks_and_routes = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 1 passenger einrichtung\n")
    assert(join(ids(plan.blocks)) == "B-A-B-1" and join(ids(plan.routes)) == "R-A-B")
  end,

  test_the_kind_of_a_line_decides_kind_and_priority_of_its_routes = function()
    local plan = build("bahnhof ST-A freight\nbahnhof ST-B freight\ndepot DEPOT-1\nstrecke ST-A ST-B 1 freight\nstrecke ST-B DEPOT-1 1 depot\n")
    local routes = by_id(plan.routes)
    assert(routes["R-A-B"].kind == "freight" and routes["R-A-B"].priority == 5)
    assert(routes["R-B-DEPOT-1"].kind == "depot" and routes["R-B-DEPOT-1"].priority == 5)
    local mixed = build("bahnhof ST-A passenger\nbahnhof ST-B freight\nstrecke ST-A ST-B\n")
    assert(by_id(mixed.routes)["R-A-B"].kind == "mixed" and by_id(mixed.routes)["R-A-B"].priority == 8)
  end,

  -- ── trains and their service plans ────────────────────────────────────────────────────────────────────────────────

  test_a_service_plan_follows_the_stops_over_the_routes_of_the_platforms_chosen = function()
    local plan = build(THREE)
    local sp = plan.service_plans[1]
    assert(sp.id == "SP-TRAIN-1" and sp.train_id == "TRAIN-1" and sp.display_name == "Regio 1" and sp.repeat_plan == true and #sp.stops == 4)
    assert(sp.stops[1].from == "ST-A" and sp.stops[1].to == "ST-B" and sp.stops[1].route_id == "R-A.1-B.1")
    assert(sp.stops[2].from == "ST-B" and sp.stops[2].to == "ST-C" and sp.stops[2].route_id == "R-B.1-C.1")
    assert(sp.stops[3].route_id == "R-C.1-B.2", sp.stops[3].route_id)
    assert(sp.stops[4].route_id == "R-B.2-A.1")
    assert(sp.stops[1].dwell_seconds == 10 and sp.stops[1].kind == "mixed" and sp.stops[1].create_destination == "Station B")
    -- every route of the plan exists
    local routes = by_id(plan.routes)
    for _, stop in ipairs(sp.stops) do assert(routes[stop.route_id], stop.route_id) end
  end,

  test_the_pause_and_the_destination_names_come_from_the_description = function()
    local plan = build('bahnhof ST-A "Nord"\nbahnhof ST-B "Sued"\nstrecke ST-A ST-B\nzug T1 ST-A ST-B pause=25 einmalig\n')
    local sp = plan.service_plans[1]
    assert(sp.repeat_plan == false and #sp.stops == 1 and sp.stops[1].dwell_seconds == 25 and sp.stops[1].create_destination == "Sued")
  end,

  test_a_stop_at_a_depot_waits_no_time_there = function()
    local plan = build("bahnhof ST-A\ndepot DEPOT-1\nstrecke ST-A DEPOT-1\nzug T1 ST-A DEPOT-1 ST-A pause=30\n")
    local sp = plan.service_plans[1]
    assert(sp.stops[1].dwell_seconds == 30 and sp.stops[2].from == "DEPOT-1" and sp.stops[2].dwell_seconds == 0, sp.stops[2].dwell_seconds)
  end,

  test_a_trip_that_does_not_come_back_is_not_repeated_in_the_plan = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-B\nzug T2 ST-A ST-B ST-A\n")
    assert(by_id(plan.service_plans)["SP-T1"].repeat_plan == false and by_id(plan.service_plans)["SP-T2"].repeat_plan == true)
  end,

  test_without_trains_there_is_no_service_plan = function()
    local plan = build("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\n")
    assert(plan.service_plans == nil or #plan.service_plans == 0)
  end,

  -- ── what the builder refuses ──────────────────────────────────────────────────────────────────────────────────────

  test_ids_that_become_too_long_are_refused_with_the_way_out = function()
    local l = assert(layout.parse("bahnhof STATION-NORD-12345\nbahnhof STATION-SUED-12345\nstrecke STATION-NORD-12345 STATION-SUED-12345 3\n"))
    local plan, errors = plan_builder.build(l)
    assert(plan == nil and type(errors) == "table")
    local text = table.concat(errors, "\n")
    assert(text:find("zu lang", 1, true) and text:find("32", 1, true) and text:find("kuerzere", 1, true), text)
  end,

  test_two_stations_with_the_same_short_code_are_refused = function()
    local l = assert(layout.parse("bahnhof ST-A\nbahnhof A\nbahnhof ST-B\nstrecke ST-A ST-B\nstrecke A ST-B\n"))
    local plan, errors = plan_builder.build(l)
    assert(plan == nil and table.concat(errors, "\n"):find("Kurzform A kommt bei ST-A und A doppelt vor", 1, true), table.concat(errors or {}, "\n"))
  end,

  test_a_network_too_large_for_the_transfer_to_the_computers_is_refused = function()
    local lines = {}
    for i = 1, 20 do lines[#lines + 1] = string.format("bahnhof S%02d", i) end
    for i = 1, 20 do lines[#lines + 1] = string.format("strecke S%02d S%02d 12", i, (i % 20) + 1) end
    local l = assert(layout.parse(table.concat(lines, "\n")))
    local plan, errors = plan_builder.build(l)
    assert(plan == nil and table.concat(errors, "\n"):find("zu gross", 1, true), table.concat(errors or {}, "\n"))
  end,

  test_the_result_is_the_same_every_time = function()
    local a = netplan.encode(build(THREE))
    local b = netplan.encode(build(THREE))
    assert(a == b)
  end,

  -- ── what is told about the computers ──────────────────────────────────────────────────────────────────────────────

  test_every_computer_of_the_plan_is_described_for_the_build_list = function()
    local plan, meta = build(THREE)
    assert(#meta.computers == #plan.nodes, #meta.computers .. " vs " .. #plan.nodes)
    local described = by_id(meta.computers)
    for _, node in ipairs(plan.nodes) do
      local item = described[node.id]
      assert(item and item.role == node.role and type(item.what) == "string" and item.what ~= "", node.id)
      assert(type(item.where) == "string", node.id)
    end
    assert(described["SIG-A-B-1-IN"].where:find("A", 1, true) and described["SW-B-ARR-1"].where:find("Bahnsteig", 1, true), described["SW-B-ARR-1"].where)
    assert(meta.stats.blocks == #plan.blocks and meta.stats.routes == #plan.routes and meta.stats.computers == #plan.nodes)
    assert(meta.create_names[1] and meta.create_names[1].name == "Station A")
  end,
}
