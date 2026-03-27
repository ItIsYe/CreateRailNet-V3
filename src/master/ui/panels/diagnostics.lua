--[[
Purpose: Diagnostics panel showing logs and faults.
Public API: new(logger, dispatcher).
]]

local diagnostics = {}

local function fallback_text(value)
  if value == nil then
    return "n/a"
  end
  return tostring(value)
end

function diagnostics.new(logger, dispatcher)
  local panel = {}

  function panel.draw(monitor)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Diagnostics")
    local row = 2
    for _, entry in ipairs(logger.get_buffer()) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", fallback_text(entry.level), fallback_text(entry.msg)))
      row = row + 1
      if row > 10 then
        break
      end
    end
    row = row + 1
    monitor.setCursorPos(1, row)
    monitor.write("Faults")
    row = row + 1
    for id, block in pairs(dispatcher.get_overview()) do
      if block and block.state == "FAULT" then
        monitor.setCursorPos(1, row)
        monitor.write(string.format("%s FAULT", fallback_text(id)))
        row = row + 1
      end
    end
  end

  function panel.touch()
    -- placeholder
  end

  return panel
end

return diagnostics
