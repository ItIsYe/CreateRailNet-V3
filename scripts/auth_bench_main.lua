--[[
Purpose: Measures the cost of the message authentication on this computer (docs/KEYS.md, in-game test 0bj). The logic lives in src/setup/auth_bench.lua.
Usage: shell.run("scripts/auth_bench.lua")            200 rounds
       shell.run("scripts/auth_bench.lua", "500")     500 rounds
Notes: reads and writes nothing; it makes its own keys.
]]

-- CC:Tweaked resolves relative require paths against the directory of the running program (scripts/); the modules live in /src.
package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local auth_bench = require("src.setup.auth_bench")

local arguments = { ... }
local result = auth_bench.run({ rounds = tonumber(arguments[1]) or 200 })
for _, line in ipairs(auth_bench.lines(result)) do print(line) end
