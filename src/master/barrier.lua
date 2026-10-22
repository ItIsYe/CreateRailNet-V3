--[[
Purpose: The commit barrier: actuations that give movement (a signal that is not RED, a switch position, a departure command) wait until both masters have the state they depend on (Kap. 5.2, S-02, S-06).
Public API: new(opts) -> barrier. opts: now_ms, logger, max_items (400).
  barrier.hold(key, run, meta) -> true        queue an actuation; run() carries it out later; an older one with the same key is replaced and the new one goes to the END of the queue
  barrier.cancel(key) -> n                    remove what waits under that key (a restrictive command, e.g. RED, overrides it)
  barrier.tag(idx)                            give every untagged item the index of the state it depends on (meta.payload gets command_id "<idx>.<n>")
  barrier.release(confirmed) -> n             carry out the items at the head of the queue whose index confirmed(idx) accepts, in order, and stop at the first that is not confirmed
  barrier.discard(reason) -> n                drop everything (the leadership is gone)      barrier.count()  barrier.oldest_age_ms()
  permissive_cmd(payload) -> boolean          the commands of a master that give movement
Notes: strictly in order: a switch that was queued before the signal is moved before the signal turns green, and a restrictive command (RED, hold, stop) never waits. Nothing expires while this master
  leads: dropping a queued switch move and keeping its green would show GREEN with the switch in the wrong position; instead the queue waits for the standby, and when the leadership is lost
  everything is discarded and the new leader restores the committed state (src/master/replica.lua). A queue of a few hundred items is a sign that the standby is gone: count() and oldest_age_ms() tell the panel.
]]

local barrier = {}

local PERMISSIVE_CMDS = { set_position = true, depart_authorized = true, set_schedule = true, set_destination = true, dispatch_train = true }

function barrier.permissive_cmd(payload)
  if type(payload) ~= "table" then return false end
  local cmd = payload.cmd
  if PERMISSIVE_CMDS[cmd] then return true end
  if cmd == "set_aspect" then return payload.aspect ~= "RED" and payload.aspect ~= "STOP" and payload.aspect ~= false end
  return false
end

function barrier.new(opts)
  opts = opts or {}
  local now_ms = opts.now_ms or function() return 0 end
  local logger = opts.logger
  local max_items = opts.max_items or 400
  local self = {}
  local items = {}
  local tag_counter = 0

  local function remove_key(key)
    local removed = 0
    local kept = {}
    for _, item in ipairs(items) do
      if item.key == key then removed = removed + 1 else kept[#kept + 1] = item end
    end
    items = kept
    return removed
  end

  function self.hold(key, run, meta)
    remove_key(key)
    if #items >= max_items then
      -- the standby has been gone for long: the oldest actuation is still the one that matters least (a later refresh of the same signal supersedes it anyway)
      table.remove(items, 1)
      if logger then logger.warn("commit barrier: the queue is full, the oldest actuation was dropped", { max = max_items }) end
    end
    items[#items + 1] = { key = key, run = run, meta = meta, at = now_ms() }
    return true
  end

  function self.cancel(key) return remove_key(key) end

  function self.tag(idx)
    tag_counter = 0
    for _, item in ipairs(items) do
      if item.need == nil then
        item.need = idx
        tag_counter = tag_counter + 1
        if item.meta and type(item.meta.payload) == "table" then item.meta.payload.command_id = tostring(idx) .. "." .. tag_counter end
      end
    end
  end

  function self.release(confirmed)
    local done = 0
    while items[1] and items[1].need ~= nil and confirmed(items[1].need) do
      local item = table.remove(items, 1)
      local ok, err = pcall(item.run)
      if not ok and logger then logger.warn("commit barrier: an actuation failed", { key = item.key, error = tostring(err) }) end
      done = done + 1
    end
    return done
  end

  function self.discard(reason)
    local n = #items
    items = {}
    if n > 0 and logger then logger.warn("commit barrier: waiting actuations dropped", { count = n, reason = reason }) end
    return n
  end

  function self.count() return #items end

  function self.oldest_age_ms()
    if not items[1] then return 0 end
    return now_ms() - items[1].at
  end

  return self
end

return barrier
