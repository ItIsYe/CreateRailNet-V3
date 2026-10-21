--[[
Purpose: Exactly-once bookkeeping for commands and requests that survives a restart (Gesamtkonzept Kap. 7.3, 8.4, 12.2: deterministic idempotence, unclear outcome).
Public API: new(opts) -> ledger. opts: journal (attached: every step is written to it before it counts), ttl_s (86400), max (2000), now (function -> seconds).
  ledger.begin(id) -> "new" | "done", outcome | "started" | "uncertain" | nil, err
  ledger.finish(id, outcome) -> ok, err          outcome is a plain value (string, number, boolean) or a small table
  ledger.status(id) -> "unknown" | "started" | "uncertain" | "done", outcome
  ledger.recover(entries) -> n                   replays "idem_begin" / "idem_done" entries of a journal after a restart; a begin without a finish becomes "uncertain"
  ledger.to_state() / ledger.load_state(state)   for the snapshot of the journal
Notes: "new" means: carry it out now, and call finish when it is done. "started" is a begin that is still running (a retry meanwhile must wait). "uncertain" is what a begin
  without finish becomes after a restart: the caller has to find out from the world what happened (a train that left or not, a schedule that was set or not) and then finish
  it; nothing repeats it blindly. "done" gives the stored outcome again, without carrying it out a second time. With a journal attached begin returns nil, err when the
  step cannot be written, and the caller must not carry the command out (no durable record, no action). Entries are pruned after ttl_s and the table is bounded by max
  (the oldest finished ones go first; one that is still started or uncertain is never pruned).
]]

local idempotency = {}

local MAX_ID = 160

local function sane_id(id) return type(id) == "string" and id ~= "" and #id <= MAX_ID end

function idempotency.new(opts)
  opts = opts or {}
  local journal = opts.journal
  local ttl = opts.ttl_s or 86400
  local max = opts.max or 2000
  local now = opts.now or function() return os.time and os.time() or 0 end
  local self = {}
  local items, count = {}, 0

  local function put(id, record)
    if not items[id] then count = count + 1 end
    items[id] = record
  end

  local function prune()
    local t = now()
    for id, record in pairs(items) do
      if record.state == "done" and t - record.at > ttl then items[id] = nil; count = count - 1 end
    end
    if count <= max then return end
    local done = {}
    for id, record in pairs(items) do if record.state == "done" then done[#done + 1] = id end end
    table.sort(done, function(a, b)
      if items[a].at ~= items[b].at then return items[a].at < items[b].at end
      return a < b
    end)
    for _, id in ipairs(done) do
      if count <= max then break end
      items[id] = nil
      count = count - 1
    end
  end

  function self.status(id)
    local record = items[id]
    if not record then return "unknown" end
    return record.state, record.outcome
  end

  function self.begin(id)
    if not sane_id(id) then return nil, "bad command id" end
    local record = items[id]
    if record then
      if record.state == "done" then return "done", record.outcome end
      return record.state
    end
    if journal then
      local seq, err = journal.append("idem_begin", { id = id, at = now() })
      if not seq then return nil, err end
    end
    put(id, { state = "started", at = now() })
    prune()
    return "new"
  end

  function self.finish(id, outcome)
    local record = items[id]
    if not record then return nil, "unknown command id" end
    if record.state == "done" then return true end
    if journal then
      local seq, err = journal.append("idem_done", { id = id, outcome = outcome, at = now() })
      if not seq then return nil, err end
    end
    record.state, record.outcome, record.at = "done", outcome, now()
    return true
  end

  -- a restart: begins that never finished are uncertain, finished ones are as they were
  function self.recover(entries)
    local applied = 0
    for _, entry in ipairs(entries or {}) do
      local data = entry.data or {}
      if entry.kind == "idem_begin" and sane_id(data.id) and not items[data.id] then
        put(data.id, { state = "uncertain", at = tonumber(data.at) or now() })
        applied = applied + 1
      elseif entry.kind == "idem_done" and sane_id(data.id) then
        put(data.id, { state = "done", outcome = data.outcome, at = tonumber(data.at) or now() })
        applied = applied + 1
      end
    end
    prune()
    return applied
  end

  function self.to_state()
    local out = {}
    for id, record in pairs(items) do out[id] = { s = record.state, o = record.outcome, t = record.at } end
    return out
  end

  -- from a snapshot: whatever was only started when the snapshot was made is uncertain now
  function self.load_state(state)
    items, count = {}, 0
    for id, record in pairs(state or {}) do
      if sane_id(id) and type(record) == "table" then
        local kind = record.s == "done" and "done" or "uncertain"
        put(id, { state = kind, outcome = record.o, at = tonumber(record.t) or now() })
      end
    end
  end

  return self
end

return idempotency
