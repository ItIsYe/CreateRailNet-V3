--[[
Purpose: Startup wrapper for a sensor node computer.
Edit CONFIG_PATH and NODE_ID for each sensor.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "SEN-AB"

local sensor_node = require("src.nodes.sensor_node")
sensor_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
