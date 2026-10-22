--[[
Purpose: Startup wrapper for an onboard train computer.
Edit CONFIG_PATH and TRAIN_NODE_ID for each train.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local TRAIN_NODE_ID = "TRAIN-1"

local train_node = require("src.nodes.train_node")
train_node.new_runtime({ id = TRAIN_NODE_ID, config = CONFIG_PATH }).run()
