--[[
Purpose: Netzverzeichnis der Leitstelle (Konzept 3, 4, 5, 10, 11): Bereiche mit ihren zwei Anschluessen und den Gleisen darin (Name, Richtung als Bezug zu einem Anschluss), dazu die Anforderungen der Nodes, die ihren Ausschnitt uebernehmen. Die Leitstelle vergibt dauerhafte Kennungen (B0001 Bereich, A0001 Gleis, N0017 Node), die nie wiederverwendet werden, und liefert Anzeigename und Computerlabel einer Node.
API: netz.new{ store, path } -> n; n.blocked (Datei von neuerem Programm); n.set_end(bereich, nr, { kind, ref, name }); n.set_area_state(id, zustand); n.add_station{ name, kind, site }; n.set_station(id, felder); n.remove_station(id); n.link_station(betriebsstelle, gleis, beziehung, richtungen); n.unlink_station(betriebsstelle, gleis); n.stations(); n.station(id); n.sites(); n.add_junction{ name }; n.add_connection(k, name, gleise); n.add_route(k, von, nach); n.add_conflict(k, f1, f2); n.propose_routes(k, art); n.propose_conflicts(k); n.confirm_junction(k); n.junctions(); n.junction(k); n.junction_part(k, teil); n.add_area{ name, ends = { a, b }, count, pattern } -> id oder nil, fehler; n.add_area_once(kennung, angaben) -> id, neu_angelegt oder nil, fehler; n.set_area(id, { name, ends }); n.remove_area(id); n.add_track(area, name, richtung); n.set_track(id, { name, direction }); n.remove_track(id); n.areas() -> Liste; n.areas_page(nach, grenze) -> Liste, weitere; n.area(id) -> Bereich mit Gleisen; n.claim_node{ claim, role, area, tracks } oder fuer die Rolle knoten { claim, role, junction } -> Eintrag oder nil, fehler; n.mark_active(id); n.discard_node(id); n.nodes() -> Liste; n.node(id); n.revision()
Notes: Vorlagen (pattern) erzeugen nur bearbeitbare Gleise: gegenlaeufig (erste Haelfte Richtung Anschluss 2, Rest Richtung Anschluss 1), gleich (alle Richtung Anschluss 2), beide. Die Richtung eines Gleises ist ein Bezug (Name eines Anschlusses) oder "beide"; sie wird nirgends ausgewertet, sondern angezeigt. Ein Gleis in einem Bereich ist nicht automatisch ein Create-Signalblock. Die Anforderung einer Node (claim) ist wiederholbar: dieselbe Claim-Kennung liefert dieselbe Node-Kennung. Benutzte Objekte (Bereich oder Gleis, das eine Node uebernommen hat) werden nicht geloescht. Zaehler stehen in der Datei und gehen nie zurueck. Anschlussarten: name (freier Name), betriebsstelle (Name folgt der Betriebsstelle), bereich (Name folgt dem Nachbarbereich), offen (Ende im Bau: der Bereich gilt dann als "im bau", nicht als betriebsbereit). Betriebsstellen (BF0001: Personenbahnhof, Gueterbahnhof, Depot) hoeren optional zu einem Standort (S0001, nur ueber den Namen gefuehrt, leere Standorte verschwinden); ihre Gleise stehen mit einer Beziehung: vorbei (das Gleis fuehrt vorbei), verbindung (das Gleis hat eine Verbindung zur Betriebsstelle, mit den baulich moeglichen Fahrtrichtungen) oder bahnhofsgleis (das Gleis gehoert zur Betriebsstelle); aus einer Beziehung folgt nie eine andere. Jedes Objekt traegt einen Stand (rev); Aenderungen mit `if_rev` werden abgelehnt, wenn das Objekt inzwischen anders geaendert wurde. Knoten (K0001) fuehren Anschluesse als Gruppen von Gleisenden (Gleise des Verzeichnisses), gerichtete Fahrwege (F0001) zwischen Gleisenden verschiedener Anschluesse und Konflikte zwischen Fahrwegen; Vorschlaege (durchgehend, alle, Konflikte bei gleichem Start oder Ziel) bleiben unbestaetigt, bis sie ausdruecklich bestaetigt werden, und Nodes bekommen nur Bestaetigtes; nie wird eine Verbindung aus einer T- oder Y-Form abgeleitet. Das Dateiformat hat eine Version; eine Datei von einem neueren Programm wird gelesen, aber nicht veraendert. Jede Aenderung wird sofort gespeichert; schlaegt das fehl, bleibt der alte Stand.
]]

local ser = require("core.ser")

local M = {}

