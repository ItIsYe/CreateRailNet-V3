--[[
Purpose: Zugregister der Leitstelle (Konzept 7): jeder verwaltete Zug hat eine interne Kennung, einen eindeutigen Create-Zugnamen, einen Anzeigenamen, Verwendung, Betriebsart, Laenge und Zustand. Die Kennung ist keine von Create gelesene Fahrzeug-ID; der Zugname ist veraenderbar und gilt nur eindeutig. Aussagen ueber den Aufenthalt tragen Art, Ort, Herkunft und Zeit.
API: register.new{ store, path } -> r; r.validate(req) -> ok, grund; r.register(req) -> ok, grund; r.get(id); r.list(); r.by_create_name(name); r.set_state(id, state); r.set_position(id, kind, where, source, t); r.set_mode(id, mode); r.rename_display(id, name); r.unregister(id)
Notes: Zustaende (7.3): registriert, gesteuert, uebergabe, abgestellt, ausgeschleust. Unregistrierte Zuege sind keine Eintraege (sie sind als Belegung relevant, siehe Leitstelle). Der Standardname "Unnamed Train" und doppelte Namen werden abgewiesen (Messung M14); eine Aenderung des Create-Zugnamens ist eine eigene kontrollierte Aktion, nicht dasselbe wie der Anzeigename. Betriebsart und Aufenthaltswissen werden unabhaengig vom Zustand gespeichert.
]]

local M = {}

M.DEFAULT_NAME = "Unnamed Train"
M.STATES = { registriert = true, gesteuert = true, uebergabe = true, abgestellt = true, ausgeschleust = true }
M.MODES = { linie = true, bedarf = true, manuell = true }
M.USES = { fracht = true, personen = true }
M.POSITION_KINDS = { am_bahnhof = true, am_melder = true, erwartet = true, unbekannt = true }

local function valid_id(id) return type(id) == "string" and id:match("^[A-Z0-9][A-Z0-9%-]*$") ~= nil and #id <= 16 end
local function valid_text(text) return type(text) == "string" and #text > 0 and #text <= 40 and text:match("^[%w _%.%-]+$") ~= nil end

function M.new(opts)
  local r = {}
  local data = opts.store.load(opts.path) or { trains = {} }
  data.trains = data.trains or {}

  local function persist()
    local ok, err = opts.store.save(opts.path, data)
    if not ok then return nil, err or "Speichern fehlgeschlagen" end
    return true
  end

  function r.get(id) return data.trains[id] end

  function r.by_create_name(name)
    for _, train in pairs(data.trains) do
      if train.create_name == name then return train end
    end
  end

  function r.list()
    local ids = {}
    for id in pairs(data.trains) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = data.trains[id] end
    return out
  end

  -- prueft eine Anmeldung, ohne etwas einzutragen
  function r.validate(req)
    if not valid_id(req.id) then return nil, "Die Kennung darf nur Grossbuchstaben, Ziffern und - enthalten (z.B. GZ-001)." end
    if data.trains[req.id] then return nil, "Die Kennung " .. req.id .. " ist schon vergeben." end
    if not valid_text(req.create_name) then return nil, "Der Create-Zugname ist leer oder enthaelt unzulaessige Zeichen." end
    if req.create_name == M.DEFAULT_NAME then return nil, "Der Standardname 'Unnamed Train' ist nicht eindeutig: bitte zuerst umbenennen." end
    local other = r.by_create_name(req.create_name)
    if other then return nil, "Der Create-Zugname " .. req.create_name .. " gehoert schon zu " .. other.id .. "." end
    if not valid_text(req.display_name or req.create_name) then return nil, "Der Anzeigename enthaelt unzulaessige Zeichen." end
    if req.usage and not M.USES[req.usage] then return nil, "Unbekannte Verwendung." end
    if req.mode and not M.MODES[req.mode] then return nil, "Unbekannte Betriebsart." end
    local length = req.length or 1
    if type(length) ~= "number" or length < 1 or length > 200 or length ~= math.floor(length) then return nil, "Die Zuglaenge muss eine ganze Zahl zwischen 1 und 200 sein." end
    return true
  end

  -- req: id, create_name, display_name, usage, mode, length, evidence = { train_name, present }
  function r.register(req)
    local ok, why = r.validate(req)
    if not ok then return nil, why end
    local length = req.length or 1
    local ev = req.evidence
    if not ev or ev.present ~= true then return nil, "Der Zug ist an der Anmeldestation nicht bestaetigt." end
    if ev.train_name ~= req.create_name then return nil, "Der Zug an der Station heisst " .. tostring(ev.train_name) .. ", nicht " .. req.create_name .. "." end
    data.trains[req.id] = {
      id = req.id, create_name = req.create_name, display_name = req.display_name or req.create_name,
      usage = req.usage or "fracht", mode = req.mode or "bedarf", length = length, state = "registriert",
      position = { kind = "am_bahnhof", where = ev.where, source = ev.source or "abfrage", t = ev.t or 0 },
    }
    local saved, err = persist()
    if not saved then data.trains[req.id] = nil return nil, err end
    return true
  end

  function r.set_state(id, state)
    local train = data.trains[id]
    if not train then return nil, "unbekannter Zug" end
    if not M.STATES[state] then return nil, "unbekannter Zustand" end
    train.state = state
    return persist()
  end

  function r.set_position(id, kind, where, source, t)
    local train = data.trains[id]
    if not train then return nil, "unbekannter Zug" end
    if not M.POSITION_KINDS[kind] then return nil, "unbekannte Art des Aufenthalts" end
    train.position = { kind = kind, where = where, source = source, t = t }
    return persist()
  end

  -- Betriebsart nur an einem bestaetigten Haltepunkt wechseln (7.3)
  function r.set_mode(id, mode)
    local train = data.trains[id]
    if not train then return nil, "unbekannter Zug" end
    if not M.MODES[mode] then return nil, "unbekannte Betriebsart" end
    if not train.position or train.position.kind ~= "am_bahnhof" then return nil, "Die Betriebsart wechselt nur an einem bestaetigten Haltepunkt." end
    train.mode = mode
    return persist()
  end

  function r.rename_display(id, name)
    local train = data.trains[id]
    if not train then return nil, "unbekannter Zug" end
    if not valid_text(name) then return nil, "Der Anzeigename enthaelt unzulaessige Zeichen." end
    train.display_name = name
    return persist()
  end

  -- Abmelden entfernt die betriebliche Zustaendigkeit, nicht den Zug (15.3)
  function r.unregister(id)
    if not data.trains[id] then return nil, "unbekannter Zug" end
    data.trains[id] = nil
    return persist()
  end

  return r
end

return M
