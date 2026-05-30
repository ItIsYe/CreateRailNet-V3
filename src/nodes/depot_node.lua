--[[
Purpose: Depot node runtime for storage/staging tracks and train readiness.
Public API: new_runtime(context_or_args), build_track_map(depot_config), render_status(monitor, state).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local shared_args = require("src.shared.args")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local create_sensors = require("src.adapter.create_sensors")
local cc_modem = require("src.adapter.cc_modem")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local depot_node = {}

local TRACK_EMPTY = "EMPTY"
local TRACK_OCCUPIED = "OCCUPIED"
local TRACK_STAGING = "STAGING"
local TRACK_READY = "READY"
local TRACK_DEPARTING = "DEPARTING"
local TRACK_FAULT = "FAULT"

local function find_depot_config(cfg, node_id)
  for _, node in ipairs(cfg.nodes or {}) do if node.id == node_id then return node end end
  return { id = node_id, role = "depot", depot_type = "mixed", tracks = {} }
end

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  local cfg = config.load(args_or_context.config or "configs/templates/network.example.json")
  return { id = args_or_context.id, role = "depot", config = cfg, logger = log.new("INFO", 200), peripherals = peripherals.new(), hardware = hardware_config.new(cfg), modem = cc_modem.new({ channel = cfg.channel }) }
end

function depot_node.build_track_map(depot_config)
  local tracks = {}
  for _, track in ipairs(depot_config.tracks or depot_config.slots or {}) do
    local id = track.id or track.track_id or track.name
    if id then
      tracks[id] = { id = id, track_id = track.track_id or id, kind = track.kind or track.type or depot_config.depot_type or "mixed", sensor_id = track.sensor_id, block_id = track.block_id, state = TRACK_EMPTY, train_id = track.train_id, train_name = track.train_name, route_id = track.route_id, destination = track.destination, ready_after_seconds = track.ready_after_seconds or depot_config.ready_after_seconds or 5, occupied_since = nil, last_occupied = false }
    end
  end
  return tracks
end

function depot_node.render_status(monitor, state)
  if not monitor then return end
  monitor.clear()
  monitor.setCursorPos(1, 1); monitor.write("CreateRailNet Depot")
  monitor.setCursorPos(1, 3); monitor.write("Depot: " .. tostring(state.depot_id or state.node_id or "-"))
  monitor.setCursorPos(1, 4); monitor.write("Type: " .. tostring(state.depot_type or "mixed"))
  monitor.setCursorPos(1, 5); monitor.write("State: " .. tostring(state.state or "ONLINE"))
  local row = 7
  for track_id, track in pairs(state.tracks or {}) do
    monitor.setCursorPos(1, row)
    monitor.write(track_id .. " " .. tostring(track.kind or "mixed") .. " " .. tostring(track.state or "-") .. " " .. tostring(track.train_name or track.train_id or ""))
    row = row + 1
  end
  monitor.setCursorPos(1, row + 1); monitor.write("Queue: " .. tostring(#(state.queue or {})))
end

local function track_payload(state, track)
  return { type = "depot_track_status", depot_id = state.depot_id, track_id = track.id, kind = track.kind, state = track.state, train_id = track.train_id, train_name = track.train_name, block_id = track.block_id, sensor_id = track.sensor_id, route_id = track.route_id, destination = track.destination }
end

function depot_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local depot_cfg = find_depot_config(context.config, context.id)
  local depot_id = depot_cfg.depot_id or context.id
  local depot_type = depot_cfg.depot_type or depot_cfg.type or "mixed"
  local display_name = depot_cfg.display_name or depot_id
  local monitor_name = depot_cfg.monitor or "monitor"
  local monitor = context.peripherals.wrap(monitor_name)
  local sensor_adapter = create_sensors.new(context.peripherals, { hardware = context.hardware })
  local state = { node_id = context.id, depot_id = depot_id, display_name = display_name, depot_type = depot_type, state = "ONLINE", queue = {}, tracks = depot_node.build_track_map(depot_cfg) }

  local node = common_node.new({ id = context.id, role = context.role, config = context.config, modem = context.modem, logger = context.logger, handlers = { on_cmd = function(payload)
    local cmd = payload and payload.cmd
    local track = payload and payload.track_id and state.tracks[payload.track_id]
    if cmd == "reserve_track" and track then track.state = "RESERVED"; track.train_id = payload.train_id; track.train_name = payload.train_name; track.route_id = payload.route_id; track.destination = payload.destination
    elseif cmd == "clear_track" and track then track.state = TRACK_EMPTY; track.train_id = nil; track.train_name = nil; track.route_id = nil; track.destination = nil; track.occupied_since = nil
    elseif cmd == "stage_train" and track then track.state = TRACK_STAGING; track.train_id = payload.train_id or track.train_id; track.train_name = payload.train_name or track.train_name; track.route_id = payload.route_id or track.route_id; track.destination = payload.destination or track.destination
    elseif cmd == "mark_ready" and track then
      track.state = TRACK_READY; track.train_id = payload.train_id or track.train_id; track.train_name = payload.train_name or track.train_name; track.route_id = payload.route_id or track.route_id; track.destination = payload.destination or track.destination
      node.net.send("event", context.config.master_id, { type = "depot_train_ready", depot_id = depot_id, track_id = track.id, train_id = track.train_id, train_name = track.train_name, route_id = track.route_id, destination = track.destination })
    elseif cmd == "dispatch_train" and track then
      track.state = TRACK_DEPARTING
      node.net.send("event", context.config.master_id, { type = "depot_request_dispatch", depot_id = depot_id, track_id = track.id, train_id = track.train_id, train_name = track.train_name, route_id = payload.route_id or track.route_id, destination = payload.destination or track.destination })
    elseif cmd == "set_depot_message" then state.message = payload.message
    else return false, "unknown depot cmd: " .. tostring(cmd) end
    depot_node.render_status(monitor, state)
    return true
  end } })

  node.register = function() return node.net.send("register", context.config.master_id, { role = "depot", depot_id = depot_id, display_name = display_name, depot_type = depot_type, state = state.state }) end
  node.heartbeat = function() return node.net.heartbeat(context.config.master_id, { role = "depot", depot_id = depot_id, display_name = display_name, depot_type = depot_type, state = state.state }) end

  local function send_track(track) node.net.send("event", context.config.master_id, track_payload(state, track)) end

  local function read_train_name(track)
    local ok, train_name = sensor_adapter.readTrainName(track.sensor_id)
    if ok and train_name and train_name ~= "" then return train_name end
    return track.train_name or track.train_id
  end

  local function check_tracks()
    for _, track in pairs(state.tracks) do
      if track.sensor_id then
        local ok, occupied = sensor_adapter.readOccupied(track.sensor_id)
        if ok then
          if occupied ~= track.last_occupied then
            track.last_occupied = occupied
            if occupied then
              track.train_name = read_train_name(track)
              track.train_id = track.train_id or track.train_name
              track.state = TRACK_OCCUPIED
              track.occupied_since = os.clock()
              node.net.send("event", context.config.master_id, { type = "depot_train_arrived", depot_id = depot_id, track_id = track.id, train_id = track.train_id, train_name = track.train_name, route_id = track.route_id })
            else
              local leaving_train_id = track.train_id
              local leaving_train_name = track.train_name
              node.net.send("event", context.config.master_id, { type = "depot_train_left", depot_id = depot_id, track_id = track.id, train_id = leaving_train_id, train_name = leaving_train_name, route_id = track.route_id })
              track.state = TRACK_EMPTY; track.train_id = nil; track.train_name = nil; track.route_id = nil; track.destination = nil; track.occupied_since = nil
            end
            send_track(track)
          elseif occupied and track.state == TRACK_OCCUPIED and track.occupied_since then
            if os.clock() - track.occupied_since >= track.ready_after_seconds then
              track.state = TRACK_READY
              node.net.send("event", context.config.master_id, { type = "depot_train_ready", depot_id = depot_id, track_id = track.id, train_id = track.train_id, train_name = track.train_name, route_id = track.route_id, destination = track.destination })
              send_track(track)
            end
          end
        else
          track.state = TRACK_FAULT
          node.net.send("event", context.config.master_id, { type = "depot_fault", depot_id = depot_id, track_id = track.id, error = occupied })
        end
      end
    end
  end

  local old_start = node.start
  node.start = function()
    old_start(); depot_node.render_status(monitor, state); node.depot_timer = os.startTimer(0.5)
    node.net.send("event", context.config.master_id, { type = "depot_status", depot_id = depot_id, depot_type = depot_type, state = state.state })
  end

  node.handlers.on_event = function(event)
    if event[1] == "timer" and event[2] == node.depot_timer then check_tracks(); depot_node.render_status(monitor, state); node.depot_timer = os.startTimer(0.5) end
  end

  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then depot_node.new_runtime(bootstrap.create_context({...}, "depot")).run() end

return depot_node
