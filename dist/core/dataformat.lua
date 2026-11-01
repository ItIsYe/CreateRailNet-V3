





local M = {}

M.FORMAT = 1
local DATA = "/crn_data"
local FILE = DATA .. "/format.lua"
local MAX_FILE, MAX_TOTAL = 30000, 120000

local function files_to_back_up(fs)
local out, total = {}, 0
if not fs.exists(DATA) then return out, 0 end
for _, name in ipairs(fs.list(DATA)) do
local path = DATA .. "/" .. name
if not fs.isDir(path) and name ~= "journal.log" and name ~= "format.lua" and not name:match("%.tmp$") then
local size = fs.getSize(path)
if size <= MAX_FILE and total + size <= MAX_TOTAL then
out[#out + 1] = name
total = total + size
end
end
end
return out, total
end

local function copy(fs, from, to)
local src = fs.open(from, "r")
if not src then return false end
local text = src.readAll()
src.close()
local dst = fs.open(to, "w")
if not dst then return false end
dst.write(text)
dst.close()
return true
end

function M.backups(fs)
local out = {}
if not fs.exists(DATA) then return out end
for _, name in ipairs(fs.list(DATA)) do
local n = name:match("^sicherung_f(%d+)$")
if n then out[#out + 1] = { format = tonumber(n), dir = DATA .. "/" .. name } end
end
table.sort(out, function(a, b) return a.format < b.format end)
return out
end

function M.check(fs, store, opts)
opts = opts or {}
local format = opts.format or M.FORMAT
local saved = store.load(FILE)
if not saved or type(saved.format) ~= "number" then
store.save(FILE, { format = format, program = opts.program })
return "neu", nil, nil
end
if saved.format == format then
if saved.program ~= opts.program then store.save(FILE, { format = format, program = opts.program }) end
return "gleich", saved.format, nil
end
if saved.format > format then return "zu_neu", saved.format, nil end

local dir = DATA .. "/sicherung_f" .. saved.format
if not fs.exists(dir) then fs.makeDir(dir) end
for _, name in ipairs((files_to_back_up(fs))) do copy(fs, DATA .. "/" .. name, dir .. "/" .. name) end
for from = saved.format, format - 1 do
local step = opts.migrations and opts.migrations[from]
if step then step(store) end
end
store.save(FILE, { format = format, program = opts.program })
return "migriert", saved.format, dir
end


function M.restore(fs, store, format)
local dir = DATA .. "/sicherung_f" .. tostring(format)
if not fs.exists(dir) then return nil, "Keine Sicherung fuer Datenformat " .. tostring(format) .. " vorhanden." end
for _, name in ipairs(fs.list(dir)) do
if not copy(fs, dir .. "/" .. name, DATA .. "/" .. name) then return nil, "Zurueckspielen von " .. name .. " fehlgeschlagen." end
end
store.save(FILE, { format = format })
return true
end

return M
