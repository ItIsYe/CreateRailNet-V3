--[[
Purpose: The binding of logical signals to peripherals on a multi-signal node (Gesamtkonzept Kap. 6, tests B-05, B-06).
Public API: new({ fs, path, node_id, now }) -> bindings.
  bindings.load() -> "empty" | "ready" | "corrupt", err      a damaged file binds nothing
  bindings.bind(logical_id, peripheral, meta) -> ok | false, err     meta.confirmed must be true (the operator saw the signal); meta: track_id, direction, signal_type, position, ptype
  bindings.replace(logical_id, peripheral, meta) -> ok | false, err  a new confirmed binding for an existing signal; the old peripheral is recorded in replaced_from
  bindings.unbind(logical_id), bindings.resolve(logical_id) -> peripheral | nil, bindings.get(logical_id), bindings.list() (sorted by logical id)
  bindings.verify(present) -> { ok, missing = { logical = peripheral }, type_changed = { logical = { expected, found } }, unbound = { peripheral names } }   present: name -> type
  bindings.is_usable(logical_id, present) -> true | false, why
  bindings.compare_topology(master_signal_ids) -> { ok, unbound = {...}, unknown = {...} }
Notes: nothing is bound, replaced or rebound by itself: not after a start, not after a change of the modem, not after a hardware swap. A difference is reported and the signal concerned
  is not used (the node keeps it at RED and says so). The file is written with shared.safe_write; a binding that could not be written is not made. Signal peripherals are recognised by a type that
  contains "signal" (case does not matter) or by the type a binding of this node already has.
]]

local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")

local signal_bindings = {}

signal_bindings.DEFAULT_PATH = "state/signal_bindings.json"

