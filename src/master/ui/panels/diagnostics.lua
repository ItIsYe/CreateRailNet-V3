--[[
Purpose: Diagnostics panel — system health, faults, log stream, queue status.
]]

local ui_utils = require("src.master.ui.ui_utils")
local diagnostics_panel = {}

function diagnostics_panel.new(logger, dispatcher)
  local panel = { log_offset = 0 }
  local C = ui_utils.colors

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "SYSTEMDIAGNOSE", nil, w)

    local row = 3
    local overview = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}

    -- ── Fault blocks ──────────────────────────────────────────────
    local faults = {}
    local free, reserved, occupied, fault_count = 0, 0, 0, 0
    for id, b in pairs(overview) do
      if b.state == "FAULT" then
        fault_count = fault_count + 1
        table.insert(faults, id)
      elseif b.state == "FREE" then free = free + 1
      elseif b.state == "RESERVED" then reserved = reserved + 1
      elseif b.state == "OCCUPIED" then occupied = occupied + 1
      end
    end
    table.sort(faults)

    -- Block summary bar
    u.fill_line(row, C.black, w)
    u.write_at(1, row, "BLOECKE  ", C.cyan)
    u.write_at(10, row, "Frei:" .. free, C.lime)
    u.write_at(20, row, "Res:" .. reserved, C.yellow)
    u.write_at(29, row, "Bes:" .. occupied, C.orange)
    if fault_count > 0 then
      u.write_at(38, row, "STOER:" .. fault_count, C.white, C.red)
    else
      u.write_at(38, row, "OK", C.lime)
    end
    row = row + 1

    -- Fault list
    if fault_count > 0 then
      for _, fid in ipairs(faults) do
        if row > 6 then break end
        u.write_at(1, row, "  !! " .. tostring(fid):sub(1, w-6), C.white, C.red)
        row = row + 1
      end
      if fault_count > 3 then
        u.write_at(1, row, string.format("  ... und %d weitere Stoerungen", fault_count - 3), C.red)
        row = row + 1
      end
    end

    row = 7
    u.separator(row, w); row = row + 1

    -- ── Log stream ────────────────────────────────────────────────
    u.write_at(1, row, "SYSTEM-LOG", C.cyan)
    row = row + 1

    local buffer = (logger and logger.get_buffer and logger.get_buffer()) or {}
    local max_lines = h - row - 1
    local start = math.max(1, #buffer - max_lines - panel.log_offset + 1)
    local last = math.min(#buffer, start + max_lines - 1)

    local level_colors = {
      ERROR = C.red, WARN = C.yellow, INFO = C.white, DEBUG = C.lightGray
    }

    for i = start, last do
      local entry = buffer[i]
      if entry and row <= h - 1 then
        local lvl = tostring(entry.level or "?"):sub(1,5)
        local msg = tostring(entry.msg or ""):sub(1, w - #lvl - 3)
        local lc = level_colors[lvl] or C.lightGray
        u.write_at(1, row, "[" .. lvl .. "] ", lc)
        u.write_at(#lvl + 3, row, msg, C.white)
        row = row + 1
      end
    end

    -- Scroll hint
    local scroll_hint = ""
    if panel.log_offset > 0 then scroll_hint = "^scrolling^ " end
    u.footer(h, scroll_hint .. "Oben=zurueck  Unten=neuer  " .. #buffer .. " Eintraege", w)
  end

  function panel.touch(x, y)
    local _, h = 51, 19
    if y < h / 2 then
      panel.log_offset = panel.log_offset + 3
    else
      panel.log_offset = math.max(0, panel.log_offset - 3)
    end
  end

  return panel
end

return diagnostics_panel
