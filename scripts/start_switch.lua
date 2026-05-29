--[[
Purpose: Startup wrapper for a switch node computer.
Edit CONFIG_PATH and NODE_ID for each switch.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "SW-YARD"

local switch_node = require("src.nodes.switch_node")
switch_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
