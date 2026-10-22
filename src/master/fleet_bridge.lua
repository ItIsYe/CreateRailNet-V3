--[[
Purpose: The master side of the fleet: route requests of fleet nodes become reservations of the dispatcher, and the fleet hears what became of them from the dispatcher's own state (Gesamtkonzept Kap. 2.1, 8, 24.1).
Public API: new({ dispatcher, network, config, logger, now, train_length(train_id) }) -> bridge.
  bridge.handle(msg) -> true            an event fleet_route | fleet_release | fleet_hold | fleet_reconstruct | fleet_complete of a fleet node (anyone else is taken in and ignored)
  bridge.poll()                         look at the dispatcher and tell the fleet: route_committed, route_eligible, departure_observed, position, arrival_observed, tail_clear (each once)
  bridge.report_blocks()                tell the fleet which blocks can be reserved now (proven free, nobody holds them)
Answers go to both nodes of the pair as events {type = "fleet_event", ev = {...}}. Nothing is claimed that the dispatcher does not know: a reconstruction of a trip the bridge never saw is not answered.
Notes: the fleet's request is a wish, the dispatcher decides (reserve_route; a request that cannot be given is refused with the reason and not queued: the fleet asks again). The phases of the reservation
  (src/domain/reservation_phase.lua) become the answers: COMMITTED_BOTH_DURABLE -> route_committed, ACTUATION_ELIGIBLE and later -> route_eligible. The first block entered is the departure, the
  last block entered is the arrival, and the clearance of the tail is the phase RELEASED_PROVEN (every block of the route proven free).
]]

local fleet_bridge = {}

local PHASE_INDEX = { PROPOSED = 1, VALIDATED = 2, PREPARED_BOTH_DURABLE = 3, COMMITTED_BOTH_DURABLE = 4, ACTUATION_ELIGIBLE = 5, ACTUATED = 6, IN_PROGRESS = 7, CLEARANCE_PENDING = 8, RELEASED_PROVEN = 9 }

local TYPES = { fleet_route = true, fleet_release = true, fleet_hold = true, fleet_reconstruct = true, fleet_complete = true }

