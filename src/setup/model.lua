--[[
Purpose: Konfiguration eines Nodes (Konzept 15): Netz, Node-Kennung und Rollen, Geraetebindung, Gleise (je eine Train Station), Pruefergebnisse. Enthaelt nur Regeln und Rechnen, keine Oberflaeche: Pruefung auf Eindeutigkeit (kein Geraet und kein Ausgang zweimal), Vorlagen fuer weitere Gleise ohne Geraete, Entwurf oder aktiv.
API: model.new(name, roles, network) -> config; model.validate(config, scan) -> Liste Probleme { code, text }; model.add_device(config, kind, device) -> id; model.add_track(config, name) -> id; model.copy_track(config, id, name) -> neue id; model.remove_track(config, id); model.assign(config, track_id, field, device_id); model.free_devices(config, scan, kind) -> Liste; model.outputs(scan) -> moegliche Ausgaenge; model.slug(text); model.ROLES
Notes: Eine Node darf mehrere Rollen tragen (15.1). Ein neues oder kopiertes Gleis bleibt "offen", bis es einem Geraet zugeordnet und geprueft ist; es nimmt nicht an der Disposition teil (29.2). Technische Anschlussnamen stehen nur in devices; Gleise verweisen auf Geraete-Kennungen (fachlicher Bezug statt Modemadresse).
]]

local detect = require("dev.detect")
local label = require("core.label")

local M = {}

M.ROLES = { "zentrale", "bahnhof", "anmeldung" }
M.ROLE_TEXT = {
  zentrale = "Leitstelle", bahnhof = "Bahnhof", anmeldung = "Anmeldung und Auftraege",
}
-- Passagierbahnhof, Gueterbahnhof und Depot waren drei Namen fuer dieselbe Rolle (sie unterschieden sich nur in der Beschriftung): aeltere Einrichtungen tragen sie noch
M.LEGACY_ROLE = { passagierbahnhof = "bahnhof", gueterbahnhof = "bahnhof", depot = "bahnhof" }

