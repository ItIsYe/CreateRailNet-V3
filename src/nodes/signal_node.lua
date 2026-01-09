--[[
Purpose: Signal node entrypoint.
Public API: none (script).
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local peripherals = require("src.adapter.peripherals")
local create_signals = require("src.adapter.create_signals")
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
local adapter = create_signals.new(peripherals.new())

local node = common_node.new({
  id = args.id,
  role = "signal",
  config = cfg,
  modem = { send = function() end, broadcast = function() end },
  logger = logger,
  handlers = {
    on_cmd = function(payload)
      if payload and payload.aspect then
        adapter.setAspect(args.id, payload.aspect)
      end
    end
  }
})

node.start()
