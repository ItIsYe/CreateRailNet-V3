--[[
Purpose: Lines and timetables of the fleet: versioned drafts, publication by both partners, fixed departures and headways in real or Minecraft time (Gesamtkonzept Kap. 9).
Public API: new({ time = { real() -> epoch seconds, ingame() -> day, hour }, tz_offset_min (0), grace_min (3), max_gap_min (5) }) -> timetable.
  timetable.add_draft(line) -> version | nil, problems          each draft is a new version of that line
  timetable.publish(line_id, version, confirmations, pair_nodes) -> ok | false, err      every node of the pair must have confirmed durably; the older published version is superseded
  timetable.published(line_id) -> line + version + state | nil, timetable.get(line_id, version), timetable.list() -> { {id, published, versions = { {version, state} } } }
  timetable.due() -> { due = {event...}, missed = {event...}, resync = boolean }
  timetable.effective_for_leg(line_id, started_version, { at_handover_point }) -> { version }
  timetable.snapshot() / timetable.restore(snapshot)
Event: { line_id, version, planned (minute stamp of the line's time base), planned_hhmm, late_min, key, order_kind, reason? }.
Line: { id, kind = PASSENGER | FREIGHT, time_base = REAL | MINECRAFT, window = { from, to } ("HH:MM", may span midnight), stops = { { station, pass_through? } }, routes = { EAST = route id, ... },
  departures = { "HH:MM" } and/or headway_min, dwell_s, train_classes, reinforcement? }.
Notes: a trip is due when its minute comes; it is driven only within grace_min of the planned time. After a downtime longer than max_gap_min, or after a jump of the clock, nothing is caught up: what was
  missed is reported (missed) and not driven. The key of a trip is made of line, version, day and planned time, so a restart or a clock set back never makes a trip twice. A change of a published
  timetable reaches a leg that is running only at the next safe programmable handover point.
]]

local timetable = {}

local ORDER_KIND = {
  PASSENGER = { [false] = "SCHEDULED_PASSENGER", [true] = "EXTRA_PASSENGER" },
  FREIGHT = { [false] = "SCHEDULED_FREIGHT", [true] = "EXTRA_FREIGHT" }
}

local function to_minutes(text)
  if type(text) ~= "string" then return nil end
  local h, m = text:match("^(%d%d):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if not h or h > 23 or m > 59 then return nil end
  return h * 60 + m
end

local function hhmm(minute_of_day) return string.format("%02d:%02d", math.floor(minute_of_day / 60), minute_of_day % 60) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

local function validate(line)
  local problems = {}
  local function bad(text) problems[#problems + 1] = text end
  if type(line) ~= "table" then return { "line must be a table" } end
  if type(line.id) ~= "string" or line.id == "" then bad("id missing") end
  if not ORDER_KIND[line.kind] then bad("kind must be PASSENGER or FREIGHT") end
  if line.time_base ~= "REAL" and line.time_base ~= "MINECRAFT" then bad("time_base must be REAL or MINECRAFT") end
  if type(line.window) ~= "table" or not to_minutes(line.window.from) or not to_minutes(line.window.to) then bad("window needs from and to as HH:MM") end
  if type(line.stops) ~= "table" or #line.stops < 2 then bad("a line needs at least two stops") end
  if type(line.routes) ~= "table" or next(line.routes) == nil then bad("a line needs a route for at least one direction") end
  local has_departures = type(line.departures) == "table" and #line.departures > 0
  for _, text in ipairs(line.departures or {}) do if not to_minutes(text) then bad("departure " .. tostring(text) .. " is not HH:MM") end end
  if line.headway_min ~= nil and (type(line.headway_min) ~= "number" or line.headway_min < 1) then bad("headway must be at least 1 minute") end
  if not has_departures and line.headway_min == nil then bad("a line needs departures or a headway") end
  return problems
end

function timetable.new(opts)
  opts = opts or {}
  local time = opts.time
  local tz = opts.tz_offset_min or 0
  local grace = opts.grace_min or 3
  local max_gap = opts.max_gap_min or 5
  local self = {}
  local lines = {}      -- line id -> { [version] = line }
  local published = {}  -- line id -> version
  local cursors = {}    -- line id -> minute stamp evaluated last
  local issued = {}     -- key -> stamp

  local function now_stamp(line)
    if line.time_base == "MINECRAFT" then
      local day, hour = time.ingame()
      return day * 1440 + math.floor(hour * 60)
    end
    return math.floor((time.real() + tz * 60) / 60)
  end

  function self.add_draft(line)
    local problems = validate(line)
    if #problems > 0 then return nil, problems end
    lines[line.id] = lines[line.id] or {}
    local version = #lines[line.id] + 1
    local stored = copy(line)
    stored.version, stored.state = version, "DRAFT"
    lines[line.id][version] = stored
    return version
  end

  -- every line with its published version and its versions (for the panel: what runs, what waits as a draft)
  function self.list()
    local out = {}
    for id, versions in pairs(lines) do
      local entry = { id = id, published = published[id], versions = {} }
      for v = 1, #versions do entry.versions[v] = { version = v, state = versions[v].state } end
      out[#out + 1] = entry
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
  end

  function self.get(line_id, version) return lines[line_id] and lines[line_id][version] or nil end

  function self.published(line_id)
    local version = published[line_id]
    return version and lines[line_id][version] or nil
  end

  function self.publish(line_id, version, confirmations, pair_nodes)
    local line = self.get(line_id, version)
    if not line then return false, "unknown draft " .. tostring(line_id) .. " v" .. tostring(version) end
    for _, node in ipairs(pair_nodes or {}) do
      if not (confirmations and confirmations[node] == true) then return false, "confirmation missing: " .. tostring(node) end
    end
    local old = published[line_id]
    if old and lines[line_id][old] then lines[line_id][old].state = "SUPERSEDED" end
    line.state = "PUBLISHED"
    published[line_id] = version
    return true
  end

  local function in_window(line, minute_of_day)
    local from, to = to_minutes(line.window.from), to_minutes(line.window.to)
    if from <= to then return minute_of_day >= from and minute_of_day <= to end
    return minute_of_day >= from or minute_of_day <= to
  end

  -- every planned departure with from < stamp <= to
  local function slots(line, from, to)
    local out = {}
    local first_day = math.floor(from / 1440) - 1
    local last_day = math.floor(to / 1440)
    local from_min, to_min = to_minutes(line.window.from), to_minutes(line.window.to)
    local length = (from_min <= to_min) and (to_min - from_min) or (to_min + 1440 - from_min)
    for day = first_day, last_day do
      for _, text in ipairs(line.departures or {}) do
        local m = to_minutes(text)
        local stamp = day * 1440 + m
        if in_window(line, m) and stamp > from and stamp <= to then out[#out + 1] = stamp end
      end
      if line.headway_min then
        local start = day * 1440 + from_min
        local k = 0
        while k * line.headway_min <= length do
          local stamp = start + k * line.headway_min
          if stamp > from and stamp <= to then
            local duplicate = false
            for _, existing in ipairs(out) do if existing == stamp then duplicate = true end end
            if not duplicate then out[#out + 1] = stamp end
          end
          k = k + 1
        end
      end
    end
    table.sort(out)
    return out
  end

  local function event_for(line, stamp, now, reason)
    local day, minute = math.floor(stamp / 1440), stamp % 1440
    return {
      line_id = line.id, version = line.version, planned = stamp, planned_hhmm = hhmm(minute), late_min = now - stamp,
      key = string.format("%s/v%d/d%d/%s", line.id, line.version, day, hhmm(minute)),
      order_kind = ORDER_KIND[line.kind][line.reinforcement == true], reason = reason
    }
  end

  function self.due()
    local result = { due = {}, missed = {}, resync = false }
    local ids = {}
    for id in pairs(published) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local line = self.published(id)
      local now = now_stamp(line)
      local cursor = cursors[id] or (now - 1)
      if now < cursor then
        -- the clock was set back: nothing is driven, the next evaluation starts here
        result.resync = true
        cursors[id] = now
      else
        local downtime = (now - cursor) > max_gap
        for _, stamp in ipairs(slots(line, cursor, now)) do
          local event = event_for(line, stamp, now)
          if not issued[event.key] then
            issued[event.key] = stamp
            if event.late_min <= grace then
              result.due[#result.due + 1] = event
            else
              event.reason = downtime and "downtime: not caught up" or "too late: not driven"
              result.missed[#result.missed + 1] = event
            end
          end
        end
        cursors[id] = now
      end
      for key, stamp in pairs(issued) do if stamp < now - 4320 then issued[key] = nil end end
    end
    return result
  end

  function self.effective_for_leg(line_id, started_version, flags)
    if flags and flags.at_handover_point then return { version = published[line_id] or started_version } end
    return { version = started_version }
  end

  function self.snapshot()
    return { lines = copy(lines), published = copy(published), cursors = copy(cursors), issued = copy(issued) }
  end

  function self.restore(snap)
    snap = snap or {}
    lines, published, cursors, issued = copy(snap.lines or {}), copy(snap.published or {}), copy(snap.cursors or {}), copy(snap.issued or {})
  end

  return self
end

timetable.validate = validate

return timetable
