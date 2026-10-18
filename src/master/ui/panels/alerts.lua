--[[
Purpose: Message page: open alerts with acknowledgement by touch, paged.
Public API: new(alerts, manual_control) -> panel with draw(monitor), touch(x, y)
Notes: touching a row acknowledges that message, the bottom row has "ALLE QUITT." on the left and previous/next page on the right.
  Unacknowledged red alerts come first; a fault that cleared itself stays listed until it was acknowledged.
]]

local ui_utils = require("src.master.ui.ui_utils")

local alerts_panel = {}

local FIRST_ROW = 3

function alerts_panel.new(alerts, manual_control)
  local panel = { page = 1 }
  local C = ui_utils.colors
  local rows = {}      -- row on screen -> alert key, rebuilt on every draw
  local height, width = 19, 51
  local pages = 1

  local function per_page() return math.max(1, height - FIRST_ROW - 1) end

  local function age_text(seconds)
    if seconds < 90 then return string.format("%ds", seconds) end
    if seconds < 5400 then return string.format("%dm", math.floor(seconds / 60)) end
    return string.format("%dh", math.floor(seconds / 3600))
  end

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    width, height = w, h
    u.clear(C.black)
    local counts = alerts and alerts.counts() or { total = 0, unacked = 0, active_red = 0, active_yellow = 0 }
    u.header(1, "MELDUNGEN", string.format("%d offen", counts.unacked), w)

    local list = alerts and alerts.list() or {}
    pages = math.max(1, math.ceil(#list / per_page()))
    if panel.page > pages then panel.page = pages end
    rows = {}
    local first = (panel.page - 1) * per_page() + 1
    local now = (require("src.shared.time")).now_s()
    if #list == 0 then u.write_at(2, FIRST_ROW, "Keine Meldungen.", C.lime) end
    for i = first, math.min(#list, first + per_page() - 1) do
      local e = list[i]
      local row = FIRST_ROW + (i - first)
      rows[row] = e.key
      local marker = e.state == "CLEARED" and "ok" or (e.severity == "RED" and "!!" or "? ")
      local color = e.acked and C.lightGray or (e.severity == "RED" and C.red or C.yellow)
      local suffix = (e.count > 1 and (" x" .. e.count) or "") .. (e.state == "CLEARED" and " behoben" or "") .. (e.acked and " (quitt.)" or "")
      local text = string.format("%s %s %s%s", marker, age_text(math.max(0, now - e.last_at)), e.text, suffix)
      u.write_at(1, row, text:sub(1, w), color)
    end
    u.footer(h, string.format("[ALLE QUITT.]  <  Seite %d/%d  >", panel.page, pages), w)
  end

  function panel.touch(x, y)
    if y == height then
      if x <= 14 then
        if manual_control then manual_control.handle({ action = "ack_alert", all = true }, "panel") end
      elseif x <= math.floor((width + 14) / 2) then
        panel.page = math.max(1, panel.page - 1)
      else
        panel.page = math.min(pages, panel.page + 1)
      end
      return
    end
    local key = rows[y]
    if key and manual_control then manual_control.handle({ action = "ack_alert", key = key }, "panel") end
  end

  return panel
end

return alerts_panel
