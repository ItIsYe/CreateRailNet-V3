--[[
Purpose: Shared fixture for dispatcher property and chaos tests: seeded topology generator, step functions and invariants.
Public API: new(seed, opts) -> world, close(world), step_legal(world), step_chaos(world), violation(world, opts) -> string | nil,
  recent(world, count) -> the last operations as text.
Notes: new() replaces os.clock with the world's synthetic clock (the sensor guard measures event age with it) so runs are
  deterministic; close() puts the real one back.
Notes: opts.chaos relaxes the checks that only hold for legal call sequences (blocks may be FAULT after garbage input).
]]

local dispatcher = require("src.master.dispatcher")
local prng = require("tests.harness.prng")

local STATES = dispatcher.STATES
local TRAIN_STATES = dispatcher.TRAIN_STATES
local TRAIN_IDS = { "T1", "T2", "T3", "T4" }

local world_mod = {}

local function build_config(rng)
  local nblocks = rng.int(4, 8)
  local blocks = {}
  for i = 1, nblocks do
    local switches = {}
    if rng.chance(0.4) then switches[1] = { id = "SW-" .. rng.int(1, 3), position = rng.pick({ "STRAIGHT", "DIVERGING" }) } end
    blocks[i] = { id = "B" .. i, entry_signal = "SE" .. i, exit_signal = "SX" .. i, sensors = { "SEN-" .. i }, switches = switches }
  end
  local stations = { "A", "B", "C" }
  local routes = {}
  for r = 1, rng.int(4, 9) do
    local used, chosen = {}, {}
    local length = rng.int(1, math.min(3, nblocks))
    while #chosen < length do
      local b = rng.int(1, nblocks)
      if not used[b] then used[b] = true; chosen[#chosen + 1] = "B" .. b end
    end
    local from = rng.pick(stations)
    local to = rng.pick(stations)
    while to == from do to = rng.pick(stations) end
    routes[r] = { id = "R" .. r, from = from, to = to, blocks = chosen, priority = rng.int(0, 10) }
  end
  return { sensor_guard_min_occupy_ms = 0, blocks = blocks, routes = routes }
end

function world_mod.new(seed, opts)
  local rng = prng.new(seed)
  local cfg = build_config(rng)
  local aspects = {}
  local adapters = {
    signals = { setAspect = function(id, aspect) aspects[id] = aspect; return true end },
    switches = { setPosition = function() return true end }
  }
  local route_by_id = {}
  for _, route in ipairs(cfg.routes) do route_by_id[route.id] = route end
  local world = { rng = rng, cfg = cfg, aspects = aspects, routes = route_by_id, clock = 0, log = {}, chaos = opts and opts.chaos or false }
  world.real_clock = os.clock
  os.clock = function() return world.clock / 1000 end
  world.d = dispatcher.new(cfg, adapters)
  return world
end

function world_mod.close(world)
  if world.real_clock then os.clock = world.real_clock; world.real_clock = nil end
end

local function active(train)
  return train and (train.state == TRAIN_STATES.RESERVED or train.state == TRAIN_STATES.RUNNING)
end

-- a train that timed out keeps its locks on purpose, see dispatcher.timeout_node
local function holds_locks(train)
  return active(train) or (train and train.state == TRAIN_STATES.FAULT)
end

local function route_has_block(world, route_id, block_id)
  local route = world.routes[route_id]
  for _, id in ipairs(route and route.blocks or {}) do if id == block_id then return true end end
  return false
end

-- Returns nil when all invariants hold, otherwise a description of the first violation.
function world_mod.violation(world, opts)
  local chaos = opts and opts.chaos
  local d = world.d
  local trains = d.get_trains()

  for _, block_def in ipairs(world.cfg.blocks) do
    local b = d.get_block(block_def.id)
    if b.state == STATES.FREE and (b.reserved_by or b.occupied_by) then return "FREE block " .. b.id .. " has an owner" end
    if b.state == STATES.RESERVED and (not b.reserved_by or b.occupied_by) then return "RESERVED block " .. b.id .. " has inconsistent owner fields" end
    if b.state == STATES.OCCUPIED and (not b.occupied_by or b.reserved_by) then return "OCCUPIED block " .. b.id .. " has inconsistent owner fields" end
    if b.state == STATES.FAULT and not chaos then return "block " .. b.id .. " went FAULT in a legal sequence" end

    local owner = b.state ~= STATES.FAULT and (b.reserved_by or b.occupied_by) or nil
    if owner then
      local t = trains[owner]
      -- a timed-out train (FAULT) keeps its blocks on purpose: it may still be standing on them
      local holds_legally = active(t) or (chaos and t and t.state == TRAIN_STATES.FAULT)
      if not holds_legally then return "block " .. b.id .. " owned by " .. tostring(owner) .. " who has no active route" end
      if not route_has_block(world, t.route, b.id) then return "block " .. b.id .. " owned by " .. owner .. " outside its route " .. tostring(t.route) end
    end

    local entry = world.aspects[b.entry_signal]
    if b.state == STATES.FAULT and (entry == "GREEN" or entry == "YELLOW") then
      return "FAULT block " .. b.id .. " shows " .. entry .. " on " .. b.entry_signal
    end
    if entry == "GREEN" or entry == "YELLOW" then
      local t = b.state == STATES.RESERVED and trains[b.reserved_by] or nil
      local route = t and world.routes[t.route]
      if not (t and t.state == TRAIN_STATES.RESERVED and route and route.blocks[t.route_index] == b.id) then
        return "entry signal " .. b.entry_signal .. " shows " .. entry .. " but block " .. b.id .. " is not the next reserved block of a waiting train"
      end
    end
    local exit_aspect = world.aspects[b.exit_signal]
    if exit_aspect ~= nil and exit_aspect ~= "RED" then return "exit signal " .. b.exit_signal .. " shows " .. tostring(exit_aspect) end
  end

  for id, t in pairs(trains) do
    if active(t) then
      local route = world.routes[t.route]
      for i = t.route_index, #route.blocks do
        local b = d.get_block(route.blocks[i])
        if b.state ~= STATES.FAULT and b.reserved_by ~= id and b.occupied_by ~= id then return "train " .. id .. " lost block " .. b.id .. " ahead of it (index " .. i .. ")" end
      end
      if t.state == TRAIN_STATES.RESERVED then
        local b = d.get_block(route.blocks[t.route_index])
        local aspect = world.aspects[b.entry_signal]
        if b.state == STATES.RESERVED and b.reserved_by == id and aspect ~= "GREEN" and aspect ~= "YELLOW" then
          return "train " .. id .. " waits on reserved block " .. b.id .. " but its entry signal shows " .. tostring(aspect)
        end
      end
    end
  end

  local locks = d.get_switch_locks()
  for switch_id, lock in pairs(locks) do
    local found = false
    for id, t in pairs(trains) do
      if holds_locks(t) and lock.owner == id .. ":" .. t.route then found = true end
    end
    if not found then return "switch lock " .. switch_id .. " leaked to " .. tostring(lock.owner) end
  end

  for group, entry in pairs(d.get_conflicts()) do
    if not holds_locks(trains[entry.train_id]) then return "conflict group " .. group .. " still held by inactive train " .. tostring(entry.train_id) end
  end
  for id, t in pairs(trains) do
    if active(t) then
      for _, group in ipairs(t.conflict_groups or {}) do
        if not d.get_conflicts()[group] then return "train " .. id .. " is active but conflict group " .. group .. " is not held" end
      end
    end
  end

  for _, item in ipairs(d.get_queue()) do
    local t = trains[item.train_id]
    if not t or (t.state ~= TRAIN_STATES.QUEUED and t.state ~= TRAIN_STATES.ARRIVED and not active(t)) then return "queued train " .. item.train_id .. " has state " .. tostring(t and t.state) end
  end
  return nil
end

local function sensor_of(block_id) return "SEN-" .. block_id:sub(2) end

function world_mod.step_legal(world)
  local rng, d = world.rng, world.d
  world.clock = world.clock + 1000
  local trains = d.get_trains()
  local roll = rng.int(1, 100)

  if roll <= 35 then
    local idle = {}
    for _, id in ipairs(TRAIN_IDS) do
      local t = trains[id]
      if not t or t.state == TRAIN_STATES.ARRIVED then idle[#idle + 1] = id end
    end
    if #idle > 0 then
      local id = rng.pick(idle)
      d.request_route(id, rng.pick(world.cfg.routes).id)
    end
  elseif roll <= 60 then
    local waiting = {}
    for id, t in pairs(trains) do
      if t.state == TRAIN_STATES.RESERVED then waiting[#waiting + 1] = id end
    end
    table.sort(waiting)
    if #waiting > 0 then
      local id = rng.pick(waiting)
      local t = trains[id]
      local block_id = world.routes[t.route].blocks[t.route_index]
      local b = d.get_block(block_id)
      if b.state == STATES.RESERVED and b.reserved_by == id then
        local ok, err = d.on_sensor_event_by_sensor(sensor_of(block_id), "enter", world.clock)
        assert(ok or world.chaos, "legal enter was rejected: " .. tostring(err))
      end
    end
  elseif roll <= 85 then
    local running = {}
    for id, t in pairs(trains) do
      if t.state == TRAIN_STATES.RUNNING and t.current_block then running[#running + 1] = id end
    end
    table.sort(running)
    if #running > 0 then
      local id = rng.pick(running)
      local ok, err = d.on_sensor_event_by_sensor(sensor_of(trains[id].current_block), "leave", world.clock)
      assert(ok or world.chaos, "legal leave was rejected: " .. tostring(err))
    end
  elseif roll <= 93 then
    d.process_queue()
  else
    local done = {}
    for id, t in pairs(trains) do
      if t.state == TRAIN_STATES.ARRIVED then done[#done + 1] = id end
    end
    table.sort(done)
    if #done > 0 then
      local id = rng.pick(done)
      d.release_route(id, trains[id].route)
    end
  end
end


-- Garbage and misuse: out-of-order sensor events, repeated or conflicting requests from busy trains, node timeouts,
-- snapshot round trips. Only safety invariants are expected to survive.
function world_mod.step_chaos(world)
  local rng, d = world.rng, world.d
  world.clock = world.clock + rng.int(0, 1500)
  local roll = rng.int(1, 100)
  local sensor = "SEN-" .. rng.int(1, #world.cfg.blocks)

  local function note(text) world.log[#world.log + 1] = text end

  if roll <= 25 then
    local id, route = rng.pick(TRAIN_IDS), rng.pick(world.cfg.routes)
    note("request " .. id .. " " .. route.id .. " [" .. table.concat(route.blocks, ",") .. "]")
    d.request_route(id, route.id)
  elseif roll <= 50 then
    local action = rng.chance(0.5) and "enter" or "leave"
    note(action .. " " .. sensor)
    d.on_sensor_event_by_sensor(sensor, action, world.clock)
  elseif roll <= 60 then
    note("legal step")
    world_mod.step_legal(world)
  elseif roll <= 70 then
    note("process_queue")
    d.process_queue()
  elseif roll <= 76 then
    local id = rng.pick(TRAIN_IDS)
    note("release_route " .. id)
    d.release_route(id, nil)
  elseif roll <= 80 then
    local node = rng.pick({ sensor, "SE" .. rng.int(1, 4), "SW-" .. rng.int(1, 3), "T1", "T2", "nobody" })
    note("timeout_node " .. node)
    d.timeout_node(node)
  elseif roll <= 86 then
    note("snapshot/restore")
    d.restore(d.snapshot())
  else
    local block, action = "B" .. rng.int(1, #world.cfg.blocks + 1), rng.chance(0.5) and "enter" or "leave"
    note("stale " .. action .. " " .. block)
    d.on_sensor_event(block, action, sensor, world.clock - rng.int(0, 20000))
  end
end

-- the last operations, for failure messages
function world_mod.recent(world, count)
  local from = math.max(1, #world.log - (count or 8) + 1)
  return table.concat(world.log, " | ", from, #world.log)
end

return world_mod
