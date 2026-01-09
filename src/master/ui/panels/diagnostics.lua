--[[
Purpose: Diagnostics panel showing logs and faults.
Public API: new(logger, dispatcher).
]]

local diagnostics = {}

function diagnostics.new(logger, dispatcher)
  local panel = {}

  function panel.draw(monitor)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Diagnostics")
    local row = 2
    for _, entry in ipairs(logger.get_buffer()) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", entry.level, entry.msg))
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
      if block.state == "FAULT" then
        monitor.setCursorPos(1, row)
        monitor.write(string.format("%s FAULT", id))
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
