--[[
Purpose: Startup wrapper for a switch node computer.
Edit CONFIG_PATH and NODE_ID for each switch.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "SW-YARD"

local switch_node = require("src.nodes.switch_node")
switch_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
