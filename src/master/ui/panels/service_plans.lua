--[[
Purpose: Service plans panel — timetable view, stop progress, active plans.
]]

local ui_utils = require("src.master.ui.ui_utils")
local service_plans_panel = {}

function service_plans_panel.new(service_plan_registry, train_registry)
  local self = { offset = 0 }
  local C = ui_utils.colors

  function self.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()

    u.clear(C.black)
    u.header(1, "FAHRPLAENE", nil, w)

    local plans = service_plan_registry and service_plan_registry.list and service_plan_registry.list() or {}
    local sorted = {}
    for id, p in pairs(plans) do table.insert(sorted, {id=id, p=p}) end
    table.sort(sorted, function(a,b) return a.id < b.id end)

    if #sorted == 0 then
      u.write_at(3, 4, "Kein Fahrplan konfiguriert.", C.lightGray)
      u.write_at(3, 6, "Fahrplaene in network.json unter", C.lightGray)
      u.write_at(3, 7, "service_plans definieren.", C.lightGray)
      u.footer(h, "", w)
      return
    end

    u.fill_line(2, C.gray, w)
    u.write_at(1, 2, string.format("%-14s %-10s %-8s %-12s", "FAHRPLAN", "ZUG", "STOP", "NAECHSTE"), C.white, C.gray)

    local row = 3
    local start = self.offset + 1

    for i = start, #sorted do
      if row > h - 3 then break end
      local entry = sorted[i]
      local p = entry.p
      local total_stops = #(p.stops or {})

      -- Get train status for this plan
      local train = nil
      if train_registry and p.train_id then
        local all_trains = train_registry.list and train_registry.list() or {}
        train = all_trains[p.train_id]
      end

      local current_stop = (train and train.service_stop_index) or p.current_index or 0
      local plan_active = train and train.service_plan == entry.id

      -- Plan header row
      u.fill_line(row, C.black, w)

      local plan_col = plan_active and C.lime or C.lightGray
      u.write_at(1, row, (plan_active and "►" or " ") .. " ", plan_col)
      u.write_at(3, row, tostring(entry.id):sub(1, 12), C.white)
      u.write_at(16, row, tostring(p.train_id or "-"):sub(1, 10), C.yellow)

      -- Stop progress
      if total_stops > 0 then
        local stop_str = string.format("%d/%d", math.max(0, current_stop), total_stops)
        u.write_at(27, row, stop_str, plan_active and C.cyan or C.lightGray)

        -- Progress bar
        local bar_w = math.min(15, w - 44)
        local pct = math.min(1.0, (current_stop or 0) / math.max(1, total_stops))
        local filled = math.floor(pct * bar_w)
        local bar = "[" .. string.rep("█", filled) .. string.rep("░", bar_w - filled) .. "]"
        u.write_at(w - bar_w - 2, row, bar, plan_active and C.lime or C.gray)
      end
      row = row + 1

      -- Current and next stop
      if row <= h - 3 then
        u.fill_line(row, C.black, w)
        local stops = p.stops or {}
        local cur = stops[current_stop]
        local nxt = stops[(current_stop or 0) + 1]
        if cur then
          u.write_at(3, row, string.format("  Von:%-8s Nach:%-8s", tostring(cur.from or "-"):sub(1,8), tostring(cur.to or "-"):sub(1,8)), C.lightGray)
        end
        if nxt then
          u.write_at(36, row, string.format("N:%-8s", tostring(nxt.to or "-"):sub(1,8)), C.cyan)
        end
        if p.repeat_plan then
          u.write_at(w - 5, row, "LOOP", C.purple)
        end
        row = row + 1
      end

      -- Separator
      if i < #sorted and row <= h - 3 then
        u.fill_line(row, C.black, w)
        u.write_at(1, row, string.rep("-", w), C.gray)
        row = row + 1
      end
    end

    u.footer(h, string.format("► = aktiv  %d/%d Fahrplaene", math.min(self.offset+1, #sorted), #sorted), w)
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

return service_plans_panel
