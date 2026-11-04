





local signallib = require("dev.signal")
local detect = require("dev.detect")
local model = require("setup.model")
local label = require("core.label")

local M = {}

local function signature(device) return device.kind .. ":" .. device.device end

function M.new(opts)
local p = {}
local env = opts.env
local run = nil

local function cfg() return opts.config() end

local function store()
local c = cfg()
c.pruefung = c.pruefung or {}
c.pruefung.devices = c.pruefung.devices or {}
return c.pruefung
end

local function persist()
if opts.persist then return opts.persist() end
return true
end


local function signal_devices()
local c = cfg()
local ids, seen = {}, {}
local track_ids = {}
for id in pairs(c.tracks) do track_ids[#track_ids + 1] = id end
table.sort(track_ids)
for _, tid in ipairs(track_ids) do
for _, did in ipairs(c.tracks[tid].signals or {}) do
if c.devices[did] and not seen[did] then
seen[did] = true
ids[#ids + 1] = did
end
end
end
return ids
end

local function track_name_of(did)
for _, track in pairs(cfg().tracks) do
for _, s in ipairs(track.signals or {}) do if s == did then return track.name end end
end
return "?"
end


function p.device(did)
local c = cfg()
local d = c.devices[did]
local rec = store().devices[did]
local out = { lesen = { state = "offen" }, sperre = { state = "offen" } }
if not d or not rec or rec.sig ~= signature(d) then return out end
for _, key in ipairs({ "lesen", "sperre" }) do
local r = rec[key]
if r then out[key] = { state = r.ok and "ok" or (r.blocked and "gesperrt" or "fehler"), text = r.text } end
end
return out
end

function p.all_ok()
local ids = signal_devices()
if #ids == 0 then return false end
for _, did in ipairs(ids) do
local r = p.device(did)
if r.lesen.state ~= "ok" or r.sperre.state ~= "ok" then return false end
end
return true
end


function p.required()
local c = cfg()
local problems = {}
local function add(text) problems[#problems + 1] = text end
local scan = opts.scan()
local modem = false
for _, d in ipairs(scan) do
if d.kind == "modem" and #detect.missing("modem", d) == 0 then modem = true end
end
if not modem then add("Ein erreichbares Netzwerkmodem fehlt.") end
if not (c.node.claimed and c.node.label) then add("Die Kennung der Leitstelle fehlt noch (Netz und Bereich waehlen).") end
local count = 0
local track_ids = {}
for id in pairs(c.tracks) do track_ids[#track_ids + 1] = id end
table.sort(track_ids)
if #track_ids == 0 then add("Es ist noch kein Gleis uebernommen.") end
for _, tid in ipairs(track_ids) do
local track = c.tracks[tid]
if #(track.signals or {}) == 0 then add(label.track(track.name) .. ": Das Signal fehlt noch.") end
count = count + #(track.signals or {})
end
for _, problem in ipairs(model.validate(c, scan)) do

if problem.code ~= "gleise_fehlen" and problem.code ~= "gleis_signal" then add(problem.text) end
end
if #track_ids > 0 and count == 0 then add("Es ist noch kein Signal zugeordnet.") end
return problems
end

function p.effect()
local ids = signal_devices()
local text = "An " .. #ids .. " Signal(en) wird nacheinander kurz eine zusaetzliche Rotsperre gesetzt, zurueckgelesen und wieder aufgehoben. "
.. "Zuege davor halten dabei kurz. Eine vorhandene Sperre bleibt unberuehrt. "
.. "'Pruefen+Aktivieren' bestaetigt, dass der Bereich dafuer vorbereitet ist."
return text, #ids
end



function p.start(confirmed, everything)
if confirmed ~= true then return nil, "Die Wirkung der Schaltpruefung muss zuerst bestaetigt werden." end
local problems = p.required()
if #problems > 0 then return nil, problems[1] end
local queue = {}
for _, did in ipairs(signal_devices()) do
local r = p.device(did)
if everything or r.lesen.state ~= "ok" or r.sperre.state ~= "ok" then queue[#queue + 1] = did end
end

local results = store().devices
for did in pairs(results) do if not cfg().devices[did] then results[did] = nil end end
run = { phase = (#queue == 0) and "fertig" or "laeuft", queue = queue, index = 0, total = #queue }
return true
end

local function fail(did, key, text, blocked)
local d = cfg().devices[did]
local rec = store().devices[did]
if not rec or rec.sig ~= signature(d) then rec = { sig = signature(d) }; store().devices[did] = rec end
rec[key] = { ok = false, text = text, blocked = blocked or nil, t = opts.now() }
end

local function pass(did, key, text)
local d = cfg().devices[did]
local rec = store().devices[did]
if not rec or rec.sig ~= signature(d) then rec = { sig = signature(d) }; store().devices[did] = rec end
rec[key] = { ok = true, text = text, t = opts.now() }
end


local function run_device(did)
local d = cfg().devices[did]
local rec = store().devices[did]
if rec and rec.sig ~= signature(d) then store().devices[did] = nil end
local g = signallib.new(env, d.device)
local before = g.read()
if not before.available then
fail(did, "lesen", "nicht erreichbar: " .. tostring(before.errors and before.errors[1] or ""))
if store().devices[did] then store().devices[did].sperre = nil end
return
end
if before.errors and #before.errors > 0 then
fail(did, "lesen", before.errors[1])
store().devices[did].sperre = nil
return
end
pass(did, "lesen", "lesbar (" .. tostring(before.state) .. ")")
if before.forced then
fail(did, "sperre", "Das Signal ist schon gesperrt (Betrieb oder fremd): erst aufheben, dann erneut pruefen. Die Sperre bleibt unberuehrt.", true)
return
end

store().lauf = { device = did, t = opts.now() }
local ok, err = persist()
if not ok then
store().lauf = nil
fail(did, "sperre", "Der Entwurf laesst sich nicht speichern (" .. tostring(err) .. "): es wird nicht geschaltet.")
return
end
local held = g.hold()
local released = g.release()
store().lauf = nil
if not held.confirmed then
fail(did, "sperre", "Sperre nicht bestaetigt" .. (held.error and (": " .. held.error) or "") .. ".")
elseif not released.confirmed then
fail(did, "sperre", "ACHTUNG: Die Testsperre blieb gesetzt. Bitte von Hand pruefen." .. (released.error and (" (" .. released.error .. ")") or ""))
else
pass(did, "sperre", "Sperre gesetzt und aufgehoben (jeweils zurueckgelesen)")
end
persist()
end


function p.step(seconds)
if not run or run.phase ~= "laeuft" then return run and run.phase or "idle" end
local clock = opts.clock or function() return 0 end
local t0 = clock()
repeat
if run.index >= run.total then break end
run.index = run.index + 1
run.current = run.queue[run.index]
run_device(run.current)
until (clock() - t0) >= (seconds or 0)
if run.index >= run.total then
run.phase = "fertig"
run.current = nil
persist()
end
return run.phase
end


function p.abort()
if run and run.phase == "laeuft" then
run.phase = "abgebrochen"
run.current = nil
persist()
end
end


function p.recover()
local pr = store()
local lauf = pr.lauf
if not lauf then return nil end
pr.lauf = nil
local d = cfg().devices[lauf.device]
local note, ok = "Eine unterbrochene Pruefung wurde erkannt; das Signal wird neu geprueft.", true
if d and d.kind == "signal" then
local g = signallib.new(env, d.device)
local st = g.read()
if st.available and st.forced then
local released = g.release()
if released.confirmed then
note = "Eine Testsperre war nach der Unterbrechung noch gesetzt und wurde aufgehoben: " .. d.device .. "."
else
note, ok = "ACHTUNG: Eine Testsperre an " .. d.device .. " blieb nach der Unterbrechung gesetzt und liess sich nicht aufheben. Bitte von Hand pruefen.", false
end
end
local rec = pr.devices[lauf.device]
if rec then rec.sperre = nil end
end
persist()
return note, ok
end

function p.state()
local ids = signal_devices()
local devices = {}
for _, did in ipairs(ids) do
devices[#devices + 1] = { id = did, device = cfg().devices[did].device, track = track_name_of(did), result = p.device(did) }
end
local current
if run and run.current then current = cfg().devices[run.current] and (track_name_of(run.current) .. " (" .. cfg().devices[run.current].device .. ")") end
return {
phase = run and run.phase or "idle",
done = run and run.index or 0,
total = run and run.total or 0,
current = current,
ok = p.all_ok(),
devices = devices,
}
end

return p
end

return M
