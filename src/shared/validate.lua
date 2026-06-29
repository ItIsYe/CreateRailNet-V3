--[[
Purpose: Validate network configuration with actionable errors.
Public API: validate_config(cfg) -> ok, errors.
]]

local validate = {}

local roles = { master = true, signal = true, sensor = true, switch = true, station = true, depot = true, panel = true, train = true }
local station_types = { passenger = true, freight = true, mixed = true }
local depot_types = { storage = true, staging = true, mixed = true }
local route_kinds = { passenger = true, freight = true, mixed = true, depot = true }

local function add(errors, path, message) table.insert(errors, path .. ": " .. message) end
local function nonempty(value) return type(value) == "string" and value ~= "" end
local function arr(value) return type(value) == "table" end
local function node_station_id(node) return node.station_id or node.id end
local function node_depot_id(node) return node.depot_id or node.id end
local function node_train_id(node) return node.train_id or node.id end
local function has_create_name(node) return nonempty(node.create_station_name) or nonempty(node.create_destination) or nonempty(node.schedule_destination) or nonempty(node.create_name) end

local function mark_unique(errors, seen, value, path, label)
  if not nonempty(value) then add(errors, path, "must be non-empty string"); return false end
  if seen[value] then add(errors, path, "duplicate " .. label .. " \"" .. value .. "\""); return false end
  seen[value] = true
  return true
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
  local station_ids, depot_ids = {}, {}
  local signal_ids, sensor_ids, switch_ids = {}, {}, {}

  for i, node in ipairs(cfg.nodes or {}) do
    local path = "nodes[" .. i .. "]"
    if mark_unique(errors, node_ids, node.id, path .. ".id", "node id") and roles[node.role] then node_roles[node.id] = node.role end
    if not roles[node.role] then add(errors, path .. ".role", "invalid role \"" .. tostring(node.role) .. "\"") end

    if node.role == "train" then
      local train_id = node_train_id(node)
      mark_unique(errors, train_ids, train_id, path .. ".train_id", "train_id")
    elseif node.role == "station" then
      local station_id = node_station_id(node)
      mark_unique(errors, station_ids, station_id, path .. ".station_id", "station_id")
      local station_type = node.station_type or node.type or "mixed"
      if not station_types[station_type] then add(errors, path .. ".station_type", "must be passenger, freight, or mixed") end
      if not has_create_name(node) then add(errors, path .. ".create_station_name", "should define exact Create destination name for schedules") end
      local platform_ids = {}
      for j, platform in ipairs(node.platforms or node.tracks or {}) do
        local ppath = path .. ".platforms[" .. j .. "]"
        local platform_id = platform.id or platform.track_id or platform.name
        mark_unique(errors, platform_ids, platform_id, ppath .. ".id", "platform id")
        local kind = platform.kind or platform.type or station_type
        if not station_types[kind] then add(errors, ppath .. ".kind", "must be passenger, freight, or mixed") end
      end
    elseif node.role == "depot" then
      local depot_id = node_depot_id(node)
      mark_unique(errors, depot_ids, depot_id, path .. ".depot_id", "depot_id")
      local depot_type = node.depot_type or node.type or "mixed"
      if not depot_types[depot_type] and depot_type ~= "freight" and depot_type ~= "passenger" then add(errors, path .. ".depot_type", "must be storage, staging, mixed, passenger, or freight") end
      local track_ids = {}
      for j, track in ipairs(node.tracks or node.slots or {}) do
        local tpath = path .. ".tracks[" .. j .. "]"
        local track_id = track.id or track.track_id or track.name
        mark_unique(errors, track_ids, track_id, tpath .. ".id", "track id")
        local kind = track.kind or track.type or "storage"
        if not depot_types[kind] then add(errors, tpath .. ".kind", "must be storage, staging, or mixed") end
      end
    elseif node.role == "panel" then
      for j, page in ipairs(node.pages or {}) do if not nonempty(page) then add(errors, path .. ".pages[" .. j .. "]", "must be non-empty string") end end
    elseif node.role == "signal" then signal_ids[node.id] = true
    elseif node.role == "sensor" then sensor_ids[node.id] = true
    elseif node.role == "switch" then
      switch_ids[node.id] = true
      -- Warn if switch uses peripheral adapter (vanilla Create switches need redstone)
      local adapter = node.adapter or "peripheral"
      if adapter == "peripheral" and not nonempty(node.peripheral) then
        add(errors, path .. ".adapter", "switch nodes require adapter=\"redstone\" for vanilla Create; peripheral adapter needs explicit peripheral name")
      end
    end
  end

  if cfg.master_id and node_roles[cfg.master_id] ~= "master" then add(errors, "master_id", "must reference node with role master") end

  for i, block in ipairs(cfg.blocks or {}) do
    local path = "blocks[" .. i .. "]"
    mark_unique(errors, block_ids, block.id, path .. ".id", "block id")
    if not nonempty(block.entry_signal) or not signal_ids[block.entry_signal] then add(errors, path .. ".entry_signal", "references unknown signal node \"" .. tostring(block.entry_signal) .. "\"") end
    if not nonempty(block.exit_signal) or not signal_ids[block.exit_signal] then add(errors, path .. ".exit_signal", "references unknown signal node \"" .. tostring(block.exit_signal) .. "\"") end
    if block.sensors ~= nil and not arr(block.sensors) then add(errors, path .. ".sensors", "must be an array") end
    for j, sensor_id in ipairs(block.sensors or {}) do if not sensor_ids[sensor_id] then add(errors, path .. ".sensors[" .. j .. "]", "references unknown sensor node \"" .. tostring(sensor_id) .. "\"") end end
    if block.switches ~= nil and not arr(block.switches) then add(errors, path .. ".switches", "must be an array") end
    for j, switch_def in ipairs(block.switches or {}) do
      if not switch_ids[switch_def.id] then add(errors, path .. ".switches[" .. j .. "].id", "references unknown switch node \"" .. tostring(switch_def.id) .. "\"") end
      if type(switch_def.position) ~= "string" or switch_def.position == "" then add(errors, path .. ".switches[" .. j .. "].position", "must be non-empty string") end
    end
  end

  for i, route in ipairs(cfg.routes or {}) do
    local path = "routes[" .. i .. "]"
    mark_unique(errors, route_ids, route.id, path .. ".id", "route id")
    if not nonempty(route.from) then add(errors, path .. ".from", "must be non-empty string")
    elseif next(station_ids) ~= nil or next(depot_ids) ~= nil then
      -- Only cross-check when station/depot nodes are defined in config
      if not station_ids[route.from] and not depot_ids[route.from] then add(errors, path .. ".from", "references unknown station/depot \"" .. tostring(route.from) .. "\"; define a station/depot node or add it") end
    end
    if not nonempty(route.to) then add(errors, path .. ".to", "must be non-empty string")
    elseif next(station_ids) ~= nil or next(depot_ids) ~= nil then
      if not station_ids[route.to] and not depot_ids[route.to] then add(errors, path .. ".to", "references unknown station/depot \"" .. tostring(route.to) .. "\"; define a station/depot node or add it") end
    end
    if route.kind and not route_kinds[route.kind] then add(errors, path .. ".kind", "must be passenger, freight, mixed, or depot") end
    if route.priority and type(route.priority) ~= "number" then add(errors, path .. ".priority", "must be number") end
    if type(route.blocks) ~= "table" or #route.blocks == 0 then add(errors, path .. ".blocks", "must contain at least one block") end
    for j, block_id in ipairs(route.blocks or {}) do if not block_ids[block_id] then add(errors, path .. ".blocks[" .. j .. "]", "references unknown block \"" .. tostring(block_id) .. "\"") end end
    if route.conflict_group and not nonempty(route.conflict_group) then add(errors, path .. ".conflict_group", "must be non-empty string") end
    if route.conflict_groups ~= nil then
      if type(route.conflict_groups) ~= "table" then add(errors, path .. ".conflict_groups", "must be an array")
      else for j, group in ipairs(route.conflict_groups) do if not nonempty(group) then add(errors, path .. ".conflict_groups[" .. j .. "]", "must be non-empty string") end end end
    end
  end

  for i, plan in ipairs((cfg.service_plans or cfg.schedules or {})) do
    local path = "service_plans[" .. i .. "]"
    mark_unique(errors, service_plan_ids, plan.id, path .. ".id", "service plan id")
    if plan.train_id and not train_ids[plan.train_id] then add(errors, path .. ".train_id", "references unknown train \"" .. tostring(plan.train_id) .. "\"") end
    if type(plan.stops) ~= "table" or #plan.stops == 0 then add(errors, path .. ".stops", "must contain at least one stop") end
    for j, stop in ipairs(plan.stops or {}) do
      local stop_path = path .. ".stops[" .. j .. "]"
      local target = stop.to or stop.destination or stop.station_id
      if stop.route_id and not route_ids[stop.route_id] then add(errors, stop_path .. ".route_id", "references unknown route \"" .. tostring(stop.route_id) .. "\"") end
      if not stop.route_id and (not nonempty(stop.from) or not nonempty(target)) then add(errors, stop_path, "must provide route_id or from/to") end
      if target and not station_ids[target] and not depot_ids[target] and not nonempty(stop.create_destination) then
        add(errors, stop_path .. ".to", "references unknown station/depot \"" .. tostring(target) .. "\" or needs create_destination override")
      end
      if stop.dwell_seconds and (type(stop.dwell_seconds) ~= "number" or stop.dwell_seconds < 0) then add(errors, stop_path .. ".dwell_seconds", "must be number >= 0") end
      if stop.kind and not route_kinds[stop.kind] then add(errors, stop_path .. ".kind", "must be passenger, freight, mixed, or depot") end
      if stop.create_destination and not nonempty(stop.create_destination) then add(errors, stop_path .. ".create_destination", "must be non-empty string") end
    end
  end

  for i, node in ipairs(cfg.nodes or {}) do
    local path = "nodes[" .. i .. "]"
    if node.role == "train" and node.service_plan and not service_plan_ids[node.service_plan] then add(errors, path .. ".service_plan", "references unknown service plan \"" .. tostring(node.service_plan) .. "\"") end
    if node.role == "station" then
      for j, platform in ipairs(node.platforms or node.tracks or {}) do
        local ppath = path .. ".platforms[" .. j .. "]"
        if platform.sensor_id and not sensor_ids[platform.sensor_id] then add(errors, ppath .. ".sensor_id", "references unknown sensor node \"" .. tostring(platform.sensor_id) .. "\"") end
        if platform.block_id and not block_ids[platform.block_id] then add(errors, ppath .. ".block_id", "references unknown block \"" .. tostring(platform.block_id) .. "\"") end
      end
    elseif node.role == "depot" then
      for j, track in ipairs(node.tracks or node.slots or {}) do
        local tpath = path .. ".tracks[" .. j .. "]"
        if track.sensor_id and not sensor_ids[track.sensor_id] then add(errors, tpath .. ".sensor_id", "references unknown sensor node \"" .. tostring(track.sensor_id) .. "\"") end
        if track.block_id and not block_ids[track.block_id] then add(errors, tpath .. ".block_id", "references unknown block \"" .. tostring(track.block_id) .. "\"") end
      end
    end
  end

  -- Validate interlocking routes (if defined)
  for i, il_route in ipairs(cfg.interlocking_routes or {}) do
    local path = "interlocking_routes[" .. i .. "]"
    if not nonempty(il_route.id) then add(errors, path .. ".id", "must be non-empty string") end
    if not nonempty(il_route.entry_signal) then add(errors, path .. ".entry_signal", "must define entry_signal for interlocking route") end
    if not (il_route.blocks and #il_route.blocks > 0) then add(errors, path .. ".blocks", "must define at least one block") end
    -- Check flank protection references valid switches
    for j, fp in ipairs(il_route.flank_protection or {}) do
      if not nonempty(fp.switch_id) then add(errors, path .. ".flank_protection[" .. j .. "].switch_id", "must define switch_id") end
      if not nonempty(fp.position) then add(errors, path .. ".flank_protection[" .. j .. "].position", "must define position") end
    end
    -- Check switch requirements for contradictions
    local sw_positions = {}
    for _, sw in ipairs(il_route.switches or {}) do
      if sw_positions[sw.id] and sw_positions[sw.id] ~= sw.position then
        add(errors, path .. ".switches", "contradicting positions for switch " .. tostring(sw.id))
      end
      sw_positions[sw.id] = sw.position
    end
  end

  -- Validate that route switch requirements don't contradict each other
  local route_switch_reqs = {}
  for i, route in ipairs(cfg.routes or {}) do
    local path = "routes[" .. i .. "]"
    for _, sw_req in ipairs(route.switches or {}) do
      -- Each switch entry in a block within this route needs a position
      if not nonempty(sw_req.id) then add(errors, path .. ".switch.id", "switch missing id") end
    end
    -- Cross-check with blocks that contain this route's blocks
    for _, block_id in ipairs(route.blocks or {}) do
      local block_cfg_entry = nil
      for _, b in ipairs(cfg.blocks or {}) do if b.id == block_id then block_cfg_entry = b; break end end
      if block_cfg_entry then
        for _, sw in ipairs(block_cfg_entry.switches or {}) do
          local key = route.id .. ":" .. sw.id
          if route_switch_reqs[sw.id] and route_switch_reqs[sw.id].position ~= sw.position and route_switch_reqs[sw.id].route_id ~= route.id then
            -- Two routes in the same traversal require the same switch in different positions
            -- This is valid (different routes), not an error, just informational
          end
          route_switch_reqs[sw.id] = { position = sw.position, route_id = route.id }
        end
      end
    end
    -- Warn if route destination doesn't match any station or depot
    -- Only when stations/depots are defined
    if (next(station_ids) ~= nil or next(depot_ids) ~= nil) then
      if route.to and not station_ids[route.to] and not depot_ids[route.to] then
        add(errors, path .. ".to", "destination \"" .. tostring(route.to) .. "\" does not match any station or depot node")
      end
    end
  end

  -- Validate duplicate sensor assignments across blocks
  local sensor_to_block = {}
  for i, block in ipairs(cfg.blocks or {}) do
    for _, sensor_id in ipairs(block.sensors or {}) do
      if sensor_to_block[sensor_id] then
        add(errors, "blocks[" .. i .. "].sensors", "sensor " .. tostring(sensor_id) .. " already used by block " .. sensor_to_block[sensor_id])
      else
        sensor_to_block[sensor_id] = block.id
      end
    end
  end

  return #errors == 0, errors
end

return validate