-- bildet alte Rollennamen auf die heutigen ab und entfernt Doppelte (Reihenfolge bleibt)
function M.normalize_roles(roles)
  local out, seen = {}, {}
  for _, r in ipairs(roles or {}) do
    r = M.LEGACY_ROLE[r] or r
    if not seen[r] then seen[r] = true; out[#out + 1] = r end
  end
  return out
end

function M.normalize_config(config)
  if config and config.node then config.node.roles = M.normalize_roles(config.node.roles) end
  return config
end
local ROLE_SET = {}
for _, r in ipairs(M.ROLES) do ROLE_SET[r] = true end

local SIDES = { "top", "bottom", "left", "right", "front", "back" }
M.SIDES = SIDES

function M.slug(text)
  local s = tostring(text):lower()
  s = s:gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then s = "node" end
  return s:sub(1, 40)
end

function M.new(name, roles, network)
  return {
    version = 1,
    revision = 1,
    network = { name = network and network.name or "", central_id = network and network.central_id or nil, key = network and network.key or nil },
    node = { id = M.slug(name), name = name, roles = M.normalize_roles(roles) },
    devices = {},
    tracks = {},
    tests = {},
    status = "offen",
  }
end

local function next_id(map, prefix)
  local n = 1
  while map[prefix .. n] do n = n + 1 end
  return prefix .. n
end

function M.add_device(config, kind, device)
  for id, d in pairs(config.devices) do
    if d.device == device then return id end
  end
  local id = next_id(config.devices, kind)
  config.devices[id] = { kind = kind, device = device }
  return id
end

-- Beobachter und Gleisrichtung gibt es in der Einrichtung nicht mehr (Create regelt die Strecke): eine Einrichtung aus einer aelteren Version verliert sie beim Aendern
function M.drop_legacy(config)
  for id, d in pairs(config.devices or {}) do
    if d.kind == "observer" then config.devices[id] = nil end
  end
  for _, track in pairs(config.tracks or {}) do
    track.observers, track.direction = nil, nil
  end
  return config
end

function M.add_track(config, name)
  local id = next_id(config.tracks, "gleis")
  config.tracks[id] = { name = name, status = "offen" }
  return id
end

-- Vorlage (15.2): Struktur und Standardwerte werden kopiert, Geraete und Ausgang muessen neu zugeordnet werden
function M.copy_track(config, id, name)
  local src = config.tracks[id]
  if not src then return nil, "unbekanntes Gleis" end
  local new_id = M.add_track(config, name)
  local dst = config.tracks[new_id]
  dst.length = src.length
  dst.preferred = src.preferred
  dst.kind = src.kind
  return new_id
end

function M.remove_track(config, id)
  config.tracks[id] = nil
end

-- entfernt ein Geraet und alle Verweise darauf (Gleise, Anmeldestation)
function M.remove_device(config, id)
  config.devices[id] = nil
  for _, track in pairs(config.tracks) do
    if track.station == id then track.station = nil end
  end
  if config.registration_station == id then config.registration_station = nil end
end

function M.assign(config, track_id, field, device_id)
  local track = config.tracks[track_id]
  if not track then return nil, "unbekanntes Gleis" end
  if field == "station" then
    track.station = device_id
  else
    return nil, "unbekanntes Feld"
  end
  return true
end

-- Geraete der Art, die noch keinem Gleis dieser Konfiguration gehoeren
function M.free_devices(config, scan, kind)
  local used = {}
  for _, track in pairs(config.tracks) do
    if track.station then used[config.devices[track.station] and config.devices[track.station].device or ""] = true end
  end
  local out = {}
  for _, d in ipairs(scan) do
    if d.kind == kind and not used[d.name] then out[#out + 1] = d end
  end
  return out
end

local function has_role(config, role)
  for _, r in ipairs(config.node.roles) do if (M.LEGACY_ROLE[r] or r) == role then return true end end
  return false
end
M.has_role = has_role

-- Rollenprofil ist die gemeinsame Grundlage fuer Auswahl und Pruefung.
function M.profile(config)
  local station = has_role(config, "bahnhof")
  local allowed = { monitor = true }
  if station or has_role(config, "anmeldung") then allowed.station = true end
  if station then allowed.displaylink = true end
  return { station = station, tracks = station, allowed = allowed }
end

function M.validate(config, scan)
  local problems = {}
  local function add(code, text) problems[#problems + 1] = { code = code, text = text } end

  -- der Name ist nur Anzeige (ohne Namen gilt die Kennung): er blockiert nie, auch nicht bei einer Einrichtung aus aelteren Versionen
  if #config.node.roles == 0 then add("rolle", "Es ist keine Rolle gewaehlt.") end
  for _, r in ipairs(config.node.roles) do
    if not ROLE_SET[M.LEGACY_ROLE[r] or r] then add("rolle", "Unbekannte Rolle " .. tostring(r) .. ".") end
  end
  if config.network.name == "" then add("netz", "Der Netzname fehlt.") end
  if not has_role(config, "zentrale") and not config.network.central_id then
    add("zentrale", "Die Leitstelle dieses Netzes ist nicht angegeben.")
  end

  local profile = M.profile(config)
  if profile.tracks and next(config.tracks) == nil then add("gleise_fehlen", "Mindestens ein Gleis muss eingerichtet werden.") end
  -- Geraete: vorhanden, richtige Art, nicht doppelt
  local used_devices = {}
  for id, d in pairs(config.devices) do
    local found = detect.find(scan, d.device)
    if not found then
      add("geraet_fehlt", "Geraet " .. d.device .. " (" .. id .. ") ist nicht angeschlossen.")
    elseif found.kind ~= d.kind then
      add("geraet_art", "Geraet " .. d.device .. " ist keine/kein " .. d.kind .. ".")
    elseif #detect.missing(d.kind, found) > 0 and d.kind == "station" then
      add("geraet_methoden", "Geraet " .. d.device .. " fehlen Methoden: " .. table.concat(detect.missing(d.kind, found), ","))
    end
    if used_devices[d.device] then add("geraet_doppelt", "Geraet " .. d.device .. " ist doppelt eingetragen.") end
    used_devices[d.device] = id
  end

  -- Gleise: Namen eindeutig, Geraete vorhanden und nur einem Gleis zugeordnet, Ausgang eindeutig
  local names, owner = {}, {}
  local ids = {}
  for id in pairs(config.tracks) do ids[#ids + 1] = id end
  table.sort(ids)
  local needs_station = has_role(config, "bahnhof")
  for _, id in ipairs(ids) do
    local track = config.tracks[id]
    if track.name == "" then add("gleis_name", "Ein Gleis hat keinen Namen.") end
    if names[track.name] then add("gleis_name_doppelt", "Der Gleisname " .. track.name .. " kommt doppelt vor.") end
    names[track.name] = true
    local function claim(device_id, what)
      if not device_id then return end
      if not config.devices[device_id] then
        add("gleis_geraet", label.track(track.name) .. ": " .. what .. " " .. device_id .. " ist nicht eingetragen.")
        return
      end
      if owner[device_id] and owner[device_id] ~= id then
        add("geraet_zwei_gleise", "Geraet " .. config.devices[device_id].device .. " gehoert zu zwei Gleisen: " .. config.tracks[owner[device_id]].name .. " und " .. track.name .. ".")
      end
      owner[device_id] = id
    end
    if track.station and config.devices[track.station] and config.devices[track.station].kind ~= "station" then add("gleis_art", label.track(track.name) .. ": falsche Geraeteart fuer den Bahnhof.") end
    claim(track.station, "Bahnhof")
    if needs_station and not track.station then add("gleis_bahnhof", label.track(track.name) .. " hat keinen Bahnhof.") end
    -- Die Freigabe der Abfahrt laeuft ueber die Train Station selbst (Fahrplan), nicht ueber Redstone am Computer: ein Gleis braucht keinen Ausgang.
  end

  if has_role(config, "anmeldung") and not config.registration_station then
    add("anmeldung_station", "Fuer die Anmeldung ist keine Station gewaehlt.")
  end

  if config.registration_station then
    local d = config.devices[config.registration_station]
    if not d or d.kind ~= "station" then add("anmeldung_station", "Die Anmeldestation ist ungueltig.") end
  end
  return problems
end

return M