local function sorted_keys(t)
  local keys = {}
  for key in pairs(t or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function copy(record)
  local out = {}
  for k, v in pairs(record) do out[k] = v end
  return out
end

function signal_bindings.new(opts)
  opts = opts or {}
  local self = {}
  local path = opts.path or signal_bindings.DEFAULT_PATH
  local io_opts = { fs = opts.fs }
  local now = opts.now or function() return os.time() end
  local records = {}   -- logical id -> record
  local by_peripheral = {}

  local function rebuild()
    by_peripheral = {}
    for logical, record in pairs(records) do by_peripheral[record.peripheral] = logical end
  end

  local function persist(candidate)
    local list = {}
    for _, id in ipairs(sorted_keys(candidate)) do list[#list + 1] = candidate[id] end
    return safe_write.write(path, json.encode({ v = 1, node_id = opts.node_id, bindings = list }), io_opts)
  end

  function self.load()
    local body, err = safe_write.read_with_backup(path, io_opts)
    records = {}
    rebuild()
    if not body then
      if err == "missing" then return "empty" end
      return "corrupt", err
    end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" or type(decoded.bindings) ~= "table" then return "corrupt", "binding file is not readable" end
    for _, record in ipairs(decoded.bindings) do
      if type(record) == "table" and type(record.logical_id) == "string" and type(record.peripheral) == "string" and not records[record.logical_id] then
        records[record.logical_id] = record
      end
    end
    rebuild()
    return "ready"
  end

  local function check_args(logical_id, peripheral, meta)
    if type(logical_id) ~= "string" or logical_id == "" then return false, "logical signal id missing" end
    if type(peripheral) ~= "string" or peripheral == "" then return false, "peripheral name missing" end
    if not (meta and meta.confirmed == true) then return false, "binding needs the confirmation of the operator" end
    return true
  end

  local function make_record(logical_id, peripheral, meta, replaced_from)
    return {
      logical_id = logical_id, peripheral = peripheral, track_id = meta.track_id, direction = meta.direction, signal_type = meta.signal_type,
      position = meta.position, ptype = meta.ptype, confirmed_at = now(), replaced_from = replaced_from
    }
  end

  local function with_change(change)
    local candidate = {}
    for id, record in pairs(records) do candidate[id] = record end
    change(candidate)
    local ok, err = persist(candidate)
    if not ok then return false, "binding could not be written: " .. tostring(err) end
    records = candidate
    rebuild()
    return true
  end

  function self.bind(logical_id, peripheral, meta)
    local ok, err = check_args(logical_id, peripheral, meta)
    if not ok then return false, err end
    if records[logical_id] then return false, "signal " .. logical_id .. " is already bound to " .. records[logical_id].peripheral .. " (unbind or replace it first)" end
    if by_peripheral[peripheral] then return false, "peripheral " .. peripheral .. " is already bound to signal " .. by_peripheral[peripheral] end
    return with_change(function(candidate) candidate[logical_id] = make_record(logical_id, peripheral, meta) end)
  end

  function self.replace(logical_id, peripheral, meta)
    local ok, err = check_args(logical_id, peripheral, meta)
    if not ok then return false, err end
    local old = records[logical_id]
    if not old then return false, "signal " .. logical_id .. " is not bound" end
    if by_peripheral[peripheral] and by_peripheral[peripheral] ~= logical_id then return false, "peripheral " .. peripheral .. " is already bound to signal " .. by_peripheral[peripheral] end
    return with_change(function(candidate) candidate[logical_id] = make_record(logical_id, peripheral, meta, old.peripheral) end)
  end

  function self.unbind(logical_id)
    if not records[logical_id] then return false, "signal " .. tostring(logical_id) .. " is not bound" end
    return with_change(function(candidate) candidate[logical_id] = nil end)
  end

  function self.resolve(logical_id)
    local record = records[logical_id]
    if not record then return nil, "signal " .. tostring(logical_id) .. " is not bound" end
    return record.peripheral
  end

  function self.get(logical_id) return records[logical_id] and copy(records[logical_id]) or nil end

  function self.list()
    local out = {}
    for _, id in ipairs(sorted_keys(records)) do out[#out + 1] = copy(records[id]) end
    return out
  end

  local function looks_like_signal(name, ptype)
    return type(ptype) == "string" and ptype:lower():find("signal", 1, true) ~= nil
  end

  function self.verify(present)
    present = present or {}
    local report = { ok = true, missing = {}, type_changed = {}, unbound = {} }
    for _, id in ipairs(sorted_keys(records)) do
      local record = records[id]
      local found = present[record.peripheral]
      if found == nil then
        report.missing[id] = record.peripheral; report.ok = false
      elseif record.ptype and found ~= record.ptype then
        report.type_changed[id] = { expected = record.ptype, found = found }; report.ok = false
      end
    end
    for _, name in ipairs(sorted_keys(present)) do
      if not by_peripheral[name] and looks_like_signal(name, present[name]) then
        report.unbound[#report.unbound + 1] = name
        report.ok = false
      end
    end
    return report
  end

  function self.is_usable(logical_id, present)
    local record = records[logical_id]
    if not record then return false, "signal " .. tostring(logical_id) .. " is not bound" end
    local found = (present or {})[record.peripheral]
    if found == nil then return false, "peripheral " .. record.peripheral .. " is missing" end
    if record.ptype and found ~= record.ptype then return false, "peripheral " .. record.peripheral .. " has another type (" .. tostring(found) .. " instead of " .. record.ptype .. ")" end
    return true
  end

  function self.compare_topology(master_ids)
    local wanted = {}
    for _, id in ipairs(master_ids or {}) do wanted[id] = true end
    local diff = { ok = true, unbound = {}, unknown = {} }
    for _, id in ipairs(sorted_keys(wanted)) do if not records[id] then diff.unbound[#diff.unbound + 1] = id; diff.ok = false end end
    for _, id in ipairs(sorted_keys(records)) do if not wanted[id] then diff.unknown[#diff.unknown + 1] = id; diff.ok = false end end
    return diff
  end

  return self
end

return signal_bindings
