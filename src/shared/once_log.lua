--[[
Purpose: Log a recurring problem once, not on every pass of a loop; say so again when it is gone.
Public API:
  new(logger, opts) -> once        opts: now_ms(), repeat_ms (60000)
  once.first(key) -> boolean       true the first time and again after repeat_ms; false in between (counts suppressed calls)
  once.warn(key, text, data) / once.error(key, text, data)   logs when first(key) is true, with how many calls were suppressed
  once.ok(key, text, data) -> boolean   a failing key recovered: logs "recovered: <text>" once, true if it had been failing
  once.active() -> list of keys that are currently failing
Notes: a screen redraw every 0.2 s or a sensor read every 0.5 s that fails writes 300 lines a minute without this, and in a
  network with many nodes the same failure shows up on every one of them.
]]

local time = require("src.shared.time")

local once_log = {}

function once_log.new(logger, opts)
  local options = opts or {}
  local now_ms = options.now_ms or time.now_ms
  local repeat_ms = options.repeat_ms or 60000
  local self = {}
  local state = {}

  function self.first(key)
    local now = now_ms()
    local entry = state[key]
    if not entry then
      state[key] = { last = now, suppressed = 0 }
      return true
    end
    if now - entry.last >= repeat_ms then
      entry.last = now
      return true
    end
    entry.suppressed = entry.suppressed + 1
    return false
  end

  local function emit(level, key, text, data)
    local entry = state[key]
    local before = entry and entry.suppressed or 0
    if not self.first(key) then return false end
    state[key].suppressed = 0
    if logger and logger[level] then
      local payload = data or {}
      if before > 0 then payload.repeated = before end
      logger[level](text, payload)
    end
    return true
  end

  function self.warn(key, text, data) return emit("warn", key, text, data) end
  function self.error(key, text, data) return emit("error", key, text, data) end

  function self.ok(key, text, data)
    if not state[key] then return false end
    state[key] = nil
    if logger and logger.info then logger.info("recovered: " .. tostring(text), data) end
    return true
  end

  function self.active()
    local keys = {}
    for key in pairs(state) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
  end

  return self
end

return once_log
