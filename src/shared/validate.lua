--[[
Purpose: Validate network configuration with actionable errors.
Public API: validate_config(cfg) -> ok, errors.
]]

local validate = {}

local roles = { master = true, signal = true, sensor = true, switch = true, station = true, depot = true, panel = true, train = true, arbiter = true, fleet = true }
local station_types = { passenger = true, freight = true, mixed = true }
local depot_types = { storage = true, staging = true, mixed = true }
local route_kinds = { passenger = true, freight = true, mixed = true, depot = true }

local function add(errors, path, message) table.insert(errors, path .. ": " .. message) end
local function nonempty(value) return type(value) == "string" and value ~= "" end
-- what CC:Tweaked's monitor.setTextScale takes: 0.5 to 5 in steps of 0.5
local function valid_text_scale(value) return type(value) == "number" and value >= 0.5 and value <= 5 and value * 2 == math.floor(value * 2) end
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

local function validate_inner(cfg, errors)
  if type(cfg) ~= "table" then add(errors, "config", "must be an object"); return false, errors end
  if cfg.v ~= 1 then add(errors, "v", "must be 1") end
  if type(cfg.channel) ~= "number" or cfg.channel <= 0 or cfg.channel % 1 ~= 0 then add(errors, "channel", "must be integer > 0") end
  if cfg.monitor_scale ~= nil and not valid_text_scale(cfg.monitor_scale) then add(errors, "monitor_scale", "must be a number from 0.5 to 5 in steps of 0.5") end
  if not nonempty(cfg.master_id) then add(errors, "master_id", "must be non-empty string") end
  if type(cfg.blocks) ~= "table" then add(errors, "blocks", "must be an array") end
  if type(cfg.routes) ~= "table" then add(errors, "routes", "must be an array") end
  if type(cfg.nodes) ~= "table" then add(errors, "nodes", "must be an array") end

  -- optional tuning keys (docs/config_reference.md): a wrong type would silently fall back to the default, so say so
  for _, key in ipairs({ "heartbeat_timeout_s", "auto_clear_stable_s", "auto_clear_max_age_s", "signal_refresh_per_s", "trace_capacity", "sensor_guard_min_occupy_ms" }) do
    local value = cfg[key]
    if value ~= nil and (type(value) ~= "number" or value < 0) then add(errors, key, "must be a number >= 0") end
  end
  for _, key in ipairs({ "auto_clear_faults", "signal_red_on_stop", "startup_autoupgrade", "log_forward", "require_release", "durable_commands" }) do
    if cfg[key] ~= nil and type(cfg[key]) ~= "boolean" then add(errors, key, "must be true or false") end
  end

  -- authentication of the messages (docs/KEYS.md): off | monitor | enforce, and the ids of the master computers
  if cfg.auth_mode ~= nil and cfg.auth_mode ~= "off" and cfg.auth_mode ~= "monitor" and cfg.auth_mode ~= "enforce" then add(errors, "auth_mode", "must be \"off\", \"monitor\" or \"enforce\"") end
  if cfg.masters ~= nil then
    if type(cfg.masters) ~= "table" then
      add(errors, "masters", "must be an array of node ids")
    else
      local seen_masters = {}
      for i, id in ipairs(cfg.masters) do
        if not nonempty(id) then add(errors, "masters[" .. i .. "]", "must be non-empty string")
        elseif seen_masters[id] then add(errors, "masters[" .. i .. "]", "master id listed twice")
        else seen_masters[id] = true end
      end
    end
  end

  local node_ids, block_ids, route_ids, node_roles = {}, {}, {}, {}
  local train_ids, service_plan_ids = {}, {}
  local station_ids, depot_ids = {}, {}
  local signal_ids, sensor_ids, switch_ids = {}, {}, {}
  local hosted_signal_owner = {}

  for i, node in ipairs(cfg.nodes or {}) do
    local path = "nodes[" .. i .. "]"
    if mark_unique(errors, node_ids, node.id, path .. ".id", "node id") and roles[node.role] then node_roles[node.id] = node.role end
    if not roles[node.role] then add(errors, path .. ".role", "invalid role \"" .. tostring(node.role) .. "\"") end
    -- the devices this computer uses: the modem it talks through, the monitor it shows on
    if node.modem ~= nil and not nonempty(node.modem) then add(errors, path .. ".modem", "must be non-empty string") end
    if node.monitor ~= nil and not nonempty(node.monitor) then add(errors, path .. ".monitor", "must be non-empty string") end
    if node.monitor_scale ~= nil and not valid_text_scale(node.monitor_scale) then add(errors, path .. ".monitor_scale", "must be a number from 0.5 to 5 in steps of 0.5") end

    -- several signals on one computer: the logical signal ids it hosts
    if node.signals ~= nil then
      if node.role ~= "signal" then
        add(errors, path .. ".signals", "only a signal node hosts signals")
      elseif type(node.signals) ~= "table" or #node.signals == 0 then
        add(errors, path .. ".signals", "must be a non-empty list of signal ids")
      else
        for j, signal_id in ipairs(node.signals) do
          if not nonempty(signal_id) then add(errors, path .. ".signals[" .. j .. "]", "must be non-empty string")
          elseif hosted_signal_owner[signal_id] then add(errors, path .. ".signals[" .. j .. "]", "signal " .. signal_id .. " is already hosted by " .. hosted_signal_owner[signal_id])
          else hosted_signal_owner[signal_id] = node.id end
        end
      end
    end
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
        -- a loading point: the inventory next to the track and whether the train is loaded or unloaded here (src/domain/cargo_meter.lua)
        if platform.cargo ~= nil then
          local cargo = platform.cargo
          if type(cargo) ~= "table" then add(errors, ppath .. ".cargo", "must be a table { inventory, item, kind }")
          else
            if not nonempty(cargo.inventory) then add(errors, ppath .. ".cargo.inventory", "needs the name of the inventory peripheral") end
            if cargo.item ~= nil and not nonempty(cargo.item) then add(errors, ppath .. ".cargo.item", "must be a non-empty item name") end
            if cargo.kind ~= "loaded" and cargo.kind ~= "unloaded" then add(errors, ppath .. ".cargo.kind", "must be loaded or unloaded") end
          end
        end
      end
      if node.cargo_report_to ~= nil then
        if type(node.cargo_report_to) ~= "table" then add(errors, path .. ".cargo_report_to", "must be a list of fleet node ids")
        else for j, target in ipairs(node.cargo_report_to) do if not nonempty(target) then add(errors, path .. ".cargo_report_to[" .. j .. "]", "must be a fleet node id") end end end
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
      if node.permission ~= nil and node.permission ~= "view" and node.permission ~= "operate" and node.permission ~= "admin" then add(errors, path .. ".permission", "must be view, operate or admin") end
      for j, page in ipairs(node.pages or {}) do if not nonempty(page) then add(errors, path .. ".pages[" .. j .. "]", "must be non-empty string") end end
    elseif node.role == "signal" then
      signal_ids[node.id] = true
      if type(node.signals) == "table" then for _, hosted_id in ipairs(node.signals) do if type(hosted_id) == "string" then signal_ids[hosted_id] = true end end end
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

  -- two masters and an arbiter (docs/HA.md): the masters are nodes of the plan, the arbiter is one more node, and master_id is the one that is preferred
  for _, key in ipairs({ "election_lease_ms", "election_beat_ms" }) do
    if cfg[key] ~= nil and (type(cfg[key]) ~= "number" or cfg[key] <= 0) then add(errors, key, "must be a number > 0") end
  end
  if cfg.election_state_file ~= nil and not nonempty(cfg.election_state_file) then add(errors, "election_state_file", "must be non-empty string") end
  -- the fleet: pairs of fleet nodes, train profiles, lines, platforms (docs/FLEET.md)
  if cfg.fleet ~= nil then
    if type(cfg.fleet) ~= "table" then
      add(errors, "fleet", "must be a table")
    else
      local fleet_nodes = {}
      for _, node in ipairs(cfg.nodes or {}) do if node.role == "fleet" then fleet_nodes[#fleet_nodes + 1] = node.id end end
      local _, pair_problems = require("src.fleet.pairs").new({ nodes = fleet_nodes, pairs = cfg.fleet.pairs or {} })
      for _, text in ipairs(pair_problems) do add(errors, "fleet.pairs", text) end
      local profiles = require("src.fleet.profile").new({})
      local known_trains = {}
      for i, spec in ipairs(cfg.fleet.train_profiles or {}) do
        local ok, err = profiles.register(spec, { operator = "plan", confirmed = true })
        if not ok then add(errors, "fleet.train_profiles[" .. i .. "]", tostring(err)) else known_trains[spec.immutable_id] = true end
      end
      for i, pair in ipairs(cfg.fleet.pairs or {}) do
        for _, train_id in ipairs(pair.trains or {}) do
          if not known_trains[train_id] then add(errors, "fleet.pairs[" .. i .. "].trains", "train " .. tostring(train_id) .. " has no profile in fleet.train_profiles") end
        end
      end
      local timetable = require("src.fleet.timetable")
      local line_ids = {}
      for i, line in ipairs(cfg.fleet.lines or {}) do
        for _, text in ipairs(timetable.validate(line)) do add(errors, "fleet.lines[" .. i .. "]", text) end
        if type(line) == "table" and line.id then
          if line_ids[line.id] then add(errors, "fleet.lines[" .. i .. "].id", "line " .. tostring(line.id) .. " is defined twice") end
          line_ids[line.id] = true
        end
      end
      local station_nodes = {}
      for _, node in ipairs(cfg.nodes or {}) do if node.role == "station" then station_nodes[node.id] = true end end
      for station, node_id in pairs(cfg.fleet.stations or {}) do
        if not station_nodes[node_id] then add(errors, "fleet.stations." .. tostring(station), "must reference a node with role station") end
      end
      -- the depots a train may be sent to: tracks with their block, and the route from each station that serves them
      local depot_nodes = {}
      for _, node in ipairs(cfg.nodes or {}) do if node.role == "depot" then depot_nodes[node.depot_id or node.id] = true end end
      for depot, def in pairs(cfg.fleet.depots or {}) do
        local dpath = "fleet.depots." .. tostring(depot)
        if not depot_nodes[depot] then add(errors, dpath, "must be the id of a node with role depot") end
        local seen = {}
        for j, track in ipairs((type(def) == "table" and (def.tracks or def)) or {}) do
          local tpath = dpath .. ".tracks[" .. j .. "]"
          if not nonempty(track.id) then add(errors, tpath .. ".id", "must be non-empty string") elseif seen[track.id] then add(errors, tpath .. ".id", "track " .. track.id .. " is defined twice") else seen[track.id] = true end
          if not nonempty(track.block) then add(errors, tpath .. ".block", "needs the id of its block") end
          if track.routes ~= nil and type(track.routes) ~= "table" then add(errors, tpath .. ".routes", "must map a station to the route that leads to the track") end
        end
      end
      for station, list in pairs(cfg.fleet.platforms or {}) do
        local seen = {}
        for j, platform in ipairs(list) do
          local path = "fleet.platforms." .. tostring(station) .. "[" .. j .. "]"
          if not nonempty(platform.id) then add(errors, path .. ".id", "must be non-empty string") elseif seen[platform.id] then add(errors, path .. ".id", "platform " .. platform.id .. " is defined twice") else seen[platform.id] = true end
          if not nonempty(platform.block) then add(errors, path .. ".block", "needs the id of its block") end
        end
      end
    end
  end
  -- how the signals are commanded (docs/SIGNAL_NODES.md)
  if cfg.signal_transport ~= nil and cfg.signal_transport ~= "local" and cfg.signal_transport ~= "network" then add(errors, "signal_transport", "must be \"local\" or \"network\"") end
  if cfg.signal_transport == "network" then
    local hosted = {}
    for _, node in ipairs(cfg.nodes or {}) do
      if node.role == "signal" then
        if type(node.signals) == "table" and #node.signals > 0 then for _, id in ipairs(node.signals) do hosted[id] = true end else hosted[node.id] = true end
      end
    end
    for i, block in ipairs(cfg.blocks or {}) do
      for _, key in ipairs({ "entry_signal", "exit_signal" }) do
        if block[key] ~= nil and not hosted[block[key]] then add(errors, "blocks[" .. i .. "]." .. key, "signal " .. tostring(block[key]) .. " is hosted by no signal node (signal_transport = network)") end
      end
    end
  end
  -- proof of occupancy and safe stops (docs/PROOF.md)
  if cfg.occupancy_proof ~= nil and cfg.occupancy_proof ~= "on" and cfg.occupancy_proof ~= "off" then add(errors, "occupancy_proof", "must be \"on\" or \"off\"") end
  if cfg.safe_stops ~= nil then
    if type(cfg.safe_stops) ~= "table" then
      add(errors, "safe_stops", "must be a list")
    else
      local known = {}
      for _, block in ipairs(cfg.blocks or {}) do known[block.id] = true end
      for i, stop in ipairs(cfg.safe_stops) do
        local path = "safe_stops[" .. i .. "]"
        if type(stop) ~= "table" or not nonempty(stop.block) then add(errors, path, "needs a block id")
        elseif not known[stop.block] then add(errors, path .. ".block", "unknown block " .. tostring(stop.block)) end
        if type(stop) == "table" then
          if stop.length ~= nil and (type(stop.length) ~= "number" or stop.length <= 0) then add(errors, path .. ".length", "must be a number > 0") end
          if stop.proven ~= nil and type(stop.proven) ~= "boolean" then add(errors, path .. ".proven", "must be true or false") end
        end
      end
    end
  end
  if cfg.occupancy_proof == "on" then
    local graph = require("src.domain.safety_graph").build(cfg)
    for _, problem in ipairs(graph.problems) do
      if problem.severity == "error" then add(errors, "safety_graph." .. tostring(problem.code), problem.text) end
    end
  end
  if cfg.master_journal_file ~= nil and not nonempty(cfg.master_journal_file) then add(errors, "master_journal_file", "must be non-empty string") end
  if cfg.ota_require_package ~= nil and type(cfg.ota_require_package) ~= "boolean" then add(errors, "ota_require_package", "must be true or false") end
  if cfg.aux_monitor ~= nil and not nonempty(cfg.aux_monitor) then add(errors, "aux_monitor", "must be the name of a monitor peripheral") end
  if cfg.aux_monitor_scale ~= nil and (type(cfg.aux_monitor_scale) ~= "number" or cfg.aux_monitor_scale < 0.5 or cfg.aux_monitor_scale > 5 or (cfg.aux_monitor_scale * 2) % 1 ~= 0) then add(errors, "aux_monitor_scale", "must be 0.5 to 5 in steps of 0.5") end
  if cfg.maintenance_file ~= nil and not nonempty(cfg.maintenance_file) then add(errors, "maintenance_file", "must be non-empty string") end
  if cfg.update_plan_file ~= nil and not nonempty(cfg.update_plan_file) then add(errors, "update_plan_file", "must be non-empty string") end
  if cfg.arbiter ~= nil and not nonempty(cfg.arbiter) then add(errors, "arbiter", "must be non-empty string") end
  if type(cfg.masters) == "table" and #cfg.masters >= 1 then
    if #cfg.masters ~= 2 then add(errors, "masters", "must list exactly two masters (or be left out for a plan with one)") end
    local listed_primary = false
    for i, id in ipairs(cfg.masters) do
      if nonempty(id) then
        if node_roles[id] ~= "master" then add(errors, "masters[" .. i .. "]", "must reference node with role master") end
        if id == cfg.master_id then listed_primary = true end
      end
    end
    if cfg.master_id and not listed_primary then add(errors, "masters", "must contain master_id") end
    if not nonempty(cfg.arbiter) then add(errors, "arbiter", "two masters need an arbiter: the id of a node with role arbiter")
    elseif node_roles[cfg.arbiter] ~= "arbiter" then add(errors, "arbiter", "must reference node with role arbiter") end
  elseif cfg.arbiter ~= nil then
    add(errors, "arbiter", "an arbiter only makes sense with two masters (masters)")
  end

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

  -- Validate interlocking routes (if defined). An entry with the id of a dispatcher route only adds fields to it
  -- (flank_protection, overlap_block); any other entry stands for itself.
  local dispatcher_route_ids = {}
  for _, route in ipairs(cfg.routes or {}) do if route.id then dispatcher_route_ids[route.id] = route end end
  for i, il_route in ipairs(cfg.interlocking_routes or {}) do
    local path = "interlocking_routes[" .. i .. "]"
    if not nonempty(il_route.id) then add(errors, path .. ".id", "must be non-empty string") end
    local base = dispatcher_route_ids[il_route.id]
    if not base then
      if not nonempty(il_route.entry_signal) then add(errors, path .. ".entry_signal", "must define entry_signal for interlocking route") end
      if not (il_route.blocks and #il_route.blocks > 0) then add(errors, path .. ".blocks", "must define at least one block") end
    end
    local route_blocks = {}
    for _, block_id in ipairs(il_route.blocks or (base and base.blocks) or {}) do route_blocks[block_id] = true end
    if il_route.overlap_block ~= nil then
      if not block_ids[il_route.overlap_block] then add(errors, path .. ".overlap_block", "references unknown block \"" .. tostring(il_route.overlap_block) .. "\"")
      elseif route_blocks[il_route.overlap_block] then add(errors, path .. ".overlap_block", "must not be a block of the route itself") end
    end
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

-- The lists of a plan are edited by hand: a "blocks": 1 or an entry that is not an object must give a message, not a Lua error.
-- Entries that are not objects are reported and replaced by an empty one (the positions in the messages stay right); whatever else
-- goes wrong inside is reported as one more message.
local LISTS = { "blocks", "routes", "nodes", "service_plans", "interlocking_routes" }

function validate.validate_config(cfg)
  local errors = {}
  if type(cfg) ~= "table" then add(errors, "config", "must be an object"); return false, errors end
  local work = {}
  for key, value in pairs(cfg) do work[key] = value end
  for _, key in ipairs(LISTS) do
    local list = cfg[key]
    if list ~= nil and type(list) ~= "table" then
      add(errors, key, "must be an array")
      work[key] = {}
    elseif type(list) == "table" then
      local copy = {}
      for i, item in ipairs(list) do
        if type(item) == "table" then
          copy[i] = item
        else
          add(errors, key .. "[" .. i .. "]", "must be an object")
          copy[i] = {}
        end
      end
      work[key] = copy
    end
  end
  local ok, valid = pcall(validate_inner, work, errors)
  if not ok then
    add(errors, "config", "unexpected structure (" .. tostring(valid):gsub("^.-:%d+: ", "") .. ")")
    return false, errors
  end
  return #errors == 0, errors
end

return validate
