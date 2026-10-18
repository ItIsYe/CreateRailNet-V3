--[[
Purpose: Writes or checks install/manifest.lua, the file list of the installer (size and Adler-32 of every installed file).
Usage: lua scripts/manifest_sync.lua --write     after changing any runtime file (src/, scripts/ that are installed, config templates)
       lua scripts/manifest_sync.lua --check     CI: fails when the committed manifest does not match the files
Notes: dev tool, runs outside the game from the repository root.
]]

package.path = table.concat({ "./?.lua", "./?/init.lua", package.path or "" }, ";")

local json = require("src.shared.json")
local manifest_builder = require("src.tools.manifest_builder")

local MANIFEST_PATH = "install/manifest.lua"

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local body = fh:read("*a")
  fh:close()
  return body
end

local mode = (arg and arg[1]) or "--check"
local runtime_manifest = json.decode(read("configs/install/runtime_manifest.json") or "{}")
local manifest, problems = manifest_builder.build(read, runtime_manifest)
if #problems > 0 then
  for _, text in ipairs(problems) do print("PROBLEM " .. text) end
  os.exit(1)
end
local text = manifest_builder.render(manifest)

if mode == "--write" then
  local fh = assert(io.open(MANIFEST_PATH, "wb"))
  fh:write(text)
  fh:close()
  local count = 0
  for _ in pairs(manifest.files) do count = count + 1 end
  print("wrote " .. MANIFEST_PATH .. " (" .. count .. " files, id " .. manifest.id .. ")")
elseif mode == "--check" then
  if read(MANIFEST_PATH) == text then
    print("manifest is current (id " .. manifest.id .. ")")
  else
    print("install/manifest.lua is out of date. Run: lua scripts/manifest_sync.lua --write")
    os.exit(1)
  end
else
  print("usage: lua scripts/manifest_sync.lua --write | --check")
  os.exit(2)
end
