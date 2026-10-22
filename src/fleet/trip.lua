--[[
Purpose: The life of a trip of the fleet from the request to the proven clearance of the tail (Gesamtkonzept Kap. 8.4, 24.1) and the ids of orders, trips, legs and commands.
Public API: new(spec) -> trip record; advance(trip, to, evidence) -> ok | false, err; wait(trip, reason); resume(trip); uncertain(trip, reason); reconstruct(trip, to, evidence); fault(trip, reason);
  cancel(trip, who); may_move(trip); is_final(state); record_position(trip, pos); position_view(trip, now, max_age); snapshot(trip); restore(saved);
  ids({ prefix, state }) -> { order(), trip(), leg(trip_id), command(trip_id), snapshot() }; trip_id_from_key(key).
States: NEW_REQUEST, VALIDATED_BY_FLEET, TRAIN_CANDIDATE, STATION_CONFIRMED, TARGET_PLATFORM_ASSIGNED, ROUTE_PROPOSED, DUAL_MASTER_COMMITTED, ACTUATOR_ELIGIBLE, SCHEDULE_APPLIED, DEPARTURE_OBSERVED,
  EN_ROUTE, ARRIVAL_OBSERVED, TAIL_CLEARANCE_PROVEN, COMPLETE; side states WAITING, UNCERTAIN, FAULT, CANCEL_PENDING, CANCELLED.
Notes: no state is skipped. A manual request is a wish (NEW_REQUEST), never a command. The steps that state a physical fact need evidence of the right kind: an accepted schedule is not a departure.
  Before the schedule is applied a missing proof means WAITING (and resuming); afterwards the train may be moving and a missing proof means UNCERTAIN, which is reconstructed from an observation, not resumed.
  A trip that is moving is cancelled only at a proven safe stop: CANCEL_PENDING keeps its reservations. The position shown is the last observed one and says when it is stale.
]]

local trip = {}

local CHAIN = { "NEW_REQUEST", "VALIDATED_BY_FLEET", "TRAIN_CANDIDATE", "STATION_CONFIRMED", "TARGET_PLATFORM_ASSIGNED", "ROUTE_PROPOSED", "DUAL_MASTER_COMMITTED", "ACTUATOR_ELIGIBLE",
  "SCHEDULE_APPLIED", "DEPARTURE_OBSERVED", "EN_ROUTE", "ARRIVAL_OBSERVED", "TAIL_CLEARANCE_PROVEN", "COMPLETE" }
local INDEX = {}
for i, state in ipairs(CHAIN) do INDEX[state] = i end
local APPLIED_INDEX = INDEX.SCHEDULE_APPLIED

local NEEDS = {
  DUAL_MASTER_COMMITTED = "master_commit",
  SCHEDULE_APPLIED = "schedule_applied",
  DEPARTURE_OBSERVED = "departure_observation",
  ARRIVAL_OBSERVED = "arrival_observation",
  TAIL_CLEARANCE_PROVEN = "tail_clearance"
}

local SIDE = { WAITING = true, UNCERTAIN = true, FAULT = true, CANCEL_PENDING = true, CANCELLED = true }
local MOVING = { SCHEDULE_APPLIED = true, DEPARTURE_OBSERVED = true, EN_ROUTE = true }
local RECONSTRUCT_TO = { DEPARTURE_OBSERVED = true, EN_ROUTE = true, ARRIVAL_OBSERVED = true, TAIL_CLEARANCE_PROVEN = true }

function trip.is_final(state) return state == "COMPLETE" or state == "CANCELLED" end

function trip.new(spec)
  local t = {}
  for k, v in pairs(spec or {}) do t[k] = v end
  t.state = "NEW_REQUEST"
  t.history = { "NEW_REQUEST" }
  t.evidence = {}
  t.applied = false
  return t
end

