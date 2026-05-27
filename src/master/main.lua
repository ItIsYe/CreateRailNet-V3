--[[
Purpose: Master node bootstrap script.
Public API: none.
]]

local shared_args = require("src.shared.args")
local master_app = require("src.master.app")

local parsed = shared_args.parse({...}, { config = {}, id = {} })
local instance = master_app.new(parsed)
instance.run()
