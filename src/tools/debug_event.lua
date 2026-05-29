--[[
Purpose: Send controlled debug events to the master for ingame testing.
Usage examples:
  require("src.tools.debug_event").send_sensor({ config = "configs/templates/network.full.example.json", src = "DBG", sensor_id = "SEN-AB", action = "enter" })
  require("src.tools.debug_event").send_train_departure({ config = "configs/templates/network.full.example.json", src = "TRAIN-1", train_id = "TRAIN-1", from = "ST-A", to = "ST-B" })
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")

local debug_event = {}

local function make_network(path, src)
  local cfg = config.load(path or "configs/templates/network.full.example.json")
  local modem = cc_modem.new({ channel = cfg.channel })
  modem:open(cfg.channel)
  return cfg, net.new(modem, cfg.channel, src or "DEBUG", log.new("INFO", 20))
end

function debug_event.send_sensor(args)
  local cfg, network = make_network(args.config, args.src or "DEBUG-SENSOR")
  return network.send("event", cfg.master_id, { type = "sensor", sensor_id = args.sensor_id, action = args.action or "enter" })
end

function debug_event.send_train_departure(args)
  local cfg, network = make_network(args.config, args.src or args.train_id or "DEBUG-TRAIN")
  return network.send("event", cfg.master_id, { type = "request_departure", train_id = args.train_id, route_id = args.route_id, from = args.from, to = args.to, destination = args.destination })
end

function debug_event.send_arrived(args)
  local cfg, network = make_network(args.config, args.src or args.train_id or "DEBUG-TRAIN")
  return network.send("event", cfg.master_id, { type = "arrived", train_id = args.train_id, station = args.station, route_id = args.route_id })
end

return debug_event
