--[[
Purpose: Key handling of the operator: master key, keys of the computers, carrying keys on a disk (docs/KEYS.md). The logic lives in src/setup/keys_tool.lua.
Usage: shell.run("scripts/keys.lua", "init")                       first master: create the master key
       shell.run("scripts/keys.lua", "issue", "SIG-1")             master: issue a key for a computer (onto the disk in the drive)
       shell.run("scripts/keys.lua", "install", "--id", "SIG-1")   computer: set up the key from the disk
       shell.run("scripts/keys.lua")                               prints all commands
Notes: a master that runs picks up a changed list of keys within seconds, so issue and revoke work while the net runs (a second shell tab).
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local keys_tool = require("src.setup.keys_tool")
local config_module = require("src.shared.config")

local cfg
if fs and fs.exists and fs.exists("configs/network.json") then
  local ok, loaded = pcall(config_module.load, "configs/network.json")
  if ok then cfg = loaded end
end

local code = keys_tool.run({ ... }, {
  fs = fs,
  peripheral = peripheral,
  say = print,
  ask = function(prompt) write(prompt); return read() end,
  now = function() return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time() end,
  entropy = function() return tostring(os.clock()) .. tostring(os.epoch and os.epoch("utc") or 0) end,
  config = cfg
})
if code ~= 0 then error("", 0) end
