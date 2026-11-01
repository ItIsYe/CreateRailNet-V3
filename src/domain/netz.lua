--[[
Purpose: Netzverzeichnis der Leitstelle (Konzept 3, 4, 5, 10, 11): Bereiche mit ihren zwei Anschluessen und den Gleisen darin (Name, Richtung als Bezug zu einem Anschluss), dazu die Anforderungen der Nodes, die ihren Ausschnitt uebernehmen. Die Leitstelle vergibt dauerhafte Kennungen (B0001 Bereich, A0001 Gleis, N0017 Node), die nie wiederverwendet werden, und liefert Anzeigename und Computerlabel einer Node.
API: netz.new{ store, path } -> n; n.add_area{ name, ends = { a, b }, count, pattern } -> id oder nil, fehler; n.set_area(id, { name, ends }); n.remove_area(id); n.add_track(area, name, richtung); n.set_track(id, { name, direction }); n.remove_track(id); n.areas() -> Liste; n.areas_page(nach, grenze) -> Liste, weitere; n.area(id) -> Bereich mit Gleisen; n.claim_node{ claim, role, area, tracks } -> Eintrag oder nil, fehler; n.mark_active(id); n.discard_node(id); n.nodes() -> Liste; n.node(id); n.revision()
Notes: Vorlagen (pattern) erzeugen nur bearbeitbare Gleise: gegenlaeufig (erste Haelfte Richtung Anschluss 2, Rest Richtung Anschluss 1), gleich (alle Richtung Anschluss 2), beide. Die Richtung eines Gleises ist ein Bezug (Name eines Anschlusses) oder "beide"; sie wird nirgends ausgewertet, sondern angezeigt. Ein Gleis in einem Bereich ist nicht automatisch ein Create-Signalblock. Die Anforderung einer Node (claim) ist wiederholbar: dieselbe Claim-Kennung liefert dieselbe Node-Kennung. Benutzte Objekte (Bereich oder Gleis, das eine Node uebernommen hat) werden nicht geloescht. Zaehler stehen in der Datei und gehen nie zurueck. Jede Aenderung wird sofort gespeichert; schlaegt das fehl, bleibt der alte Stand.
]]

local ser = require("core.ser")

local M = {}

M.MAX_AREAS = 200
M.MAX_TRACKS = 40          -- je Bereich (eine Antwort an eine Node muss in eine Funknachricht passen)
M.MAX_NODES = 500
M.NAME_MAX = 30

local ROLE_CODE = { passagierbahnhof = "PBF", gueterbahnhof = "GBF", depot = "DEP", signal = "SIG", knoten = "KNO", anmeldung = "ANM" }
local ROLE_TEXT = { passagierbahnhof = "Personenbahnhof", gueterbahnhof = "Gueterbahnhof", depot = "Depot", signal = "Signal", knoten = "Knoten", anmeldung = "Anmeldung" }
M.ROLE_CODE, M.ROLE_TEXT = ROLE_CODE, ROLE_TEXT

local PATTERNS = { gegenlaeufig = true, gleich = true, beide = true }
M.PATTERNS = PATTERNS

local function copy(value) return ser.decode(ser.encode(value)) end

local function clean(text)
  if type(text) ~= "string" then return nil end
  text = text:match("^%s*(.-)%s*$"):gsub("%s+", " ")
  return text
end

-- Namen: nur Buchstaben, Ziffern, Leerzeichen, - und _ (wie bei den Namen im Assistenten), nicht leer, nicht zu lang
local function valid_name(text)
  text = clean(text)
  if not text or text == "" then return nil, "Der Name fehlt." end
  if #text > M.NAME_MAX then return nil, "Der Name ist zu lang (hoechstens " .. M.NAME_MAX .. " Zeichen)." end
  if text:find("[^A-Za-z0-9 _%-]") then return nil, "Der Name darf nur Buchstaben, Ziffern, Leerzeichen, - und _ enthalten." end
  return text
end
M.valid_name = valid_name

local function same(a, b) return a:lower() == b:lower() end

