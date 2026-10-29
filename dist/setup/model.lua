--[[
Purpose: Konfiguration eines Nodes (Konzept 15): Netz, Node-Kennung und Rollen, Geraetebindung, Gleise (Bahnhof, Signale, Beobachter, Freigabeausgang), Knotenpunkte (Anschluesse, Verbindungen, Konfliktbereiche), Pruefergebnisse. Enthaelt nur Regeln und Rechnen, keine Oberflaeche: Pruefung auf Eindeutigkeit (kein Geraet und kein Ausgang zweimal), Vorlagen fuer weitere Gleise ohne Geraete, Entwurf oder aktiv.
API: model.new(name, roles, network) -> config; model.validate(config, scan) -> Liste Probleme { code, text }; model.add_device(config, kind, device) -> id; model.add_track(config, name) -> id; model.copy_track(config, id, name) -> neue id; model.remove_track(config, id); model.assign(config, track_id, field, device_id); model.free_devices(config, scan, kind) -> Liste; model.outputs(scan) -> moegliche Ausgaenge; model.slug(text); model.ROLES
Notes: Eine Node darf mehrere Rollen tragen (15.1). Ein neues oder kopiertes Gleis bleibt "entwurf", bis es einem Geraet zugeordnet und geprueft ist; es nimmt nicht an der Disposition teil (29.2). Technische Anschlussnamen stehen nur in devices; Gleise verweisen auf Geraete-Kennungen (fachlicher Bezug statt Modemadresse).
]]

local detect = require("dev.detect")

local M = {}

M.ROLES = { "zentrale", "passagierbahnhof", "gueterbahnhof", "depot", "signal", "knoten", "anmeldung" }
M.ROLE_TEXT = {
  zentrale = "Leitstelle", passagierbahnhof = "Passagierbahnhof", gueterbahnhof = "Gueterbahnhof", depot = "Depot und Uebergabe",
  signal = "Signal und Strecke", knoten = "Knotenpunkt", anmeldung = "Anmeldung und Auftraege",
}
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
    node = { id = M.slug(name), name = name, roles = roles or {} },
    devices = {},
    tracks = {},
    junction = { connections = {}, moves = {}, conflicts = {} },
    tests = {},
    status = "entwurf",
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

function M.add_track(config, name)
  local id = next_id(config.tracks, "gleis")
  config.tracks[id] = { name = name, direction = "beide", signals = {}, observers = {}, status = "entwurf" }
  return id
end

