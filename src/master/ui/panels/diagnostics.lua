--[[
Purpose: Diagnostics panel showing logs, faults, and OTA status.
Public API: new(logger, dispatcher).
]]

local diagnostics_panel = {}

function diagnostics_panel.new(logger, dispatcher)
  local panel = {}
  local log_offset = 0

  function panel.draw(monitor)
    if not monitor then return end
    local w, h = 51, 19
    if monitor.getSize then w, h = monitor.getSize() end
    monitor.clear()

    monitor.setCursorPos(1, 1)
    monitor.write("== DIAGNOSTICS ==")

    -- Fault blocks
    local row = 3
    monitor.setCursorPos(1, row); monitor.write("FAULTS"); row = row + 1
    local overview = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    local fault_count = 0
    for id, block in pairs(overview) do
      if block.state == "FAULT" then
        if row <= 6 then
          monitor.setCursorPos(1, row)
          monitor.write("  ! " .. id)
          row = row + 1
        end
        fault_count = fault_count + 1
      end
    end
    if fault_count == 0 then
      monitor.setCursorPos(1, row); monitor.write("  (none)"); row = row + 1
    elseif fault_count > 2 then
      monitor.setCursorPos(1, row); monitor.write("  +" .. (fault_count - 2) .. " more"); row = row + 1
    end

    -- Log buffer
    row = row + 1
    monitor.setCursorPos(1, row); monitor.write("LOGS"); row = row + 1
    local buffer = (logger and logger.get_buffer and logger.get_buffer()) or {}
    local max_lines = h - row - 1
    local start = math.max(1, #buffer - max_lines - log_offset + 1)
    for i = start, math.min(#buffer, start + max_lines) do
      local entry = buffer[i]
      if entry and row <= h - 1 then
        local line = string.format("[%s] %s", (entry.level or "?"):sub(1,4), tostring(entry.msg or ""):sub(1, w-8))
        monitor.setCursorPos(1, row)
        monitor.write(line)
        row = row + 1
      end
    end

    -- Footer: scroll hint
    monitor.setCursorPos(1, h)
    monitor.write("Touch top=scroll up, bottom=down")
  end

  function panel.touch(x, y)
    local w, h = 51, 19
    if type(y) == "number" then
      if y < h / 2 then
        log_offset = log_offset + 3
      else
        log_offset = math.max(0, log_offset - 3)
      end
    end
  end

  return panel
end

return diagnostics_panel
