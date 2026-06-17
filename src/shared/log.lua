--[[
Purpose: Logging with levels and ring buffer; optional remote sink.
Public API: new(level, buffer_size, sink), levels.
]]

local log = {}

log.levels = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40 }

local function level_value(level)
  return log.levels[string.upper(level or "INFO")] or log.levels.INFO
end

function log.new(level, buffer_size, sink)
  local min_level = level_value(level)
  local size = buffer_size or 200
  local buffer = {}

  local function push(entry)
    table.insert(buffer, entry)
    if #buffer > size then
      table.remove(buffer, 1)
    end
    if sink then
      sink(entry)
    end
  end

  local logger = {}
  function logger.get_buffer()
    return buffer
  end

  function logger.log(lvl, msg, context)
    if level_value(lvl) < min_level then
      return
    end
    local entry = {
      level = lvl,
      msg = msg,
      ts = os.time(),
      context = context
    }
    push(entry)
  end

  function logger.debug(msg, context) logger.log("DEBUG", msg, context) end
  function logger.info(msg, context) logger.log("INFO", msg, context) end
  function logger.warn(msg, context) logger.log("WARN", msg, context) end
  function logger.error(msg, context) logger.log("ERROR", msg, context) end

  return logger
end

return log
