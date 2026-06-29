--[[
Purpose: Render external panel state to a CC:Tweaked monitor.
Public API: render(monitor, state), render_header(monitor, state).
]]

local panel_renderer = {}

local function count_table(t)
  local count = 0
  for _ in pairs(t or {}) do count = count + 1 end
  return count
end

local function line(monitor, row, text)
  monitor.setCursorPos(1, row)
  monitor.write(tostring(text))
end

local function short(text, max_len)
  local value = tostring(text or "")
  local limit = max_len or 38
  if #value <= limit then return value end
  return string.sub(value, 1, limit - 3) .. "..."
end

function panel_renderer.render_header(monitor, state)
  -- Use color if available
  local has_color = false
  if monitor and monitor.isColor then
    local ok, v = pcall(function() return monitor.isColor() end)
    has_color = ok and v
  end
  if has_color then
    pcall(monitor.setBackgroundColor, 8192)  -- green
    pcall(monitor.setTextColor, 1)            -- white
  end
  local w = 51
  if monitor and monitor.getSize then w = monitor.getSize() end
  if monitor then
    pcall(monitor.setCursorPos, 1, 1)
    pcall(monitor.write, string.rep(" ", w))
    pcall(monitor.setCursorPos, 1, 1)
    pcall(monitor.write, " CreateRailNet  " .. tostring(state.display_name or state.panel_id):sub(1,15))
    local page_str = tostring(state.page or "overview"):upper()
    pcall(monitor.setCursorPos, w - #page_str, 1)
    pcall(monitor.write, page_str)
  end
  if has_color then
    pcall(monitor.setBackgroundColor, 32768)  -- black
    pcall(monitor.setTextColor, 1)
  end
  line(monitor, 2, "Master: " .. tostring(state.master_state or "UNBEKANNT") ..
    (state.maintenance_locked and "  [WARTUNG]" or ""))
end

local function render_overview(monitor, state)
  line(monitor, 5, "Overview")
  line(monitor, 6, "Blocks: " .. tostring(count_table(state.overview)))
  local row = 8
  for block_id, block in pairs(state.overview or {}) do line(monitor, row, block_id .. " " .. tostring(block.state or "-")); row = row + 1 end
end

local function render_trains(monitor, state)
  line(monitor, 5, "Trains")
  local row = 7
  for train_id, train in pairs(state.trains or {}) do
    line(monitor, row, train_id .. " " .. tostring(train.state or "-") .. " Sch " .. tostring(train.schedule_state or "-")); row = row + 1
    line(monitor, row, "  Route " .. tostring(train.route_id or "-") .. " Dest " .. tostring(train.destination or "-")); row = row + 1
    line(monitor, row, "  Plan " .. tostring(train.service_plan or "-") .. " Stop " .. tostring(train.service_stop_index or "-")); row = row + 1
    if train.error or train.message then line(monitor, row, "  ! " .. short(train.error or train.message)); row = row + 1 end
  end
end

local function render_stations(monitor, state)
  line(monitor, 5, "Stations")
  local row = 7
  for station_id, station in pairs(state.stations or {}) do
    line(monitor, row, station_id .. " " .. tostring(station.station_type or "mixed") .. " " .. tostring(station.state or "-")); row = row + 1
    for platform_id, platform in pairs(station.platforms or {}) do line(monitor, row, "  " .. platform_id .. " " .. tostring(platform.kind or "mixed") .. " " .. tostring(platform.state or "-") .. " " .. tostring(platform.train_name or platform.train_id or "")); row = row + 1 end
  end
end

local function render_depots(monitor, state)
  line(monitor, 5, "Depots")
  local row = 7
  for depot_id, depot in pairs(state.depots or {}) do
    line(monitor, row, depot_id .. " " .. tostring(depot.depot_type or "mixed") .. " " .. tostring(depot.state or "-")); row = row + 1
    for track_id, track in pairs(depot.tracks or {}) do line(monitor, row, "  " .. track_id .. " " .. tostring(track.kind or "mixed") .. " " .. tostring(track.state or "-") .. " " .. tostring(track.train_name or track.train_id or "")); row = row + 1 end
    line(monitor, row, "  Queue " .. tostring(#(depot.queue or {}))); row = row + 1
  end
end

local function render_service_plans(monitor, state)
  line(monitor, 5, "Service Plans")
  local row = 7
  for plan_id, plan in pairs(state.service_plans or {}) do
    line(monitor, row, plan_id .. " " .. tostring(plan.state or "-") .. " Train " .. tostring(plan.train_id or "-")); row = row + 1
    line(monitor, row, "  Current " .. tostring(plan.current_index or "-") .. " / " .. tostring(#(plan.stops or {}))); row = row + 1
    local stop = plan.stops and plan.stops[plan.current_index or 1]
    if stop then line(monitor, row, "  Next " .. tostring(stop.from or "-") .. " -> " .. tostring(stop.to or "-")); row = row + 1 end
  end
end

local function render_manual(monitor, state)
  line(monitor, 5, "Manual Control")
  line(monitor, 6, "Touch action row")
  local row = 7
  for _, action in ipairs(state.manual_actions or {}) do line(monitor, row, tostring(action.label or action.action or "action")); row = row + 1 end
  if state.last_action then line(monitor, row + 1, "Last: " .. tostring(state.last_action)) end
end

local function render_recent_logs(monitor, row, logs)
  line(monitor, row, "Recent logs")
  row = row + 1
  for _, entry in ipairs(logs or {}) do line(monitor, row, short(tostring(entry.level or "-") .. " " .. tostring(entry.msg or "-"))); row = row + 1 end
  return row
end

local function render_diagnostics(monitor, state)
  local diag = state.diagnostics or {}
  local health = diag.node_health or {}
  local cfg = diag.config or {}
  local maintenance = diag.maintenance or {}
  line(monitor, 5, "Diagnostics")
  line(monitor, 6, "Maint: " .. tostring(maintenance.enabled and "LOCKED" or "open") .. " " .. tostring(maintenance.reason or ""))
  line(monitor, 7, "Nodes up/down: " .. tostring(health.up or 0) .. "/" .. tostring(health.down or 0) .. " total " .. tostring(health.total or 0))
  line(monitor, 8, "Cfg N/B/R/SP: " .. tostring(cfg.nodes or 0) .. "/" .. tostring(cfg.blocks or 0) .. "/" .. tostring(cfg.routes or 0) .. "/" .. tostring(cfg.service_plans or 0))
  line(monitor, 9, "Queue: " .. tostring(#(diag.queue or {})) .. " Deadlocks: " .. tostring(count_table(diag.deadlocks or {})))
  line(monitor, 10, "SwitchLocks: " .. tostring(count_table(diag.switch_locks or {})) .. " Pending: " .. tostring(count_table(diag.pending_departures or {})))
  local row = render_recent_logs(monitor, 12, diag.recent_logs or {})
  if row < 18 then line(monitor, row + 1, "Channel: " .. tostring(cfg.channel or "-") .. " Master: " .. tostring(cfg.master_id or "-")) end
end

local function render_audit(monitor, state)
  local audit = (state.diagnostics or {}).recent_audit or {}
  line(monitor, 5, "Audit")
  local row = 7
  for _, entry in ipairs(audit) do
    local data = entry.data or entry.payload or {}
    local msg = "#" .. tostring(entry.seq or "-") .. " " .. tostring(entry.kind or "-")
    if data.train_id then msg = msg .. " T=" .. tostring(data.train_id) end
    if data.route_id then msg = msg .. " R=" .. tostring(data.route_id) end
    if data.reason then msg = msg .. " " .. tostring(data.reason) end
    line(monitor, row, short(msg)); row = row + 1
  end
  if #audit == 0 then line(monitor, row, "No audit entries") end
end

local function render_maintenance(monitor, state)
  local diag = state.diagnostics or {}
  local maintenance = diag.maintenance or {}
  line(monitor, 5, "Maintenance")
  line(monitor, 7, "State: " .. tostring(maintenance.enabled and "LOCKED" or "open"))
  line(monitor, 8, "Reason: " .. short(maintenance.reason or "-"))
  line(monitor, 9, "By: " .. tostring(maintenance.changed_by or "-"))
  line(monitor, 11, "Use Manual page actions")
  line(monitor, 12, "Enter/Exit Maintenance")
  line(monitor, 14, "Queue: " .. tostring(#(diag.queue or {})))
  line(monitor, 15, "Pending departures: " .. tostring(count_table(diag.pending_departures or {})))
end

function panel_renderer.render(monitor, state)
  if not monitor then return end
  monitor.clear()
  panel_renderer.render_header(monitor, state)
  if state.page == "trains" then render_trains(monitor, state)
  elseif state.page == "stations" then render_stations(monitor, state)
  elseif state.page == "depots" then render_depots(monitor, state)
  elseif state.page == "service_plans" then render_service_plans(monitor, state)
  elseif state.page == "manual" then render_manual(monitor, state)
  elseif state.page == "diagnostics" then render_diagnostics(monitor, state)
  elseif state.page == "audit" then render_audit(monitor, state)
  elseif state.page == "maintenance" then render_maintenance(monitor, state)
  else render_overview(monitor, state) end
end

return panel_renderer
