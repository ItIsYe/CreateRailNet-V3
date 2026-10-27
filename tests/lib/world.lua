--[[
Purpose: Gemeinsame Testwelt fuer Installer und Dialog: ein Computer (Fake-Dateisystem), ein "Server" mit den Dateien aus dem echten dist/ unter einer Version, und Hilfen zum Erzeugen einer zweiten Version.
API: world.world(opts) -> fs, http, env; world.add_version(http, from, to); world.BASE; world.read(path)
]]

local cc = dofile("tests/fakes/cc.lua")

local M = {}

M.BASE = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/"

function M.read(path)
  local fh = assert(io.open(path, "rb"))
  local text = fh:read("*a")
  fh:close()
  return text
end

-- Antworten des Servers aus dem echten dist/; tweak darf Dateien veraendern
function M.routes_for(ref, tweak)
  local manifest = dofile("dist/manifest.lua")
  local routes = { [M.BASE .. ref .. "/dist/manifest.lua"] = M.read("dist/manifest.lua") }
  for path in pairs(manifest.files) do routes[M.BASE .. ref .. "/dist/" .. path] = M.read("dist/" .. path) end
  if tweak then tweak(routes, ref) end
  return routes
end

function M.world(opts)
  opts = opts or {}
  local fs = cc.fs(opts.fs)
  local http = cc.http(M.routes_for(opts.ref or "v0.1.0", opts.tweak))
  return fs, http, cc.env(fs, http)
end

-- legt unter der Version "to" einen Stand an, der wie "from" aussieht, aber eine andere Versionsnummer und einen anderen Stand hat
function M.add_version(http, from, to, number)
  local manifest = http.routes[M.BASE .. from .. "/dist/manifest.lua"]
  http.routes[M.BASE .. to .. "/dist/manifest.lua"] =
    (manifest:gsub('version = "[^"]+"', 'version = "' .. number .. '"'):gsub('id = "%x+"', 'id = "deadbeef"'))
  for url, body in pairs(http.routes) do
    local path = url:match("^" .. M.BASE:gsub("%p", "%%%0") .. from:gsub("%p", "%%%0") .. "/dist/(.+)$")
    if path and path ~= "manifest.lua" then http.routes[M.BASE .. to .. "/dist/" .. path] = body end
  end
end

return M