local function enter(t, state, evidence)
  t.state = state
  t.history[#t.history + 1] = state
  while #t.history > 40 do table.remove(t.history, 1) end
  if evidence then t.evidence[#t.evidence + 1] = { state = state, kind = evidence.kind, ref = evidence.ref } end
  if state == "SCHEDULE_APPLIED" then t.applied = true end
end

function trip.advance(t, to, evidence)
  if INDEX[to] == nil and to ~= "CANCELLED" then return false, "unknown state " .. tostring(to) end
  if t.state == "CANCEL_PENDING" and to == "CANCELLED" then
    if not (evidence and evidence.kind == "safe_stop_reached" and evidence.ref) then return false, "a moving trip is cancelled only with evidence of a safe stop" end
    enter(t, "CANCELLED", evidence)
    return true
  end
  local from = INDEX[t.state]
  if not from then return false, "cannot advance from " .. t.state end
  if INDEX[to] ~= from + 1 then return false, "cannot go from " .. t.state .. " to " .. to end
  local need = NEEDS[to]
  if need then
    if not evidence then return false, to .. " needs evidence (" .. need .. ")" end
    if evidence.kind ~= need or not evidence.ref then return false, to .. " needs evidence of kind " .. need end
  end
  enter(t, to, evidence)
  return true
end

function trip.wait(t, reason)
  if trip.is_final(t.state) then return false, "trip is final" end
  if t.applied then return false, "the schedule is applied: a missing proof makes the trip uncertain, not waiting" end
  if t.state == "WAITING" or SIDE[t.state] then return false, "cannot wait from " .. t.state end
  t.waiting_from, t.reason = t.state, reason
  enter(t, "WAITING")
  return true
end

function trip.resume(t)
  if t.state ~= "WAITING" or not t.waiting_from then return false, "only a waiting trip is resumed" end
  t.state = t.waiting_from
  t.history[#t.history + 1] = t.state
  t.waiting_from, t.reason = nil, nil
  return true
end

function trip.uncertain(t, reason)
  if trip.is_final(t.state) then return false, "trip is final" end
  t.reason = reason
  enter(t, "UNCERTAIN")
  return true
end

function trip.reconstruct(t, to, evidence)
  if t.state ~= "UNCERTAIN" then return false, "only an uncertain trip is reconstructed" end
  if not RECONSTRUCT_TO[to] then return false, "cannot reconstruct to " .. tostring(to) end
  if not (evidence and evidence.kind and evidence.ref) then return false, "reconstruction needs an observation (evidence)" end
  t.reason = nil
  enter(t, to, evidence)
  return true
end

function trip.fault(t, reason)
  if trip.is_final(t.state) then return false, "trip is final" end
  t.reason = reason
  enter(t, "FAULT")
  return true
end

function trip.cancel(t, who)
  if trip.is_final(t.state) then return false, "trip is final" end
  t.cancelled_by = who
  if not t.applied then
    enter(t, "CANCELLED")
  else
    enter(t, "CANCEL_PENDING")
  end
  return true
end

function trip.may_move(t)
  if not t.applied or trip.is_final(t.state) then return false end
  if MOVING[t.state] or t.state == "CANCEL_PENDING" then return true end
  if t.state == "UNCERTAIN" or t.state == "FAULT" then return true end
  return false
end

function trip.record_position(t, pos) t.position = { block = pos.block, at = pos.at, quality = pos.quality } end

function trip.position_view(t, now, max_age)
  local pos = t.position
  if not pos then return {} end
  local stale = (now - pos.at) > max_age
  return { block = pos.block, at = pos.at, stale = stale, proven = (not stale) and pos.quality == "observed" }
end

function trip.snapshot(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      local c = {}
      for k2, v2 in pairs(v) do c[k2] = type(v2) == "table" and { state = v2.state, kind = v2.kind, ref = v2.ref } or v2 end
      out[k] = c
    else
      out[k] = v
    end
  end
  return out
end

function trip.restore(saved)
  local t = trip.snapshot(saved or {})
  t.history, t.evidence = t.history or {}, t.evidence or {}
  if not INDEX[t.state] and not SIDE[t.state] then
    t.state = "UNCERTAIN"
    t.history[#t.history + 1] = "UNCERTAIN"
  end
  return t
end

function trip.ids(opts)
  opts = opts or {}
  local prefix = opts.prefix or "F"
  local state = opts.state or {}
  local counters = { order = state.order or 0, trip = state.trip or 0, legs = {}, commands = {} }
  for k, v in pairs(state.legs or {}) do counters.legs[k] = v end
  for k, v in pairs(state.commands or {}) do counters.commands[k] = v end
  local self = {}
  function self.order() counters.order = counters.order + 1; return prefix .. "-O" .. counters.order end
  function self.trip() counters.trip = counters.trip + 1; return prefix .. "-T" .. counters.trip end
  function self.leg(trip_id) counters.legs[trip_id] = (counters.legs[trip_id] or 0) + 1; return trip_id .. "/L" .. counters.legs[trip_id] end
  function self.command(trip_id) counters.commands[trip_id] = (counters.commands[trip_id] or 0) + 1; return trip_id .. "/C" .. counters.commands[trip_id] end
  function self.snapshot()
    local out = { order = counters.order, trip = counters.trip, legs = {}, commands = {} }
    for k, v in pairs(counters.legs) do out.legs[k] = v end
    for k, v in pairs(counters.commands) do out.commands[k] = v end
    return out
  end
  return self
end

function trip.trip_id_from_key(key) return "TRIP-" .. key end

return trip
