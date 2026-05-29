--[[
Purpose: Startup wrapper for the master computer.
Edit CONFIG_PATH and MASTER_ID for your world.
]]

local CONFIG_PATH = "configs/templates/network.full.example.json"
local MASTER_ID = "MASTER-1"

local app = require("src.master.app")
app.new({ id = MASTER_ID, config = CONFIG_PATH }).run()
