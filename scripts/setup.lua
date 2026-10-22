--[[
Purpose: First-time setup and the tools of a CreateRailNet computer (wizard, --check, --doctor, --fetch-plan, --test, --linktest, --export, --layout).
Usage: shell.run("scripts/setup.lua", "--role", "sensor")   see scripts/setup_main.lua for all options
Notes: stub. The tool itself is scripts/setup_main.lua; it is part of the setup bundle that is fetched when needed and removed afterwards (src/shared/setup_bundle.lua), because a computer holds a fixed 1 000 000 bytes.
]]

package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local setup_bundle = require("src.shared.setup_bundle")

local ok, err = setup_bundle.run("scripts/setup_main.lua", { ... }, { fs = fs, shell = shell, say = print })
if not ok then
  if err and err ~= "failed" then print(err) end
  error("", 0)
end
