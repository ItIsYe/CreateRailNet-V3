





local adler = require("core.adler")

local M = {}

local KINDS = { "station", "signal", "observer" }

function M.signature(scan, host)
local parts = { "host=" .. tostring(host or "?") }
for _, kind in ipairs(KINDS) do
local names
for _, d in ipairs(scan) do
if d.kind == kind then
local list = {}
for m in pairs(d.methods or {}) do list[#list + 1] = m end
table.sort(list)
local joined = table.concat(list, ",")

if names == nil or #joined < #names then names = joined end
end
end
if names then parts[#parts + 1] = kind .. "=" .. adler.hex(names) end
end
return table.concat(parts, ";")
end

function M.check(store, path, scan, host)
local current = M.signature(scan, host)
local saved = store.load(path)
if not saved or type(saved.signature) ~= "string" then
store.save(path, { signature = current })
return "erstmals", nil, current
end
if saved.signature == current then return "gleich", saved.signature, current end
return "geaendert", saved.signature, current
end

function M.accept(store, path, scan, host)
return store.save(path, { signature = M.signature(scan, host) })
end

return M
