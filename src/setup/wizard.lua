--[[
Purpose: Ablauf des Einrichtungsassistenten in sechs Hauptschritten (Konzept 29.1): Anlage, Rolle, Geraete, Gleise, Test, Fertig. Reine Zustandsfuehrung ohne Oberflaeche: Eingaben, Weiterschalten mit Pruefung, Geraeteauswahl, Gleise und Knotenpunkt bearbeiten, gefuehrte Pruefungen (lesend und schaltend, schaltend nur nach ausdruecklicher Bestaetigung), Speichern als Entwurf oder aktiv.
API: wizard.new{ scan, env, now, existing } -> w; w.step; w.next() / w.back(); w.step_ok(n) -> ok, grund; w.config; w.tests() -> Liste; w.run_test(id, confirmed) -> ok, text; w.finish(store, path) -> status, probleme
Notes: Lesende Erkennung und schaltende Pruefungen sind getrennt: ein schaltender Test laeuft nur mit confirmed = true, nennt vorher Geraet und erwartete Wirkung (test.explain) und stellt den Ausgangszustand wieder her. Ein erfolgreicher API-Aufruf zaehlt nur als Ausfuehrung des Befehls (Konzept 29.1). Fehlt ein Geraet, wird die Einrichtung als Entwurf gespeichert; die betroffene Betriebsfunktion bleibt inaktiv (status = "entwurf").
]]

local model = require("setup.model")
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

  w.config = existing or model.new("", {}, {})
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

  function w.rescan() w.scan = opts.scan() end

  function w.set_mode(mode) w.mode = mode; sync_config() end
  function w.set_network(name, central, key)
    w.network_name, w.central_id, w.key = name or w.network_name, central or w.central_id, key or w.key
    sync_config()
  end
  function w.set_name(name) w.name = name; sync_config() end
  function w.toggle_role(role)
    if has(w.roles, role) then
      local kept = {}
      for _, r in ipairs(w.roles) do if r ~= role then kept[#kept + 1] = r end end
      w.roles = kept
    else
      w.roles[#w.roles + 1] = role
    end
    sync_config()
  end

  local function needs(kind_role)
    return model.has_role(w.config, kind_role)
  end

  function w.step_ok(n)
    sync_config()
    if n == 1 then
      if w.network_name == "" then return false, "Der Netzname fehlt." end
      if w.mode == "join" and w.central_id == "" then return false, "Die Kennung der Leitstelle fehlt." end
      return true
    elseif n == 2 then
      if w.name == "" then return false, "Der Node braucht einen Namen." end
      if #w.roles == 0 then return false, "Bitte mindestens eine Rolle waehlen." end
      if w.mode == "create" and not has(w.roles, "zentrale") then return false, "Die erste Leitstelle braucht die Rolle Leitstelle." end
      if w.mode == "join" and has(w.roles, "zentrale") then
        return false, "Eine zweite aktive Leitstelle ist nicht vorgesehen. Eine Ersatz-Leitstelle wird ueber 'Vorhandene Node uebernehmen' eingerichtet."
      end
      return true
    elseif n == 3 then
      return true
    elseif n == 4 then
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
    if not found or not SELECTABLE[found.kind] then return false end
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

  function w.test_state(id)
    local test = find_test(id)
    if not test then return nil end
    local result = w.config.tests[id]
    if not result then return "offen" end
    if result.spec ~= test.spec then return "offen" end
    return result.ok and "ok" or "fehler", result.text
  end

  function w.all_tests_ok()
    for _, test in ipairs(w.tests()) do
      if w.test_state(test.id) ~= "ok" then return false end
    end
    return true
  end

  local function record(test, ok, text)
    w.config.tests[test.id] = { ok = ok, text = text, spec = test.spec, at = opts.now() }
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
  function w.finish(store, path)
    sync_config()
    local problems = model.validate(w.config, w.scan)
    local status = (#problems == 0 and w.all_tests_ok()) and "aktiv" or "entwurf"
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
