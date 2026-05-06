--[[
Purpose: Switch node entrypoint.
Public API: none (script).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local peripherals = require("src.adapter.peripherals")
local create_switches = require("src.adapter.create_switches")
local common_node = require("src.nodes.common_node")
local cc_modem = require("src.adapter.cc_modem")

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
local adapter = create_switches.new(peripherals.new())

local node = common_node.new({
  id = args.id,
  role = "switch",
  config = cfg,
  modem = cc_modem.new({ channel = cfg.channel }),
  logger = log.new("INFO", 200),
  handlers = {
    on_cmd = function(payload)
      if not payload or not payload.position then
        return false, "missing payload.position"
      end
      return adapter.setPosition(args.id, payload.position)
    end
  }
})

if args.id then
  node.run()
end