-- Vorlage (15.2): Struktur und Standardwerte werden kopiert, Geraete und Ausgang muessen neu zugeordnet werden
function M.copy_track(config, id, name)
  local src = config.tracks[id]
  if not src then return nil, "unbekanntes Gleis" end
  local new_id = M.add_track(config, name)
  local dst = config.tracks[new_id]
  dst.direction = src.direction
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
    for _, field in ipairs({ "signals", "observers" }) do
      local kept = {}
      for _, ref in ipairs(track[field]) do if ref ~= id then kept[#kept + 1] = ref end end
      track[field] = kept
    end
  end
  if config.registration_station == id then config.registration_station = nil end
end

function M.assign(config, track_id, field, device_id)
  local track = config.tracks[track_id]
  if not track then return nil, "unbekanntes Gleis" end
  if field == "station" then
    track.station = device_id
  elseif field == "signals" or field == "observers" then
    for _, existing in ipairs(track[field]) do if existing == device_id then return true end end
    track[field][#track[field] + 1] = device_id
  elseif field == "release" then
    track.release = device_id
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
    for _, list in ipairs({ track.signals, track.observers }) do
      for _, id in ipairs(list) do if config.devices[id] then used[config.devices[id].device] = true end end
    end
  end
  local out = {}
  for _, d in ipairs(scan) do
    if d.kind == kind and not used[d.name] then out[#out + 1] = d end
  end
  return out
end

-- moegliche Freigabeausgaenge: Computerseiten und Seiten jedes Redstone Relays im Scan
function M.outputs(scan)
  local out = {}
  for _, side in ipairs(SIDES) do out[#out + 1] = { side = side, label = "Computer " .. side } end
  for _, d in ipairs(scan) do
    if d.kind == "relay" then
      for _, side in ipairs(SIDES) do out[#out + 1] = { relay = d.name, side = side, label = d.name .. " " .. side } end
    end
  end
  return out
end

local function output_key(spec)
  if not spec then return nil end
  return (spec.relay or "computer") .. ":" .. spec.side
end

local function has_role(config, role)
  for _, r in ipairs(config.node.roles) do if r == role then return true end end
  return false
end
M.has_role = has_role

function M.validate(config, scan)
  local problems = {}
  local function add(code, text) problems[#problems + 1] = { code = code, text = text } end

  if config.node.name == "" then add("name", "Der Node braucht einen Namen.") end
  if #config.node.roles == 0 then add("rolle", "Es ist keine Rolle gewaehlt.") end
  for _, r in ipairs(config.node.roles) do
    if not ROLE_SET[r] then add("rolle", "Unbekannte Rolle " .. tostring(r) .. ".") end
  end
  if config.network.name == "" then add("netz", "Der Netzname fehlt.") end
  if not has_role(config, "zentrale") and not config.network.central_id then
    add("zentrale", "Die Leitstelle dieses Netzes ist nicht angegeben.")
  end

  -- Geraete: vorhanden, richtige Art, nicht doppelt
  local used_devices = {}
  for id, d in pairs(config.devices) do
    local found = detect.find(scan, d.device)
    if not found then
      add("geraet_fehlt", "Geraet " .. d.device .. " (" .. id .. ") ist nicht angeschlossen.")
    elseif found.kind ~= d.kind then
      add("geraet_art", "Geraet " .. d.device .. " ist keine/kein " .. d.kind .. ".")
    elseif #detect.missing(d.kind, found) > 0 and (d.kind == "station" or d.kind == "signal" or d.kind == "observer") then
      add("geraet_methoden", "Geraet " .. d.device .. " fehlen Methoden: " .. table.concat(detect.missing(d.kind, found), ","))
    end
    if used_devices[d.device] then add("geraet_doppelt", "Geraet " .. d.device .. " ist doppelt eingetragen.") end
    used_devices[d.device] = id
  end

  -- Gleise: Namen eindeutig, Geraete vorhanden und nur einem Gleis zugeordnet, Ausgang eindeutig
  local names, owner, outputs = {}, {}, {}
  local ids = {}
  for id in pairs(config.tracks) do ids[#ids + 1] = id end
  table.sort(ids)
  local needs_station = has_role(config, "passagierbahnhof") or has_role(config, "gueterbahnhof") or has_role(config, "depot")
  local needs_signals = has_role(config, "signal") or has_role(config, "knoten")
  for _, id in ipairs(ids) do
    local track = config.tracks[id]
    if track.name == "" then add("gleis_name", "Ein Gleis hat keinen Namen.") end
    if names[track.name] then add("gleis_name_doppelt", "Der Gleisname " .. track.name .. " kommt doppelt vor.") end
    names[track.name] = true
    local function claim(device_id, what)
      if not device_id then return end
      if not config.devices[device_id] then
        add("gleis_geraet", "Gleis " .. track.name .. ": " .. what .. " " .. device_id .. " ist nicht eingetragen.")
        return
      end
      if owner[device_id] and owner[device_id] ~= id then
        add("geraet_zwei_gleise", "Geraet " .. config.devices[device_id].device .. " gehoert zu zwei Gleisen: " .. config.tracks[owner[device_id]].name .. " und " .. track.name .. ".")
      end
      owner[device_id] = id
    end
    claim(track.station, "Bahnhof")
    for _, s in ipairs(track.signals) do claim(s, "Signal") end
    for _, o in ipairs(track.observers) do claim(o, "Beobachter") end
    if needs_station and not track.station then add("gleis_bahnhof", "Gleis " .. track.name .. " hat keinen Bahnhof.") end
    if has_role(config, "signal") and #track.signals == 0 then add("gleis_signal", "Gleis " .. track.name .. " hat kein Signal.") end
    if track.junction then
      if not config.junction.connections[track.junction.connection] then
        add("knoten_gleis", "Gleis " .. track.name .. " verweist auf den unbekannten Anschluss " .. tostring(track.junction.connection) .. ".")
      elseif track.junction.role == "ein" and #track.signals == 0 then
        add("knoten_gleis", "Einfahrtsgleis " .. track.name .. " braucht ein Signal, das die Einfahrt zusaetzlich sperrt.")
      elseif #track.observers == 0 then
        add("knoten_gleis", "Gleis " .. track.name .. " braucht einen Beobachter als Meldepunkt (Einfahrt erkennen, Raeumung nachweisen).")
      end
    end
    if track.release then
      local key = output_key(track.release)
      if outputs[key] then
        add("ausgang_doppelt", "Der Ausgang " .. key .. " dient zwei Gleisen: " .. outputs[key] .. " und " .. track.name .. ". Gemeinsame Leitungen duerfen keine fremde Freigabe ausloesen.")
      end
      outputs[key] = track.name
    elseif needs_station and (has_role(config, "passagierbahnhof") or has_role(config, "gueterbahnhof")) and track.station then
      add("gleis_ausgang", "Gleis " .. track.name .. " hat keinen Freigabeausgang.")
    end
  end

  -- Knotenpunkt
  if has_role(config, "knoten") then
    local j = config.junction
    local count = 0
    for _ in pairs(j.connections) do count = count + 1 end
    if count < 2 then add("knoten_anschluesse", "Ein Knotenpunkt braucht mindestens zwei Anschluesse.") end
    for i, move in ipairs(j.moves) do
      if not j.connections[move.from] or not j.connections[move.to] then add("knoten_verbindung", "Verbindung " .. i .. " nennt einen unbekannten Anschluss.") end
      if move.from == move.to then add("knoten_verbindung", "Verbindung " .. i .. " beginnt und endet am selben Anschluss.") end
    end
    -- jede Einfahrt braucht ein Einfahrtsgleis, jede Ausfahrt ein Ausfahrtsgleis mit Beobachter
    local has_in, has_out = {}, {}
    for _, track in pairs(config.tracks) do
      if track.junction then
        if track.junction.role == "ein" then has_in[track.junction.connection] = true else has_out[track.junction.connection] = true end
      end
    end
    for i, move in ipairs(j.moves) do
      if j.connections[move.from] and not has_in[move.from] then add("knoten_einfahrt", "Der Anschluss " .. move.from .. " hat kein Einfahrtsgleis mit Signal.") end
      if j.connections[move.to] and not has_out[move.to] then add("knoten_ausfahrt", "Der Anschluss " .. move.to .. " hat kein Ausfahrtsgleis mit Beobachter (ohne ihn gibt es keine Raeumungsmeldung).") end
    end
    for i, conflict in ipairs(j.conflicts) do
      if #conflict.moves < 2 then add("knoten_konflikt", "Konfliktbereich " .. i .. " braucht mindestens zwei Verbindungen.") end
      for _, m in ipairs(conflict.moves) do
        if not j.moves[m] then add("knoten_konflikt", "Konfliktbereich " .. i .. " nennt eine unbekannte Verbindung.") end
      end
    end
  end

  if has_role(config, "anmeldung") and not config.registration_station then
    add("anmeldung_station", "Fuer die Anmeldung ist keine Station gewaehlt.")
  end

  return problems
end

return M
