--[[
Purpose: Fahrtauftraege (Konzept 8): Vorlage und Ausfuehrung sind getrennt; jede Ausfuehrung ist ein eigener Vorgang mit Lebenszyklus (angefordert, in Pruefung, wartend, vorbereitet, Fahrplan uebergeben, Abfahrt freigegeben, unterwegs, am Ziel, abgeschlossen, Klaerung erforderlich; dazu abgelehnt und storniert). Uebergaenge sind begrenzt, jeder Schritt bleibt mit Zeit und Grund erhalten. Eine zweite Anforderung derselben Vorlage zeigt den laufenden Auftrag, statt eine neue Fahrt zu erzeugen.
API: orders.new{ store, path, now } -> o; o.add_template(t); o.templates(); o.request(template_id, request_id) -> auftrag, neu; o.get(id); o.active(); o.active_for(template_id); o.transition(id, to, grund); o.cancel(id) -> ok, hinweis; o.list(); o.save()
Notes: Eine Ablehnung betrifft eine nicht ausfuehrbare Anforderung; Stornieren geht nur, solange noch kein Fahrplan uebergeben wurde. Danach ist "Abbrechen" nur ein Aenderungswunsch (change_request), kein Zustandswechsel: das Loeschen eines Auftrags bremst keinen Zug (8.1). Wiederholte Anforderung mit derselben request_id liefert denselben Auftrag.
]]

local M = {}

M.STATES = {
  "angefordert", "in_pruefung", "wartend", "vorbereitet", "fahrplan_uebergeben", "abfahrt_freigegeben", "unterwegs", "am_ziel",
  "abgeschlossen", "klaerung", "abgelehnt", "storniert",
}

local ALLOWED = {
  angefordert = { in_pruefung = true, abgelehnt = true, storniert = true },
  in_pruefung = { vorbereitet = true, wartend = true, abgelehnt = true, klaerung = true, storniert = true },
  wartend = { in_pruefung = true, storniert = true, abgelehnt = true },
  vorbereitet = { fahrplan_uebergeben = true, klaerung = true, wartend = true, storniert = true },
  fahrplan_uebergeben = { abfahrt_freigegeben = true, klaerung = true },
  abfahrt_freigegeben = { unterwegs = true, klaerung = true },
  unterwegs = { am_ziel = true, klaerung = true },
  am_ziel = { abfahrt_freigegeben = true, abgeschlossen = true, klaerung = true },
  klaerung = { in_pruefung = true, abgeschlossen = true, storniert = true },
  abgeschlossen = {}, abgelehnt = {}, storniert = {},
}
M.ALLOWED = ALLOWED

local TERMINAL = { abgeschlossen = true, abgelehnt = true, storniert = true }
local CANCELABLE = { angefordert = true, in_pruefung = true, wartend = true, vorbereitet = true }

