--[[
Purpose: The fleet engine: orders become trips, a trip goes from the request to the proven clearance of the tail, and nothing moves without the proofs of Gesamtkonzept Kap. 24.1.
Public API: new(opts) -> engine. opts: id, pair_id, profiles, timetable, pairs, now() (seconds), ids_prefix, platforms (station -> list of platform records of src/domain/track_choice.lua), is_free(block),
  route_timeout_s (120), apply_timeout_s (30), depart_timeout_s (120), retry_s (30), max_refusals (5), cargo_may_check(person).
  engine.tick()                          advance the clock: timetable -> orders, orders -> trips, trips -> next step, timeouts
  engine.event(ev)                       what the world says (see below)
  engine.take_outbox() -> messages       what the fleet asks the world to do (the node sends them reliably)
  engine.request(spec) -> ok, trip_id    a manual request: a wish in NEW_REQUEST, handled like every other order
  engine.cancel(trip_id, who), engine.create_cargo_order(spec), engine.cargo_summary(order_id), engine.trip(id), engine.trips(), engine.trip_for_order(order_id), engine.queue_size(), engine.status()
  engine.snapshot() / engine.restore(snapshot)
Events in: station_train, route_committed, route_eligible, route_refused, schedule_applied, departure_observed, position, arrival_observed, tail_clear, safe_stop_reached, reconstruction, cargo.
Messages out: route_request, apply_schedule, hold_at_waiting_point, reconstruct_request, release_reservation, trip_complete.
Notes: new automatic activity needs a healthy pair (src/fleet/pairs.lua); the orders wait in their queue. The schedule is applied exactly once per trip: a lost answer makes the trip UNCERTAIN and is
  reconstructed from observations, never repeated blindly. A route that is refused makes the trip wait and ask again with a new command id, and after max_refusals the trip is a fault. A restored
  engine continues where it was and does not repeat what it already sent. Pure logic: the node around it carries the messages.
]]

local priority = require("src.fleet.priority")
local trip_module = require("src.fleet.trip")
local cargo_ledger = require("src.fleet.cargo_ledger")
local track_choice = require("src.domain.track_choice")

local engine = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

