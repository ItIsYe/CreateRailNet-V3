--[[
Purpose: Station panel — platform status, dwelling trains, dwell progress.
]]

local ui_utils = require("src.master.ui.ui_utils")
local stations_panel = {}

local PLAT_LABELS = {
  EMPTY="FREI", DWELLING="DWELL", READY_TO_DEPART="ABFAHRT",
  RESERVED="RESERV", FAULT="STOER", UNKNOWN="?", OCCUPIED="BESETZT"
}

function stations_panel.new(station_registry)
  local self = { offset = 0 }
  local C = ui_utils.colors

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "BAHNHOEFE", nil, w)

    local stations = station_registry and station_registry.list() or {}
    local sorted = {}
    for id, s in pairs(stations) do table.insert(sorted, {id=id, s=s}) end
    table.sort(sorted, function(a, b) return a.id < b.id end)

    if #sorted == 0 then
      u.write_at(3, 4, "Keine Bahnhoefe registriert.", C.lightGray)
      u.footer(h, "Warte auf Station-Verbindung...", w)
      return
    end

    -- Column header
    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-16s %-8s %-10s %-12s", "STATION", "STATUS", "PLATTFORM", "ZUG"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 2 then break end
      local entry = sorted[i]
      local s = entry.s

      -- Station header row
      local st_online = (s.state == "ONLINE")
      u.fill_line(row, C.black, w)
      local st_col = st_online and C.lime or C.gray
      u.write_at(1, row, (st_online and "■" or "□") .. " ", st_col)
      u.write_at(3, row, tostring(entry.id):sub(1, 14), C.white)
      u.write_at(18, row, tostring(s.state or "-"):sub(1, 8), st_col)
      local stype = tostring(s.station_type or s.type or "mixed"):sub(1,8)
      u.write_at(w - #stype, row, stype, C.lightGray)
      row = row + 1

      -- Platforms
      local plats = {}
      for pid, p in pairs(s.platforms or {}) do table.insert(plats, {id=pid, p=p}) end
      table.sort(plats, function(a,b) return a.id < b.id end)

      for _, pe in ipairs(plats) do
        if row > h - 2 then break end
        local p = pe.p
        local state_col = (ui_utils.STATE_COLORS[tostring(p.state)] or {fg=C.lightGray}).fg
        local plat_label = PLAT_LABELS[tostring(p.state)] or tostring(p.state or "?")

        u.fill_line(row, C.black, w)
        u.write_at(3, row, "  " .. tostring(pe.id):sub(1,6), C.lightGray)
        u.state_badge(10, row, p.state)
        u.write_at(15, row, plat_label:sub(1,8), state_col)

        local train_str = tostring(p.train_name or p.train_id or ""):sub(1, 14)
        if train_str ~= "" then
          u.write_at(24, row, train_str, C.yellow)
        end

        -- Show dwell progress as a bar if dwelling
        if p.state == "DWELLING" and p.occupied_since then
          local elapsed = math.floor(os.clock() - (p.occupied_since or os.clock()))
          local dwell = p.dwell_seconds or 15
          local pct = math.min(1.0, elapsed / math.max(1, dwell))
          local bar_w = math.min(10, w - 40)
          local filled = math.floor(pct * bar_w)
          local bar = "[" .. string.rep("=", filled) .. string.rep("-", bar_w - filled) .. "]"
          u.write_at(w - #bar - 2, row, bar, C.cyan)
        end
        row = row + 1
      end

      -- Station separator
      if row <= h - 2 and i < #sorted then
        u.fill_line(row, C.black, w)
        u.write_at(1, row, string.rep("-", w), C.gray)
        row = row + 1
      end
    end

    u.footer(h, string.format("Antippen zum Scrollen  %d/%d Bhf", math.min(self.offset+1, #sorted), #sorted), w)
  end

  function self.touch(x, y)
    local _, h = 51, 19
    if y > h / 2 then
      self.offset = self.offset + 1
    else
      self.offset = math.max(0, self.offset - 1)
    end
  end

  return self
end

return stations_panel
