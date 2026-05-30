--[[
Purpose: Station node runtime for passenger/freight/mixed stations with multiple platforms/tracks.
Public API: new_runtime(context_or_args), build_platform_map(station_config), render_status(monitor, state).
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

local station_node = {}

local PLATFORM_EMPTY = "EMPTY"
local PLATFORM_OCCUPIED = "OCCUPIED"
local PLATFORM_DWELLING = "DWELLING"
local PLATFORM_READY = "READY_TO_DEPART"
local PLATFORM_FAULT = "FAULT"

local function find_station_config(cfg, node_id)
  for _, node in ipairs(cfg.nodes or {}) do if node.id == node_id then return node end end
  return { id = node_id, role = "station", station_type = "mixed", platforms = {} }
end

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  local cfg = config.load(args_or_context.config or "configs/templates/network.example.json")
  return { id = args_or_context.id, role = "station", config = cfg, logger = log.new("INFO", 200), peripherals = peripherals.new(), hardware = hardware_config.new(cfg), modem = cc_modem.new({ channel = cfg.channel }) }
end

function station_node.build_platform_map(station_config)
  local platforms = {}
  for _, platform in ipairs(station_config.platforms or station_config.tracks or {}) do
    local id = platform.id or platform.track_id or platform.name
    if id then
      platforms[id] = { id = id, track_id = platform.track_id or id, kind = platform.kind or platform.type or station_config.station_type or "mixed", sensor_id = platform.sensor_id, block_id = platform.block_id, dwell_seconds = platform.dwell_seconds or station_config.dwell_seconds or 15, state = PLATFORM_EMPTY, train_id = platform.train_id, train_name = platform.train_name, occupied_since = nil, last_occupied = false }
    end
  end
  return platforms
end

function station_node.render_status(monitor, state)
  if not monitor then return end
  monitor.clear()
  monitor.setCursorPos(1, 1); monitor.write("CreateRailNet Station")
  monitor.setCursorPos(1, 3); monitor.write("Station: " .. tostring(state.station_id or state.node_id or "-"))
  monitor.setCursorPos(1, 4); monitor.write("Type: " .. tostring(state.station_type or "mixed"))
  monitor.setCursorPos(1, 5); monitor.write("State: " .. tostring(state.state or "ONLINE"))
  local row = 7
  for platform_id, platform in pairs(state.platforms or {}) do
    monitor.setCursorPos(1, row)
    monitor.write(platform_id .. " " .. tostring(platform.kind or "mixed") .. " " .. tostring(platform.state or "-") .. " " .. tostring(platform.train_name or platform.train_id or ""))
    row = row + 1
  end
end

local function platform_payload(state, platform)
  return { type = "platform_status", station_id = state.station_id, platform_id = platform.id, kind = platform.kind, state = platform.state, train_id = platform.train_id, train_name = platform.train_name, block_id = platform.block_id, sensor_id = platform.sensor_id }
end

function station_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local station_cfg = find_station_config(context.config, context.id)
  local station_id = station_cfg.station_id or context.id
  local station_type = station_cfg.station_type or station_cfg.type or "mixed"
  local display_name = station_cfg.display_name or station_id
  local monitor_name = station_cfg.monitor or "monitor"
  local monitor = context.peripherals.wrap(monitor_name)
  local sensor_adapter = create_sensors.new(context.peripherals, { hardware = context.hardware })
  local state = { node_id = context.id, station_id = station_id, display_name = display_name, station_type = station_type, state = "ONLINE", platforms = station_node.build_platform_map(station_cfg) }

  local node = common_node.new({ id = context.id, role = context.role, config = context.config, modem = context.modem, logger = context.logger, handlers = { on_cmd = function(payload)
    local cmd = payload and payload.cmd
    local platform = payload and payload.platform_id and state.platforms[payload.platform_id]
    if cmd == "reserve_platform" and platform then platform.state = "RESERVED"; platform.train_id = payload.train_id; platform.train_name = payload.train_name
    elseif cmd == "clear_platform" and platform then platform.state = PLATFORM_EMPTY; platform.train_id = nil; platform.train_name = nil; platform.occupied_since = nil
    elseif cmd == "mark_ready_departure" and platform then
      platform.state = PLATFORM_READY; platform.train_id = payload.train_id or platform.train_id; platform.train_name = payload.train_name or platform.train_name
      node.net.send("event", context.config.master_id, { type = "station_ready_departure", station_id = station_id, platform_id = platform.id, train_id = platform.train_id, train_name = platform.train_name, route_id = payload.route_id, destination = payload.destination })
    elseif cmd == "set_station_message" then state.message = payload.message
    else return false, "unknown station cmd: " .. tostring(cmd) end
    station_node.render_status(monitor, state)
    return true
  end } })

  node.register = function() return node.net.send("register", context.config.master_id, { role = "station", station_id = station_id, display_name = display_name, station_type = station_type, state = state.state }) end
  node.heartbeat = function() return node.net.heartbeat(context.config.master_id, { role = "station", station_id = station_id, display_name = display_name, station_type = station_type, state = state.state }) end

  local function send_platform(platform) node.net.send("event", context.config.master_id, platform_payload(state, platform)) end

  local function read_train_name(platform)
    local ok, train_name = sensor_adapter.readTrainName(platform.sensor_id)
    if ok and train_name and train_name ~= "" then return train_name end
    return platform.train_name or platform.train_id
  end

  local function check_platforms()
    for _, platform in pairs(state.platforms) do
      if platform.sensor_id then
        local ok, occupied = sensor_adapter.readOccupied(platform.sensor_id)
        if ok then
          if occupied ~= platform.last_occupied then
            platform.last_occupied = occupied
            if occupied then
              platform.train_name = read_train_name(platform)
              platform.train_id = platform.train_id or platform.train_name
              platform.state = PLATFORM_DWELLING
              platform.occupied_since = os.clock()
              node.net.send("event", context.config.master_id, { type = "train_arrived_station", station_id = station_id, platform_id = platform.id, train_id = platform.train_id, train_name = platform.train_name, block_id = platform.block_id })
            else
              local leaving_train_id = platform.train_id
              local leaving_train_name = platform.train_name
              node.net.send("event", context.config.master_id, { type = "train_left_station", station_id = station_id, platform_id = platform.id, train_id = leaving_train_id, train_name = leaving_train_name, block_id = platform.block_id })
              platform.state = PLATFORM_EMPTY; platform.train_id = nil; platform.train_name = nil; platform.occupied_since = nil
            end
            send_platform(platform)
          elseif occupied and platform.state == PLATFORM_DWELLING and platform.occupied_since then
            if os.clock() - platform.occupied_since >= platform.dwell_seconds then
              platform.state = PLATFORM_READY
              node.net.send("event", context.config.master_id, { type = "station_ready_departure", station_id = station_id, platform_id = platform.id, train_id = platform.train_id, train_name = platform.train_name, block_id = platform.block_id })
              send_platform(platform)
            end
          end
        else
          platform.state = PLATFORM_FAULT
          node.net.send("event", context.config.master_id, { type = "station_fault", station_id = station_id, platform_id = platform.id, error = occupied })
        end
      end
    end
  end

  local old_start = node.start
  node.start = function()
    old_start(); station_node.render_status(monitor, state); node.station_timer = os.startTimer(0.5)
    node.net.send("event", context.config.master_id, { type = "station_status", station_id = station_id, station_type = station_type, state = state.state })
  end

  node.handlers.on_event = function(event)
    if event[1] == "timer" and event[2] == node.station_timer then check_platforms(); station_node.render_status(monitor, state); node.station_timer = os.startTimer(0.5) end
  end

  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then station_node.new_runtime(bootstrap.create_context({...}, "station")).run() end

return station_node
