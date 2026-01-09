--[[
Purpose: Sensor node entrypoint.
Public API: none (script).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local peripherals = require("src.adapter.peripherals")
local create_sensors = require("src.adapter.create_sensors")
local common_node = require("src.nodes.common_node")

local function parse_args(argv)
  local args = {}
  for i = 1, #argv do
    if argv[i] == "--config" then
      args.config = argv[i + 1]
    elseif argv[i] == "--id" then
      args.id = argv[i + 1]
    end
  end
  return args
end

local args = parse_args({...})
local cfg = config.load(args.config or "configs/templates/network.example.json")
local logger = log.new("INFO", 200)
local adapter = create_sensors.new(peripherals.new())

local node = common_node.new({
  id = args.id,
  role = "sensor",
  config = cfg,
  modem = { send = function() end, broadcast = function() end },
  logger = logger,
  handlers = {}
})

local last_state = false

local function check()
  local ok, occupied = adapter.readOccupied(args.id)
  if ok and occupied ~= last_state then
    local action = occupied and "enter" or "leave"
    node.net.send("event", cfg.master_id, { type = "sensor", id = args.id, action = action })
    last_state = occupied
  end
end

node.start()

while false do
  check()
end
