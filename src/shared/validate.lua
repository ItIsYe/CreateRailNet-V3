--[[
Purpose: Validate network configuration with actionable errors.
Public API: validate_config(cfg) -> ok, errors.
]]

local validate = {}

local roles = { master = true, signal = true, sensor = true, switch = true, station = true, depot = true, panel = true, train = true }
local station_types = { passenger = true, freight = true, mixed = true }
local depot_types = { storage = true, staging = true, mixed = true }

local function add(errors, path, message)
  table.insert(errors, path .. ": " .. message)
end

local function nonempty(value)
  return type(value) == "string" and value ~= ""
end

function validate.validate_config(cfg)
  local errors = {}
  if type(cfg) ~= "table" then add(errors, "config", "must be an object"); return false, errors end
  if cfg.v ~= 1 then add(errors, "v", "must be 1") end
  if type(cfg.channel) ~= "number" or cfg.channel <= 0 or cfg.channel % 1 ~= 0 then add(errors, "channel", "must be integer > 0") end
  if not nonempty(cfg.master_id) then add(errors, "master_id", "must be non-empty string") end
  if type(cfg.blocks) ~= "table" then add(errors, "blocks", "must be an array") end
  if type(cfg.routes) ~= "table" then add(errors, "routes", "must be an array") end
  if type(cfg.nodes) ~= "table" then add(errors, "nodes", "must be an array") end

  local node_ids, block_ids, route_ids, node_roles = {}, {}, {}, {}
  local train_ids, service_plan_ids = {}, {}

  for i, node in ipairs(cfg.nodes or {}) do
    local path = "nodes[" .. i .. "]"
    if not nonempty(node.id) then add(errors, path .. ".id", "must be non-empty string")
    elseif node_ids[node.id] then add(errors, path .. ".id", "duplicate node id \"" .. node.id .. "\"")
    else node_ids[node.id] = true end

    if not roles[node.role] then add(errors, path .. ".role", "invalid role \"" .. tostring(node.role) .. "\"")
    else node_roles[node.id] = node.role end

    if node.role == "train" then
      local train_id = node.train_id or node.id
      train_ids[train_id] = true
    elseif node.role == "station" then
      local station_type = node.station_type or node.type or "mixed"
      if not station_types[station_type] then add(errors, path .. ".station_type", "must be passenger, freight, or mixed") end
      for j, platform in ipairs(node.platforms or node.tracks or {}) do
        if not nonempty(platform.id or platform.track_id or platform.name) then add(errors, path .. ".platforms[" .. j .. "].id", "must be non-empty string") end
      end
    elseif node.role == "depot" then
      for j, track in ipairs(node.tracks or node.slots or {}) do
        if not nonempty(track.id or track.track_id or track.name) then add(errors, path .. ".tracks[" .. j .. "].id", "must be non-empty string") end
        local kind = track.kind or track.type or "storage"
        if not depot_types[kind] then add(errors, path .. ".tracks[" .. j .. "].kind", "must be storage, staging, or mixed") end
      end
    elseif node.role == "panel" then
      for j, page in ipairs(node.pages or {}) do
        if not nonempty(page) then add(errors, path .. ".pages[" .. j .. "]", "must be non-empty string") end
      end
    end
  end

  if cfg.master_id and node_roles[cfg.master_id] ~= "master" then add(errors, "master_id", "must reference node with role master") end

  for i, block in ipairs(cfg.blocks or {}) do
    local path = "blocks[" .. i .. "]"
    if not nonempty(block.id) then add(errors, path .. ".id", "must be non-empty string")
    elseif block_ids[block.id] then add(errors, path .. ".id", "duplicate block id \"" .. block.id .. "\"")
    else block_ids[block.id] = true end
    if not nonempty(block.entry_signal) or node_roles[block.entry_signal] ~= "signal" then add(errors, path .. ".entry_signal", "references unknown signal node \"" .. tostring(block.entry_signal) .. "\"") end
    if not nonempty(block.exit_signal) or node_roles[block.exit_signal] ~= "signal" then add(errors, path .. ".exit_signal", "references unknown signal node \"" .. tostring(block.exit_signal) .. "\"") end
    for j, sensor_id in ipairs(block.sensors or {}) do if node_roles[sensor_id] ~= "sensor" then add(errors, path .. ".sensors[" .. j .. "]", "references unknown sensor node \"" .. tostring(sensor_id) .. "\"") end end
    for j, switch_def in ipairs(block.switches or {}) do
      if node_roles[switch_def.id] ~= "switch" then add(errors, path .. ".switches[" .. j .. "].id", "references unknown switch node \"" .. tostring(switch_def.id) .. "\"") end
      if type(switch_def.position) ~= "string" or switch_def.position == "" then add(errors, path .. ".switches[" .. j .. "].position", "must be non-empty string") end
    end
  end

  for i, route in ipairs(cfg.routes or {}) do
    local path = "routes[" .. i .. "]"
    if not nonempty(route.id) then add(errors, path .. ".id", "must be non-empty string")
    elseif route_ids[route.id] then add(errors, path .. ".id", "duplicate route id \"" .. route.id .. "\"")
    else route_ids[route.id] = true end
    if type(route.from) ~= "string" then add(errors, path .. ".from", "must be a string") end
    if type(route.to) ~= "string" then add(errors, path .. ".to", "must be a string") end
    for j, block_id in ipairs(route.blocks or {}) do if not block_ids[block_id] then add(errors, path .. ".blocks[" .. j .. "]", "references unknown block \"" .. tostring(block_id) .. "\"") end end
  end

  for i, plan in ipairs((cfg.service_plans or cfg.schedules or {})) do
    local path = "service_plans[" .. i .. "]"
    if not nonempty(plan.id) then add(errors, path .. ".id", "must be non-empty string")
    elseif service_plan_ids[plan.id] then add(errors, path .. ".id", "duplicate service plan id \"" .. plan.id .. "\"")
    else service_plan_ids[plan.id] = true end
    if plan.train_id and not train_ids[plan.train_id] then add(errors, path .. ".train_id", "references unknown train \"" .. tostring(plan.train_id) .. "\"") end
    if type(plan.stops) ~= "table" or #plan.stops == 0 then add(errors, path .. ".stops", "must contain at least one stop") end
    for j, stop in ipairs(plan.stops or {}) do
      local stop_path = path .. ".stops[" .. j .. "]"
      if stop.route_id and not route_ids[stop.route_id] then add(errors, stop_path .. ".route_id", "references unknown route \"" .. tostring(stop.route_id) .. "\"") end
      if not stop.route_id and (not nonempty(stop.from) or not nonempty(stop.to or stop.destination)) then add(errors, stop_path, "must provide route_id or from/to") end
      if stop.dwell_seconds and (type(stop.dwell_seconds) ~= "number" or stop.dwell_seconds < 0) then add(errors, stop_path .. ".dwell_seconds", "must be number >= 0") end
    end
  end

  for i, node in ipairs(cfg.nodes or {}) do
    if node.role == "train" and node.service_plan and not service_plan_ids[node.service_plan] then add(errors, "nodes[" .. i .. "].service_plan", "references unknown service plan \"" .. tostring(node.service_plan) .. "\"") end
  end

  return #errors == 0, errors
end

return validate
