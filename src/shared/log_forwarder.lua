--[[
Purpose: Sends the warnings and errors of a node to the log collector in small batches instead of one message per line.
Public API: attach(logger, send, opts) -> forwarder, or nil when the logger cannot be wrapped
  forwarder.flush() -> number of entries sent      send(payload) is called with { type = "log_batch", entries = {...}, dropped = n }
  forwarder.stats() -> { queued, sent, dropped }
  opts: min_level ("WARN"), capacity (40), max_batch (15), rate_per_min (30), now_ms()
Notes: wraps logger.log, so every level method is covered. Consecutive identical lines are folded into one entry with a count; a node
  forwards at most rate_per_min lines a minute and counts the rest as dropped, so a node in a failure loop cannot flood the channel.
  Lines about the network itself ("net ...", retries and drops) are never forwarded: forwarding a retry warning would cause more traffic
  on a channel that is already in trouble. The collector gets best-effort messages; nothing is retried.
]]

local time = require("src.shared.time")

local log_forwarder = {}

local LEVELS = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40 }
local MAX_TEXT = 120

local function summarize(context)
  if type(context) ~= "table" then return nil end
  local out, count = {}, 0
  local keys = {}
  for key in pairs(context) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do
    local value = context[key]
    local kind = type(value)
    if (kind == "string" or kind == "number" or kind == "boolean") and count < 4 then
      out[tostring(key)] = kind == "string" and value:sub(1, 60) or value
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return out
end

function log_forwarder.attach(logger, send, opts)
  if type(logger) ~= "table" or type(logger.log) ~= "function" then return nil end
  local options = opts or {}
  local now_ms = options.now_ms or time.now_ms
  local min_level = LEVELS[options.min_level or "WARN"] or LEVELS.WARN
  local capacity = options.capacity or 40
  local max_batch = options.max_batch or 15
  local rate = options.rate_per_min or 30

  local self = {}
  local queue = {}
  local dropped, sent = 0, 0
  local tokens, last_refill = rate, now_ms()

  local function refill()
    local now = now_ms()
    tokens = math.min(rate, tokens + (now - last_refill) * rate / 60000)
    last_refill = now
  end

  local function enqueue(level, message, context)
    local text = tostring(message)
    if text:sub(1, 4) == "net " then return end
    local last = queue[#queue]
    if last and last.lvl == level and last.msg == text:sub(1, MAX_TEXT) then
      last.n = last.n + 1
      return
    end
    refill()
    if tokens < 1 or #queue >= capacity then dropped = dropped + 1; return end
    tokens = tokens - 1
    queue[#queue + 1] = { lvl = level, msg = text:sub(1, MAX_TEXT), ts = time.now_s(), n = 1, ctx = summarize(context) }
  end

  local original = logger.log
  logger.log = function(level, message, context)
    original(level, message, context)
    if (LEVELS[string.upper(tostring(level))] or 0) >= min_level then pcall(enqueue, string.upper(tostring(level)), message, context) end
  end

  function self.flush()
    if #queue == 0 then return 0 end
    local batch = {}
    while #queue > 0 and #batch < max_batch do batch[#batch + 1] = table.remove(queue, 1) end
    local ok = pcall(send, { type = "log_batch", entries = batch, dropped = dropped })
    if ok then sent = sent + #batch end
    dropped = 0
    return #batch
  end

  function self.stats()
    return { queued = #queue, sent = sent, dropped = dropped }
  end

  return self
end

return log_forwarder