-- "Weizenhof:5:640; Zentrallager:3" -> Halte { station, wait, cargo = { count } }; Menge ist optional
function M.parse_stops(text)
  local stops = {}
  for part in (text or ""):gmatch("[^;]+") do
    local fields = {}
    for f in (part .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = f:match("^%s*(.-)%s*$") end
    local station = fields[1]
    if not station or station == "" then return nil, "Ein Halt hat keinen Bahnhofsnamen." end
    local stop = { station = station }
    if fields[2] then
      stop.wait = tonumber(fields[2])
      if not stop.wait or stop.wait < 0 then return nil, "Wartezeit bei " .. station .. " ist keine Zahl." end
    end
    if fields[3] then
      local count = tonumber(fields[3])
      if not count or count < 1 then return nil, "Menge bei " .. station .. " ist keine Zahl." end
      stop.cargo = { count = count }
    end
    if #fields > 3 then return nil, "Zu viele Angaben bei " .. station .. " (Bahnhof:Sekunden:Menge)." end
    stops[#stops + 1] = stop
  end
  if #stops == 0 then return nil, "Mindestens ein Halt ist noetig." end
  return stops
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

function M.new(opts)
  local o = {}
  local data = opts.store.load(opts.path) or { templates = {}, orders = {}, counter = 0 }
  data.templates = data.templates or {}
  data.orders = data.orders or {}
  data.counter = data.counter or 0
  local max_finished = opts.max_finished or 50

  function o.save() return opts.store.save(opts.path, data) end

  function o.add_template(t)
    if type(t.id) ~= "string" or not t.id:match("^[%w%-_]+$") then return nil, "Die Vorlagenkennung ist ungueltig." end
    if type(t.title) ~= "string" or t.title == "" then return nil, "Die Vorlage braucht einen Titel." end
    if type(t.train) ~= "string" then return nil, "Die Vorlage braucht einen Zug." end
    if type(t.stops) ~= "table" or #t.stops < 1 then return nil, "Die Vorlage braucht mindestens ein Ziel." end
    for i, stop in ipairs(t.stops) do
      if type(stop.station) ~= "string" or stop.station == "" then return nil, "Ziel " .. i .. " hat keinen Bahnhof." end
    end
    local previous = data.templates[t.id]
    data.templates[t.id] = copy(t)
    local ok, err = o.save()
    if not ok then
      data.templates[t.id] = previous
      return nil, err
    end
    return true
  end

  function o.templates()
    local ids = {}
    for id in pairs(data.templates) do ids[#ids + 1] = id end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = data.templates[id] end
    return out
  end

  function o.template(id) return data.templates[id] end

  function o.get(id) return data.orders[id] end

  function o.list()
    local ids = {}
    for id in pairs(data.orders) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return data.orders[a].number < data.orders[b].number end)
    local out = {}
    for _, id in ipairs(ids) do out[#out + 1] = data.orders[id] end
    return out
  end

  function o.active()
    local out = {}
    for _, order in ipairs(o.list()) do
      if not TERMINAL[order.state] then out[#out + 1] = order end
    end
    return out
  end

  function o.active_for(template_id)
    for _, order in ipairs(o.active()) do
      if order.template == template_id then return order end
    end
  end

  -- Aufraeumen: abgeschlossene Auftraege bleiben begrenzt erhalten
  local function prune()
    local finished = {}
    for _, order in ipairs(o.list()) do
      if TERMINAL[order.state] then finished[#finished + 1] = order end
    end
    for i = 1, #finished - max_finished do data.orders[finished[i].id] = nil end
  end

  -- liefert den Auftrag und ob er neu ist
  function o.request(template_id, request_id)
    local template = data.templates[template_id]
    if not template then return nil, "Unbekannte Vorlage." end
    if request_id then
      for _, order in pairs(data.orders) do
        if order.request_id == request_id then return order, false end
      end
    end
    local running = o.active_for(template_id)
    if running then return running, false end
    data.counter = data.counter + 1
    local order = {
      id = "A-" .. data.counter, number = data.counter, template = template_id, train = template.train, state = "angefordert",
      request_id = request_id, created = opts.now(), since = opts.now(), leg = 0,
      history = { { state = "angefordert", t = opts.now() } },
    }
    data.orders[order.id] = order
    prune()
    local ok, err = o.save()
    if not ok then data.orders[order.id] = nil data.counter = data.counter - 1 return nil, err end
    return order, true
  end

  function o.transition(id, to, reason)
    local order = data.orders[id]
    if not order then return nil, "Unbekannter Auftrag." end
    if order.state == to then return true end
    if not (ALLOWED[order.state] and ALLOWED[order.state][to]) then
      return nil, "Uebergang " .. order.state .. " -> " .. to .. " ist nicht vorgesehen."
    end
    order.state = to
    order.since = opts.now()
    order.reason = reason
    order.history[#order.history + 1] = { state = to, t = opts.now(), reason = reason }
    if #order.history > 40 then table.remove(order.history, 1) end
    return o.save()
  end

  -- Stornieren nur vor der Fahrplanuebergabe; danach nur ein Aenderungswunsch (8.1)
  function o.cancel(id)
    local order = data.orders[id]
    if not order then return nil, "Unbekannter Auftrag." end
    if TERMINAL[order.state] then return nil, "Der Auftrag ist schon beendet." end
    if CANCELABLE[order.state] then
      local ok, err = o.transition(id, "storniert", "vom Bediener storniert")
      if not ok then return nil, err end
      return true, "storniert"
    end
    order.change_request = true
    o.save()
    return true, "Aenderungswunsch vorgemerkt: die Fahrt laeuft weiter, bis ein geeigneter Zugriffspunkt erreicht ist."
  end

  return o
end

return M
