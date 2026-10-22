--[[
Purpose: Measures the cost of the message authentication on this computer (docs/KEYS.md, in-game test 0bj).
Usage: shell.run("scripts/auth_bench.lua", "500")
Notes: stub. The tool itself is scripts/auth_bench_main.lua; it is part of the setup bundle that is fetched when needed and removed afterwards (src/shared/setup_bundle.lua), because a computer holds a fixed 1 000 000 bytes.
]]

package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local setup_bundle = require("src.shared.setup_bundle")

local ok, err = setup_bundle.run("scripts/auth_bench_main.lua", { ... }, { fs = fs, shell = shell, say = print })
if not ok then
  if err and err ~= "failed" then print(err) end
  error("", 0)
end
