--[[
Purpose: Startup wrapper for a station node computer.
Edit CONFIG_PATH and NODE_ID for each station.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "ST-A"

local station_node = require("src.nodes.station_node")
station_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
