--[[
Purpose: Startup wrapper for a sensor node computer.
Edit CONFIG_PATH and NODE_ID for each sensor.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "SEN-AB"

local sensor_node = require("src.nodes.sensor_node")
sensor_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
