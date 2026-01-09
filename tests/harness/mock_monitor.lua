--[[
Purpose: Mock monitor that captures draw calls and can inject touches.
Public API: new(), get_calls(), inject_touch(x,y).
]]

local mock_monitor = {}

function mock_monitor.new()
  local self = { calls = {}, touch = nil }

  function self.clear()
    table.insert(self.calls, { action = "clear" })
  end

  function self.setCursorPos(x, y)
    table.insert(self.calls, { action = "cursor", x = x, y = y })
  end

  function self.write(text)
    table.insert(self.calls, { action = "write", text = text })
  end

  function self.get_calls()
    return self.calls
  end

  function self.inject_touch(x, y)
    if self.touch then
      self.touch(x, y)
    end
  end

  return self
end

return mock_monitor
