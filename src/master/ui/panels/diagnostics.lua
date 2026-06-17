--[[
Purpose: Diagnostics panel showing logs and faults.
Public API: new(logger, dispatcher).
]]

local diagnostics = {}

function diagnostics.new(logger, dispatcher)
  local panel = {}

  function panel.draw(monitor)
    if not monitor then return end
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Diagnostics")
    local row = 2
    local buffer = (logger and logger.get_buffer and logger.get_buffer()) or {}
    for _, entry in ipairs(buffer) do
      monitor.setCursorPos(1, row)
      monitor.write(string.format("%s: %s", entry.level or "?", entry.msg or ""))
      row = row + 1
      if row > 10 then break end
    end
    row = row + 1
    monitor.setCursorPos(1, row)
    monitor.write("Faults")
    row = row + 1
    local overview = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    for id, block in pairs(overview) do
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