function fleet_bridge.new(opts)
  local dispatcher, network, logger = opts.dispatcher, opts.network, opts.logger
  local cfg = opts.config or {}
  local self = {}
  local fleet_nodes, pair_of_node, pair_trains = {}, {}, {}
  for _, node in ipairs(cfg.nodes or {}) do if node.role == "fleet" then fleet_nodes[node.id] = true end end
  for _, pair in ipairs((cfg.fleet and cfg.fleet.pairs) or {}) do
    for _, id in ipairs(pair.nodes or {}) do pair_of_node[id] = pair end
    for _, train_id in ipairs(pair.trains or {}) do pair_trains[train_id] = pair.id end
  end
  local trips = {}        -- trip id -> { train_id, route_id, pair, sent = {...}, last_block, last_state }
  local by_command = {}

  local function tell(pair, ev)
    for _, id in ipairs(pair.nodes) do
      network.send_reliable("event", id, { type = "fleet_event", ev = ev })
    end
  end

  local function refuse(pair, trip_id, reason)
    tell(pair, { type = "route_refused", trip_id = trip_id, reason = reason })
  end

  local function handle_route(msg, pair)
    local p = msg.payload
    if type(p.trip_id) ~= "string" or type(p.train_id) ~= "string" or type(p.route_id) ~= "string" then return end
    local known = trips[p.trip_id]
    if known and by_command[p.command_id] then
      -- the same request came again: say what is true now
      known.sent = {}
      self.poll()
      return
    end
    if pair_trains[p.train_id] ~= pair.id then
      refuse(pair, p.trip_id, "train " .. p.train_id .. " does not belong to pair " .. pair.id)
      return
    end
    local ok, err = dispatcher.reserve_route(p.train_id, p.route_id, { length = opts.train_length and opts.train_length(p.train_id) or nil })
    if not ok then
      refuse(pair, p.trip_id, tostring(err))
      return
    end
    trips[p.trip_id] = { trip_id = p.trip_id, train_id = p.train_id, route_id = p.route_id, pair = pair, sent = {}, platform_block = p.platform_block }
    by_command[p.command_id] = p.trip_id
    self.poll()
  end

  local function handle_release(p)
    local trip = trips[p.trip_id]
    if not trip then return end
    dispatcher.release_route(trip.train_id, trip.route_id)
  end

  local function handle_reconstruct(p)
    local trip = trips[p.trip_id]
    if not trip then return end
    local train = dispatcher.get_trains()[trip.train_id]
    if not train then return end
    local state = "EN_ROUTE"
    if train.state == "ARRIVED" then state = "ARRIVAL_OBSERVED" end
    if not train.current_block and train.state ~= "ARRIVED" then return end
    tell(trip.pair, { type = "reconstruction", trip_id = trip.trip_id, state = state, block = train.current_block, ref = "reconstruct:" .. tostring(train.current_block or "arrived") .. "@" .. tostring(opts.now and opts.now() or 0) })
  end

  function self.handle(msg)
    local p = msg.payload
    if type(p) ~= "table" or not TYPES[p.type] then return true end
    local pair = pair_of_node[msg.src]
    if not pair or not fleet_nodes[msg.src] then return true end
    if p.type == "fleet_route" then handle_route(msg, pair)
    elseif p.type == "fleet_release" then handle_release(p)
    elseif p.type == "fleet_reconstruct" then handle_reconstruct(p) end
    return true
  end

  function self.poll()
    local trains = dispatcher.get_trains()
    local clearing = dispatcher.get_clearing()
    for trip_id, trip in pairs(trips) do
      local train = trains[trip.train_id]
      local sent = trip.sent
      local function once(key, ev)
        if sent[key] then return end
        sent[key] = true
        ev.trip_id = trip_id
        tell(trip.pair, ev)
      end
      if train and train.route == trip.route_id then
        local index = PHASE_INDEX[train.phase or ""] or 0
        if index >= PHASE_INDEX.COMMITTED_BOTH_DURABLE and index < PHASE_INDEX.RELEASED_PROVEN then once("committed", { type = "route_committed", commit_index = train.entry_idx or 0 }) end
        if index >= PHASE_INDEX.ACTUATION_ELIGIBLE and index < PHASE_INDEX.RELEASED_PROVEN then once("eligible", { type = "route_eligible" }) end
        if train.current_block then
          once("departure", { type = "departure_observed", ref = "enter:" .. train.current_block })
          if trip.last_block ~= train.current_block then
            trip.last_block = train.current_block
            tell(trip.pair, { type = "position", trip_id = trip_id, block = train.current_block, observed = true, ref = "enter:" .. train.current_block })
          end
          local block = dispatcher.get_block(train.current_block)
          local route = dispatcher.get_graph().routes[trip.route_id]
          local last = route and route.blocks[#route.blocks]
          if last and train.current_block == last then once("arrival", { type = "arrival_observed", ref = "enter:" .. last }) end
        end
        if train.state == "ARRIVED" and train.phase == "RELEASED_PROVEN" then
          once("departure", { type = "departure_observed", ref = "route finished" })
          once("arrival", { type = "arrival_observed", ref = "route finished" })
          once("tail", { type = "tail_clear", ref = "released:" .. trip.route_id })
        end
      end
      if train and train.route == trip.route_id and train.state == "ARRIVED" and train.phase == "RELEASED_PROVEN" then
        once("tail", { type = "tail_clear", ref = "released:" .. trip.route_id })
      end
      local cleared = trip.train_id and clearing[trip.train_id]
      if not train and not cleared and sent.departure and sent.arrival then once("tail", { type = "tail_clear", ref = "released:" .. trip.route_id }) end
    end
  end

  -- a train arrived at or left a station: every pair hears it (the pair that owns the train acts on it, the others have no such trip)
  function self.on_station_event(payload, station_id)
    local present = payload.type == "train_arrived_station"
    for _, pair in pairs((cfg.fleet and cfg.fleet.pairs) or {}) do
      tell(pair, { type = "station_train", train_id = payload.train_id, station = station_id, present = present, create_name = payload.train_name })
    end
  end

  function self.report_blocks()
    local free = {}
    local overview = dispatcher.get_overview()
    local ids = {}
    for id in pairs(overview) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local block = dispatcher.get_block(id)
      local proven = dispatcher.get_occupancy(id).state == "FREE_PROVEN"
      if block.state == "FREE" and (proven or not dispatcher.proof_mode()) then free[#free + 1] = id end
    end
    for _, pair in pairs(cfg.fleet and cfg.fleet.pairs or {}) do
      for _, id in ipairs(pair.nodes) do network.send_reliable("event", id, { type = "fleet_blocks", free = free }) end
    end
  end

  return self
end

return fleet_bridge
