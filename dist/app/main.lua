




local M = {}

local function load_table(env, path)
if not env.fs.exists(path) then return nil end
local fh = env.fs.open(path, "r")
if not fh then return nil end
local text = fh.readAll()
fh.close()
local chunk
if setfenv then
chunk = loadstring(text, "=" .. path)
if chunk then setfenv(chunk, {}) end
else
chunk = load(text, "=" .. path, "t", {})
end
if not chunk then return nil end
local ok, value = pcall(chunk)
if ok and type(value) == "table" then return value end
return nil
end

function M.info(env)
local root = env.root or "/crn"
local say = env.print
local manifest = load_table(env, root .. "/manifest.lua")
local install = load_table(env, root .. "/install.lua")
say("CRN - Create Rail Net")
if not manifest then
say("Kein Dateiverzeichnis gefunden (" .. root .. "/manifest.lua). Bitte neu installieren.")
return false
end
say("Version: " .. tostring(manifest.version) .. "  Stand: " .. tostring(manifest.id))
say("Rolle: " .. tostring(install and install.role or "unbekannt"))
local role = install and install.role
local paths = manifest.roles and manifest.roles[role] or {}
local bytes = 0
local count = 0
for _, path in ipairs(paths) do
local entry = manifest.files and manifest.files[path]
if entry then
bytes = bytes + math.max(entry.size, 500)
count = count + 1
end
end
say("Programm: " .. count .. " Dateien, " .. bytes .. " Byte belegt (jede Datei zaehlt mindestens 500)")
say("Frei auf dem Computer: " .. env.fs.getFreeSpace("/") .. " Byte")
return true
end


function M.run(env, args)
if args[1] == "selftest" then
local rest = {}
for i = 2, #args do rest[#rest + 1] = args[i] end
return require("app.selftest").run(env, rest)
end
if args[1] == "info" then return M.info(env) end
if args[1] == "datenstand" or args[1] == "daten-zurueck" then
local dataformat = require("core.dataformat")
local store = require("core.store").new(env.fs)
local saved = store.load("/crn_data/format.lua")
if args[1] == "datenstand" then
env.print("Datenformat auf dem Computer: " .. tostring(saved and saved.format or "unbekannt") .. ", dieses Programm kennt: " .. dataformat.FORMAT)
for _, b in ipairs(dataformat.backups(env.fs)) do env.print("Sicherung fuer Format " .. b.format .. ": " .. b.dir) end
return true
end
local ok, err = dataformat.restore(env.fs, store, tonumber(args[2]))
env.print(ok and ("Sicherung zurueckgespielt (Datenformat " .. tostring(args[2]) .. "). Bitte neu starten.") or err)
return ok == true
end
if args[1] == "update" then return M.update(env, args) end
local node = require("app.node").new(env)
node.run()
return true
end


function M.update(env, args)
local say = env.print
local u = require("core.updater").new({
fs = env.fs, store = require("core.store").new(env.fs), http = env.http, now = function() return 0 end, node_id = "befehl",
healthy = function() return true end, notify = function(_, text) say(text) end,
reboot = function() if env.reboot then env.reboot() end end,
})
local cmd, st = args[2], u.state()
if cmd == "pruefen" then
local _, text = u.check()
say(text)
return true
elseif cmd == "jetzt" then
local ok, text = u.install({ force = true })
say(text)
return ok
elseif cmd == "auto" or cmd == "melden" or cmd == "aus" then
u.set_mode(cmd)
say("Betriebsart der Selbstaktualisierung: " .. cmd)
return true
elseif cmd == "ersetzen" then
u.set_replace(args[3] == "ein")
say("Ersetzen der bisherigen Version, wenn alt und neu nicht zugleich passen: " .. (args[3] == "ein" and "erlaubt (kein Zurueck zur Vorversion)" or "nicht erlaubt"))
return true
elseif cmd ~= nil and cmd ~= "status" then
say("Aufruf: main update [status | pruefen | jetzt | auto | melden | aus | ersetzen ein|aus]")
return false
end
say("Installiert: Version " .. tostring(st.version) .. ", Stand " .. tostring(st.id) .. ", Kanal " .. tostring(st.ref) .. ", Rolle " .. tostring(st.role))
say("Betriebsart: " .. st.mode .. (st.replace and ", Ersetzen erlaubt" or "") .. (st.skipped and (", zurueckgenommener Stand " .. st.skipped) or ""))
if st.probe then say("Probezeit des neuen Stands laeuft.") end
return true
end

function M.real_env()
local function pull(timeout)
local timer = os.startTimer(timeout)
while true do
local ev = { os.pullEvent() }
if ev[1] == "timer" and ev[2] == timer then return nil end
if ev[1] ~= "timer" then
os.cancelTimer(timer)
return ev
end
end
end
return {
fs = fs, http = rawget(_G, "http"), reboot = os.reboot, print = print, raw_clock = os.clock, peripheral = peripheral, rednet = rednet, redstone = redstone, pull = pull, host = _HOST,
term = term.current and term.current() or term,
wrap = function(name) return peripheral.wrap(name) end,
start_timer = os.startTimer,
set_label = function(text) if os.setComputerLabel then os.setComputerLabel(text) end end,

unique = function()
local id = os.getComputerID and os.getComputerID() or 0
local stamp = os.epoch and (os.epoch("utc") % 2147483647) or math.random(1, 2147483646)
return tostring(id) .. "-" .. tostring(stamp)
end,

utc_seconds = function()
if os.epoch then return math.floor(os.epoch("utc") / 1000) end
return 0
end,
pull_event = function() return { os.pullEvent() } end,
}
end

if rawget(_G, "__CRN_TEST") then return M end
package.path = "/crn/?.lua;/crn/?/init.lua;" .. package.path
M.run(M.real_env(), { ... })
