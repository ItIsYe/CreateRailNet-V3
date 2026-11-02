





local observerlib = require("dev.observer")
local areaslib = require("domain.areas")
local model = require("setup.model")
local W = require("ui.widgets")

local M = {}

local HEARTBEAT = 5
local OWNER = "knoten"
local DEDUPE = 5

function M.new(node, signals)
local role = {}
local config = node.config
local env = node.env
local now = function() return node.clock.now() end
local junction = config.junction
local confirm = {}
local last_beat = -9999
local dirty = true

role.areas = areaslib.new({
connections = junction.connections, moves = junction.moves, conflicts = junction.conflicts, now = now,
store = node.store, path = "/crn_data/knoten.lua",
})



local function entry_signals(spec)
local all = spec.signals or {}
if #all <= 1 then return all end
local marked = {}
for _, did in ipairs(all) do
local d = config.devices[did]
if d and d.signal and d.signal.use == "einfahrt" then marked[#marked + 1] = did end
end
if #marked == 1 then return marked end
return all
end


local points = {}
local entries = {}
local tids = {}
for id in pairs(config.tracks) do tids[#tids + 1] = id end
table.sort(tids)
for _, tid in ipairs(tids) do
local spec = config.tracks[tid]
local jn = spec.junction
if jn and junction.connections[jn.connection] then
local obs_ids = {}
for _, oid in ipairs(spec.observers or {}) do
if config.devices[oid] then
local name = config.devices[oid].device
points[oid] = { conn = jn.connection, kind = jn.role, track = tid, observer = observerlib.new(env, name), device = name, last = nil }
obs_ids[#obs_ids + 1] = oid
end
end
if jn.role == "ein" then
entries[jn.connection] = entries[jn.connection] or {}
entries[jn.connection][#entries[jn.connection] + 1] = { track = tid, name = spec.name, signals = entry_signals(spec) }
end
end
end


local function entry_track(conn, track_id)
for _, e in ipairs(entries[conn] or {}) do if e.track == track_id then return e end end
end

local function lock_entry(e, reason)
for _, sid in ipairs(e.signals) do
local ok, err = signals.lock(sid, OWNER, reason)
if not ok then node.notify("fehler", "Einfahrt " .. e.name .. ": " .. tostring(err)) end
end
end

local function unlock_entry(e)
for _, sid in ipairs(e.signals) do
local ok, err = signals.unlock(sid, OWNER)
if not ok then node.notify("fehler", "Einfahrt " .. e.name .. ": Freigabe nicht bestaetigt: " .. tostring(err)) end
end
end

local function grant_pending()
for _, use in ipairs(role.areas.next_grants()) do
local e = entry_track(use.entry, use.track)
if e then unlock_entry(e) end
dirty = true
end
end



function role.observe(oid, train, kind)
local p = points[oid]
if not p then return end

local key = kind .. ":" .. tostring(train)
local t = now()
p.seen = p.seen or {}
if p.seen[key] and t - p.seen[key] < DEDUPE then return end
p.seen[key] = t
if kind == "passing" then p.last = train elseif p.last == train then p.last = nil end
dirty = true
if p.kind == "ein" then
if kind == "passing" and train then
role.areas.announce(p.conn, train, p.track)
grant_pending()
elseif kind == "passed" then
local use, unplanned = role.areas.entered(p.conn, train, p.track)
local e = entry_track(p.conn, p.track)
if e then lock_entry(e, "Einfahrt gesperrt") end
if unplanned then
node.notify("warnung", "Knoten: " .. tostring(train) .. " ist an " .. p.conn .. " eingefahren, ohne dass die Einfahrt freigegeben war.")
end
end
else
local use, state = role.areas.exited(p.conn, train, kind)
if not use then
node.notify("warnung", "Knoten: Ausfahrt " .. p.conn .. " von " .. tostring(train) .. " ohne passende Einfahrt (" .. tostring(state) .. ").")
else
grant_pending()
end
end
end

function role.on_event(ev)
if ev.kind ~= "observer" or ev.problem then return end
if ev.type == "train_passing" then role.observe(ev.id, ev.train, "passing")
elseif ev.type == "train_passed" then role.observe(ev.id, ev.train, "passed") end
end


local function poll()
for oid, p in pairs(points) do
local st = p.observer.read()
if st.available then
if st.passing and st.train and p.last ~= st.train then
role.observe(oid, st.train, "passing")
elseif not st.passing and p.last ~= nil then
role.observe(oid, p.last, "passed")
end
end
end
end


local function initial_locks()
local open = {}
for _, u in ipairs(role.areas.status()) do
if u.state == "freigegeben" and u.track then open[u.entry .. "/" .. u.track] = true end
end
local conns = {}
for conn in pairs(entries) do conns[#conns + 1] = conn end
table.sort(conns)
for _, conn in ipairs(conns) do
for _, e in ipairs(entries[conn]) do
if not open[conn .. "/" .. e.track] then lock_entry(e, "Einfahrt gesperrt") end
end
end
end





local SYNC_FIRST, SYNC_EVERY, SYNC_WAIT, SYNC_RETRY = 20, 600, 15, 60
local sync = { next_at = SYNC_FIRST, req = nil, state = "offen", note = nil, notified = nil, stage = nil, full = nil, plan = nil, why = nil }
role.sync = sync
local sync_confirm = {}

local function directory_backed() return config.node.claimed and config.node.junction or nil end

local function ask(part, stage)
local m = node.send_to(node.central_id(), "abfrage", { kind = "knoten_teil", junction = directory_backed(), part = part })
sync.req, sync.stage, sync.asked, sync.state = m and m.messageId or nil, stage or part, now(), "frage"
return m ~= nil
end

function role.sync_request()
if not directory_backed() then return nil, "Diese Node ist nicht ueber das Netzverzeichnis eingerichtet." end
if sync.state == "frage" and now() - (sync.asked or 0) < SYNC_WAIT then return nil, "Die Frage laeuft noch." end
sync.full, sync.plan, sync.why, sync_confirm.armed = nil, nil, nil, false
sync.next_at = now() + SYNC_EVERY
ask("anschluesse")
return true
end

local function count_of(list) return #list end


local function evaluate(full)
local t, why = model.junction_from_directory({ connections = full.connections, routes = full.routes, conflicts = full.conflicts })
if not t then return nil, why end
local mine, own = {}, 0
for tid, tr in pairs(config.tracks) do
if not tr.dir then return nil, "Ein Gleis hat keine Zuordnung zum Verzeichnis." end
mine[tr.dir.id] = tid
own = own + 1
end
if #t.tracks ~= own then return nil, "Die Gleise des Knotens haben sich geaendert." end
local names = {}
for _, x in ipairs(t.tracks) do
local tid = mine[x.id]
local tr = tid and config.tracks[tid]
if not tr or not tr.junction or tr.junction.connection ~= x.connection or tr.junction.role ~= x.role then
return nil, "Anschluesse oder Gleisrollen haben sich geaendert."
end
if tr.name ~= x.name then names[tid] = x.name end
end
local renamed = 0
for _ in pairs(names) do renamed = renamed + 1 end
return {
rev = full.rev, names = names, renamed = renamed,
junction = { connections = t.connections, moves = t.moves, conflicts = t.conflicts },
text = "Fahrwege " .. count_of(junction.moves) .. " -> " .. count_of(t.moves) .. ", Konflikte " .. count_of(junction.conflicts) .. " -> " .. count_of(t.conflicts)
.. (renamed > 0 and (", " .. renamed .. " Gleisname(n)") or ""),
}
end

local function announce_deviation(rev)
if sync.notified ~= rev then
sync.notified = rev
node.notify("warnung", "Abweichung zum Netzverzeichnis: " .. sync.note)
end
end

function role.on_message(m, status)
if status ~= "ok" or m.messageType ~= "bestaetigung" then return end
local p = m.payload
if type(p) ~= "table" or p.kind ~= "antwort" or p.antwort_auf ~= "knoten_teil" then return end
if not (sync.req and m.correlationId == sync.req and sync.state == "frage") then return end
sync.req = nil
local stage = sync.stage
if p.status ~= "ok" then
sync.state, sync.note, sync.full, sync.plan = "abgelehnt", type(p.grund) == "string" and p.grund:sub(1, 80) or "abgelehnt", nil, nil
if sync.notified ~= "abgelehnt" then
sync.notified = "abgelehnt"
node.notify("warnung", "Netzverzeichnis: " .. sync.note)
end
return
end
local id = directory_backed()
local part = p.part
if type(part) ~= "table" or part.id ~= id then
sync.state, sync.note, sync.full = "unlesbar", "Unerwartete Antwort der Leitstelle.", nil
return
end
if stage == "anschluesse" then
if type(part.rev) ~= "number" then sync.state, sync.note = "unlesbar", "Unerwartete Antwort der Leitstelle." return end
if math.floor(part.rev) == config.node.junction_rev then
sync.state, sync.note, sync.notified, sync.plan, sync.full = "gleich", nil, nil, nil, nil
return
end

local base = "Der Knoten wurde in der Leitstelle geaendert (Stand " .. tostring(config.node.junction_rev) .. " -> " .. math.floor(part.rev) .. ")"
sync.base, sync.rev = base, math.floor(part.rev)
local parsed = node.parse_junction_connections(part, id)
if not parsed then
sync.state, sync.note, sync.plan = "abweichend", base .. ": Einrichtung pruefen.", nil
announce_deviation(sync.rev)
return
end
sync.full = parsed
ask("fahrwege")
elseif stage == "fahrwege" then
local routes = node.parse_junction_routes(part, id)
if not routes or not sync.full then sync.state, sync.note, sync.full = "unlesbar", "Unerwartete Antwort der Leitstelle.", nil return end
sync.full.routes = routes
ask("konflikte")
elseif stage == "konflikte" then
local conflicts = node.parse_junction_conflicts(part, id)
if not conflicts or not sync.full then sync.state, sync.note, sync.full = "unlesbar", "Unerwartete Antwort der Leitstelle.", nil return end
sync.full.conflicts = conflicts
ask("anschluesse", "nachpruefung")
elseif stage == "nachpruefung" then

if type(part.rev) ~= "number" or not sync.full or math.floor(part.rev) ~= sync.full.rev then
sync.state, sync.plan, sync.full = "abweichend", nil, nil
sync.note = sync.base .. ": die Leitstelle aendert den Knoten gerade, Abgleich wird wiederholt."
sync.next_at = now() + SYNC_RETRY
return
end
local plan, why = evaluate(sync.full)
sync.full = nil
sync.state = "abweichend"
if plan then
sync.plan, sync.why = plan, nil
sync.note = sync.base .. ": Uebernehmen moeglich (" .. plan.text .. ")."
else
sync.plan, sync.why = nil, why
sync.note = sync.base .. ": nicht uebernehmbar (" .. tostring(why) .. ") Einrichtung neu durchlaufen."
end
announce_deviation(sync.rev)
end
end


function role.sync_apply()
local plan = sync.plan
if sync.state ~= "abweichend" or not plan then return nil, "Nichts zu uebernehmen." end
if #role.areas.status() > 0 then return nil, "Im Knoten ist eine Nutzung vorgemerkt oder unterwegs: erst uebernehmen, wenn er frei ist." end
local before = { junction = config.junction, rev = config.node.junction_rev, revision = config.revision, names = {} }
for tid in pairs(plan.names) do before.names[tid] = config.tracks[tid].name end
config.junction, config.node.junction_rev = plan.junction, plan.rev
for tid, name in pairs(plan.names) do config.tracks[tid].name = name end
config.revision = (config.revision or 0) + 1
local ok, err = node.save_config()
if not ok then
config.junction, config.node.junction_rev, config.revision = before.junction, before.rev, before.revision
for tid, name in pairs(before.names) do config.tracks[tid].name = name end
return nil, "Speichern fehlgeschlagen: " .. tostring(err)
end
junction = config.junction
role.areas = areaslib.new({
connections = junction.connections, moves = junction.moves, conflicts = junction.conflicts, now = now,
store = node.store, path = "/crn_data/knoten.lua",
})
for _, list in pairs(entries) do
for _, e in ipairs(list) do if config.tracks[e.track] then e.name = config.tracks[e.track].name end end
end
sync.state, sync.note, sync.notified, sync.plan, sync.why, sync_confirm.armed = "gleich", nil, nil, nil, nil, false
dirty = true
return true
end

function role.tick()
poll()
grant_pending()
local t = now()
if directory_backed() then
if sync.state == "frage" and t - (sync.asked or 0) >= SYNC_WAIT then
sync.state, sync.note = "keine Antwort", "Die Leitstelle antwortet nicht; die lokale Einrichtung bleibt unveraendert."
end
if t >= sync.next_at and sync.state ~= "frage" then role.sync_request() end
end
if dirty or t - last_beat >= HEARTBEAT then
node.send_to(node.central_id(), "meldung", { kind = "knoten", node = config.node.id, uses = role.areas.status(), t = t })
last_beat, dirty = t, false
end
end


local STATE_TEXT = { angekuendigt = "angekuendigt, wartet", freigegeben = "Einfahrt freigegeben", eingefahren = "eingefahren", ausgefahren = "Spitze ausgefahren, Ende fehlt" }
role.page = {
id = "knoten", title = "Knoten",
render = function(v, rect)
local state = v.page_state("knoten")
state.list = state.list or { index = 1 }
state.uses = {}
local items = {}
for i, u in ipairs(role.areas.status()) do
items[i] = {
text = u.id .. " " .. tostring(u.train) .. " an " .. u.entry,
detail = (u.long and "LANGE BELEGT: " or "") .. (STATE_TEXT[u.state] or u.state) .. (u.unplanned and ", ungeplant" or ""),
kind = u.long and "halt" or (u.state == "angekuendigt" and "wait" or "text"),
}
state.uses[i] = u
end
local has_sync = directory_backed() ~= nil
local text, kind
if has_sync then
if sync.state == "abweichend" then text, kind = sync.note, "attention"
elseif sync.state == "gleich" then text, kind = "Netzverzeichnis: der Knoten stimmt mit der Leitstelle ueberein.", "ok"
elseif sync.state == "frage" then text, kind = "Netzverzeichnis: frage die Leitstelle ...", "wait"
elseif sync.state == "offen" then text, kind = "Netzverzeichnis: noch nicht abgeglichen.", "dim"
else text, kind = "Netzverzeichnis: " .. tostring(sync.note or sync.state), "wait" end
end
local lines = text and W.wrap(text, rect.w - 2) or {}
local used = math.min(#lines, 3)
W.list(v, "knoten", has_sync and { x = rect.x, y = rect.y, w = rect.w, h = math.max(2, rect.h - used) } or rect, items, state.list, { empty = "Der Knoten ist frei (nachgewiesen)." })
for i = 1, used do W.label(v, rect.x + 1, rect.y + rect.h - used + i - 1, lines[i], kind, rect.w - 2) end
end,
actions = function(v)
local state = v.page_state("knoten")
local u = state.uses and state.uses[(state.list or { index = 1 }).index]
local list = { { id = "aufloesen", label = confirm.armed and "Wirklich?" or "Pruefen+frei", kind = "danger", enabled = u ~= nil, reason = "Keine Nutzung gewaehlt." } }
if directory_backed() then
list[#list + 1] = { id = "abgleich", label = "Abgleich", kind = "secondary", enabled = sync.state ~= "frage", reason = "Die Frage an die Leitstelle laeuft." }
if sync.state == "abweichend" and sync.plan then
list[#list + 1] = { id = "uebernehmen", label = sync_confirm.armed and "Wirklich?" or "Uebernehmen", kind = "danger" }
end
end
return list
end,
on_action = function(v, id)
if id == "act:abgleich" then
local ok, why = role.sync_request()
v.hint = ok and "Frage die Leitstelle ..." or why
return true
elseif id == "act:uebernehmen" then
if not (sync.state == "abweichend" and sync.plan) then v.hint = "Nichts zu uebernehmen." return true end
if not sync_confirm.armed then
sync_confirm.armed = true
v.hint = "Fahrwege und Konflikte aendern die Freigaben: " .. sync.plan.text .. ". Nochmal druecken."
return true
end
sync_confirm.armed = false
local ok, why = role.sync_apply()
v.hint = ok and "Aenderung aus dem Netzverzeichnis uebernommen." or why
return true
end
if id ~= "act:aufloesen" then return end
local state = v.page_state("knoten")
local u = state.uses and state.uses[state.list.index]
if not u then return true end
if not confirm.armed then
confirm.armed = true
v.hint = "Nur nach Sichtpruefung: der Bereich gilt dann als frei. Nochmal druecken."
else
confirm.armed = false
local ok, err = role.areas.clear(u.id, "Bediener nach Pruefung")
if ok then
local e = u.track and entry_track(u.entry, u.track)
if e then lock_entry(e, "Einfahrt gesperrt") end
grant_pending()
v.hint = "Nutzung aufgeloest (protokolliert)."
else
v.hint = err
end
end
return true
end,
}

initial_locks()
return role
end

return M
