--[[
Purpose: Startup wrapper for the arbiter computer, the third voice of the master election.
Edit CONFIG_PATH and NODE_ID for this computer.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local NODE_ID = "ARBITER-1"

local arbiter_node = require("src.nodes.arbiter_node")
arbiter_node.new_runtime({ id = NODE_ID, config = CONFIG_PATH }).run()
