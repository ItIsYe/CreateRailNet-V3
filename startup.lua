--[[
CreateRailNet-V3 CC:Tweaked startup entrypoint.
Edit CRN_ROLE, CRN_ID, and CRN_CONFIG on each computer.
]]

local CRN_ROLE = "master"
local CRN_ID = "MASTER-1"
local CRN_CONFIG = "configs/templates/network.full.example.json"

local role_entrypoints = {
  master = "src.master.main",
  signal = "src.nodes.signal_node",
  sensor = "src.nodes.sensor_node",
  switch = "src.nodes.switch_node",
  train = "src.nodes.train_node",
  station = "src.nodes.station_node",
  depot = "src.nodes.depot_node",
  panel = "src.nodes.panel_node"
}

local entrypoint = role_entrypoints[CRN_ROLE]
if not entrypoint then error("Unknown CRN_ROLE: " .. tostring(CRN_ROLE)) end

print("CreateRailNet starting role=" .. CRN_ROLE .. " id=" .. CRN_ID)
local mod = require(entrypoint)
if mod and mod.new_runtime then
  mod.new_runtime({ id = CRN_ID, config = CRN_CONFIG }).run()
elseif mod and mod.run then
  mod.run({ id = CRN_ID, config = CRN_CONFIG })
else
  shell.run("run", entrypoint, "--id", CRN_ID, "--config", CRN_CONFIG)
end
