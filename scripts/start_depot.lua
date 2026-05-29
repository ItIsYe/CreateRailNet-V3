--[[
Purpose: Startup wrapper for a depot node computer.
Edit CONFIG_PATH and NODE_ID for each depot.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "DEPOT-1"

local depot_node = require("src.nodes.depot_node")
depot_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