function engine.new(opts)
  local self = {}
  local now = opts.now
  local profiles, timetable, pairs_ = opts.profiles, opts.timetable, opts.pairs
  local queue = priority.new({ now = now, aging_s = opts.aging_s, max_promotion = opts.max_promotion })
  local ids = trip_module.ids({ prefix = opts.ids_prefix or "F" })
  local cargo = cargo_ledger.new({ may_check = opts.cargo_may_check })
  local trips, by_id = {}, {}
  local outbox = {}
  local auto_blocked = nil
  local route_timeout, apply_timeout, depart_timeout = opts.route_timeout_s or 120, opts.apply_timeout_s or 30, opts.depart_timeout_s or 120
  local retry_s, max_refusals = opts.retry_s or 30, opts.max_refusals or 5

  local function send(message) outbox[#outbox + 1] = message end

  local function add_trip(spec)
    local t = trip_module.new(spec)
    trips[#trips + 1] = t
    by_id[t.trip_id] = t
    return t
  end

  local function busy(train_id)
    for _, t in ipairs(trips) do
      if t.assigned_train == train_id and not trip_module.is_final(t.state) then return true end
    end
    return false
  end

  local function pick_train(spec)
    for _, p in ipairs(profiles.list({ lifecycle = "ACTIVE" })) do
      local id = p.immutable_id
      if (not spec.train_id or spec.train_id == id) and pairs_.owner_of_train(id) == opts.pair_id and not busy(id)
        and profiles.eligible(id, { train_class = spec.train_class, line = spec.line_id, direction = spec.direction }) then
        return id
      end
    end
    return nil
  end

  local function line_spec(line, event)
    local direction = line.direction
    if not direction then
      local names = {}
      for name in pairs(line.routes or {}) do names[#names + 1] = name end
      table.sort(names)
      direction = names[1]
    end
    return {
      origin = line.origin or line.stops[1].station, goal = line.goal or line.stops[#line.stops].station, direction = direction, route_id = (line.routes or {})[direction],
      line_id = line.id, train_class = line.kind, key = event.key, schedule_version = event.version
    }
  end

  -- orders from the clock ---------------------------------------------------------------------------------------------------
  local function intake()
    local result = timetable.due()
    for _, event in ipairs(result.due) do
      local line = timetable.get(event.line_id, event.version)
      local trip_id = trip_module.trip_id_from_key(event.key)
      if line and not by_id[trip_id] and not queue.get("ORD-" .. event.key) then
        local order = { id = "ORD-" .. event.key, kind = event.order_kind, spec = line_spec(line, event), order_id = ids.order(), trip_id = trip_id }
        queue.push(order)
      end
    end
  end

  -- orders to trips ---------------------------------------------------------------------------------------------------------
  local function start_order(order)
    local spec = order.spec
    local train_id = pick_train(spec)
    if not train_id then return false end
    local t = order.trip_id and by_id[order.trip_id]
    if not t then
      t = add_trip({ trip_id = order.trip_id or ids.trip(), order_id = order.order_id, origin = spec.origin, goal = spec.goal, direction = spec.direction, route_id = spec.route_id,
        line_id = spec.line_id, schedule_version = spec.schedule_version, priority_class = order.kind, train_class = spec.train_class, cargo_order_id = spec.cargo_order_id,
        committed_owner_pair = opts.pair_id, requested_by = spec.requested_by })
    end
    t.assigned_train = train_id
    trip_module.advance(t, "VALIDATED_BY_FLEET")
    trip_module.advance(t, "TRAIN_CANDIDATE")
    t.since = now()
    queue.remove(order.id)
    return true
  end

  local function assign_orders()
    while true do
      local order = queue.next(function(o) return pick_train(o.spec) ~= nil end)
      if not order then return end
      if not start_order(order) then return end
    end
  end

  -- one step of one trip ----------------------------------------------------------------------------------------------------
  local function uncertain(t, reason)
    trip_module.uncertain(t, reason)
    send({ type = "reconstruct_request", trip_id = t.trip_id, train_id = t.assigned_train, station = t.origin })
  end

  local function propose_route(t)
    t.leg_id = t.leg_id or ids.leg(t.trip_id)
    t.route_command = ids.command(t.trip_id)
    t.proposed_at = now()
    send({ type = "route_request", trip_id = t.trip_id, leg_id = t.leg_id, command_id = t.route_command, order_id = t.order_id, train_id = t.assigned_train, route_id = t.route_id,
      platform = t.platform, platform_block = t.platform_block, schedule_version = t.schedule_version })
  end

  local function cargo_ready(t)
    if not t.cargo_order_id then return true end
    local ok, why = cargo.may_depart(t.cargo_order_id, now())
    t.hold_reason = (not ok) and why or nil
    return ok
  end

  local function step(t)
    local state = t.state
    if state == "WAITING" then
      if t.retry_at and now() >= t.retry_at then
        local from = t.waiting_from
        trip_module.resume(t)
        t.retry_at = nil
        if from == "ROUTE_PROPOSED" then propose_route(t) end
        state = t.state
      elseif t.waiting_from == "STATION_CONFIRMED" then
        trip_module.resume(t)
        state = t.state
      else
        return
      end
    end
    if state == "STATION_CONFIRMED" then
      local profile = profiles.get(t.assigned_train)
      local best, _, _, wait = track_choice.choose_platform((opts.platforms or {})[t.goal] or {}, { length = profile and profile.length, train_type = t.train_class, direction = t.direction }, { is_free = opts.is_free })
      if best then
        t.platform = best
        for _, platform in ipairs(opts.platforms[t.goal]) do if platform.id == best then t.platform_block = platform.block end end
        trip_module.advance(t, "TARGET_PLATFORM_ASSIGNED")
        state = t.state
      elseif wait then
        trip_module.wait(t, "no free platform at " .. tostring(t.goal))
        send({ type = "hold_at_waiting_point", trip_id = t.trip_id, train_id = t.assigned_train, station = t.goal })
        return
      else
        trip_module.fault(t, "no suitable platform at " .. tostring(t.goal))
        return
      end
    end
    if state == "TARGET_PLATFORM_ASSIGNED" then
      propose_route(t)
      trip_module.advance(t, "ROUTE_PROPOSED")
      return
    end
    if state == "ROUTE_PROPOSED" then
      if t.proposed_at and now() - t.proposed_at >= route_timeout then
        trip_module.wait(t, "the masters did not answer the route request")
        t.retry_at = now()
      end
      return
    end
    if state == "ACTUATOR_ELIGIBLE" then
      if t.apply_command then
        if now() - t.apply_sent_at >= apply_timeout then uncertain(t, "no answer to the schedule call") end
        return
      end
      if not cargo_ready(t) then return end
      t.apply_command = ids.command(t.trip_id)
      t.apply_sent_at = now()
      send({ type = "apply_schedule", trip_id = t.trip_id, leg_id = t.leg_id, command_id = t.apply_command, train_id = t.assigned_train, station = t.origin, destination = t.goal,
        platform = t.platform, route_id = t.route_id, schedule_version = t.schedule_version })
      return
    end
    if state == "SCHEDULE_APPLIED" then
      if now() - (t.applied_at or now()) >= depart_timeout then uncertain(t, "no departure observed after the schedule") end
    end
  end

  function self.tick()
    intake()
    local ok, why = pairs_.auto_allowed(opts.pair_id)
    auto_blocked = (not ok) and why or nil
    if ok then assign_orders() end
    for _, t in ipairs(trips) do
      if not trip_module.is_final(t.state) then step(t) end
    end
  end

  -- what the world says ------------------------------------------------------------------------------------------------------
  local handlers = {}

  function handlers.station_train(ev)
    -- the station knows the train by its Create name; the fleet by its own id
    local profile = profiles.get(ev.train_id) or profiles.by_name(ev.create_name or ev.train_id)
    if not profile then
      profiles.seen(ev.create_name or ev.train_id)
      return
    end
    if not ev.present then return end
    for _, t in ipairs(trips) do
      if t.state == "TRAIN_CANDIDATE" and t.assigned_train == profile.immutable_id and t.origin == ev.station then trip_module.advance(t, "STATION_CONFIRMED") end
    end
  end

  function handlers.route_committed(ev, t)
    if t.state == "ROUTE_PROPOSED" then trip_module.advance(t, "DUAL_MASTER_COMMITTED", { kind = "master_commit", ref = "idx-" .. tostring(ev.commit_index) }) end
  end

  function handlers.route_eligible(ev, t)
    if t.state == "DUAL_MASTER_COMMITTED" then trip_module.advance(t, "ACTUATOR_ELIGIBLE") end
  end

  function handlers.route_refused(ev, t)
    if t.state ~= "ROUTE_PROPOSED" then return end
    t.refusals = (t.refusals or 0) + 1
    if t.refusals > max_refusals then
      trip_module.fault(t, "route refused too often: " .. tostring(ev.reason))
      return
    end
    trip_module.wait(t, tostring(ev.reason))
    t.retry_at = now() + retry_s
  end

  function handlers.schedule_applied(ev, t)
    if t.state ~= "ACTUATOR_ELIGIBLE" or ev.command_id ~= t.apply_command then return end
    if ev.ok then
      trip_module.advance(t, "SCHEDULE_APPLIED", { kind = "schedule_applied", ref = ev.command_id })
      t.applied_at = now()
    else
      uncertain(t, "the schedule call failed: " .. tostring(ev.reason))
    end
  end

  function handlers.departure_observed(ev, t)
    if t.state == "SCHEDULE_APPLIED" then trip_module.advance(t, "DEPARTURE_OBSERVED", { kind = "departure_observation", ref = ev.ref }) end
  end

  function handlers.position(ev, t)
    if t.state == "DEPARTURE_OBSERVED" then trip_module.advance(t, "EN_ROUTE") end
    if t.state == "EN_ROUTE" or t.state == "DEPARTURE_OBSERVED" then
      trip_module.record_position(t, { block = ev.block, at = now(), quality = ev.observed and "observed" or "reported" })
    end
  end

  function handlers.arrival_observed(ev, t)
    if t.state == "DEPARTURE_OBSERVED" then trip_module.advance(t, "EN_ROUTE") end
    if t.state == "EN_ROUTE" then trip_module.advance(t, "ARRIVAL_OBSERVED", { kind = "arrival_observation", ref = ev.ref }) end
  end

  function handlers.tail_clear(ev, t)
    if t.state == "ARRIVAL_OBSERVED" then
      trip_module.advance(t, "TAIL_CLEARANCE_PROVEN", { kind = "tail_clearance", ref = ev.ref })
      trip_module.advance(t, "COMPLETE")
      send({ type = "trip_complete", trip_id = t.trip_id, train_id = t.assigned_train })
    end
  end

  function handlers.safe_stop_reached(ev, t)
    if t.state == "CANCEL_PENDING" then
      trip_module.advance(t, "CANCELLED", { kind = "safe_stop_reached", ref = ev.ref })
      send({ type = "release_reservation", trip_id = t.trip_id, leg_id = t.leg_id, train_id = t.assigned_train })
    end
  end

  function handlers.reconstruction(ev, t)
    if trip_module.reconstruct(t, ev.state, { kind = "position_observation", ref = ev.ref }) and ev.block then
      trip_module.record_position(t, { block = ev.block, at = now(), quality = "observed" })
    end
  end

  function self.event(ev)
    if ev.type == "cargo" then
      cargo.report({ order_id = ev.order_id, shipment_id = ev.shipment_id, kind = ev.kind, qty = ev.qty, quality = ev.quality, ref = ev.ref, by = ev.by })
      return
    end
    local handler = handlers[ev.type]
    if not handler then return end
    if ev.type == "station_train" then return handler(ev) end
    local t = ev.trip_id and by_id[ev.trip_id]
    if t then handler(ev, t) end
  end

  function self.take_outbox()
    local out = outbox
    outbox = {}
    return out
  end

  function self.request(spec)
    local order_id = ids.order()
    local trip_id = ids.trip()
    local kind = (spec.train_class == "FREIGHT") and "EXTRA_FREIGHT" or "EXTRA_PASSENGER"
    local t = add_trip({ trip_id = trip_id, order_id = order_id, origin = spec.origin, goal = spec.goal, direction = spec.direction, route_id = spec.route_id, line_id = spec.line_id,
      priority_class = kind, train_class = spec.train_class, origin_kind = "manual", requested_by = spec.requested_by, committed_owner_pair = opts.pair_id })
    local ok, err = queue.push({ id = "ORD-" .. trip_id, kind = kind, spec = spec, order_id = order_id, trip_id = trip_id, manual = true })
    if not ok then return false, err end
    return true, trip_id, t
  end

  function self.cancel(trip_id, who)
    local t = by_id[trip_id]
    if not t then return false, "unknown trip" end
    local had_route = t.leg_id ~= nil
    queue.remove("ORD-" .. trip_id)
    local ok, err = trip_module.cancel(t, who)
    if ok and t.state == "CANCELLED" and had_route then send({ type = "release_reservation", trip_id = t.trip_id, leg_id = t.leg_id, train_id = t.assigned_train }) end
    return ok, err
  end

  function self.create_cargo_order(spec)
    local ok, err = cargo.create_order(spec)
    if not ok then return false, err end
    local order = { id = "ORD-" .. spec.id, kind = "SCHEDULED_FREIGHT", order_id = ids.order(),
      spec = { origin = spec.origin, goal = spec.goal, direction = spec.direction, route_id = spec.route_id, train_class = spec.train_class or "FREIGHT", cargo_order_id = spec.id } }
    return queue.push(order)
  end

  function self.cargo_summary(order_id) return cargo.summary(order_id) end
  function self.trip(id) return by_id[id] end
  function self.trips() return trips end
  function self.trip_for_order(order_id)
    for _, t in ipairs(trips) do if t.cargo_order_id == order_id then return t end end
    return nil
  end
  function self.queue_size() return queue.size() end
  function self.status() return { auto_blocked = auto_blocked, queued = queue.size(), trips = #trips } end

  function self.snapshot()
    local snap = { queue = queue.snapshot(), ids = ids.snapshot(), cargo = cargo.snapshot(), trips = {}, profiles = profiles.snapshot(), timetable = timetable.snapshot(), pairs = pairs_.snapshot() }
    for i, t in ipairs(trips) do snap.trips[i] = trip_module.snapshot(t) end
    return snap
  end

  function self.restore(snap)
    queue.restore(snap.queue)
    ids = trip_module.ids({ prefix = opts.ids_prefix or "F", state = snap.ids })
    cargo.restore(snap.cargo)
    profiles.restore(snap.profiles)
    timetable.restore(snap.timetable)
    pairs_.restore(snap.pairs)
    trips, by_id = {}, {}
    for _, saved in ipairs(snap.trips or {}) do
      local t = trip_module.restore(saved)
      trips[#trips + 1] = t
      by_id[t.trip_id] = t
    end
    outbox = {}
  end

  return self
end

return engine
