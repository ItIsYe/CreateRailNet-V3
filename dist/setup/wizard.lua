--[[
Purpose: Ablauf des Einrichtungsassistenten in sechs Hauptschritten (Konzept 29.1): Anlage, Rolle, Geraete, Gleise, Test, Fertig. Reine Zustandsfuehrung ohne Oberflaeche: Eingaben, Weiterschalten mit Pruefung, Geraeteauswahl, Gleise und Knotenpunkt bearbeiten, gefuehrte Pruefungen (lesend und schaltend, schaltend nur nach ausdruecklicher Bestaetigung), Speichern als Entwurf oder aktiv.
API: wizard.new{ scan, env, now, existing } -> w; w.step; w.next() / w.back(); w.step_ok(n) -> ok, grund; w.config; w.tests() -> Liste; w.run_test(id, confirmed) -> ok, text; w.finish(store, path) -> status, probleme
Notes: Lesende Erkennung und schaltende Pruefungen sind getrennt: ein schaltender Test laeuft nur mit confirmed = true, nennt vorher Geraet und erwartete Wirkung (test.explain) und stellt den Ausgangszustand wieder her. Ein erfolgreicher API-Aufruf zaehlt nur als Ausfuehrung des Befehls (Konzept 29.1). Fehlt ein Geraet, wird die Einrichtung als Entwurf gespeichert; die betroffene Betriebsfunktion bleibt inaktiv (status = "entwurf").
]]

local model = require("setup.model")
local ser = require("core.ser")
local adler = require("core.adler")
local detect = require("dev.detect")
local stationlib = require("dev.station")
local signallib = require("dev.signal")
local observerlib = require("dev.observer")
local outlib = require("dev.out")

local M = {}

-- Geraeteklassen, die zu einem Node gehoeren koennen (Modems werden nicht zugeordnet, sondern nur gezeigt)
local SELECTABLE = { station = true, signal = true, observer = true, relay = true, monitor = true, displaylink = true }

M.STEPS = { "Anlage", "Rolle", "Geraete", "Gleise", "Test", "Fertig" }

