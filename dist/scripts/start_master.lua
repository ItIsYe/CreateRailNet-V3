--[[
Purpose: Startup wrapper for the master computer.
Edit CONFIG_PATH and MASTER_ID for your world.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local CONFIG_PATH = "configs/templates/network.full.example.json"
local MASTER_ID = "MASTER-1"

local app = require("src.master.app")
app.new({ id = MASTER_ID, config = CONFIG_PATH }).run()
