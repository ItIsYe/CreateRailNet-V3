--[[
Purpose: The plans of the plan builder against the real dispatcher: every route can be reserved and driven block by block with detector events to its
  end, with the switches and signals as the plan says; trains follow their service plans leg after leg; opposite trains, trains for one platform and
  trains that need a switch in different positions exclude each other; and seeded random traffic over the generated networks keeps every safety
  invariant of tests/harness/dispatcher_world.lua and always ends with an empty queue (no route that can never be granted).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local layout = require("src.setup.layout")
local plan_builder = require("src.setup.plan_builder")
local world_mod = require("tests.harness.dispatcher_world")
local prng = require("tests.harness.prng")

local STATES = world_mod.STATES or require("src.master.dispatcher").STATES
local TRAIN_STATES = require("src.master.dispatcher").TRAIN_STATES

local NETWORKS = {
  simple = "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 2\nzug TRAIN-1 ST-A ST-B ST-A\n",
  three = [[
bahnhof ST-A "Station A" passenger
bahnhof ST-B "Station B" mixed 2
bahnhof ST-C "Station C"
depot DEPOT-1 "Depot 1" 2
strecke ST-A ST-B 2
strecke ST-B ST-C 1
strecke ST-B DEPOT-1 1 depot
zug TRAIN-1 "Regio 1" ST-A ST-B:1 ST-C ST-B:2 ST-A
zug TRAIN-2 "Fracht" ST-C ST-B:2 DEPOT-1:2 ST-B:1 ST-C
]],
  big = [[
bahnhof ST-A "A" passenger 3
bahnhof ST-B "B" mixed 2
bahnhof ST-C "C" freight 2
depot DEPOT-1 "Depot" 3
strecke ST-A ST-B 2
strecke ST-B ST-C 2
strecke ST-C ST-A 3 mixed einrichtung
strecke ST-B DEPOT-1 1 depot
zug T1 ST-A:1 ST-B:2 ST-C:1 ST-A:3
]],
}

local function plan_of(name)
  local l, errors = layout.parse(NETWORKS[name])
  assert(l, table.concat(errors or {}, "\n"))
  local plan, meta = plan_builder.build(l)
  assert(plan, table.concat(meta or {}, "\n"))
  plan.sensor_guard_min_occupy_ms = 0
  return plan
end

local function new_world(plan)
  return world_mod.from_config(plan, { strict = true })
end

local function sensor_of(world, block_id)
  for _, block in ipairs(world.cfg.blocks) do if block.id == block_id then return block.sensors[1] end end
  error("no block " .. block_id)
end

local function check(world, what)
  local broken = world_mod.violation(world)
  assert(not broken, what .. ": " .. tostring(broken))
end

local function event(world, block_id, action)
  world.clock = world.clock + 1000
  local ok, err = world.d.on_sensor_event_by_sensor(sensor_of(world, block_id), action, world.clock)
  assert(ok, action .. " " .. block_id .. ": " .. tostring(err))
end

-- reserves the route for the train and checks what the plan promises; then drives it to its end
local function reserve(world, train, route)
  local ok, err = world.d.request_route(train, route.id)
  assert(ok, route.id .. " was not granted: " .. tostring(err))
  check(world, "after reserving " .. route.id)
  local locks = world.d.get_switch_locks()
  for _, block_id in ipairs(route.blocks) do
    for _, def in ipairs(world.d.get_block(block_id).switches or {}) do
      assert(locks[def.id] and locks[def.id].position == def.position, route.id .. ": switch " .. def.id .. " should be " .. def.position)
    end
  end
  local first = world.d.get_block(route.blocks[1])
  local aspect = world.aspects[first.entry_signal]
  assert(aspect == "GREEN" or aspect == "YELLOW", route.id .. ": the entry signal of " .. first.id .. " shows " .. tostring(aspect))
end

-- loose: other trains wait in the queue and may be granted the moment this one is done, so the table of locks need not be empty
local function run(world, train, route, loose)
  for _, block_id in ipairs(route.blocks) do
    event(world, block_id, "enter"); check(world, route.id .. " enter " .. block_id)
    event(world, block_id, "leave"); check(world, route.id .. " leave " .. block_id)
  end
  local record = world.d.get_trains()[train]
  assert(record and record.state == TRAIN_STATES.ARRIVED, route.id .. ": the train did not arrive: " .. tostring(record and record.state))
  for _, block_id in ipairs(route.blocks) do
    local block = world.d.get_block(block_id)
    assert(block.state == STATES.FREE or loose, route.id .. ": block " .. block_id .. " is not free at the end")
  end
  if loose then return end
  for _, block_id in ipairs(route.blocks) do
    assert(world.aspects[world.d.get_block(block_id).entry_signal] == "RED", route.id .. ": signal of " .. block_id .. " is not red at the end")
  end
  assert(next(world.d.get_switch_locks()) == nil, route.id .. ": a switch lock is left over")
  assert(next(world.d.get_conflicts()) == nil, route.id .. ": a conflict group is left over")
end

return {
  test_every_route_of_every_generated_network_can_be_driven_to_its_end = function()
    for name in pairs(NETWORKS) do
      local plan = plan_of(name)
      local world = new_world(plan)
      for _, route in ipairs(plan.routes) do
        reserve(world, "T1", route)
        run(world, "T1", route)
      end
      world_mod.close(world)
    end
  end,

  test_trains_follow_their_service_plans_leg_after_leg_for_several_rounds = function()
    for name in pairs(NETWORKS) do
      local plan = plan_of(name)
      local routes = {}
      for _, route in ipairs(plan.routes) do routes[route.id] = route end
      local world = new_world(plan)
      for _, sp in ipairs(plan.service_plans or {}) do
        for round = 1, 3 do
          for _, stop in ipairs(sp.stops) do
            local route = assert(routes[stop.route_id], stop.route_id)
            reserve(world, sp.train_id, route)
            run(world, sp.train_id, route)
          end
        end
      end
      world_mod.close(world)
    end
  end,

  test_the_routes_a_service_plan_names_chain_end_to_start = function()
    -- a train that arrives at platform j of a station leaves from platform j: the route of the next leg starts where the last one ended
    for name in pairs(NETWORKS) do
      local plan = plan_of(name)
      local routes = {}
      for _, route in ipairs(plan.routes) do routes[route.id] = route end
      for _, sp in ipairs(plan.service_plans or {}) do
        for i = 1, #sp.stops - 1 do
          local a, b = routes[sp.stops[i].route_id], routes[sp.stops[i + 1].route_id]
          assert(a.to == b.from, sp.id .. ": leg " .. i .. " ends at " .. a.to .. " but leg " .. (i + 1) .. " starts at " .. b.from)
          -- the platform group of the arrival is the group of the departure
          assert(a.conflict_groups[2] == b.conflict_groups[1], sp.id .. ": leg " .. i .. " arrives at " .. a.conflict_groups[2] .. " and leg " .. (i + 1) .. " leaves from " .. b.conflict_groups[1])
        end
      end
    end
  end,

  -- ── what must exclude each other ──────────────────────────────────────────────────────────────────────────────────

  test_opposite_trains_on_one_line_exclude_each_other = function()
    local plan = plan_of("simple")
    local world = new_world(plan)
    assert(world.d.request_route("T1", "R-A-B"))
    local ok = world.d.request_route("T2", "R-B-A")
    assert(ok == false, "the opposite direction waits")
    check(world, "with a train waiting")
    world_mod.close(world)
  end,

  test_two_trains_for_one_platform_exclude_each_other_and_the_second_follows = function()
    local plan = plan_of("three")
    local world = new_world(plan)
    assert(world.d.request_route("T1", "R-A.1-B.2"))
    assert(world.d.request_route("T2", "R-C.1-B.2") == false, "same platform B.2")
    assert(world.d.request_route("T3", "R-C.1-B.1") == false, "the switch of the approach would have to be in two positions")
    -- the first one arrives; the queue lets the others follow, one after the other
    local route = nil
    for _, r in ipairs(plan.routes) do if r.id == "R-A.1-B.2" then route = r end end
    run(world, "T1", route, true)
    -- the queue already ran when the first train left its last block (the dispatcher grants one waiting request then)
    local granted = world.d.process_queue()
    local trains = world.d.get_trains()
    local running = 0
    for _, t in pairs(trains) do if t.state == TRAIN_STATES.RESERVED then running = running + 1 end end
    assert(running >= 1, "somebody was granted after the first has arrived (" .. #granted .. " more in this round)")
    check(world, "after the queue ran")
    world_mod.close(world)
  end,

  test_routes_that_share_nothing_may_run_at_the_same_time = function()
    local plan = plan_of("three")
    local world = new_world(plan)
    assert(world.d.request_route("T1", "R-A.1-B.1"))
    -- B.2 leaving towards C: other platform, other switches, other blocks
    assert(world.d.request_route("T2", "R-B.2-C.1"), "departure from platform 2 while platform 1 is being entered")
    check(world, "with two trains on their way")
    world_mod.close(world)
  end,

  test_trains_to_two_platforms_over_one_throat_need_the_ladder_in_different_positions = function()
    local plan = plan_of("big")
    local world = new_world(plan)
    assert(world.d.request_route("T1", "R-A.1-B.1"))
    assert(world.d.request_route("T2", "R-C.1-B.2") == false, "SW-B-ARR-1 is locked STRAIGHT by the first")
    world_mod.close(world)
  end,

  -- ── random traffic ────────────────────────────────────────────────────────────────────────────────────────────────

  test_random_traffic_over_the_generated_networks_keeps_the_invariants_and_never_blocks_for_good = function()
    local TRAINS = { "T1", "T2", "T3", "T4" }
    for name in pairs(NETWORKS) do
      for seed = 1, 12 do
        local plan = plan_of(name)
        local world = new_world(plan)
        world.rng = prng.new(seed * 31 + #name)
        local d, rng = world.d, world.rng
        local routes = plan.routes
        local function blame(step, text) return string.format("%s seed %d step %d: %s", name, seed, step, text) end

        -- a train on its way takes the next step: enter the block it waits for, or leave the one it is in
        local function advance(trains)
          local moving = {}
          for id, t in pairs(trains) do
            if t.state == TRAIN_STATES.RESERVED or (t.state == TRAIN_STATES.RUNNING and t.current_block) then moving[#moving + 1] = id end
          end
          table.sort(moving)
          if #moving == 0 then return false end
          local id = rng.pick(moving)
          local t = trains[id]
          local route
          for _, r in ipairs(routes) do if r.id == t.route then route = r end end
          if t.state == TRAIN_STATES.RESERVED then event(world, route.blocks[t.route_index], "enter")
          else event(world, t.current_block, "leave") end
          return true
        end

        for step = 1, 140 do
          local ok, err = pcall(function()
            local trains = d.get_trains()
            local roll = rng.int(1, 100)
            if roll <= 30 then
              local idle = {}
              for _, id in ipairs(TRAINS) do
                local t = trains[id]
                if not t or t.state == TRAIN_STATES.ARRIVED then idle[#idle + 1] = id end
              end
              if #idle > 0 then d.request_route(rng.pick(idle), rng.pick(routes).id) end
            elseif roll <= 85 then
              advance(trains)
            elseif roll <= 93 then
              d.process_queue()
            else
              for _, id in ipairs(TRAINS) do
                local t = trains[id]
                if t and t.state == TRAIN_STATES.ARRIVED then d.release_route(id, t.route); break end
              end
            end
          end)
          assert(ok, blame(step, tostring(err)))
          check(world, blame(step, "invariant"))
        end

        -- finish everything: nobody waits for ever
        for round = 1, 400 do
          local trains = d.get_trains()
          if not advance(trains) then
            d.process_queue()
            if #d.get_queue() == 0 and not advance(d.get_trains()) then break end
          end
          check(world, blame(1000 + round, "while finishing"))
        end
        assert(#d.get_queue() == 0, blame(0, "the queue is not empty at the end: " .. tostring(d.get_queue()[1] and d.get_queue()[1].route_id)))
        for _, t in pairs(d.get_trains()) do assert(t.state == TRAIN_STATES.ARRIVED, blame(0, "a train is stuck in " .. t.state)) end
        world_mod.close(world)
      end
    end
  end,
}
