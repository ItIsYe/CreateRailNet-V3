--[[
Purpose: Sensor node entrypoint and runtime factory.
Public API: new_runtime(args), build_check_fn(node, adapter, sensor_id, master_id).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local shared_args = require("src.shared.args")
local peripherals = require("src.adapter.peripherals")
local create_sensors = require("src.adapter.create_sensors")
local common_node = require("src.nodes.common_node")
local cc_modem = require("src.adapter.cc_modem")

local sensor_node = {}

function sensor_node.build_check_fn(node, adapter, sensor_id, master_id)
  local last_state = false
  return function()
    local ok, occupied = adapter.readOccupied(sensor_id)
    if not ok then
      return false, occupied
    end
    if occupied ~= last_state then
      local action = occupied and "enter" or "leave"
      node.net.send("event", master_id, { type = "sensor", sensor_id = sensor_id, action = action })
      last_state = occupied
    end
    return true
  end
end

function sensor_node.new_runtime(args)
  local cfg = config.load(args.config or "configs/templates/network.example.json")
  local logger = log.new("INFO", 200)
  local adapter = create_sensors.new(peripherals.new())

  local node = common_node.new({
    id = args.id,
    role = "sensor",
    config = cfg,
    modem = cc_modem.new({ channel = cfg.channel }),
    logger = logger
  })

  local check = sensor_node.build_check_fn(node, adapter, args.id, cfg.master_id)

  local old_start = node.start
  node.start = function()
    old_start()
    node.sensor_timer = os.startTimer(0.2)
  end

  node.handlers.on_event = function(event)
    if event[1] == "timer" and event[2] == node.sensor_timer then
      check()
      node.sensor_timer = os.startTimer(0.2)
    end
  end

  return node
end

local args = shared_args.parse({...}, { config = {}, id = {} })
if args.id then
  sensor_node.new_runtime(args).run()
end

return sensor_node
