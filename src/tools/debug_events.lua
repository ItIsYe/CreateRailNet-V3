--[[
Purpose: Safe debug event sender for ingame tests.
Usage examples:
  debug_events.run({ id="DBG-1", config="configs/templates/network.full.example.json", kind="sensor", sensor_id="SEN-AB", action="enter" })
  debug_events.run({ id="DBG-1", config="configs/templates/network.full.example.json", kind="train_depart", train_id="TRAIN-1", from="ST-A", to="ST-B" })
]]

local config = require("src.shared.config")
local log = require("src.shared.log")
local cc_modem = require("src.adapter.cc_modem")
local net = require("src.shared.net")

local debug_events = {}

local function build_payload(args)
  if args.kind == "sensor" then
    return { type = "sensor", sensor_id = args.sensor_id, action = args.action or "enter" }
  elseif args.kind == "train_depart" then
    return { type = "request_departure", train_id = args.train_id, from = args.from, to = args.to, route_id = args.route_id }
  elseif args.kind == "train_arrived" then
    return { type = "arrived", train_id = args.train_id, station = args.station, route_id = args.route_id }
  elseif args.kind == "manual" then
    return { type = "manual_control", action = args.action, train_id = args.train_id, route_id = args.route_id, signal_id = args.signal_id, switch_id = args.switch_id, aspect = args.aspect, position = args.position, reason = args.reason }
  end
  return nil, "unknown debug kind: " .. tostring(args.kind)
end

function debug_events.run(args)
  local options = args or {}
  local cfg = config.load(options.config or "configs/templates/network.full.example.json")
  local modem = cc_modem.new({ channel = cfg.channel })
  local ok, err = modem:open(cfg.channel)
  if ok == false then print("MODEM FAIL: " .. tostring(err)); return false, err end
  local network = net.new(modem, cfg.channel, options.id or "DEBUG-1", log.new("INFO", 20))
  local payload, payload_err = build_payload(options)
  if not payload then print(payload_err); return false, payload_err end
  network.send("event", cfg.master_id, payload)
  print("sent " .. tostring(options.kind) .. " to " .. tostring(cfg.master_id))
  return true
end

local raw = {...}
if #raw > 0 then
  debug_events.run({ kind = raw[1], sensor_id = raw[2], action = raw[3], train_id = raw[2], to = raw[3] })
end

return debug_events
