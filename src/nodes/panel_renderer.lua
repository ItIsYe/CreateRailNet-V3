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

function panel_renderer.render_header(monitor, state)
  line(monitor, 1, "CreateRailNet Panel")
  line(monitor, 2, tostring(state.display_name or state.panel_id) .. " | " .. tostring(state.page or "overview"))
  line(monitor, 3, "Master: " .. tostring(state.master_state or "UNKNOWN"))
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
  end
end

local function render_stations(monitor, state)
  line(monitor, 5, "Stations")
  local row = 7
  for station_id, station in pairs(state.stations or {}) do
    line(monitor, row, station_id .. " " .. tostring(station.station_type or "mixed") .. " " .. tostring(station.state or "-")); row = row + 1
    for platform_id, platform in pairs(station.platforms or {}) do line(monitor, row, "  " .. platform_id .. " " .. tostring(platform.kind or "mixed") .. " " .. tostring(platform.state or "-")); row = row + 1 end
  end
end

local function render_depots(monitor, state)
  line(monitor, 5, "Depots")
  local row = 7
  for depot_id, depot in pairs(state.depots or {}) do
    line(monitor, row, depot_id .. " " .. tostring(depot.depot_type or "mixed") .. " " .. tostring(depot.state or "-")); row = row + 1
    for track_id, track in pairs(depot.tracks or {}) do line(monitor, row, "  " .. track_id .. " " .. tostring(track.kind or "mixed") .. " " .. tostring(track.state or "-")); row = row + 1 end
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
  for _, action in ipairs(state.manual_actions or {}) do
    line(monitor, row, tostring(action.label or action.action or "action"))
    row = row + 1
  end
  if state.last_action then line(monitor, row + 1, "Last: " .. tostring(state.last_action)) end
end

local function render_recent_logs(monitor, row, logs)
  line(monitor, row, "Recent logs")
  row = row + 1
  for _, entry in ipairs(logs or {}) do
    line(monitor, row, tostring(entry.level or "-") .. " " .. tostring(entry.msg or "-"))
    row = row + 1
  end
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
  else render_overview(monitor, state) end
end

return panel_renderer
