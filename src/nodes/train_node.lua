--[[
Purpose: Onboard train node for train identity, status display, schedule/service stop display, and master commands.
Public API: new_runtime(context_or_args), render_status(monitor, state).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local shared_args = require("src.shared.args")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local create_train_schedule = require("src.adapter.create_train_schedule")
local cc_modem = require("src.adapter.cc_modem")
local common_node = require("src.nodes.common_node")
local bootstrap = require("src.nodes.bootstrap")

local train_node = {}

local function find_train_config(cfg, node_id)
  for _, node in ipairs(cfg.nodes or {}) do if node.id == node_id then return node end end
  return { id = node_id, role = "train" }
end

local function build_context(args_or_context)
  if args_or_context.config and args_or_context.logger and args_or_context.peripherals and args_or_context.modem then return args_or_context end
  local cfg = config.load(args_or_context.config or "configs/templates/network.example.json")
  return { id = args_or_context.id, role = "train", config = cfg, logger = log.new("INFO", 200), peripherals = peripherals.new(), hardware = hardware_config.new(cfg), modem = cc_modem.new({ channel = cfg.channel }) }
end

function train_node.render_status(monitor, state)
  if not monitor then return end
  monitor.clear()
  monitor.setCursorPos(1, 1); monitor.write("CreateRailNet-V3")
  monitor.setCursorPos(1, 3); monitor.write("Train: " .. tostring(state.train_id or state.node_id or "-"))
  monitor.setCursorPos(1, 4); monitor.write("Name: " .. tostring(state.display_name or "-"))
  monitor.setCursorPos(1, 5); monitor.write("State: " .. tostring(state.state or "-"))
  monitor.setCursorPos(1, 6); monitor.write("Route: " .. tostring(state.route_id or "-"))
  monitor.setCursorPos(1, 7); monitor.write("Dest: " .. tostring(state.destination or "-"))
  monitor.setCursorPos(1, 8); monitor.write("Plan: " .. tostring(state.service_plan or "-") .. " Stop: " .. tostring(state.service_stop_index or "-"))
  monitor.setCursorPos(1, 9); monitor.write("Schedule: " .. tostring(state.schedule_state or "not_applied"))
  monitor.setCursorPos(1, 10); monitor.write("Master: " .. tostring(state.master_state or "ONLINE"))
  if state.message then monitor.setCursorPos(1, 12); monitor.write(tostring(state.message)) end
end

function train_node.new_runtime(args_or_context)
  local context = build_context(args_or_context)
  local train_cfg = find_train_config(context.config, context.id)
  local train_id = train_cfg.train_id or context.id
  local display_name = train_cfg.display_name or train_id
  local monitor_name = train_cfg.monitor or "monitor"
  local monitor = context.peripherals.wrap(monitor_name)
  local schedule_adapter = create_train_schedule.new(context.peripherals, { hardware = context.hardware })

  local state = {
    node_id = context.id,
    train_id = train_id,
    display_name = display_name,
    state = "IDLE",
    route_id = train_cfg.default_route,
    destination = train_cfg.default_destination,
    home_depot = train_cfg.home_depot,
    service_plan = train_cfg.service_plan,
    service_stop_index = nil,
    schedule_state = "not_applied",
    master_state = "ONLINE"
  }

  local node = common_node.new({
    id = context.id,
    role = context.role,
    config = context.config,
    modem = context.modem,
    logger = context.logger,
    handlers = {
      on_cmd = function(payload)
        local cmd = payload and payload.cmd
        if cmd == "set_destination" then
          state.destination = payload.destination
          state.route_id = payload.route_id or state.route_id
          state.service_stop_index = payload.service_stop_index or state.service_stop_index
          state.state = "WAITING_FOR_ROUTE"
        elseif cmd == "set_schedule" then
          state.route_id = payload.route_id
          state.destination = payload.destination or state.destination
          state.service_plan = payload.service_plan or state.service_plan
          state.service_stop_index = payload.service_stop_index or state.service_stop_index
          if payload.schedule then
            local ok, err = schedule_adapter.apply(train_id, payload.schedule)
            state.schedule_state = ok and "applied" or "failed"
            if not ok then state.message = err end
          elseif payload.stops then
            local ok, err = schedule_adapter.apply_stops(train_id, payload.stops)
            state.schedule_state = ok and "applied" or "failed"
            if not ok then state.message = err end
          end
          state.state = "ROUTE_ASSIGNED"
          node.net.send("event", context.config.master_id, { type = "schedule_applied", train_id = train_id, route_id = state.route_id, destination = state.destination, state = state.state, service_plan = state.service_plan, service_stop_index = state.service_stop_index, schedule_state = state.schedule_state })
        elseif cmd == "depart_authorized" then
          state.route_id = payload.route_id or state.route_id
          state.destination = payload.destination or state.destination
          state.service_stop_index = payload.service_stop_index or state.service_stop_index
          state.state = "DEPART_AUTHORIZED"
        elseif cmd == "hold_position" then
          state.service_stop_index = payload.service_stop_index or state.service_stop_index
          state.message = payload.reason
          state.state = "WAITING_DEPARTURE"
        elseif cmd == "emergency_stop" then
          state.state = "FAULT"
          state.message = payload.reason or "Emergency stop"
        elseif cmd == "update_display" then
          state.message = payload.message
        else
          return false, "unknown train cmd: " .. tostring(cmd)
        end
        train_node.render_status(monitor, state)
        return true
      end
    }
  })

  node.register = function()
    return node.net.send("register", context.config.master_id, { role = "train", train_id = train_id, display_name = display_name, destination = state.destination, route_id = state.route_id, state = state.state, home_depot = state.home_depot, service_plan = state.service_plan, service_stop_index = state.service_stop_index, schedule_state = state.schedule_state })
  end

  node.heartbeat = function()
    return node.net.heartbeat(context.config.master_id, { role = "train", train_id = train_id, display_name = display_name, destination = state.destination, route_id = state.route_id, state = state.state, home_depot = state.home_depot, service_plan = state.service_plan, service_stop_index = state.service_stop_index, schedule_state = state.schedule_state })
  end

  local old_start = node.start
  node.start = function()
    old_start()
    train_node.render_status(monitor, state)
    node.status_timer = os.startTimer(2)
  end

  node.handlers.on_event = function(event)
    if event[1] == "timer" and event[2] == node.status_timer then
      node.net.send("event", context.config.master_id, { type = "train_status", train_id = train_id, state = state.state, route_id = state.route_id, destination = state.destination, home_depot = state.home_depot, service_plan = state.service_plan, service_stop_index = state.service_stop_index, schedule_state = state.schedule_state })
      train_node.render_status(monitor, state)
      node.status_timer = os.startTimer(2)
    end
  end

  node.request_departure = function(from_station, to_station)
    state.state = "WAITING_FOR_ROUTE"
    state.destination = to_station or state.destination
    return node.net.send("event", context.config.master_id, { type = "request_departure", train_id = train_id, from = from_station, to = to_station or state.destination, route_id = state.route_id, service_plan = state.service_plan, service_stop_index = state.service_stop_index })
  end

  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then train_node.new_runtime(bootstrap.create_context({...}, "train")).run() end

return train_node