M.MAX_AREAS = 200
M.MAX_TRACKS = 40          -- je Bereich (eine Antwort an eine Node muss in eine Funknachricht passen)
M.MAX_NODES = 500
M.MAX_STATIONS = 300
M.VERSION = 2
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
  -- eine Datei von einem neueren Programm wird gelesen, aber nie veraendert (Datenformat, Konzept 18)
  n.blocked = type(data.version) == "number" and data.version > M.VERSION
  if not n.blocked then data.version = M.VERSION end
  data.revision = data.revision or 0
  data.counters = data.counters or {}
  for _, k in ipairs({ "bereich", "gleis", "node", "betriebsstelle", "standort", "knoten" }) do data.counters[k] = data.counters[k] or 0 end
  data.areas, data.tracks, data.nodes = data.areas or {}, data.tracks or {}, data.nodes or {}
  data.stations, data.sites = data.stations or {}, data.sites or {}
  data.junctions = data.junctions or {}

  -- Aenderung ausfuehren; schlaegt das Speichern fehl, kommt der alte Stand zurueck
  local function change(fn)
    if n.blocked then return nil, "Das Verzeichnis stammt von einem neueren Programm: nichts wird veraendert." end
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

  local function touch(entity) entity.rev = (entity.rev or 0) + 1 end
  local follow_names                      -- weiter unten (Anschlussarten)

  -- Aenderung mit `if_rev`: nur, wenn das Objekt seit dem Lesen unveraendert ist
  local function stale(entity, if_rev, what)
    if if_rev ~= nil and (entity.rev or 0) ~= if_rev then
      return "Das " .. what .. " wurde inzwischen geaendert (Stand " .. (entity.rev or 0) .. "): bitte neu laden."
    end
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

  local function create_area(spec2)
    do
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
      data.areas[id] = { name = name, ends = ends, order = 0, rev = 1 }
      local toward_second = (pattern == "gleich") and tracks or math.ceil(tracks / 2)
      for i = 1, tracks do
        local tid = new_id("gleis", "A")
        local direction = "beide"
        if pattern ~= "beide" then direction = (i <= toward_second) and ends[2] or ends[1] end
        data.tracks[tid] = { area = id, name = "Gleis " .. i, direction = direction, order = i, rev = 1 }
        data.areas[id].order = i
      end
      return id
    end
  end

  function n.add_area(spec2)
    return change(function() return create_area(spec2) end)
  end

  -- Bereich von einer Node aus anlegen (Konzept 10.2): dieselbe Anforderungskennung liefert denselben Bereich, auch wenn die Antwort verloren ging.
  -- Die Kennungen der letzten Anforderungen stehen in der Datei (hoechstens M.MAX_TOKENS).
  M.MAX_TOKENS = 200
  function n.add_area_once(token, spec2)
    if type(token) ~= "string" or #token < 8 or #token > 64 or token:find("[^%w%-_]") then return nil, "Die Anforderungskennung ist ungueltig." end
    local known = data.area_tokens and data.area_tokens[token]
    if known and data.areas[known] then return known, false end
    local id, err = change(function()
      local created, why = create_area(spec2)
      if not created then return nil, why end
      data.area_tokens = data.area_tokens or {}
      data.area_token_list = data.area_token_list or {}
      data.area_tokens[token] = created
      data.area_token_list[#data.area_token_list + 1] = token
      while #data.area_token_list > M.MAX_TOKENS do
        data.area_tokens[table.remove(data.area_token_list, 1)] = nil
      end
      return created
    end)
    if not id then return nil, err end
    return id, true
  end

  function n.set_area(id, fields)
    return change(function()
      local area = data.areas[id]
      if not area then return nil, "Den Bereich gibt es nicht." end
      local old = stale(area, fields.if_rev, "Bereich")
      if old then return nil, old end
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
      -- ein Nachbarbereich, der diesen Bereich als Anschluss fuehrt, darf nicht zwei gleich benannte Anschluesse bekommen
      for other_id, other in pairs(data.areas) do
        for nr = 1, 2 do
          local info = other.end_info and other.end_info[nr]
          if other_id ~= id and info and info.kind == "bereich" and info.ref == id and same(name, other.ends[3 - nr]) then
            return nil, "Der Bereich " .. other.name .. " haette zwei gleich benannte Anschluesse."
          end
        end
      end
      area.name, area.ends = name, ends
      touch(area)
      follow_names()
      return true
    end)
  end

  function n.remove_area(id)
    return change(function()
      if not data.areas[id] then return nil, "Den Bereich gibt es nicht." end
      local user = area_used_by(id)
      if user then return nil, "Die Node " .. user .. " nutzt diesen Bereich: erst dort aufloesen." end
      for other_id, other in pairs(data.areas) do
        for i, info in pairs(other.end_info or {}) do
          if info.kind == "bereich" and info.ref == id then return nil, "Der Bereich " .. other.name .. " hat diesen Bereich als Anschluss " .. i .. ": erst dort aendern." end
        end
      end
      for sid, station in pairs(data.stations) do
        for tid in pairs(station.links or {}) do
          if data.tracks[tid] and data.tracks[tid].area == id then return nil, "Die Betriebsstelle " .. station.name .. " (" .. sid .. ") nutzt ein Gleis dieses Bereichs: erst dort aufloesen." end
        end
      end
      for jid, j in pairs(data.junctions) do
        for cname, c in pairs(j.connections) do
          for _, tid in ipairs(c.tracks) do
            if data.tracks[tid] and data.tracks[tid].area == id then return nil, "Der Knoten " .. j.name .. " (" .. jid .. ") fuehrt ein Gleis dieses Bereichs: erst dort aufloesen." end
          end
        end
      end
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
      data.tracks[tid] = { area = area_id, name = clean_name, direction = direction, order = area.order, rev = 1 }
      return tid
    end)
  end

  function n.set_track(id, fields)
    return change(function()
      local t = data.tracks[id]
      if not t then return nil, "Das Gleis gibt es nicht." end
      local area = data.areas[t.area]
      local old = stale(t, fields.if_rev, "Gleis")
      if old then return nil, old end
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
      touch(t)
      return true
    end)
  end

  function n.remove_track(id)
    return change(function()
      if not data.tracks[id] then return nil, "Das Gleis gibt es nicht." end
      local user = track_used_by(id)
      if user then return nil, "Die Node " .. user .. " nutzt dieses Gleis: erst dort aufloesen." end
      for sid, station in pairs(data.stations) do
        if station.links and station.links[id] then return nil, "Die Betriebsstelle " .. station.name .. " (" .. sid .. ") nutzt dieses Gleis: erst dort aufloesen." end
      end
      for jid, j in pairs(data.junctions) do
        for cname, c in pairs(j.connections) do
          for _, tid in ipairs(c.tracks) do
            if tid == id then return nil, "Der Knoten " .. j.name .. " (" .. jid .. ") fuehrt es im Anschluss " .. cname .. ": erst dort aufloesen." end
          end
        end
      end
      data.tracks[id] = nil
      return true
    end)
  end

  -- Abfragen -------------------------------------------------------------------------------------------------------------------------------
  local function tracks_of(area_id)
    local list = {}
    for id, t in pairs(data.tracks) do
      if t.area == area_id then list[#list + 1] = { id = id, name = t.name, direction = t.direction, order = t.order or 0, rev = t.rev or 0 } end
    end
    table.sort(list, function(a, b) if a.order ~= b.order then return a.order < b.order end return a.id < b.id end)
    for _, t in ipairs(list) do t.order = nil end
    return list
  end

  function n.areas()
    local list = {}
    for id, a in pairs(data.areas) do
      -- Zusammenfassung fuer die Funkantwort: der Zustand nur, wenn er vom Normalfall abweicht
      list[#list + 1] = { id = id, name = a.name, ends = { a.ends[1], a.ends[2] }, tracks = track_count(id), state = (a.state == "im bau") and "im bau" or nil }
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
    local kinds = { (a.end_info and a.end_info[1] and a.end_info[1].kind) or "name", (a.end_info and a.end_info[2] and a.end_info[2].kind) or "name" }
    return { id = id, name = a.name, ends = { a.ends[1], a.ends[2] }, end_kinds = kinds, tracks = tracks_of(id), state = a.state or "betriebsbereit", rev = a.rev or 0 }
  end

  function n.track(id)
    local t = data.tracks[id]
    if not t then return nil end
    return { id = id, area = t.area, name = t.name, direction = t.direction, rev = t.rev or 0 }
  end

  function n.revision() return data.revision end

  -- Anschlussarten und Zustand eines Bereichs (Konzept 4.3, 8) -----------------------------------------------------------------------------
  local END_KINDS = { name = true, betriebsstelle = true, bereich = true, offen = true }
  M.END_KINDS = END_KINDS

  local function end_name_of(spec2, area_id)
    if spec2.kind == "betriebsstelle" then
      local st = data.stations[spec2.ref]
      if not st then return nil, "Die Betriebsstelle gibt es nicht." end
      return st.name
    elseif spec2.kind == "bereich" then
      if spec2.ref == area_id then return nil, "Ein Bereich kann nicht an sich selbst anschliessen." end
      local other = data.areas[spec2.ref]
      if not other then return nil, "Den Nachbarbereich gibt es nicht." end
      return other.name
    end
    return valid_name(spec2.name)
  end

  -- Anschluss nr (1 oder 2) setzen; der Name folgt Betriebsstelle oder Nachbarbereich, Richtungen der Gleise ziehen mit
  function n.set_end(area_id, nr, spec2)
    return change(function()
      local area = data.areas[area_id]
      if not area then return nil, "Den Bereich gibt es nicht." end
      local old = stale(area, spec2.if_rev, "Bereich")
      if old then return nil, old end
      if nr ~= 1 and nr ~= 2 then return nil, "Der Anschluss ist 1 oder 2." end
      if not END_KINDS[spec2.kind] then return nil, "Unbekannte Anschlussart " .. tostring(spec2.kind) .. " (name, betriebsstelle, bereich, offen)." end
      local name, why = end_name_of(spec2, area_id)
      if not name then return nil, why end
      if name:lower() == "beide" then return nil, "'beide' ist als Anschlussname nicht moeglich." end
      if same(name, area.ends[3 - nr]) then return nil, "Die beiden Anschluesse brauchen verschiedene Namen." end
      local previous = area.ends[nr]
      for _, t in pairs(data.tracks) do
        if t.area == area_id and t.direction == previous then t.direction = name end
      end
      area.ends[nr] = name
      area.end_info = area.end_info or {}
      area.end_info[nr] = { kind = spec2.kind, ref = (spec2.kind == "betriebsstelle" or spec2.kind == "bereich") and spec2.ref or nil }
      if spec2.kind == "offen" then area.state = "im bau" end
      touch(area)
      return true
    end)
  end

  function n.set_area_state(id, state)
    return change(function()
      local area = data.areas[id]
      if not area then return nil, "Den Bereich gibt es nicht." end
      if state ~= "betriebsbereit" and state ~= "im bau" then return nil, "Zustand: betriebsbereit oder im bau." end
      if state == "betriebsbereit" then
        for _, info in pairs(area.end_info or {}) do
          if info.kind == "offen" then return nil, "Ein offenes Ende gilt nicht als betriebsbereit: erst den Anschluss festlegen." end
        end
      end
      area.state = state
      touch(area)
      return true
    end)
  end

  -- Namen, die einer Betriebsstelle oder einem Nachbarbereich folgen, nach einer Umbenennung nachziehen
  function follow_names()
    for area_id, area in pairs(data.areas) do
      for nr = 1, 2 do
        local info = area.end_info and area.end_info[nr]
        if info and (info.kind == "betriebsstelle" or info.kind == "bereich") then
          local target = (info.kind == "betriebsstelle") and data.stations[info.ref] or data.areas[info.ref]
          if target and target.name ~= area.ends[nr] and not same(target.name, area.ends[3 - nr]) then
            for _, t in pairs(data.tracks) do
              if t.area == area_id and t.direction == area.ends[nr] then t.direction = target.name end
            end
            area.ends[nr] = target.name
            touch(area)
          end
        end
      end
    end
  end

  -- Standorte und Betriebsstellen (Konzept 6) -------------------------------------------------------------------------------------------
  local STATION_KINDS = { personenbahnhof = true, gueterbahnhof = true, depot = true }
  local RELATIONS = { vorbei = true, verbindung = true, bahnhofsgleis = true }
  M.STATION_KINDS, M.RELATIONS = STATION_KINDS, RELATIONS

  local function site_by_name(name)
    for id, site in pairs(data.sites) do if same(site.name, name) then return id end end
  end

  local function empty_text(v) return v == nil or v == false or clean(v) == "" end

  -- Standort ueber den Namen: wird bei Bedarf angelegt; leere Standorte verschwinden. Ergebnis: Kennung, nil (kein Standort) oder nil, Fehler
  local function site_for(name)
    if empty_text(name) then return nil end
    local text, why = valid_name(name)
    if not text then return nil, why end
    local id = site_by_name(text)
    if not id then
      id = new_id("standort", "S")
      data.sites[id] = { name = text }
    end
    return id
  end

  local function prune_sites()
    for id in pairs(data.sites) do
      local used = false
      for _, st in pairs(data.stations) do if st.site == id then used = true end end
      if not used then data.sites[id] = nil end
    end
  end

  local function station_name_taken(name, except)
    for id, st in pairs(data.stations) do
      if id ~= except and same(st.name, name) then return true end
    end
    return false
  end

  function n.add_station(spec2)
    return change(function()
      local count = 0
      for _ in pairs(data.stations) do count = count + 1 end
      if count >= M.MAX_STATIONS then return nil, "Es gibt schon " .. M.MAX_STATIONS .. " Betriebsstellen." end
      local name, why = valid_name(spec2.name)
      if not name then return nil, why end
      if station_name_taken(name) then return nil, "Eine Betriebsstelle " .. name .. " gibt es schon." end
      if not STATION_KINDS[spec2.kind] then return nil, "Die Art ist personenbahnhof, gueterbahnhof oder depot." end
      local site, why_site = site_for(spec2.site)
      if not site and not empty_text(spec2.site) then return nil, why_site end
      local id = new_id("betriebsstelle", "BF")
      data.stations[id] = { name = name, kind = spec2.kind, site = site, links = {}, rev = 1 }
      return id
    end)
  end

  function n.set_station(id, fields)
    return change(function()
      local st = data.stations[id]
      if not st then return nil, "Die Betriebsstelle gibt es nicht." end
      local old = stale(st, fields.if_rev, "Betriebsstelle")
      if old then return nil, old end
      if fields.name ~= nil then
        local name, why = valid_name(fields.name)
        if not name then return nil, why end
        if station_name_taken(name, id) then return nil, "Eine Betriebsstelle " .. name .. " gibt es schon." end
        -- ein Anschluss mit dem Namen dieser Betriebsstelle darf mit dem anderen Ende nicht gleich werden
        for _, area in pairs(data.areas) do
          for nr = 1, 2 do
            local info = area.end_info and area.end_info[nr]
            if info and info.kind == "betriebsstelle" and info.ref == id and same(name, area.ends[3 - nr]) then
              return nil, "Der Bereich " .. area.name .. " haette zwei gleich benannte Anschluesse."
            end
          end
        end
        st.name = name
      end
      if fields.kind ~= nil then
        if not STATION_KINDS[fields.kind] then return nil, "Die Art ist personenbahnhof, gueterbahnhof oder depot." end
        st.kind = fields.kind
      end
      if fields.site ~= nil then
        local site, why = site_for(fields.site)
        if not site and not empty_text(fields.site) then return nil, why end
        st.site = site
      end
      touch(st)
      follow_names()
      prune_sites()
      return true
    end)
  end

  function n.remove_station(id)
    return change(function()
      local st = data.stations[id]
      if not st then return nil, "Die Betriebsstelle gibt es nicht." end
      for _, area in pairs(data.areas) do
        for nr = 1, 2 do
          local info = area.end_info and area.end_info[nr]
          if info and info.kind == "betriebsstelle" and info.ref == id then return nil, "Der Bereich " .. area.name .. " hat sie als Anschluss " .. nr .. ": erst dort aendern." end
        end
      end
      for node_id, node in pairs(data.nodes) do
        if node.station == id and node.state ~= "verworfen" then return nil, "Die Node " .. node_id .. " nutzt diese Betriebsstelle: erst dort aufloesen." end
      end
      data.stations[id] = nil
      prune_sites()
      return true
    end)
  end

  -- Gleis und Betriebsstelle verbinden: vorbei, verbindung (mit den baulich moeglichen Fahrtrichtungen) oder bahnhofsgleis (Konzept 6.1)
  function n.link_station(station_id, track_id, relation, directions)
    return change(function()
      local st = data.stations[station_id]
      if not st then return nil, "Die Betriebsstelle gibt es nicht." end
      local track = data.tracks[track_id]
      if not track then return nil, "Das Gleis gibt es nicht." end
      if not RELATIONS[relation] then return nil, "Die Beziehung ist vorbei, verbindung oder bahnhofsgleis." end
      local list = {}
      if relation == "verbindung" and directions ~= nil then
        if type(directions) ~= "table" then return nil, "Die Fahrtrichtungen fehlen." end
        local area = data.areas[track.area]
        for _, d in ipairs(directions) do
          if not (d == area.ends[1] or d == area.ends[2]) then return nil, "Die Fahrtrichtung " .. tostring(d) .. " ist kein Anschluss des Bereichs." end
          list[#list + 1] = d
        end
        table.sort(list)
      end
      if relation == "bahnhofsgleis" then
        for sid, other in pairs(data.stations) do
          if sid ~= station_id and other.links[track_id] and other.links[track_id].relation == "bahnhofsgleis" then
            return nil, "Das Gleis gehoert schon zur Betriebsstelle " .. other.name .. "."
          end
        end
      end
      st.links[track_id] = { relation = relation, directions = (#list > 0) and list or nil }
      touch(st)
      return true
    end)
  end

  function n.unlink_station(station_id, track_id)
    return change(function()
      local st = data.stations[station_id]
      if not st then return nil, "Die Betriebsstelle gibt es nicht." end
      if not st.links[track_id] then return nil, "Dieses Gleis ist nicht mit der Betriebsstelle verbunden." end
      for node_id, node in pairs(data.nodes) do
        if node.station == station_id and node.state ~= "verworfen" then
          for _, tid in ipairs(node.tracks) do
            if tid == track_id then return nil, "Die Node " .. node_id .. " nutzt dieses Gleis der Betriebsstelle: erst dort aufloesen." end
          end
        end
      end
      st.links[track_id] = nil
      touch(st)
      return true
    end)
  end

  local function station_view(id, st, with_links)
    local out = { id = id, name = st.name, kind = st.kind, site = st.site, site_name = st.site and data.sites[st.site] and data.sites[st.site].name or nil, rev = st.rev or 0 }
    local count = 0
    for _ in pairs(st.links or {}) do count = count + 1 end
    out.links = count
    if with_links then
      local list = {}
      for tid, link in pairs(st.links or {}) do
        local track = data.tracks[tid]
        list[#list + 1] = { track = tid, name = track and track.name or "?", area = track and track.area or nil, relation = link.relation, directions = link.directions and copy(link.directions) or nil }
      end
      table.sort(list, function(a, b) return a.track < b.track end)
      out.links = list
    end
    return out
  end

  function n.stations()
    local list = {}
    for id, st in pairs(data.stations) do list[#list + 1] = station_view(id, st, false) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end

  function n.station(id)
    local st = data.stations[id]
    return st and station_view(id, st, true) or nil
  end

  function n.sites()
    local list = {}
    for id, site in pairs(data.sites) do
      local c = 0
      for _, st in pairs(data.stations) do if st.site == id then c = c + 1 end end
      list[#list + 1] = { id = id, name = site.name, stations = c }
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end

  -- Knoten: Anschluesse als Gruppen von Gleisenden, Fahrwege, Konflikte (Konzept 7) ------------------------------------------------------
  M.MAX_JUNCTIONS = 100
  M.MAX_JUNCTION_ENDS = 24
  M.MAX_ROUTES = 60
  M.MAX_CONFLICTS = 90

  local function junction_name_taken(name, except)
    for id, j in pairs(data.junctions) do
      if id ~= except and same(j.name, name) then return true end
    end
    return false
  end

  local function end_owner(j, track_id)
    for name, c in pairs(j.connections) do
      for _, tid in ipairs(c.tracks) do if tid == track_id then return name end end
    end
  end

  local function count_of(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
  end

  function n.add_junction(spec2)
    return change(function()
      if count_of(data.junctions) >= M.MAX_JUNCTIONS then return nil, "Es gibt schon " .. M.MAX_JUNCTIONS .. " Knoten." end
      local name, why = valid_name(spec2.name)
      if not name then return nil, why end
      if junction_name_taken(name) then return nil, "Einen Knoten " .. name .. " gibt es schon." end
      local id = new_id("knoten", "K")
      data.junctions[id] = { name = name, connections = {}, routes = {}, conflicts = {}, route_counter = 0, rev = 1 }
      return id
    end)
  end

  function n.set_junction(id, fields)
    return change(function()
      local j = data.junctions[id]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local old = stale(j, fields.if_rev, "Knoten")
      if old then return nil, old end
      if fields.name ~= nil then
        local name, why = valid_name(fields.name)
        if not name then return nil, why end
        if junction_name_taken(name, id) then return nil, "Einen Knoten " .. name .. " gibt es schon." end
        j.name = name
      end
      touch(j)
      return true
    end)
  end

  function n.remove_junction(id)
    return change(function()
      if not data.junctions[id] then return nil, "Den Knoten gibt es nicht." end
      for node_id, node in pairs(data.nodes) do
        if node.junction == id and node.state ~= "verworfen" then return nil, "Die Node " .. node_id .. " nutzt diesen Knoten: erst dort aufloesen." end
      end
      data.junctions[id] = nil
      return true
    end)
  end

  -- Anschluss: Name und die Gleisenden (Gleise des Verzeichnisses), jedes Gleisende gehoert zu hoechstens einem Anschluss des Knotens
  function n.add_connection(jid, name, track_ids)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local clean_name, why = valid_name(name)
      if not clean_name then return nil, why end
      if clean_name:lower() == "beide" then return nil, "'beide' ist als Anschlussname nicht moeglich." end
      for existing in pairs(j.connections) do
        if same(existing, clean_name) then return nil, "Den Anschluss " .. clean_name .. " gibt es in diesem Knoten schon." end
      end
      if type(track_ids) ~= "table" or #track_ids == 0 then return nil, "Ein Anschluss braucht mindestens ein Gleisende." end
      local list = {}
      for _, tid in ipairs(track_ids) do
        if not data.tracks[tid] then return nil, "Das Gleis " .. tostring(tid) .. " gibt es nicht." end
        local owner = end_owner(j, tid)
        if owner then return nil, "Das Gleis " .. tid .. " gehoert schon zum Anschluss " .. owner .. "." end
        for _, seen in ipairs(list) do if seen == tid then return nil, "Das Gleis " .. tid .. " ist doppelt angegeben." end end
        list[#list + 1] = tid
      end
      local total = #list
      for _, c in pairs(j.connections) do total = total + #c.tracks end
      if total > M.MAX_JUNCTION_ENDS then return nil, "Ein Knoten hat hoechstens " .. M.MAX_JUNCTION_ENDS .. " Gleisenden." end
      if count_of(j.connections) >= 8 then return nil, "Ein Knoten hat hoechstens 8 Anschluesse." end
      j.connections[clean_name] = { tracks = list }
      touch(j)
      return true
    end)
  end

  function n.remove_connection(jid, name)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local c = j.connections[name]
      if not c then return nil, "Den Anschluss gibt es nicht." end
      local ends = {}
      for _, tid in ipairs(c.tracks) do ends[tid] = true end
      for rid, r in pairs(j.routes) do
        if ends[r.from] or ends[r.to] then
          j.routes[rid] = nil
        end
      end
      local kept = {}
      for _, cf in ipairs(j.conflicts) do
        if j.routes[cf.a] and j.routes[cf.b] then kept[#kept + 1] = cf end
      end
      j.conflicts = kept
      j.connections[name] = nil
      touch(j)
      return true
    end)
  end

  -- Fahrweg: gerichtete Verbindung zwischen zwei Gleisenden verschiedener Anschluesse (nie aus der Form abgeleitet; zunaechst unbestaetigt)
  function n.add_route(jid, from, to, confirmed)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local a, b = end_owner(j, from), end_owner(j, to)
      if not a then return nil, "Das Gleis " .. tostring(from) .. " gehoert zu keinem Anschluss des Knotens." end
      if not b then return nil, "Das Gleis " .. tostring(to) .. " gehoert zu keinem Anschluss des Knotens." end
      if a == b then return nil, "Ein Fahrweg verbindet verschiedene Anschluesse." end
      for _, r in pairs(j.routes) do
        if r.from == from and r.to == to then return nil, "Diesen Fahrweg gibt es schon." end
      end
      if count_of(j.routes) >= M.MAX_ROUTES then return nil, "Ein Knoten hat hoechstens " .. M.MAX_ROUTES .. " Fahrwege." end
      j.route_counter = j.route_counter + 1
      local rid = string.format("F%04d", j.route_counter)
      j.routes[rid] = { from = from, to = to, confirmed = confirmed == true }
      touch(j)
      return rid
    end)
  end

  function n.remove_route(jid, rid)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      if not j.routes[rid] then return nil, "Den Fahrweg gibt es nicht." end
      j.routes[rid] = nil
      local kept = {}
      for _, cf in ipairs(j.conflicts) do if cf.a ~= rid and cf.b ~= rid then kept[#kept + 1] = cf end end
      j.conflicts = kept
      touch(j)
      return true
    end)
  end

  local function conflict_index(j, a, b)
    for i, cf in ipairs(j.conflicts) do
      if (cf.a == a and cf.b == b) or (cf.a == b and cf.b == a) then return i end
    end
  end

  function n.add_conflict(jid, a, b, confirmed)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      if a == b then return nil, "Ein Fahrweg steht nicht im Konflikt mit sich selbst." end
      if not j.routes[a] or not j.routes[b] then return nil, "Beide Fahrwege muessen es im Knoten geben." end
      if conflict_index(j, a, b) then return nil, "Diesen Konflikt gibt es schon." end
      if #j.conflicts >= M.MAX_CONFLICTS then return nil, "Ein Knoten hat hoechstens " .. M.MAX_CONFLICTS .. " Konflikte." end
      if a > b then a, b = b, a end
      j.conflicts[#j.conflicts + 1] = { a = a, b = b, confirmed = confirmed == true }
      touch(j)
      return true
    end)
  end

  function n.remove_conflict(jid, a, b)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local i = conflict_index(j, a, b)
      if not i then return nil, "Den Konflikt gibt es nicht." end
      table.remove(j.conflicts, i)
      touch(j)
      return true
    end)
  end

  -- Vorschlaege: sie bereiten Eingaben vor und bleiben unbestaetigt (Konzept 7.3). durchgehend = gleich nummerierte Gleisenden der ersten
  -- beiden Anschluesse in beide Richtungen; alle = jeder Fahrweg zwischen verschiedenen Anschluessen
  function n.propose_routes(jid, kind)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      if kind ~= "durchgehend" and kind ~= "alle" then return nil, "Vorschlag: durchgehend oder alle." end
      local names = {}
      for name in pairs(j.connections) do names[#names + 1] = name end
      table.sort(names)
      local pairs_list = {}
      if kind == "durchgehend" then
        if #names ~= 2 then return nil, "'durchgehend' braucht genau zwei Anschluesse (hier " .. #names .. ")." end
        local x, y = j.connections[names[1]].tracks, j.connections[names[2]].tracks
        for i = 1, math.min(#x, #y) do
          pairs_list[#pairs_list + 1] = { x[i], y[i] }
          pairs_list[#pairs_list + 1] = { y[i], x[i] }
        end
      else
        for _, na in ipairs(names) do
          for _, nb in ipairs(names) do
            if na ~= nb then
              for _, ta in ipairs(j.connections[na].tracks) do
                for _, tb in ipairs(j.connections[nb].tracks) do pairs_list[#pairs_list + 1] = { ta, tb } end
              end
            end
          end
        end
      end
      local made = 0
      for _, pair in ipairs(pairs_list) do
        local exists = false
        for _, r in pairs(j.routes) do if r.from == pair[1] and r.to == pair[2] then exists = true end end
        if not exists then
          if count_of(j.routes) >= M.MAX_ROUTES then return nil, "Mit dem Vorschlag waeren es mehr als " .. M.MAX_ROUTES .. " Fahrwege." end
          j.route_counter = j.route_counter + 1
          j.routes[string.format("F%04d", j.route_counter)] = { from = pair[1], to = pair[2], confirmed = false }
          made = made + 1
        end
      end
      touch(j)
      return made
    end)
  end

  -- Konfliktvorschlaege: Fahrwege mit gemeinsamem Start- oder Zielgleis. Kreuzungen auf gleicher Hoehe und gemeinsame Gleisteile
  -- kennt das Verzeichnis nicht; sie traegt man von Hand ein (eine Bruecke ueber einem Gleis ist kein Konflikt).
  function n.propose_conflicts(jid)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local ids = {}
      for rid in pairs(j.routes) do ids[#ids + 1] = rid end
      table.sort(ids)
      local made = 0
      for i = 1, #ids do
        for k = i + 1, #ids do
          local ra, rb = j.routes[ids[i]], j.routes[ids[k]]
          if (ra.from == rb.from or ra.to == rb.to) and not conflict_index(j, ids[i], ids[k]) then
            if #j.conflicts >= M.MAX_CONFLICTS then return nil, "Mit dem Vorschlag waeren es mehr als " .. M.MAX_CONFLICTS .. " Konflikte." end
            j.conflicts[#j.conflicts + 1] = { a = ids[i], b = ids[k], confirmed = false }
            made = made + 1
          end
        end
      end
      touch(j)
      return made
    end)
  end

  function n.confirm_junction(jid)
    return change(function()
      local j = data.junctions[jid]
      if not j then return nil, "Den Knoten gibt es nicht." end
      local changed = 0
      for _, r in pairs(j.routes) do if not r.confirmed then r.confirmed = true; changed = changed + 1 end end
      for _, cf in ipairs(j.conflicts) do if not cf.confirmed then cf.confirmed = true; changed = changed + 1 end end
      if changed > 0 then touch(j) end
      return changed
    end)
  end

  -- offene Punkte eines Knotens: unbestaetigte Fahrwege/Konflikte (blockieren), fehlende Konflikte bei gemeinsamem Start/Ziel (Hinweis)
  local function junction_open(j)
    local unconfirmed, hints = 0, {}
    for _, r in pairs(j.routes) do if not r.confirmed then unconfirmed = unconfirmed + 1 end end
    for _, cf in ipairs(j.conflicts) do if not cf.confirmed then unconfirmed = unconfirmed + 1 end end
    local ids = {}
    for rid in pairs(j.routes) do ids[#ids + 1] = rid end
    table.sort(ids)
    for i = 1, #ids do
      for k = i + 1, #ids do
        local ra, rb = j.routes[ids[i]], j.routes[ids[k]]
        if (ra.from == rb.from or ra.to == rb.to) and not conflict_index(j, ids[i], ids[k]) then
          hints[#hints + 1] = "Die Fahrwege " .. ids[i] .. " und " .. ids[k] .. " haben " .. (ra.from == rb.from and "dasselbe Startgleis" or "dasselbe Zielgleis") .. ": Konflikt nicht eingetragen."
        end
      end
    end
    return unconfirmed, hints
  end

  local function junction_view(id, j, detail)
    local unconfirmed, hints = junction_open(j)
    local out = { id = id, name = j.name, rev = j.rev or 0, connections = count_of(j.connections), routes = count_of(j.routes), conflicts = #j.conflicts, unconfirmed = unconfirmed, hints = #hints }
    if detail then
      local conns = {}
      for name, c in pairs(j.connections) do conns[#conns + 1] = { name = name, tracks = copy(c.tracks) } end
      table.sort(conns, function(a, b) return a.name < b.name end)
      local routes = {}
      for rid, r in pairs(j.routes) do routes[#routes + 1] = { id = rid, from = r.from, to = r.to, confirmed = r.confirmed } end
      table.sort(routes, function(a, b) return a.id < b.id end)
      out.connections, out.routes, out.conflicts, out.hints = conns, routes, copy(j.conflicts), hints
    end
    return out
  end

  function n.junctions()
    local list = {}
    for id, j in pairs(data.junctions) do list[#list + 1] = junction_view(id, j, false) end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
  end

  function n.junction(id)
    local j = data.junctions[id]
    return j and junction_view(id, j, true) or nil
  end

  -- fuer eine Node: nur Bestaetigtes (Anschluesse; Fahrwege; Konflikte); jeder Teil passt in eine Funkantwort
  function n.junction_part(id, part)
    local j = data.junctions[id]
    if not j then return nil, "Den Knoten gibt es nicht." end
    if part == "anschluesse" then
      local conns = {}
      for name, c in pairs(j.connections) do
        local ends = {}
        for _, tid in ipairs(c.tracks) do
          local t = data.tracks[tid]
          local a = t and data.areas[t.area]
          ends[#ends + 1] = { id = tid, name = t and t.name or "?", area = a and a.name or "?" }
        end
        conns[#conns + 1] = { name = name, tracks = ends }
      end
      table.sort(conns, function(a, b) return a.name < b.name end)
      return { id = id, name = j.name, rev = j.rev or 0, connections = conns }
    elseif part == "fahrwege" then
      local routes = {}
      for rid, r in pairs(j.routes) do
        if r.confirmed then routes[#routes + 1] = { id = rid, from = r.from, to = r.to } end
      end
      table.sort(routes, function(a, b) return a.id < b.id end)
      return { id = id, routes = routes }
    elseif part == "konflikte" then
      local list = {}
      for _, cf in ipairs(j.conflicts) do
        if cf.confirmed and j.routes[cf.a] and j.routes[cf.b] and j.routes[cf.a].confirmed and j.routes[cf.b].confirmed then
          list[#list + 1] = { a = cf.a, b = cf.b }
        end
      end
      return { id = id, conflicts = list }
    end
    return nil, "Teil: anschluesse, fahrwege oder konflikte."
  end

  -- Nodes ----------------------------------------------------------------------------------------------------------------------------------
  local function view(id, node)
    return { id = id, claim = node.claim, role = node.role, area = node.area, junction = node.junction, tracks = copy(node.tracks), state = node.state, name = node.name, label = node.label }
  end

  -- Anforderung einer Node-Kennung. Normale Rollen betreuen Gleise eines Bereichs (area, tracks); die Rolle knoten betreut einen Knoten des Verzeichnisses
  -- (junction): sie bekommt alle Gleisenden seiner Anschluesse, und der Knoten muss vollstaendig bestaetigt sein (Nodes erhalten nur Bestaetigtes).
  function n.claim_node(spec2)
    return change(function()
      local claim = spec2.claim
      if type(claim) ~= "string" or #claim < 8 or #claim > 64 or claim:find("[^%w%-_]") then return nil, "Die Anforderungskennung ist ungueltig." end
      local code = ROLE_CODE[spec2.role]
      if not code then return nil, "Fuer diese Rolle gibt es keine Anforderung." end
      local wanted = {}
      local area_id, junction_id, where_name, where_code
      if spec2.role == "knoten" then
        local j = type(spec2.junction) == "string" and data.junctions[spec2.junction] or nil
        if not j then return nil, "Den Knoten gibt es nicht." end
        if spec2.area ~= nil or spec2.tracks ~= nil then return nil, "Ein Knoten wird ohne Bereich und Gleise angefordert." end
        local open = junction_open(j)
        if open > 0 then return nil, "Der Knoten hat " .. open .. " unbestaetigte Fahrwege oder Konflikte: erst in der Leitstelle bestaetigen." end
        if count_of(j.connections) < 2 then return nil, "Ein Knoten braucht mindestens zwei Anschluesse." end
        if count_of(j.routes) < 1 then return nil, "Der Knoten hat keinen Fahrweg." end
        local seen = {}
        for _, c in pairs(j.connections) do
          for _, tid in ipairs(c.tracks) do if not seen[tid] then seen[tid] = true; wanted[#wanted + 1] = tid end end
        end
        table.sort(wanted)
        junction_id, where_name, where_code = spec2.junction, j.name, spec2.junction
      else
        local area = data.areas[spec2.area]
        if not area then return nil, "Den Bereich gibt es nicht." end
        if spec2.junction ~= nil then return nil, "Nur die Rolle knoten wird fuer einen Knoten angefordert." end
        if type(spec2.tracks) ~= "table" then return nil, "Die Gleise fehlen." end
        for _, tid in ipairs(spec2.tracks) do
          local t = data.tracks[tid]
          if not t or t.area ~= spec2.area then return nil, "Das Gleis " .. tostring(tid) .. " gehoert nicht zu diesem Bereich." end
          for _, seen in ipairs(wanted) do if seen == tid then return nil, "Das Gleis " .. tid .. " ist doppelt angegeben." end end
          wanted[#wanted + 1] = tid
        end
        if #wanted == 0 then return nil, "Mindestens ein Gleis muss uebernommen werden." end
        area_id, where_name, where_code = spec2.area, area.name, spec2.area
      end
      -- dieselbe Anforderung noch einmal: dieselbe Kennung, neue Angaben
      for id, node in pairs(data.nodes) do
        if node.claim == claim then
          if node.state == "verworfen" then return nil, "Diese Anforderung wurde verworfen." end
          node.role, node.area, node.junction, node.tracks = spec2.role, area_id, junction_id, wanted
          node.name = ROLE_TEXT[spec2.role] .. " " .. where_name .. " " .. id
          node.label = id .. " | " .. code .. " | " .. where_code
          return view(id, node)
        end
      end
      local count = 0
      for _ in pairs(data.nodes) do count = count + 1 end
      if count >= M.MAX_NODES then return nil, "Es gibt schon " .. M.MAX_NODES .. " Nodes im Verzeichnis." end
      local id = new_id("node", "N")
      data.nodes[id] = {
        claim = claim, role = spec2.role, area = area_id, junction = junction_id, tracks = wanted, state = "reserviert",
        name = ROLE_TEXT[spec2.role] .. " " .. where_name .. " " .. id,
        label = id .. " | " .. code .. " | " .. where_code,
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
