--[[
Purpose: Startup wrapper for an onboard train computer.
Edit CONFIG_PATH and TRAIN_NODE_ID for each train.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local TRAIN_NODE_ID = "TRAIN-1"

local train_node = require("src.nodes.train_node")
train_node.new_runtime({ id = TRAIN_NODE_ID, config = CONFIG_PATH }).run()
