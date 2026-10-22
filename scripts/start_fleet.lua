--[[
Purpose: Startup wrapper for a fleet node (one of a fixed pair: trains, timetables, orders, cargo).
Edit CONFIG_PATH and NODE_ID for this computer.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "FLEET-A"

local fleet_node = require("src.nodes.fleet_node")
fleet_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
