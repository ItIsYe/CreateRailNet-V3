--[[
Purpose: Key handling of the operator (docs/KEYS.md): master key, keys of the computers, carrying keys on a disk.
Usage: shell.run("scripts/keys.lua", "init")   see scripts/keys_main.lua for all commands
Notes: stub. The tool itself is scripts/keys_main.lua; it is part of the setup bundle that is fetched when needed and removed afterwards (src/shared/setup_bundle.lua), because a computer holds a fixed 1 000 000 bytes.
]]

package.path = "/?.lua;/?/init.lua;" .. (package.path or "")

local setup_bundle = require("src.shared.setup_bundle")

local ok, err = setup_bundle.run("scripts/keys_main.lua", { ... }, { fs = fs, shell = shell, say = print })
if not ok then
  if err and err ~= "failed" then print(err) end
  error("", 0)
end
