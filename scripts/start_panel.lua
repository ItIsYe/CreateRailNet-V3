--[[
Purpose: Startup wrapper for a remote panel computer.
Edit CONFIG_PATH and PANEL_NODE_ID for each panel.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local PANEL_NODE_ID = "PANEL-1"

local panel_node = require("src.nodes.panel_node")
panel_node.new_runtime({ id = PANEL_NODE_ID, config = CONFIG_PATH }).run()
