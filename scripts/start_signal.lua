--[[
Purpose: Startup wrapper for a signal node computer.
Edit CONFIG_PATH and NODE_ID for each signal.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "SIG-AB-IN"

local signal_node = require("src.nodes.signal_node")
signal_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