function M.new(opts)
  local w = { step = 1, mode = "create", network_name = "", central_id = "", key = "", name = "", roles = {}, scan = opts.scan() }
  local env = opts.env
  local existing = opts.existing
  if not existing and opts.role_available and not opts.role_available("zentrale") then w.mode = "join" end

  w.config = existing and assert(ser.decode(ser.encode(existing))) or model.new("", {}, {})
  if existing then
    w.network_name = existing.network.name
    w.central_id = existing.network.central_id or ""
    w.key = existing.network.key or ""
    w.name = existing.node.name
    w.roles = {}
    for _, r in ipairs(existing.node.roles) do w.roles[#w.roles + 1] = r end
    w.mode = model.has_role(existing, "zentrale") and "create" or "join"
  end

  local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
  end

  local function sync_config()
    local c = w.config
    c.network.name = w.network_name
    c.network.central_id = (w.mode == "join" and w.central_id ~= "") and w.central_id or nil
    c.network.key = (w.key ~= "") and w.key or nil
    c.node.name = w.name
    if not existing then c.node.id = model.slug(w.name) end
    c.node.roles = {}
    for _, r in ipairs(model.ROLES) do if has(w.roles, r) then c.node.roles[#c.node.roles + 1] = r end end
  end

  function w.rescan()
    w.scan = opts.scan()
    for _, d in pairs(w.config.devices) do
      local found = detect.find(w.scan, d.device)
      if not found or found.kind ~= d.kind or #detect.missing(d.kind, found) > 0 then w.config.tests = {} end
    end
  end

  function w.set_mode(mode) w.mode = mode; sync_config() end
  function w.set_network(name, central, key)
    w.network_name, w.central_id, w.key = name or w.network_name, central or w.central_id, key or w.key
    sync_config()
  end
  function w.set_name(name) w.name = name; sync_config() end
  function w.available_roles()
    local roles = {}
    for _, role in ipairs(model.ROLES) do if not opts.role_available or opts.role_available(role) then roles[#roles+1]=role end end
    return roles
  end

  function w.toggle_role(role)
    if not has(w.available_roles(), role) then return false end
    if has(w.roles, role) then
      local kept = {}
      for _, r in ipairs(w.roles) do if r ~= role then kept[#kept + 1] = r end end
      w.roles = kept
    else
      w.roles[#w.roles + 1] = role
    end
    sync_config()
    local p = model.profile(w.config)
    local remove = {}
    for id, d in pairs(w.config.devices) do if not p.allowed[d.kind] then remove[#remove+1]=id end end
    for _,id in ipairs(remove) do model.remove_device(w.config,id) end
    if not p.release then for _,track in pairs(w.config.tracks) do track.release=nil end end
    if not model.has_role(w.config,"anmeldung") then w.config.registration_station=nil end
    if not model.has_role(w.config,"knoten") then
      w.config.junction={connections={},moves={},conflicts={}}
      for _,track in pairs(w.config.tracks) do track.junction=nil end
    end
    if not p.tracks then w.config.tracks={} end
    w.config.tests={}
    return true
  end

  local function needs(kind_role)
    return model.has_role(w.config, kind_role)
  end

  function w.allowed_devices() return model.profile(w.config).allowed end

  local function fingerprint()
    local c = w.config
    local tracks = assert(ser.decode(ser.encode(c.tracks)))
    for _, track in pairs(tracks) do track.status = nil end
    local text = ser.encode({ network = c.network, node = c.node, devices = c.devices,
      tracks = tracks, junction = c.junction, registration_station = c.registration_station })
    -- Feste Laenge pro Test: keine Kopie der Gesamtanlage fuer jedes Signal speichern.
    return #text .. ":" .. adler.hex(text)
  end

  function w.step_ok(n)
    sync_config()
    if n == 1 then
      if not w.network_name:match("%S") then return false, "Der Netzname fehlt." end
      if w.mode == "join" and not w.central_id:match("%S") then return false, "Die Kennung der Leitstelle fehlt." end
      return true
    elseif n == 2 then
      if not w.name:match("%S") then return false, "Der Node braucht einen Namen." end
      if #w.roles == 0 then return false, "Bitte mindestens eine Rolle waehlen." end
      for _,role in ipairs(w.roles) do if not has(w.available_roles(),role) then return false, "Die Programmdateien fuer Rolle " .. role .. " fehlen." end end
      if w.mode == "create" and not has(w.roles, "zentrale") then return false, "Die erste Leitstelle braucht die Rolle Leitstelle." end
      if w.mode == "join" and has(w.roles, "zentrale") then
        return false, "Eine zweite aktive Leitstelle ist nicht vorgesehen. Eine Ersatz-Leitstelle wird ueber 'Vorhandene Node uebernehmen' eingerichtet."
      end
      return true
    elseif n >= 3 then
      w.rescan()
      local modem = false
      for _, d in ipairs(w.scan) do
        if d.kind == "modem" and #detect.missing("modem", d) == 0 then modem = true end
      end
      if not modem then return false, "Ein erreichbares Netzwerkmodem fehlt." end
      local counts = {}
      for _, d in pairs(w.config.devices) do
        local found = detect.find(w.scan, d.device)
        if not w.allowed_devices()[d.kind] then return false, "Geraet " .. d.device .. " passt nicht zur Rolle. Bitte abwaehlen." end
        if not found or found.kind ~= d.kind then return false, "Geraet " .. d.device .. " ist nicht erreichbar oder hat die falsche Art." end
        if #detect.missing(d.kind, found) > 0 then return false, "Geraet " .. d.device .. ": erforderliche Methoden fehlen." end
        counts[d.kind] = (counts[d.kind] or 0) + 1
      end
      local p = model.profile(w.config)
      if (p.station or needs("anmeldung")) and not counts.station then return false, "Mindestens eine Train Station muss ausgewaehlt werden." end
      if p.signal and not counts.signal then return false, "Mindestens ein Train Signal muss ausgewaehlt werden." end
      if needs("knoten") and not counts.observer then return false, "Ein Knotenpunkt braucht Beobachter fuer die Rueckmeldung." end
      if n >= 4 then
        local problems = model.validate(w.config, w.scan)
        if #problems > 0 then return false, problems[1].text end
      end
      if n >= 5 and not w.all_tests_ok() then return false, "Erforderliche Pruefungen sind noch offen oder fehlgeschlagen." end
      return true
    end
    return true
  end

  function w.warnings()
    sync_config()
    local out = {}
    for _, p in ipairs(model.validate(w.config, w.scan)) do out[#out + 1] = p end
    return out
  end

  function w.next()
    local ok, reason = w.step_ok(w.step)
    if not ok then return false, reason end
    if w.step < #M.STEPS then w.step = w.step + 1 end
    if w.step == 3 then w.rescan() end
    return true
  end

  function w.back()
    if w.step > 1 then w.step = w.step - 1 end
    if w.step == 3 then w.rescan() end
    return true
  end

  -- Schritt 3 ----------------------------------------------------------------------------------------------------------------------------
  function w.device_selected(name)
    for _, d in pairs(w.config.devices) do if d.device == name then return true end end
    return false
  end

  function w.toggle_device(name)
    local found = detect.find(w.scan, name)
    if not found or not SELECTABLE[found.kind] or not w.allowed_devices()[found.kind] then return false end
    for id, d in pairs(w.config.devices) do
      if d.device == name then
        model.remove_device(w.config, id)
        return true
      end
    end
    model.add_device(w.config, found.kind, name)
    return true
  end

  -- Schritt 4 ----------------------------------------------------------------------------------------------------------------------------
  function w.tracks()
    local ids = {}
    for id in pairs(w.config.tracks) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
  end

  function w.add_track(name)
    return model.add_track(w.config, name)
  end

  function w.copy_track(id, name)
    return model.copy_track(w.config, id, name)
  end

  function w.remove_track(id)
    model.remove_track(w.config, id)
  end

  function w.rename_track(id, name)
    local track = w.config.tracks[id]
    if not track then return false end
    track.name = name
    return true
  end

  -- Knoten: Gleis gehoert zu einer Einfahrt oder Ausfahrt eines Anschlusses (nil = keinem)
  function w.set_junction_link(id, link)
    local track = w.config.tracks[id]
    if not track then return false end
    if link == nil then
      track.junction = nil
      return true
    end
    if not w.config.junction.connections[link.connection] then return false, "Unbekannter Anschluss." end
    if link.role ~= "ein" and link.role ~= "aus" then return false, "Einfahrt oder Ausfahrt." end
    track.junction = { connection = link.connection, role = link.role }
    return true
  end

  function w.set_direction(id, direction)
    local track = w.config.tracks[id]
    if not track then return false end
    track.direction = direction
    return true
  end

  -- schaltet ein Geraet (Geraete-Kennung) bei einem Gleis ein oder aus; ein Geraet gehoert hoechstens einem Gleis
  function w.toggle_track_device(track_id, field, device_id)
    local track = w.config.tracks[track_id]
    if not track then return false, "unbekanntes Gleis" end
    if field == "station" then
      if track.station == device_id then track.station = nil return true end
      for id, other in pairs(w.config.tracks) do
        if id ~= track_id and other.station == device_id then return false, "Das Geraet gehoert schon zu " .. other.name .. "." end
      end
      track.station = device_id
      return true
    end
    local list = track[field]
    for i, existing_id in ipairs(list) do
      if existing_id == device_id then table.remove(list, i) return true end
    end
    for id, other in pairs(w.config.tracks) do
      if id ~= track_id then
        for _, ref in ipairs(other[field]) do
          if ref == device_id then return false, "Das Geraet gehoert schon zu " .. other.name .. "." end
        end
      end
    end
    list[#list + 1] = device_id
    return true
  end

  function w.set_release(track_id, spec)
    local track = w.config.tracks[track_id]
    if not track then return false, "unbekanntes Gleis" end
    if spec then
      for id, other in pairs(w.config.tracks) do
        if id ~= track_id and other.release and other.release.side == spec.side and other.release.relay == spec.relay then
          return false, "Der Ausgang gehoert schon zu " .. other.name .. "."
        end
      end
    end
    track.release = spec
    return true
  end

  function w.set_registration(device_id)
    w.config.registration_station = device_id
    return true
  end

  -- Knotenpunkt
  function w.add_connection(name)
    if name == "" then return false, "Der Anschluss braucht einen Namen." end
    w.config.junction.connections[name] = true
    return true
  end

  function w.remove_connection(name)
    local j = w.config.junction
    j.connections[name] = nil
    local kept = {}
    for _, move in ipairs(j.moves) do
      if move.from ~= name and move.to ~= name then kept[#kept + 1] = move end
    end
    j.moves = kept
    j.conflicts = {}
  end

  function w.add_move(from, to)
    local j = w.config.junction
    if not j.connections[from] or not j.connections[to] then return false, "Unbekannter Anschluss." end
    if from == to then return false, "Anfang und Ende duerfen nicht gleich sein." end
    for _, move in ipairs(j.moves) do
      if move.from == from and move.to == to then return false, "Diese Verbindung gibt es schon." end
    end
    j.moves[#j.moves + 1] = { from = from, to = to }
    return true
  end

  function w.add_conflict(a, b)
    local j = w.config.junction
    if a == b or not j.moves[a] or not j.moves[b] then return false, "Zwei verschiedene Verbindungen waehlen." end
    local lo, hi = math.min(a, b), math.max(a, b)
    for _, c in ipairs(j.conflicts) do
      if c.moves[1] == lo and c.moves[2] == hi then return false, "Dieser Konflikt ist schon eingetragen." end
    end
    j.conflicts[#j.conflicts + 1] = { moves = { lo, hi } }
    return true
  end

  -- Schritt 5: Pruefungen ----------------------------------------------------------------------------------------------------------------
  local function device_name(id) return w.config.devices[id] and w.config.devices[id].device or "?" end

  function w.tests()
    sync_config()
    local list = {}
    local ids = {}
    for id in pairs(w.config.devices) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local d = w.config.devices[id]
      if d.kind == "station" or d.kind == "signal" or d.kind == "observer" then
        list[#list + 1] = {
          id = "lesen:" .. id, kind = "lesen", title = "Lesen: " .. d.device, spec = d.device,
          explain = "Der Zustand von " .. d.device .. " wird nur gelesen.",
        }
      end
      if d.kind == "signal" then
        list[#list + 1] = {
          id = "sperre:" .. id, kind = "schalten", title = "Sperre: " .. d.device, spec = d.device,
          explain = "Das Signal " .. d.device .. " wird kurz zusaetzlich auf Rot gesperrt und wieder freigegeben. Es darf gerade keinen Zug schuetzen; ein belegtes Signal bleibt nach dem Aufheben rot.",
        }
      end
    end
    local track_ids = w.tracks()
    for _, tid in ipairs(track_ids) do
      local track = w.config.tracks[tid]
      if track.release then
        local key = (track.release.relay or "Computer") .. " " .. track.release.side
        list[#list + 1] = {
          id = "ausgang:" .. tid, kind = "schalten", title = "Ausgang: " .. track.name, spec = key,
          explain = "Der Freigabeausgang " .. key .. " von Gleis " .. track.name .. " wird kurz eingeschaltet und wieder ausgeschaltet. Die Leitung darf dabei keinen wartenden Zug freigeben (Bahnhofsblock ohne Zug oder Leitung getrennt).",
        }
      end
    end
    return list
  end

  local function find_test(id)
    for _, t in ipairs(w.tests()) do if t.id == id then return t end end
  end

  function w.test_state(id, current, test)
    test = test or find_test(id)
    if not test then return nil end
    local result = w.config.tests[id]
    if not result then return "offen" end
    if result.spec ~= test.spec or result.fingerprint ~= (current or fingerprint()) then return "offen" end
    return result.ok and "ok" or "fehler", result.text
  end

  function w.all_tests_ok()
    local current = fingerprint()
    for _, test in ipairs(w.tests()) do
      if w.test_state(test.id, current, test) ~= "ok" then return false end
    end
    return true
  end

  local function record(test, ok, text)
    w.config.tests[test.id] = { ok = ok, text = text, spec = test.spec, fingerprint = fingerprint(), at = opts.now() }
    return ok, text
  end

  function w.run_test(id, confirmed)
    local test = find_test(id)
    if not test then return false, "unbekannte Pruefung" end
    if test.kind == "schalten" and confirmed ~= true then
      return false, "Schaltende Pruefung: erst die Vorbereitung bestaetigen."
    end
    local kind, ref = id:match("^(%a+):(.+)$")
    if kind == "lesen" then
      local d = w.config.devices[ref]
      local adapter
      if d.kind == "station" then adapter = stationlib.new(env, d.device)
      elseif d.kind == "signal" then adapter = signallib.new(env, d.device)
      else adapter = observerlib.new(env, d.device) end
      local state = adapter.read()
      if not state.available then return record(test, false, "nicht erreichbar: " .. tostring(state.errors and state.errors[1] or "")) end
      if state.errors and #state.errors > 0 then return record(test, false, state.errors[1]) end
      return record(test, true, "lesbar")
    elseif kind == "sperre" then
      local d = w.config.devices[ref]
      local g = signallib.new(env, d.device)
      local before = g.read()
      if not before.available then return record(test, false, "nicht erreichbar") end
      if before.forced then return record(test, false, "Das Signal ist schon gesperrt; bitte zuerst die Sperre aufheben.") end
      local held = g.hold()
      local released = g.release()
      if not held.confirmed then return record(test, false, "Sperre nicht bestaetigt" .. (held.error and (": " .. held.error) or "")) end
      if not released.confirmed then return record(test, false, "ACHTUNG: Sperre blieb gesetzt. Bitte von Hand pruefen.") end
      return record(test, true, "Sperre gesetzt und aufgehoben (zurueckgelesen)")
    elseif kind == "ausgang" then
      local track = w.config.tracks[ref]
      local o = outlib.new(env, track.release)
      local before = o.get()
      if before == nil then return record(test, false, "Ausgang nicht lesbar") end
      if before == true then return record(test, false, "Der Ausgang ist schon eingeschaltet; bitte von Hand pruefen.") end
      local on = o.set(true)
      local off = o.set(false)
      if not off.confirmed then return record(test, false, "ACHTUNG: Ausgang blieb eingeschaltet. Bitte von Hand pruefen.") end
      if not on.confirmed then return record(test, false, "Ausgang liess sich nicht einschalten") end
      return record(test, true, "Ausgang geschaltet und zurueckgelesen (Sollzustand; ob ein Zug abfaehrt, zeigt erst der Betrieb)")
    end
    return false, "unbekannte Pruefung"
  end

  -- Schritt 6 ----------------------------------------------------------------------------------------------------------------------------------
  -- liefert "aktiv" oder "entwurf" und die offenen Probleme
  function w.finish(store, path, draft)
    sync_config()
    w.rescan()
    local problems = model.validate(w.config, w.scan)
    for n = 1, 5 do
      local ok, reason = w.step_ok(n)
      if not ok then problems[#problems + 1] = { code = "schritt_" .. n, text = reason } end
    end
    local status = (not draft and #problems == 0 and w.all_tests_ok()) and "aktiv" or "entwurf"
    w.config.status = status
    for _, track in pairs(w.config.tracks) do
      track.status = (status == "aktiv" and track.station ~= nil or status == "aktiv" and #track.signals > 0) and "aktiv" or "entwurf"
    end
    w.config.revision = (w.config.revision or 0) + 1
    local ok, err = store.save(path, w.config)
    if not ok then return nil, problems, err end
    return status, problems
  end

  return w
end

return M
