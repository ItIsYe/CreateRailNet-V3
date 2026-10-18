--[[
Purpose: Gives the startup.lua of this computer the OTA recovery block (older setup.lua versions did not write it).
Usage: lua scripts/upgrade_startup.lua   (nodes and the master do this by themselves at every start; this is for a look at the result)
Notes: the old file stays as startup.lua.prev. A startup.lua that does not look like setup.lua's output is not changed.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local startup_guard = require("src.shared.startup_guard")

local status, detail = startup_guard.ensure({})
if status == "upgraded" then
  print("startup.lua upgraded (old copy: startup.lua.prev). Active from the next boot.")
elseif status == "current" then
  print("startup.lua already has the OTA recovery.")
elseif status == "unrecognized" then
  print("startup.lua was NOT changed: " .. tostring(detail))
  print("Add the block from docs/OTA.md by hand, or delete startup.lua and run scripts/setup.lua again.")
else
  print("startup.lua check: " .. tostring(status) .. " " .. tostring(detail or ""))
end
