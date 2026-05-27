--[[
Purpose: Small message dispatcher used by master and node runtimes.
Public API: dispatch(msg, handlers, default_handler) -> ok, result.
]]

local message_handlers = {}

function message_handlers.dispatch(msg, handlers, default_handler)
  if type(msg) ~= "table" then
    return false, "message must be table"
  end

  local handler = handlers and handlers[msg.type]
  if handler then
    return handler(msg)
  end

  if default_handler then
    return default_handler(msg)
  end

  return true, "ignored"
end

return message_handlers
