--[[
Purpose: The timetable editor of the panel: a draft of a line that is changed in small steps with touch buttons, checked, previewed, sent to the fleet pair and published against the version it was made on (Gesamtkonzept Kap. 9, 13, 11.5; Pruefplan D-10, H-09, H-10, H-12).
Public API: new({ fs, path ("state/panel_timetable_draft.json") }) -> editor.
  editor.open(line_id, line) -> ok      line as the fleet reports it (published version, kind, time_base, window, headway_min, dwell_s, departures, stops, routes, direction)
  editor.adjust(field, delta) -> ok | false, err      field: "headway_min" (+-1 min), "dwell_s" (+-5 s), "window_from" / "window_to" (+-30 min), "departures" (all fixed departures +-5 min)
  editor.draft() -> the line to send (without the fields that only the fleet fills in)      editor.changes() -> list of German lines      editor.dirty() -> boolean      editor.validate() -> problems
  editor.base_version() / editor.line_id() / editor.sent(request_id) / editor.sent_request() / editor.reset() / editor.rebase(version) / editor.conflict(current_version) -> boolean
  editor.save() / editor.load() -> "empty" | "ready" | "corrupt"
Notes: the editor only changes the draft; nothing reaches the fleet before the operator sends it, and a draft is published against its base version: when the published version has moved on in the meantime (another control room,
  or the pair after the panel was offline) the draft is a conflict (conflict(current) is true) that is resolved by a person: reload the line (reset) or keep the changes on the new version (rebase) after having looked at them.
  A line whose list of fixed departures was cut off in the report (more than the report carries) cannot have its departures shifted. The draft is kept on disk, so a restart of the panel does not lose it.
]]

local json = require("src.shared.json")
local canon = require("src.shared.canon")
local safe_write = require("src.shared.safe_write")
local timetable = require("src.fleet.timetable")

local timetable_editor = {}

local KEEP = { "id", "kind", "time_base", "window", "headway_min", "dwell_s", "departures", "stops", "routes", "direction", "origin", "goal", "train_classes", "reinforcement" }

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = copy(v) end
  return out
end

local function to_minutes(text)
  local h, m = tostring(text):match("^(%d%d):(%d%d)$")
  h, m = tonumber(h), tonumber(m)
  if not h or h > 23 or m > 59 then return nil end
  return h * 60 + m
end
local function hhmm(minutes)
  minutes = minutes % 1440
  return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

function timetable_editor.new(opts)
  opts = opts or {}
  local io_opts = { fs = opts.fs }
  local path = opts.path or "state/panel_timetable_draft.json"
  local self = {}
  local base, draft, base_version, id, sent_request, truncated

  local function clean(line)
    local out = {}
    for _, key in ipairs(KEEP) do if line[key] ~= nil then out[key] = copy(line[key]) end end
    return out
  end

  function self.open(line_id, line)
    if type(line_id) ~= "string" or type(line) ~= "table" or type(line.version) ~= "number" then return false, "the line has no published version" end
    id, base_version, truncated = line_id, line.version, line.departures_truncated == true
    base = clean(line)
    base.id = line_id
    draft = copy(base)
    sent_request = nil
    return true
  end

  function self.adjust(field, delta)
    if not draft then return false, "no line is open" end
    if type(delta) ~= "number" then return false, "delta must be a number" end
    if field == "headway_min" then
      if draft.headway_min == nil then return false, "this line has fixed departures, no headway" end
      local value = draft.headway_min + delta
      if value < 1 then return false, "the headway is at least 1 minute" end
      draft.headway_min = value
    elseif field == "dwell_s" then
      local value = (draft.dwell_s or 30) + delta
      if value < 0 then return false, "the dwell time cannot be negative" end
      draft.dwell_s = value
    elseif field == "window_from" or field == "window_to" then
      draft.window = draft.window or {}
      local key = field == "window_from" and "from" or "to"
      local minutes = to_minutes(draft.window[key] or "")
      if not minutes then return false, "the window has no " .. key end
      draft.window[key] = hhmm(minutes + delta)
    elseif field == "departures" then
      if truncated then return false, "the list of departures is cut off in the report, it cannot be shifted" end
      if not draft.departures or #draft.departures == 0 then return false, "this line has no fixed departures" end
      for i, text in ipairs(draft.departures) do
        local minutes = to_minutes(text)
        if not minutes then return false, "departure " .. tostring(text) .. " is not HH:MM" end
        draft.departures[i] = hhmm(minutes + delta)
      end
    else
      return false, "unknown field " .. tostring(field)
    end
    sent_request = nil     -- what was sent is no longer what is on the screen
    return true
  end

  function self.draft() return draft and copy(draft) or nil end
  function self.line_id() return id end
  function self.base_version() return base_version end
  function self.dirty()
    if not draft then return false end
    -- compared as canonical text: Lua lists the keys of equal tables in different orders
    return canon.encode(draft) ~= canon.encode(base)
  end

  function self.changes()
    local out = {}
    if not draft then return out end
    local function diff(label, a, b) if a ~= b then out[#out + 1] = label .. ": " .. tostring(a) .. " -> " .. tostring(b) end end
    diff("Takt (min)", base.headway_min, draft.headway_min)
    diff("Haltezeit (s)", base.dwell_s, draft.dwell_s)
    diff("Fenster von", (base.window or {}).from, (draft.window or {}).from)
    diff("Fenster bis", (base.window or {}).to, (draft.window or {}).to)
    diff("Abfahrten", table.concat(base.departures or {}, " "), table.concat(draft.departures or {}, " "))
    return out
  end

  function self.validate()
    if not draft then return { "no line is open" } end
    return timetable.validate(draft)
  end

  function self.sent(request_id) sent_request = request_id end
  function self.sent_request() return sent_request end

  function self.conflict(current_version) return draft ~= nil and current_version ~= base_version end
  function self.rebase(version)
    if not draft or type(version) ~= "number" then return false end
    base_version, sent_request = version, nil
    return true
  end
  function self.reset() base, draft, base_version, id, sent_request, truncated = nil, nil, nil, nil, nil, nil end

  function self.save()
    if not draft then return true end
    return safe_write.write(path, json.encode({ v = 1, id = id, base_version = base_version, base = base, draft = draft, truncated = truncated }), io_opts)
  end

  function self.load()
    local body, err = safe_write.read_with_backup(path, io_opts)
    if not body then return err == "missing" and "empty" or "corrupt" end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" or type(decoded.draft) ~= "table" or type(decoded.base) ~= "table" or type(decoded.id) ~= "string" or type(decoded.base_version) ~= "number" then return "corrupt" end
    id, base_version, base, draft, truncated = decoded.id, decoded.base_version, decoded.base, decoded.draft, decoded.truncated == true
    sent_request = nil
    return "ready"
  end

  return self
end

return timetable_editor
