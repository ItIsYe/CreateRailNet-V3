--[[
Purpose: Proof level of every block: FREE_PROVEN, OCCUPIED_PROVEN or UNKNOWN, with source and moment (Gesamtkonzept Kap. 3 S-03, S-07, S-10, 4.1).
Public API: new({ blocks = {ids} }) -> ledger.
  ledger.observe(block_id, state, source, meta) -> ok | false, err     state FREE_PROVEN | OCCUPIED_PROVEN; meta = { at = ms, train_id? }
  ledger.suspect(block_id, reason)        the proof is gone (never improves a block)
  ledger.invalidate(block_ids, reason) / ledger.invalidate_all(reason) -> number of blocks that had a proof
  ledger.is_free(block_id) -> true | false, why                        FREE_PROVEN and no maintenance/fault flag
  ledger.set_flag(block_id, flag, on) -> ok                            flags: maintenance, fault; clearing one proves nothing: the block becomes UNKNOWN
  ledger.get(block_id) -> { state, source, at, train_id, reason, last, flags } (a copy)
  ledger.snapshot() / ledger.restore(snapshot)                          restore demotes every proof to UNKNOWN (last keeps what it was)
  ledger.summary() -> { FREE_PROVEN, OCCUPIED_PROVEN, UNKNOWN }
Notes: "a block is free" needs a proof. These do not prove a block free, they only justify a conservative lock: a red signal, no train at the station, N seconds without a message, an accepted
  schedule, a planned position, a computer that does not answer, a missing observer message, a restart, a lost link, an operator's word. Evidence older than the record is ignored. Pure data, no I/O.
]]

local ledger = {}

local FREE, OCCUPIED, UNKNOWN = "FREE_PROVEN", "OCCUPIED_PROVEN", "UNKNOWN"

local FREE_SOURCES = { tail_sensor = true, sensor_level = true, observer = true, station = true }
local OCCUPIED_SOURCES = { tail_sensor = true, sensor_level = true, observer = true, station = true, enter_sensor = true, create_signal = true }
local FLAGS = { maintenance = true, fault = true }

local function copy_record(r)
  local flags = {}
  for k, v in pairs(r.flags) do flags[k] = v end
  return { state = r.state, source = r.source, at = r.at, train_id = r.train_id, reason = r.reason, last = r.last, flags = flags }
end

function ledger.new(opts)
  local self = {}
  local records = {}
  for _, id in ipairs((opts and opts.blocks) or {}) do records[id] = { state = UNKNOWN, flags = {} } end

  local function demote(r, reason)
    if r.state ~= UNKNOWN then r.last = r.state end
    r.state, r.source, r.reason = UNKNOWN, nil, reason
  end

  function self.observe(block_id, state, source, meta)
    local r = records[block_id]
    if not r then return false, "unknown block " .. tostring(block_id) end
    if state ~= FREE and state ~= OCCUPIED then return false, "unknown proof level " .. tostring(state) end
    local allowed = (state == FREE) and FREE_SOURCES or OCCUPIED_SOURCES
    if type(source) ~= "string" or not allowed[source] then return false, "'" .. tostring(source) .. "' is not a proof for " .. state end
    local at = meta and meta.at or 0
    if r.at and at < r.at then return false, "evidence older than the record (" .. tostring(at) .. " < " .. tostring(r.at) .. ")" end
    r.state, r.source, r.at, r.reason, r.last = state, source, at, nil, nil
    r.train_id = (state == OCCUPIED) and meta and meta.train_id or nil
    return true
  end

  function self.suspect(block_id, reason)
    local r = records[block_id]
    if not r then return false end
    demote(r, reason or "suspected")
    return true
  end

  function self.invalidate(ids, reason)
    local n = 0
    for _, id in ipairs(ids or {}) do
      local r = records[id]
      if r then
        if r.state ~= UNKNOWN then n = n + 1 end
        demote(r, reason or "invalidated")
      end
    end
    return n
  end

  function self.invalidate_all(reason)
    local ids = {}
    for id in pairs(records) do ids[#ids + 1] = id end
    return self.invalidate(ids, reason)
  end

  function self.is_free(block_id)
    local r = records[block_id]
    if not r then return false, "unknown block " .. tostring(block_id) end
    if r.flags.maintenance then return false, "block " .. block_id .. " is in maintenance" end
    if r.flags.fault then return false, "block " .. block_id .. " is in fault" end
    if r.state ~= FREE then return false, "block " .. block_id .. " is " .. r.state end
    return true
  end

  function self.set_flag(block_id, flag, on)
    local r = records[block_id]
    if not r or not FLAGS[flag] then return false end
    local was = r.flags[flag] == true
    r.flags[flag] = on and true or nil
    if was and not on then demote(r, "flag " .. flag .. " cleared") end
    if on and not was then demote(r, "flag " .. flag .. " set") end
    return true
  end

  function self.get(block_id)
    local r = records[block_id]
    return r and copy_record(r) or nil
  end

  function self.snapshot()
    local out = {}
    for id, r in pairs(records) do out[id] = copy_record(r) end
    return out
  end

  function self.restore(snapshot)
    for id, saved in pairs(snapshot or {}) do
      local r = records[id]
      if r then
        r.flags = {}
        for k, v in pairs(saved.flags or {}) do if FLAGS[k] and v then r.flags[k] = true end end
        r.state, r.source, r.at, r.train_id, r.reason = UNKNOWN, nil, nil, saved.train_id, "restored"
        r.last = (saved.state ~= UNKNOWN) and saved.state or saved.last
      end
    end
  end

  function self.summary()
    local s = { FREE_PROVEN = 0, OCCUPIED_PROVEN = 0, UNKNOWN = 0 }
    for _, r in pairs(records) do s[r.state] = s[r.state] + 1 end
    return s
  end

  return self
end

return ledger
