--[[
Purpose: Startup wrapper for a station node computer.
Edit CONFIG_PATH and NODE_ID for each station.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "ST-A"

local station_node = require("src.nodes.station_node")
station_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