function M.new(spec)
  local n = {}
  local store, path = spec.store, spec.path
  local data = (store and path and store.load(path)) or nil
  if type(data) ~= "table" then data = {} end
  data.version = 1
  data.revision = data.revision or 0
  data.counters = data.counters or {}
  for _, k in ipairs({ "bereich", "gleis", "node" }) do data.counters[k] = data.counters[k] or 0 end
  data.areas, data.tracks, data.nodes = data.areas or {}, data.tracks or {}, data.nodes or {}

  -- Aenderung ausfuehren; schlaegt das Speichern fehl, kommt der alte Stand zurueck
  local function change(fn)
    local before = copy(data)
    local result, err = fn()
    if result == nil then
      data = before
      return nil, err
    end
    data.revision = data.revision + 1
    if store and path then
      local ok, why = store.save(path, data)
      if not ok then
        data = before
        return nil, "Das Verzeichnis konnte nicht gespeichert werden: " .. tostring(why)
      end
    end
    return result
  end

  local function new_id(kind, prefix)
    data.counters[kind] = data.counters[kind] + 1
    return string.format("%s%04d", prefix, data.counters[kind])
  end

  local function track_count(area_id)
    local c = 0
    for _, t in pairs(data.tracks) do if t.area == area_id then c = c + 1 end end
    return c
  end

  local function is_end(area, direction)
    return direction == "beide" or direction == area.ends[1] or direction == area.ends[2]
  end

  local function area_used_by(area_id)
    for id, node in pairs(data.nodes) do
      if node.area == area_id and node.state ~= "verworfen" then return id end
    end
  end

  local function track_used_by(track_id)
    for id, node in pairs(data.nodes) do
      if node.state ~= "verworfen" then
        for _, tid in ipairs(node.tracks) do if tid == track_id then return id end end
      end
    end
  end

  local function track_name_taken(area_id, name, except)
    for id, t in pairs(data.tracks) do
      if t.area == area_id and id ~= except and same(t.name, name) then return true end
    end
    return false
  end

  -- Bereiche -------------------------------------------------------------------------------------------------------------------------------
  local function valid_ends(ends)
    if type(ends) ~= "table" then return nil, "Die beiden Anschluesse fehlen." end
    local a, why_a = valid_name(ends[1])
    if not a then return nil, "Anschluss 1: " .. why_a end
    local b, why_b = valid_name(ends[2])
    if not b then return nil, "Anschluss 2: " .. why_b end
    if same(a, b) then return nil, "Die beiden Anschluesse brauchen verschiedene Namen." end
    if a:lower() == "beide" or b:lower() == "beide" then return nil, "'beide' ist als Anschlussname nicht moeglich." end
    return { a, b }
  end

  local function area_name_taken(name, except)
    for id, a in pairs(data.areas) do
      if id ~= except and same(a.name, name) then return true end
    end
    return false
  end

  function n.add_area(spec2)
    return change(function()
      local count = 0
      for _ in pairs(data.areas) do count = count + 1 end
      if count >= M.MAX_AREAS then return nil, "Es gibt schon " .. M.MAX_AREAS .. " Bereiche." end
      local name, why = valid_name(spec2.name)
      if not name then return nil, why end
      if area_name_taken(name) then return nil, "Einen Bereich " .. name .. " gibt es schon." end
      local ends, why_ends = valid_ends(spec2.ends)
      if not ends then return nil, why_ends end
      local tracks = tonumber(spec2.count) or 0
      if tracks ~= math.floor(tracks) or tracks < 1 or tracks > M.MAX_TRACKS then
        return nil, "Die Gleisanzahl muss zwischen 1 und " .. M.MAX_TRACKS .. " liegen."
      end
      local pattern = spec2.pattern or "gegenlaeufig"
      if not PATTERNS[pattern] then return nil, "Unbekannte Vorlage " .. tostring(pattern) .. " (gegenlaeufig, gleich oder beide)." end
      local id = new_id("bereich", "B")
      data.areas[id] = { name = name, ends = ends, order = 0 }
      local toward_second = (pattern == "gleich") and tracks or math.ceil(tracks / 2)
      for i = 1, tracks do
        local tid = new_id("gleis", "A")
        local direction = "beide"
        if pattern ~= "beide" then direction = (i <= toward_second) and ends[2] or ends[1] end
        data.tracks[tid] = { area = id, name = "Gleis " .. i, direction = direction, order = i }
        data.areas[id].order = i
      end
      return id
    end)
  end

  function n.set_area(id, fields)
    return change(function()
      local area = data.areas[id]
      if not area then return nil, "Den Bereich gibt es nicht." end
      local name = area.name
      if fields.name ~= nil then
        local why
        name, why = valid_name(fields.name)
        if not name then return nil, why end
        if area_name_taken(name, id) then return nil, "Einen Bereich " .. name .. " gibt es schon." end
      end
      local ends = area.ends
      if fields.ends ~= nil then
        local why
        ends, why = valid_ends(fields.ends)
        if not ends then return nil, why end
      end
      -- umbenannte Anschluesse ziehen die Richtungen der Gleise mit
      for _, t in pairs(data.tracks) do
        if t.area == id then
          if t.direction == area.ends[1] then t.direction = ends[1]
          elseif t.direction == area.ends[2] then t.direction = ends[2] end
        end
      end
      area.name, area.ends = name, ends
      return true
    end)
  end

  function n.remove_area(id)
    return change(function()
      if not data.areas[id] then return nil, "Den Bereich gibt es nicht." end
      local user = area_used_by(id)
      if user then return nil, "Die Node " .. user .. " nutzt diesen Bereich: erst dort aufloesen." end
      data.areas[id] = nil
      for tid, t in pairs(data.tracks) do if t.area == id then data.tracks[tid] = nil end end
      return true
    end)
  end

  -- Gleise ---------------------------------------------------------------------------------------------------------------------------------
  function n.add_track(area_id, name, direction)
    return change(function()
      local area = data.areas[area_id]
      if not area then return nil, "Den Bereich gibt es nicht." end
      if track_count(area_id) >= M.MAX_TRACKS then return nil, "Ein Bereich hat hoechstens " .. M.MAX_TRACKS .. " Gleise." end
      local clean_name, why = valid_name(name)
      if not clean_name then return nil, why end
      if track_name_taken(area_id, clean_name) then return nil, "Das Gleis " .. clean_name .. " gibt es in diesem Bereich schon." end
      direction = direction or "beide"
      if not is_end(area, direction) then return nil, "Die Richtung muss 'beide' oder ein Anschluss des Bereichs sein." end
      local tid = new_id("gleis", "A")
      area.order = (area.order or 0) + 1
      data.tracks[tid] = { area = area_id, name = clean_name, direction = direction, order = area.order }
      return tid
    end)
  end

  function n.set_track(id, fields)
    return change(function()
      local t = data.tracks[id]
      if not t then return nil, "Das Gleis gibt es nicht." end
      local area = data.areas[t.area]
      if fields.name ~= nil then
        local name, why = valid_name(fields.name)
        if not name then return nil, why end
        if track_name_taken(t.area, name, id) then return nil, "Das Gleis " .. name .. " gibt es in diesem Bereich schon." end
        t.name = name
      end
      if fields.direction ~= nil then
        if not is_end(area, fields.direction) then return nil, "Die Richtung muss 'beide' oder ein Anschluss des Bereichs sein." end
        t.direction = fields.direction
      end
      return true
    end)
  end

  function n.remove_track(id)
    return change(function()
      if not data.tracks[id] then return nil, "Das Gleis gibt es nicht." end
      local user = track_used_by(id)
      if user then return nil, "Die Node " .. user .. " nutzt dieses Gleis: erst dort aufloesen." end
      data.tracks[id] = nil
      return true
    end)
  end

  -- Abfragen -------------------------------------------------------------------------------------------------------------------------------
  local function tracks_of(area_id)
    local list = {}
    for id, t in pairs(data.tracks) do
      if t.area == area_id then list[#list + 1] = { id = id, name = t.name, direction = t.direction, order = t.order or 0 } end
    end
    table.sort(list, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
    for _, t in ipairs(list) do t.order = nil end
    return list
  end

  function n.areas()
    local list = {}
    for id, a in pairs(data.areas) do
      list[#list + 1] = { id = id, name = a.name, ends = { a.ends[1], a.ends[2] }, tracks = track_count(id) }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end

  -- seitenweise (eine Funkantwort fasst nur etwa 40 Bereiche): die Bereiche nach der Kennung `after`, hoechstens `limit`; zweiter Wert: es folgen weitere
  function n.areas_page(after, limit)
    local all = n.areas()
    local out, more = {}, false
    for _, a in ipairs(all) do
      if after == nil or a.id > after then
        if #out >= limit then more = true break end
        out[#out + 1] = a
      end
    end
    return out, more
  end

  function n.area(id)
    local a = data.areas[id]
    if not a then return nil end
    return { id = id, name = a.name, ends = { a.ends[1], a.ends[2] }, tracks = tracks_of(id) }
  end

  function n.track(id)
    local t = data.tracks[id]
    if not t then return nil end
    return { id = id, area = t.area, name = t.name, direction = t.direction }
  end

  function n.revision() return data.revision end

  -- Nodes ----------------------------------------------------------------------------------------------------------------------------------
  local function view(id, node)
    return { id = id, claim = node.claim, role = node.role, area = node.area, tracks = copy(node.tracks), state = node.state, name = node.name, label = node.label }
  end

  function n.claim_node(spec2)
    return change(function()
      local claim = spec2.claim
      if type(claim) ~= "string" or #claim < 8 or #claim > 64 or claim:find("[^%w%-_]") then return nil, "Die Anforderungskennung ist ungueltig." end
      local code = ROLE_CODE[spec2.role]
      if not code then return nil, "Fuer diese Rolle gibt es keine Anforderung." end
      local area = data.areas[spec2.area]
      if not area then return nil, "Den Bereich gibt es nicht." end
      local wanted = {}
      if type(spec2.tracks) ~= "table" then return nil, "Die Gleise fehlen." end
      for _, tid in ipairs(spec2.tracks) do
        local t = data.tracks[tid]
        if not t or t.area ~= spec2.area then return nil, "Das Gleis " .. tostring(tid) .. " gehoert nicht zu diesem Bereich." end
        for _, seen in ipairs(wanted) do if seen == tid then return nil, "Das Gleis " .. tid .. " ist doppelt angegeben." end end
        wanted[#wanted + 1] = tid
      end
      if #wanted == 0 then return nil, "Mindestens ein Gleis muss uebernommen werden." end
      -- dieselbe Anforderung noch einmal: dieselbe Kennung, neue Angaben
      for id, node in pairs(data.nodes) do
        if node.claim == claim then
          if node.state == "verworfen" then return nil, "Diese Anforderung wurde verworfen." end
          node.role, node.area, node.tracks = spec2.role, spec2.area, wanted
          node.name = ROLE_TEXT[spec2.role] .. " " .. area.name .. " " .. id
          node.label = id .. " | " .. code .. " | " .. spec2.area
          return view(id, node)
        end
      end
      local count = 0
      for _ in pairs(data.nodes) do count = count + 1 end
      if count >= M.MAX_NODES then return nil, "Es gibt schon " .. M.MAX_NODES .. " Nodes im Verzeichnis." end
      local id = new_id("node", "N")
      data.nodes[id] = {
        claim = claim, role = spec2.role, area = spec2.area, tracks = wanted, state = "reserviert",
        name = ROLE_TEXT[spec2.role] .. " " .. area.name .. " " .. id,
        label = id .. " | " .. code .. " | " .. spec2.area,
      }
      return view(id, data.nodes[id])
    end)
  end

  -- eine Node hat sich im Betrieb gemeldet
  function n.mark_active(id)
    local node = data.nodes[id]
    if not node or node.state ~= "reserviert" then return true end
    return change(function() node.state = "aktiv" return true end)
  end

  -- eine nie aktivierte Anforderung verwerfen (die Kennung bleibt vergeben)
  function n.discard_node(id)
    return change(function()
      local node = data.nodes[id]
      if not node then return nil, "Die Node gibt es nicht." end
      if node.state ~= "reserviert" then return nil, "Nur eine noch nicht aktivierte Anforderung laesst sich verwerfen." end
      node.state = "verworfen"
      return true
    end)
  end

  function n.nodes()
    local list = {}
    for id, node in pairs(data.nodes) do list[#list + 1] = view(id, node) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end

  function n.node(id)
    local node = data.nodes[id]
    return node and view(id, node) or nil
  end

  return n
end

return M
