--[[
Purpose: Leitstelle (Konzept 4.1, 7, 8, 9): fuehrt Zugregister, Auftragsvorlagen und Fahrtauftraege, kennt die Bahnhofs-Nodes und ihre Gleise (aus deren Anmeldung), prueft vor jeder Fahrt, laesst den Fahrplan und die Freigabe von den verantwortlichen Bahnhoefen ausfuehren und glaubt nur bestaetigte Meldungen. Fehlende Antworten werden wiederholt (dieselbe Nachricht, sie wird beim Empfaenger nicht doppelt ausgefuehrt); kommt keine, bleibt der Vorgang offen oder wird zur Klaerung. Jeder Neustart bekommt eine neue Epoche: alte Nachrichten bewirken nichts.
API: zentrale_role.new(node) -> role; role.register; role.orders; role.on_message(m, status); role.tick(); role.pages
Notes: Die Leitstelle kennt keine lueckenlose Zugposition (4.1): Aufenthalte tragen Art, Ort, Herkunft und Zeit. "Abfahrt freigegeben" ist ein Sollzustand; erst die Abfahrtsmeldung des Bahnhofs fuehrt zu "unterwegs"; "am Ziel" ist noch kein Lieferabschluss (9.5). Ein Zug mit unbekanntem Fahrplan wird nie ueberschrieben: das ist ein Uebergabevorgang (Klaerung). Die Betriebsfreigabe ist an Node, Zug und Aufenthalt gebunden.
]]

local registerlib = require("domain.register")
local orderslib = require("domain.orders")
local schedulelib = require("domain.schedule")
local stationslib = require("domain.stations")
local lineslib = require("domain.lines")
local W = require("ui.widgets")
local forms = require("ui.forms")
local model = require("setup.model")

local M = {}

local REPLY_WAIT = 8          -- Sekunden bis zur Wiederholung einer unbeantworteten Anfrage
local MAX_TRIES = 6
local RETRY_WAITING = 10      -- Sekunden bis ein wartender Auftrag neu geprueft wird
local NODE_SILENT = 60        -- Sekunden ohne Meldung: Node gilt als nicht erreichbar

function M.new(node)
  local role = {}
  local now = function() return node.clock.now() end
  local DATA = "/crn_data"

  -- Epoche: jeder Start der Leitstelle zaehlt hoch; Nachrichten aelterer Laeufe wirken nicht mehr (13.2)
  local epoch_state = node.store.load(DATA .. "/epoche.lua") or { n = 0 }
  epoch_state.n = epoch_state.n + 1
  node.store.save(DATA .. "/epoche.lua", epoch_state)
  node.own_epoch = epoch_state.n

  role.register = registerlib.new({ store = node.store, path = DATA .. "/register.lua" })
  role.orders = orderslib.new({ store = node.store, path = DATA .. "/auftraege.lua", now = now })
  role.stations = stationslib.new({ store = node.store, path = DATA .. "/bahnhoefe.lua" })
  role.lines = lineslib.new({ store = node.store, path = DATA .. "/linien.lua", now = now })
  local samples = node.store.load(DATA .. "/muster.lua") or {}
  local closed = node.store.load(DATA .. "/gesperrt.lua") or {}    -- Create-Bahnhofsname -> true (betriebliche Sperre)

  local nodes = {}        -- node_id -> { name, roles, tracks = {...}, last_seen, active }
  local dir = {}          -- Bahnhofsname -> { node, track, ambiguous }
  local track_state = {}  -- "node:gleis" -> letzter Zustandsbericht
  local pending = {}      -- messageId -> { m, order, sent, tries, on_reply }
  local waiting = {}      -- Auftrag -> true, solange eine Anfrage offen ist
  local flags = {}        -- Auftrag -> { unconfirmed = true }
  local unknown_seen = {}
  local silent_notified = {}

  local function notify(level, text) node.notify(level, text) end

  local function rebuild_dir()
    dir = {}
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      for _, track in ipairs(nodes[id].tracks or {}) do
        local name = track.station_name
        if name then
          if dir[name] then dir[name].ambiguous = true else dir[name] = { node = id, track = track.id, ambiguous = false } end
        end
      end
    end
  end

  local function reachable(node_id)
    local info = nodes[node_id]
    return info ~= nil and now() - info.last_seen < NODE_SILENT
  end

  local function locate(station)
    local entry = dir[station]
    if not entry then return nil, "Der Bahnhof " .. station .. " ist unbekannt." end
    if entry.ambiguous then return nil, "Der Bahnhofsname " .. station .. " ist nicht eindeutig." end
    if not reachable(entry.node) then return nil, "Der Node " .. entry.node .. " meldet sich nicht." end
    return entry
  end

  -- Anfragen mit Wiederholung ------------------------------------------------------------------------------------------------------------
  local function ask(node_id, message_type, payload, order, on_reply)
    local m = node.send_to(node_id, message_type, payload, { requestId = order and order.id or nil })
    if not m then return nil end
    pending[m.messageId] = { m = m, order = order and order.id or nil, sent = now(), tries = 1, on_reply = on_reply, target = node_id }
    if order then waiting[order.id] = true end
    return m
  end

  local function release_wait(p)
    if p.order then waiting[p.order] = nil; if flags[p.order] then flags[p.order].unconfirmed = nil end end
  end

  local function to_clarification(order, reason)
    local ok = role.orders.transition(order.id, "klaerung", reason)
    if ok then notify("warnung", "Auftrag " .. order.id .. ": " .. reason) end
  end

  local function check_pending()
    local t = now()
    local ids = {}
    for id in pairs(pending) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local p = pending[id]
      if t - p.sent >= REPLY_WAIT then
        if p.tries >= MAX_TRIES then
          pending[id] = nil
          release_wait(p)
          local order = p.order and role.orders.get(p.order)
          if order then to_clarification(order, "Keine Rueckmeldung von " .. p.target .. " (Rueckmeldung fehlt).") end
        else
          p.tries, p.sent = p.tries + 1, t
          if p.order then flags[p.order] = flags[p.order] or {}; flags[p.order].unconfirmed = true end
          node.send_message(p.m)       -- dieselbe Nachricht: der Empfaenger fuehrt sie nicht noch einmal aus
        end
      end
    end
  end

  -- Zugpositionen ------------------------------------------------------------------------------------------------------------------------
  local function set_position(train_name, kind, where, source, t)
    local train = role.register.by_create_name(train_name)
    if not train then return nil end
    local pos = train.position
    if pos and pos.kind == kind and pos.where == where then return train end
    role.register.set_position(train.id, kind, where, source, t)
    return train
  end

  -- Fahrplaene und Reihenfolge eines Auftrags ------------------------------------------------------------------------------------------
  local function entries_of(template)
    local list = {}
    for _, stop in ipairs(template.stops) do list[#list + 1] = stop end
    if template.return_to_start ~= false then
      list[#list + 1] = { station = template.stops[1].station, wait = 0 }
    end
    return list
  end

  local function release_message(order, entry, stay)
    local train = role.register.get(order.train)
    return { kind = "freigabe", orderId = order.id, track = entry.track, train = train and train.create_name, stay = stay, min_stay = order.min_stay or 0 }
  end

  -- Fahren eines Auftrags: jeder Aufruf macht hoechstens einen Schritt und wartet dann auf die Antwort --------------------------------------
  local drive

  -- Zielwahl (10.1): fuer jeden Halt das erste geeignete Gleis; Gruende, wenn keins passt
  local function track_info(create_name, order, train, payload)
    local entry = dir[create_name]
    if not entry then return { problem = "unbekannt" } end
    if entry.ambiguous then return { problem = "Name nicht eindeutig" } end
    if not reachable(entry.node) then return { problem = "Node " .. entry.node .. " meldet sich nicht" } end
    if closed[create_name] then return { problem = "gesperrt" } end
    local r = payload.reach and payload.reach[create_name]
    if r and not r.ok then return { problem = "nicht erreichbar" .. (r.reason and (" (" .. tostring(r.reason) .. ")") or "") } end
    local st = track_state[entry.node .. ":" .. entry.track]
    if st and st.present and st.train and st.train ~= (train and train.create_name) then return { problem = "belegt von " .. tostring(st.train) } end
    for _, other in ipairs(role.orders.active()) do
      if other.id ~= order.id and other.plan then
        for i = math.max(1, (other.leg or 0) + 1), #other.plan do
          if other.plan[i].station == create_name then return { problem = "dem Auftrag " .. other.id .. " zugewiesen" } end
        end
      end
    end
    local length
    for _, tr in ipairs(nodes[entry.node].tracks or {}) do if tr.id == entry.track then length = tr.length end end
    if train and train.length and length and train.length > length then return { problem = "zu kurz (" .. length .. " Wagen, Zug " .. train.length .. ")" } end
    return {}
  end

  local function handle_check_reply(order, payload)
    local template = role.orders.template(order.template)
    local train = role.register.get(order.train)
    local function waiting_for(reason)
      role.orders.transition(order.id, "wartend", reason)
    end
    if payload.status ~= "ok" then return waiting_for(payload.grund or "Der Bahnhof lehnt die Pruefung ab.") end
    if not payload.available then return waiting_for("Der Bahnhof " .. payload.station_name .. " ist nicht verfuegbar.") end
    if not payload.present then return waiting_for("Der Zug fehlt am Startbahnhof.") end
    if not train then return waiting_for("Der Zug " .. order.train .. " ist nicht registriert.") end
    if payload.train ~= train.create_name then
      return waiting_for("Am Start steht " .. tostring(payload.train) .. ", nicht " .. train.create_name .. ": Identitaet klaeren, kein fremder Fahrplan wird ueberschrieben.")
    end
    if payload.has_schedule and not payload.waiting_ok then
      return to_clarification(order, "Der Zug hat einen unbekannten Fahrplan: Uebergabe noetig.")
    end
    if payload.output then return waiting_for("Der Freigabeausgang am Start ist eingeschaltet.") end
    local entries = entries_of(template)
    -- Zielgleise festlegen; das Startgleis ist das, auf dem der Zug steht
    local plan = { { station = payload.station_name, node = order.start.node, track = order.start.track } }
    for i = 2, #entries do
      local candidates = role.stations.candidates(entries[i].station)
      local chosen, reasons = stationslib.choose(candidates, function(name) return track_info(name, order, train, payload) end)
      if not chosen then
        return waiting_for("Kein geeignetes Gleis fuer " .. entries[i].station .. " (" .. table.concat(reasons, "; ") .. ").")
      end
      plan[i] = { station = chosen, node = dir[chosen].node, track = dir[chosen].track }
    end
    local stops = {}
    for i, e in ipairs(entries) do stops[i] = { station = plan[i].station, wait = e.wait, cargo = e.cargo } end
    local schedule, err = schedulelib.order(stops, samples)
    if not schedule then return role.orders.transition(order.id, "abgelehnt", err) end
    local problems = schedulelib.check(schedule)
    if #problems > 0 then return role.orders.transition(order.id, "abgelehnt", problems[1]) end
    order.schedule = schedule
    order.plan = plan
    order.stay = payload.stay
    order.leg = 1
    order.min_stay = entries[1].wait or 0
    role.orders.save()
    role.orders.transition(order.id, "vorbereitet", "Zug und Auftrag sind zugeordnet")
  end

  local function handle_schedule_reply(order, payload)
    if payload.status == "uebergeben" then
      role.orders.transition(order.id, "fahrplan_uebergeben", "Fahrplan uebergeben (Schnittstelle bestaetigt die Uebergabe)")
    elseif payload.klaerung then
      to_clarification(order, payload.grund or "Fahrplan nicht uebergeben.")
    else
      role.orders.transition(order.id, "wartend", payload.grund or "Fahrplan nicht uebergeben.")
    end
  end

  local function handle_release_reply(order, payload)
    if payload.status == "freigabe_gesetzt" then
      role.orders.transition(order.id, "abfahrt_freigegeben", "Freigabe gesetzt, Abfahrt noch nicht bestaetigt")
    elseif payload.status == "zurueckgestellt" then
      order.retry_at = now() + (payload.retry_in or 2)
    else
      to_clarification(order, "Freigabe abgelehnt: " .. tostring(payload.grund))
    end
  end

  local function handle_wait_reply(order, payload)
    local train = role.register.get(order.train)
    if payload.status == "uebergeben" then
      if train then role.register.set_state(train.id, "gesteuert") end
      role.orders.transition(order.id, "abgeschlossen", "Rueckkehr bestaetigt, Warteauftrag erteilt")
    else
      to_clarification(order, "Warteauftrag am Ziel nicht erteilt: " .. tostring(payload.grund))
    end
  end

  drive = function(order)
    if waiting[order.id] then return end
    local template = role.orders.template(order.template)
    if not template then return role.orders.transition(order.id, "abgelehnt", "Die Vorlage gibt es nicht mehr.") end
    local state = order.state
    if state == "angefordert" then
      role.orders.transition(order.id, "in_pruefung", "Voraussetzungen werden geprueft")
      state = "in_pruefung"
    end
    local entries = entries_of(template)
    if state == "wartend" then
      if now() - order.since >= RETRY_WAITING then role.orders.transition(order.id, "in_pruefung", "erneute Pruefung") end
      return
    end
    if state == "in_pruefung" then
      -- Startgleis: bei einem Bahnhof mit mehreren Gleisen das, auf dem der Zug nachweislich steht
      local train = role.register.get(order.train)
      local start, why
      for _, name in ipairs(role.stations.candidates(entries[1].station)) do
        local entry = locate(name)
        if entry then
          local st = track_state[entry.node .. ":" .. entry.track]
          if st and st.present and train and st.train == train.create_name then start = entry break end
          start = start or entry
        else
          why = why or select(2, locate(name))
        end
      end
      if not start then return role.orders.transition(order.id, "wartend", why or ("Der Bahnhof " .. entries[1].station .. " ist unbekannt.")) end
      local targets = {}
      for i = 2, #entries do
        for _, name in ipairs(role.stations.candidates(entries[i].station)) do targets[#targets + 1] = name end
      end
      order.start = { node = start.node, track = start.track }
      ask(start.node, "abfrage", { kind = "pruefen", track = start.track, targets = targets }, order, function(payload) handle_check_reply(order, payload) end)
    elseif state == "vorbereitet" then
      local train = role.register.get(order.train)
      ask(order.start.node, "auftrag", { kind = "fahrplan", orderId = order.id, track = order.start.track, train = train.create_name, schedule = order.schedule }, order,
        function(payload) handle_schedule_reply(order, payload) end)
    elseif state == "fahrplan_uebergeben" or (state == "am_ziel" and order.leg < #entries) then
      if order.retry_at and now() < order.retry_at then return end
      order.retry_at = nil
      local at = order.at or order.start
      local entry = { track = at.track }
      ask(at.node, "auftrag", release_message(order, entry, order.stay), order, function(payload) handle_release_reply(order, payload) end)
    elseif state == "am_ziel" and order.leg >= #entries then
      local at = order.at
      local train = role.register.get(order.train)
      ask(at.node, "auftrag", { kind = "warteauftrag", track = at.track, train = train.create_name, wait = 0, expect = order.schedule and schedulelib.hash(order.schedule) or nil }, order, function(payload) handle_wait_reply(order, payload) end)
    end
  end

  local function drive_all()
    -- Reihenfolge (12.2): Bevorzugte zuerst, aber wartende normale Auftraege holen auf
    local list = role.orders.active()
    local t = now()
    table.sort(list, function(a, b)
      local ra, rb = orderslib.rank(a, t), orderslib.rank(b, t)
      if ra ~= rb then return ra > rb end
      return a.number < b.number
    end)
    for _, order in ipairs(list) do
      local ok, err = pcall(drive, order)
      if not ok then notify("fehler", "Auftrag " .. order.id .. ": " .. tostring(err)) end
    end
  end

  -- Meldungen der Bahnhoefe --------------------------------------------------------------------------------------------------------------
  local function orders_of_train(train_name)
    local out = {}
    local train = role.register.by_create_name(train_name)
    if not train then return out end
    for _, order in ipairs(role.orders.active()) do
      if order.train == train.id then out[#out + 1] = order end
    end
    return out
  end

  local function on_arrival(m)
    local p = m.payload
    local where = p.node .. ":" .. p.track
    local train = set_position(p.train, "am_bahnhof", where, "meldung", p.t)
    if not train then
      if not unknown_seen[where .. ":" .. tostring(p.train)] then
        unknown_seen[where .. ":" .. tostring(p.train)] = true
        notify("warnung", "Unerwarteter Zug " .. tostring(p.train) .. " auf Gleis " .. p.track .. " (" .. p.node .. "). Er wird als Belegung beachtet, aber keinem Auftrag zugeordnet.")
      end
      return
    end
    for _, order in ipairs(orders_of_train(p.train)) do
      local template = role.orders.template(order.template)
      local entries = entries_of(template)
      if order.state == "unterwegs" then
        local expected = order.plan and order.plan[order.leg + 1]
        if expected and p.station_name == expected.station then
          order.leg = order.leg + 1
          order.at = { node = p.node, track = p.track }
          order.stay = p.stay
          order.min_stay = entries[order.leg] and entries[order.leg].wait or 0
          role.orders.save()
          role.orders.transition(order.id, "am_ziel", "Zielankunft bestaetigt: " .. tostring(p.station_name))
        else
          to_clarification(order, "Der Zug ist an einer unerwarteten Station angekommen: " .. tostring(p.station_name) .. ".")
        end
      end
    end
  end

  local function on_departure(m)
    local p = m.payload
    local where = p.node .. ":" .. p.track
    local train = role.register.by_create_name(p.train)
    if train then role.register.set_position(train.id, "unbekannt", nil, "meldung", p.t) end
    for _, order in ipairs(orders_of_train(p.train)) do
      if order.state == "abfahrt_freigegeben" and p.released then
        role.orders.transition(order.id, "unterwegs", "Abfahrt bestaetigt")
      elseif order.state == "vorbereitet" or order.state == "fahrplan_uebergeben" then
        to_clarification(order, "Der Zug ist ohne Freigabe abgefahren.")
      end
    end
  end

  local function on_vanished(m)
    local p = m.payload
    for _, order in ipairs(orders_of_train(p.train)) do
      if order.state == "abfahrt_freigegeben" or order.state == "fahrplan_uebergeben" or order.state == "vorbereitet" then
        to_clarification(order, "Der Zug ist nicht mehr am Bahnhof, aber die Abfahrt wurde nicht gemeldet.")
      end
    end
  end

  local function on_state(m)
    local p = m.payload
    for _, tr in ipairs(p.tracks or {}) do
      track_state[p.node .. ":" .. tr.id] = tr
      -- verlorene Abfahrts- oder Verschwindensmeldung: der Zustandsbericht traegt die letzte Abfahrt nach
      local exit = tr.last_exit
      if exit and not tr.present and exit.train then
        for _, order in ipairs(orders_of_train(exit.train)) do
          if order.stay == exit.stay and (order.state == "abfahrt_freigegeben" or order.state == "fahrplan_uebergeben" or order.state == "vorbereitet") then
            local pp = { node = p.node, track = tr.id, train = exit.train, released = exit.released, t = p.t }
            if exit.vanished then on_vanished({ payload = pp }) else on_departure({ payload = pp }) end
          end
        end
      end
      if tr.present and tr.train then
        local train = set_position(tr.train, "am_bahnhof", p.node .. ":" .. tr.id, "meldung", p.t)
        if not train and not unknown_seen[p.node .. ":" .. tr.id .. ":" .. tostring(tr.train)] then
          unknown_seen[p.node .. ":" .. tr.id .. ":" .. tostring(tr.train)] = true
          notify("warnung", "Unerwarteter Zug " .. tostring(tr.train) .. " auf Gleis " .. tr.id .. " (" .. p.node .. ").")
        end
        -- verpasste Ankunftsmeldung: der Zustand beweist die Ankunft
        for _, order in ipairs(orders_of_train(tr.train)) do
          if order.state == "unterwegs" then
            on_arrival({ payload = { node = p.node, track = tr.id, train = tr.train, station_name = tr.station_name, stay = tr.stay, t = p.t } })
          end
        end
      end
    end
  end

  local function on_hello(m)
    local p = m.payload
    nodes[p.node] = { name = p.name, roles = p.roles, tracks = p.tracks, last_seen = now(), active = p.active, revision = p.revision }
    silent_notified[p.node] = nil
    rebuild_dir()
    node.reply(m, "ok", {})
  end

  -- Anfragen von Bedien-Nodes ---------------------------------------------------------------------------------------------------------------
  local function handle_register(m)
    local p = m.payload
    local entry = dir[p.station_name or ""]
    -- "spaeter": der Bahnhof hat sich (noch) nicht gemeldet; die Anmeldestelle versucht es mit neuer Anfrage erneut
    if not entry then return node.reply(m, "spaeter", { grund = "Die Station " .. tostring(p.station_name) .. " ist der Leitstelle noch nicht bekannt." }) end
    if entry.ambiguous then return node.reply(m, "abgelehnt", { grund = "Die Station " .. tostring(p.station_name) .. " gehoert zu keinem eindeutigen Bahnhofs-Node." }) end
    if not reachable(entry.node) then return node.reply(m, "spaeter", { grund = "Der Node " .. entry.node .. " meldet sich nicht." }) end
    local req = { id = p.id, create_name = p.create_name, display_name = p.display_name, usage = p.usage, mode = p.mode, length = p.length }
    local ok, why = role.register.validate(req)
    if not ok then return node.reply(m, "abgelehnt", { grund = why }) end
    local function finish()
      req.evidence = { present = true, train_name = p.create_name, where = entry.node .. ":" .. entry.track, source = "abfrage", t = now() }
      local saved, err = role.register.register(req)
      if not saved then return node.reply(m, "abgelehnt", { grund = err }) end
      node.reply(m, "angenommen", { id = p.id })
      -- vereinbarter Warteauftrag; Uebergabe ist durch die Anmeldung vor Ort bestaetigt
      local train = role.register.get(p.id)
      ask(entry.node, "auftrag", { kind = "warteauftrag", track = entry.track, train = p.create_name, wait = 0, handover = true }, nil, function(payload)
        if payload.status == "uebergeben" then
          role.register.set_state(p.id, "gesteuert")
        else
          notify("warnung", "Zug " .. p.id .. ": Warteauftrag nicht erteilt (" .. tostring(payload.grund) .. ").")
        end
      end)
    end
    if p.current_name ~= p.create_name then
      ask(entry.node, "auftrag", { kind = "umbenennen", track = entry.track, from = p.current_name, to = p.create_name }, nil, function(payload)
        if payload.status == "ok" then finish() else node.reply(m, "abgelehnt", { grund = "Umbenennen nicht moeglich: " .. tostring(payload.grund) }) end
      end)
    else
      finish()
    end
  end

  local function handle_demand(m)
    local order, new = role.orders.request(m.payload.template, m.payload.requestId or m.requestId, { source = "bedarf" })
    if not order then return node.reply(m, "abgelehnt", { grund = new }) end
    node.reply(m, "angenommen", { order = order.id, state = order.state, neu = new })
    if new then drive_all() end
  end

  local function templates_info()
    local list = {}
    for _, template in ipairs(role.orders.templates()) do
      local active = role.orders.active_for(template.id)
      list[#list + 1] = {
        id = template.id, title = template.title, train = template.train, priority = template.priority,
        active = active and { id = active.id, state = active.state, reason = active.reason, unconfirmed = flags[active.id] and flags[active.id].unconfirmed or nil } or nil,
      }
    end
    return list
  end

  local function handle_templates_query(m)
    node.reply(m, "ok", { templates = templates_info() })
  end

  local function handle_cancel(m)
    local order = m.payload.order and role.orders.get(m.payload.order)
    if not order then return node.reply(m, "abgelehnt", { grund = "Unbekannter Auftrag." }) end
    local ok, text = role.orders.cancel(order.id)
    node.reply(m, ok and "angenommen" or "abgelehnt", { hinweis = text, grund = not ok and text or nil })
  end

  function role.on_message(m, status)
    -- ein verspaetetes "hallo" ist trotzdem eine gueltige Anmeldung des Nodes (Zustandsmeldungen holen den Rest nach)
    if status == "old_sequence" and m.messageType == "meldung" and m.payload.kind == "hallo" then return on_hello(m) end
    if status ~= "ok" then return end
    if m.messageType == "bestaetigung" and m.correlationId and pending[m.correlationId] then
      local p = pending[m.correlationId]
      pending[m.correlationId] = nil
      release_wait(p)
      if nodes[m.senderNodeId] then nodes[m.senderNodeId].last_seen = now() end
      if p.on_reply then
        local ok, err = pcall(p.on_reply, m.payload, m)
        if not ok then notify("fehler", "Antwort von " .. m.senderNodeId .. ": " .. tostring(err)) end
      end
      drive_all()
      return
    end
    if nodes[m.senderNodeId] then nodes[m.senderNodeId].last_seen = now() end
    if m.messageType == "meldung" then
      local kind = m.payload.kind
      if kind == "hallo" then on_hello(m)
      elseif kind == "zustand" then on_state(m)
      elseif kind == "ankunft" then on_arrival(m)
      elseif kind == "abfahrt" then on_departure(m)
      elseif kind == "zug_weg" then on_vanished(m)
      elseif kind == "zug_umbenannt" then
        notify("warnung", "Der Zug " .. tostring(m.payload.before) .. " heisst jetzt " .. tostring(m.payload.train) .. " (" .. tostring(m.payload.node) .. "): die Zuordnung ist ungeklaert.")
      end
      drive_all()
    elseif m.messageType == "auftrag" then
      local kind = m.payload.kind
      if kind == "anmelden" then handle_register(m)
      elseif kind == "bedarf" then handle_demand(m)
      elseif kind == "stornieren" then handle_cancel(m) end
    elseif m.messageType == "abfrage" then
      if m.payload.kind == "vorlagen" then handle_templates_query(m)
      elseif m.payload.kind == "tafel" then node.reply(m, "ok", { rows = role.board(m.payload.station), t = now() }) end
    end
  end

  -- Linien: jeder faellige Termin erzeugt hoechstens einen Fahrtwunsch (12.1) --------------------------------------------------------
  local function idle_train(line, template)
    local ids = #line.trains > 0 and line.trains or { template.train }
    -- Rundlauf: hinter dem zuletzt eingesetzten Zug weitersuchen
    local from = 1
    for i, id in ipairs(ids) do if id == line.last_train then from = i % #ids + 1 end end
    local first_name = template.stops[1].station
    local starts = {}
    for _, name in ipairs(role.stations.candidates(first_name)) do starts[name] = true end
    for k = 0, #ids - 1 do
      local id = ids[(from - 1 + k) % #ids + 1]
      local train = role.register.get(id)
      local busy = false
      for _, order in ipairs(role.orders.active()) do if order.train == id then busy = true end end
      if train and train.state == "gesteuert" and not busy then
        local pos = train.position
        if pos and pos.kind == "am_bahnhof" then
          for name in pairs(starts) do
            local entry = dir[name]
            if entry and pos.where == entry.node .. ":" .. entry.track then return train end
          end
        end
      end
    end
    return nil
  end

  local function run_lines()
    for _, line in ipairs(role.lines.due()) do
      local template = role.orders.template(line.template)
      local term = line.next_due
      local served = false
      if not template then
        role.lines.note(line.id, "Die Vorlage " .. line.template .. " gibt es nicht.")
      else
        local train = idle_train(line, template)
        if train then
          local order = role.orders.request(line.template, "linie-" .. line.id .. "-" .. term, { train = train.id, priority = line.priority, source = "linie" })
          served = order ~= nil
          if served then role.lines.used(line.id, train.id) end
          role.lines.note(line.id, order and ("Termin bedient: " .. order.id) or "Auftrag nicht angelegt.")
        else
          role.lines.note(line.id, "Termin ausgelassen: kein Zug bereit am Start.")
        end
      end
      local info = role.lines.advance(line.id, served)
      if info and info.skipped > 0 then notify("warnung", "Linie " .. line.id .. ": " .. info.skipped .. " Termine waehrend einer Unterbrechung ausgelassen (keine Nachholfahrten).") end
    end
  end

  -- Tafel: Plan (Termin der Linie) und Ist (Auftrag, Meldungen) getrennt (22, 10.3)
  function role.board(station)
    local rows = {}
    for _, line in ipairs(role.lines.list()) do
      local template = role.orders.template(line.template)
      local serves = station == nil
      if template and station then
        local names = {}
        for _, name in ipairs(role.stations.candidates(station)) do names[name] = true end
        for _, stop in ipairs(template.stops) do
          for _, name in ipairs(role.stations.candidates(stop.station)) do if names[name] or stop.station == station then serves = true end end
        end
      end
      if serves then
        local row = { line = line.id, title = line.title, interval = line.interval, next_due = line.next_due, in_seconds = line.next_due - now(), missed = line.missed, note = line.note, active = line.active, priority = line.priority }
        for _, order in ipairs(role.orders.active()) do
          local ot = role.orders.template(order.template)
          if ot and order.template == line.template and order.source == "linie" then
            row.order = { id = order.id, train = order.train, state = order.state, reason = order.reason, leg = order.leg, legs = #entries_of(ot) }
            break
          end
        end
        rows[#rows + 1] = row
      end
    end
    return rows
  end

  function role.tick()
    check_pending()
    run_lines()
    for id, info in pairs(nodes) do
      if now() - info.last_seen >= NODE_SILENT and not silent_notified[id] then
        silent_notified[id] = true
        notify("warnung", "Der Node " .. id .. " meldet sich nicht mehr.")
      end
    end
    drive_all()
  end

  -- fuer Tests und Seiten
  function role.info()
    return { nodes = nodes, dir = dir, track_state = track_state, pending = pending, flags = flags, samples = samples }
  end

  -- Mengenmuster: der Bediener legt in Create an einem Bahnhof einen Fahrplan mit einer Mengenbedingung (z.B. Weizen, Zahl 7) an;
  -- die Leitstelle liest ihn, findet die Zahl und merkt sich den Pfad. Ergebnis erscheint in role.sample_status.
  role.sample_status = nil
  function role.read_sample(station_name, value)
    local entry, why = locate(station_name)
    if not entry then role.sample_status = { kind = "halt", text = why } return nil, why end
    role.sample_status = { kind = "wait", text = "Fahrplan wird gelesen ..." }
    ask(entry.node, "abfrage", { kind = "lesen", track = entry.track }, nil, function(payload)
      if payload.status ~= "ok" then
        role.sample_status = { kind = "halt", text = "Lesen nicht moeglich: " .. tostring(payload.grund) }
        return
      end
      local cond = schedulelib.find_cargo(payload.schedule)
      if not cond then
        role.sample_status = { kind = "halt", text = "Im Fahrplan des Zuges " .. tostring(payload.train) .. " steht keine Mengenbedingung (nur Warten/Redstone)." }
        return
      end
      if cond.id ~= "create:item_threshold" then
        role.sample_status = { kind = "halt", text = "Die Bedingung ist " .. tostring(cond.id) .. ", gebraucht wird create:item_threshold (Fracht: Gegenstaende)." }
        return
      end
      local path, err = schedulelib.locate_unique(cond, value)
      if not path then role.sample_status = { kind = "halt", text = err } return end
      local ok, serr = role.set_sample("item_threshold", { condition = cond, path = path })
      role.sample_status = ok and { kind = "ok", text = "Muster gespeichert (Feld " .. table.concat(path, ".") .. ")." } or { kind = "halt", text = tostring(serr) }
    end)
    return true
  end

  function role.create_template(fields)
    local stops, err = orderslib.parse_stops(fields.stops)
    if not stops then return nil, err end
    local train = role.register.get(fields.train)
    if not train then return nil, "Der Zug " .. tostring(fields.train) .. " ist nicht angemeldet." end
    for _, stop in ipairs(stops) do
      if stop.cargo and not samples.item_threshold then return nil, "Fuer Mengenangaben fehlt das Muster (Seite Vorlagen, Muster erfassen)." end
    end
    local ok, e = role.orders.add_template({ id = fields.id, title = fields.title, train = fields.train, return_to_start = true, stops = stops })
    if not ok then return nil, e end
    return true
  end

  -- betriebliche Sperre eines Gleises (10.1): ein gesperrtes Gleis wird nicht als Ziel zugewiesen, ein Zug darauf bleibt unberuehrt
  function role.set_closed(create_name, value)
    local previous = closed[create_name]
    closed[create_name] = value and true or nil
    local ok, err = node.store.save(DATA .. "/gesperrt.lua", closed)
    if not ok then closed[create_name] = previous return nil, err end
    return true
  end
  function role.is_closed(create_name) return closed[create_name] == true end

  function role.set_sample(kind, sample)
    samples[kind] = sample
    return node.store.save(DATA .. "/muster.lua", samples)
  end

  -- offene Auftraege nach dem Neustart: Vorbereitung wiederholen, nie blind weiterfahren
  for _, order in ipairs(role.orders.active()) do
    if order.state == "vorbereitet" or order.state == "in_pruefung" then
      role.orders.transition(order.id, order.state == "in_pruefung" and "in_pruefung" or "in_pruefung", "nach Neustart neu geprueft")
    end
    if order.start and order.state ~= "angefordert" then
      -- Aufenthalt und Standort bleiben gespeichert; die Bahnhoefe melden sich neu
    end
  end

  -- Seiten -----------------------------------------------------------------------------------------------------------------------------
  local pages = {}
  local arm = { cancel = false }

  local STATE_TEXT = {
    angefordert = "angefordert", in_pruefung = "wird geprueft", wartend = "wartet", vorbereitet = "vorbereitet",
    fahrplan_uebergeben = "Fahrplan uebergeben", abfahrt_freigegeben = "Abfahrt freigegeben (noch nicht bestaetigt)",
    unterwegs = "unterwegs", am_ziel = "am Ziel", abgeschlossen = "abgeschlossen", klaerung = "KLAERUNG erforderlich",
    abgelehnt = "abgelehnt", storniert = "storniert",
  }
  local STATE_KIND = { klaerung = "halt", wartend = "wait", abgeschlossen = "ok", abgelehnt = "halt", storniert = "dim", abfahrt_freigegeben = "wait", am_ziel = "ok", unterwegs = "text" }

  pages[#pages + 1] = {
    id = "zuege", title = "Zuege",
    render = function(v, rect)
      local state = v.page_state("zuege")
      state.list = state.list or { index = 1 }
      local items = {}
      state.trains = {}
      for i, train in ipairs(role.register.list()) do
        local pos = train.position
        local where = pos and (pos.kind == "am_bahnhof" and ("am Bahnhof " .. tostring(pos.where)) or pos.kind) or "unbekannt"
        items[#items + 1] = { text = train.id .. " " .. train.display_name, detail = train.state .. ", " .. train.mode .. ", " .. where }
        state.trains[i] = train
      end
      W.list(v, "zuege", rect, items, state.list, { empty = "Noch kein Zug angemeldet (Rolle Anmeldung)." })
    end,
    actions = function(v)
      local state = v.page_state("zuege")
      local train = state.trains and state.trains[(state.list or { index = 1 }).index]
      return { { id = "abmelden", label = arm.unregister and "Wirklich?" or "Abmelden", kind = "danger", enabled = train ~= nil, reason = "Erst einen Zug waehlen." } }
    end,
    on_action = function(v, id)
      if id == "act:abmelden" then
        local state = v.page_state("zuege")
        local train = state.trains and state.trains[state.list.index]
        if not train then return true end
        for _, order in ipairs(role.orders.active()) do
          if order.train == train.id then
            v.hint = "Der Zug hat den aktiven Auftrag " .. order.id .. "."
            arm.unregister = false
            return true
          end
        end
        if not arm.unregister then
          arm.unregister = true
          v.hint = "Nochmal druecken: nur die Zustaendigkeit endet, nicht der Zug."
        else
          arm.unregister = false
          role.register.unregister(train.id)
          v.hint = "Abgemeldet; der Zug und seine Belegung bleiben bestehen."
        end
        return true
      end
    end,
  }

  pages[#pages + 1] = {
    id = "auftraege", title = "Auftraege",
    render = function(v, rect)
      local state = v.page_state("auftraege")
      state.list = state.list or { index = 1 }
      local items = {}
      state.orders = {}
      local all = role.orders.list()
      for i = #all, 1, -1 do
        local order = all[i]
        local template = role.orders.template(order.template)
        local text = STATE_TEXT[order.state] or order.state
        if flags[order.id] and flags[order.id].unconfirmed then text = text .. " - Rueckmeldung fehlt" end
        items[#items + 1] = { text = order.id .. " " .. (template and template.title or order.template), detail = text .. (order.reason and (": " .. order.reason) or ""), kind = STATE_KIND[order.state] or "text" }
        state.orders[#items] = order
      end
      W.list(v, "auftraege", rect, items, state.list, { empty = "Noch keine Auftraege." })
    end,
    actions = function(v)
      local state = v.page_state("auftraege")
      local order = state.orders and state.orders[(state.list or { index = 1 }).index]
      local terminal = order and (order.state == "abgeschlossen" or order.state == "abgelehnt" or order.state == "storniert")
      return {
        { id = "stornieren", label = arm.cancel and "Wirklich?" or "Abbrechen", kind = "danger", enabled = order ~= nil and not terminal, reason = "Kein laufender Auftrag gewaehlt." },
        { id = "neu_pruefen", label = "Neu pruefen", kind = "secondary", enabled = order ~= nil and (order.state == "klaerung" or order.state == "wartend"), reason = "Nur fuer wartende Auftraege und Klaerungen." },
      }
    end,
    on_action = function(v, id)
      local state = v.page_state("auftraege")
      local order = state.orders and state.orders[state.list.index]
      if id == "act:stornieren" and order then
        if not arm.cancel then
          arm.cancel = true
          v.hint = "Nochmal druecken. Vor der Fahrplanuebergabe wird storniert, danach ist es nur ein Aenderungswunsch."
        else
          arm.cancel = false
          local ok, text = role.orders.cancel(order.id)
          v.hint = ok and text or text
        end
        return true
      elseif id == "act:neu_pruefen" and order then
        role.orders.transition(order.id, "in_pruefung", "vom Bediener neu angestossen")
        drive_all()
        return true
      end
    end,
  }

  pages[#pages + 1] = {
    id = "netz", title = "Netz",
    render = function(v, rect)
      local state = v.page_state("netz")
      state.list = state.list or { index = 1 }
      local items = {}
      local ids = {}
      for id in pairs(nodes) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local info = nodes[id]
        local ok = reachable(id)
        local tracks = {}
        for _, tr in ipairs(info.tracks or {}) do
          local st = track_state[id .. ":" .. tr.id]
          tracks[#tracks + 1] = tr.name .. (st and st.present and (":" .. tostring(st.train)) or "")
        end
        items[#items + 1] = { text = id .. " " .. (info.name or ""), detail = (ok and "erreichbar" or "NICHT ERREICHBAR") .. ", " .. #tracks .. " Gleise" .. (#tracks > 0 and (": " .. table.concat(tracks, ",")) or ""), kind = ok and "ok" or "halt" }
      end
      W.list(v, "netz", rect, items, state.list, { empty = "Noch kein Node hat sich gemeldet." })
    end,
  }

  pages[#pages + 1] = {
    id = "vorlagen", title = "Vorlagen",
    render = function(v, rect)
      local state = v.page_state("vorlagen")
      state.list = state.list or { index = 1 }
      state.screen = state.screen or "liste"
      state.fields = state.fields or {
        id = { value = "", max = 16 }, title = { value = "", max = 30 }, train = { value = "", max = 16 }, stops = { value = "", max = 120 },
        station = { value = "", max = 40 }, count = { value = "7", max = 6 },
      }
      if state.screen == "liste" then
        local items = {}
        state.templates = {}
        for i, info in ipairs(templates_info()) do
          items[#items + 1] = { text = info.title .. (info.priority == "bevorzugt" and " (bevorzugt)" or ""), detail = info.active and ("Auftrag " .. info.active.id .. ": " .. (STATE_TEXT[info.active.state] or info.active.state)) or ("Zug " .. info.train), kind = info.active and "wait" or "dim" }
          state.templates[i] = info
        end
        W.list(v, "vorlagen", rect, items, state.list, { empty = "Noch keine Vorlage. Mit 'Neue Vorlage' anlegen." })
      elseif state.screen == "neu1" then
        W.label(v, rect.x + 1, rect.y, "Neue Vorlage (1/2)", "hell")
        W.field(v, "id", rect.x + 1, rect.y + 2, math.min(24, rect.w - 2), "Kennung (z.B. weizen)", state.fields.id)
        W.field(v, "title", rect.x + 1, rect.y + 5, math.min(34, rect.w - 2), "Titel (z.B. Weizen liefern)", state.fields.title)
      elseif state.screen == "neu2" then
        W.label(v, rect.x + 1, rect.y, "Neue Vorlage (2/2)", "hell")
        W.field(v, "train", rect.x + 1, rect.y + 2, math.min(24, rect.w - 2), "Zug (Kennung, angemeldet)", state.fields.train)
        W.field(v, "stops", rect.x + 1, rect.y + 5, rect.w - 2, "Halte: Bahnhof:Sekunden:Menge; naechster ...", state.fields.stops)
        W.label(v, rect.x + 1, rect.y + 8, "Beispiel: Weizenhof:5:640; Zentrallager:3", "dim", rect.w - 2)
        W.label(v, rect.x + 1, rect.y + 9, "Danach faehrt der Zug zum ersten Halt zurueck.", "dim", rect.w - 2)
      elseif state.screen == "muster" then
        W.label(v, rect.x + 1, rect.y, "Mengenmuster erfassen", "hell")
        W.label(v, rect.x + 1, rect.y + 1, "Lege in Create am Bahnhof einen Fahrplan mit einer Fracht-", "dim", rect.w - 2)
        W.label(v, rect.x + 1, rect.y + 2, "bedingung (Gegenstand, Menge) an, z.B. Weizen, Menge 7.", "dim", rect.w - 2)
        W.field(v, "station", rect.x + 1, rect.y + 4, math.min(34, rect.w - 2), "Bahnhof, an dem der Zug steht (Create-Name)", state.fields.station)
        W.field(v, "count", rect.x + 1, rect.y + 7, 10, "Die Zahl, die du eingestellt hast", state.fields.count)
        if role.sample_status then W.label(v, rect.x + 1, rect.y + 10, role.sample_status.text, role.sample_status.kind, rect.w - 2) end
        if samples.item_threshold and not role.sample_status then W.label(v, rect.x + 1, rect.y + 10, "Ein Muster ist gespeichert.", "ok", rect.w - 2) end
      end
    end,
    actions = function(v)
      local state = v.page_state("vorlagen")
      local screen = state.screen or "liste"
      if screen == "liste" then
        local info = state.templates and state.templates[(state.list or { index = 1 }).index]
        return {
          { id = "anfordern", label = "Anfordern", enabled = info ~= nil, reason = "Erst eine Vorlage waehlen." },
          { id = "neu", label = "Neu", kind = "secondary" },
          { id = "prio", label = "Prio", kind = "secondary", enabled = info ~= nil, reason = "Erst eine Vorlage waehlen." },
          { id = "muster", label = "Muster", kind = "secondary" },
        }
      elseif screen == "muster" then
        return { { id = "lesen", label = "Fahrplan lesen", side = "rechts" }, { id = "vl_zurueck", label = "Fertig", kind = "secondary", side = "rechts" } }
      end
      return {
        { id = screen == "neu2" and "vl_speichern" or "vl_weiter", label = screen == "neu2" and "Speichern" or "Weiter", side = "rechts" },
        { id = "vl_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" },
      }
    end,
    on_action = function(v, id)
      local state = v.page_state("vorlagen")
      local f = state.fields
      if id == "act:anfordern" then
        local info = state.templates and state.templates[state.list.index]
        if not info then return true end
        local order, new = role.orders.request(info.id, nil)
        v.hint = order and ((new and "Auftrag " or "Laeuft schon: ") .. order.id) or tostring(new)
        drive_all()
        return true
      elseif id == "act:neu" then
        f.id.value, f.title.value, f.train.value, f.stops.value = "", "", "", ""
        state.screen = "neu1"
        return true
      elseif id == "act:prio" then
        local info = state.templates and state.templates[state.list.index]
        if info then
          local ok, err = role.orders.set_priority(info.id, info.priority == "bevorzugt" and "normal" or "bevorzugt")
          v.hint = ok and ("Prioritaet: " .. (info.priority == "bevorzugt" and "normal" or "bevorzugt")) or err
        end
        return true
      elseif id == "act:muster" then
        role.sample_status = nil
        state.screen = "muster"
        return true
      elseif id == "act:lesen" then
        local ok, why = role.read_sample(f.station.value, f.count.value)
        if not ok then v.hint = why end
        return true
      elseif id == "act:vl_weiter" then
        if f.id.value == "" or f.title.value == "" then v.hint = "Kennung und Titel sind noetig." return true end
        state.screen = "neu2"
        return true
      elseif id == "act:vl_zurueck" then
        state.screen = (state.screen == "neu2") and "neu1" or "liste"
        return true
      elseif id == "act:vl_speichern" then
        local ok, err = role.create_template({ id = f.id.value, title = f.title.value, train = f.train.value, stops = f.stops.value })
        if ok then
          v.hint = "Vorlage gespeichert."
          state.screen = "liste"
        else
          v.hint = err
        end
        return true
      end
    end,
  }

  -- Bahnhoefe mit mehreren Gleisen ---------------------------------------------------------------------------------------------------
  pages[#pages + 1] = forms.page({
    id = "bahnhoefe", title = "Bahnhoefe", empty = "Noch kein Bahnhof mit mehreren Gleisen. Einzelne Gleise brauchen keinen Eintrag.",
    new_label = "Neu",
    items = function()
      local items, records = {}, {}
      for i, g in ipairs(role.stations.list()) do
        local parts = {}
        for _, member in ipairs(g.members) do parts[#parts + 1] = member .. (closed[member] and " (gesperrt)" or "") end
        items[i] = { text = g.name, detail = table.concat(parts, ", ") }
        records[i] = g
      end
      return items, records
    end,
    fields = {
      { id = "name", label = "Name (z.B. Hauptbahnhof)", max = 30, width = 34 },
      { id = "members", label = "Gleise (Create-Namen mit ; trennen)", max = 160, width = 48 },
    },
    edit = function(g) return { name = g.name, members = table.concat(g.members, "; ") } end,
    on_save = function(values)
      local members = {}
      for part in (values.members or ""):gmatch("[^;]+") do
        local name = part:match("^%s*(.-)%s*$")
        if name ~= "" then members[#members + 1] = name end
      end
      return role.stations.set(values.name, members)
    end,
    extra = {
      { id = "loeschen", label = "Loeschen", kind = "danger", run = function(v, g) local ok, err = role.stations.remove(g.name) return ok and "Bahnhof geloescht (die Gleise bleiben)." or err end },
      { id = "sperren", label = "Sperre", run = function(v, g)
          local name = g.members[1]
          local ok, err = role.set_closed(name, not closed[name])
          return ok and (name .. (closed[name] and " ist gesperrt." or " ist frei.")) or err
        end },
    },
  })

  -- Linien im Takt -------------------------------------------------------------------------------------------------------------------
  pages[#pages + 1] = forms.page({
    id = "linien", title = "Linien", empty = "Noch keine Linie. Eine Linie fuehrt eine Vorlage im Takt aus.", new_label = "Neu",
    items = function()
      local items, records = {}, {}
      for i, line in ipairs(role.lines.list()) do
        local text = line.title .. " alle " .. line.interval .. " s" .. (line.priority == "bevorzugt" and " (bevorzugt)" or "") .. (line.active and "" or " [aus]")
        local detail = "naechster Termin in " .. math.max(0, math.floor(line.next_due - now())) .. " s, ausgelassen " .. line.missed
        if line.note then detail = detail .. ": " .. line.note end
        items[i] = { text = text, detail = detail, kind = line.active and "text" or "dim" }
        records[i] = line
      end
      return items, records
    end,
    fields = {
      { id = "id", label = "Kennung (z.B. pendel)", max = 16, width = 24 },
      { id = "title", label = "Titel", max = 30, width = 34 },
      { id = "template", label = "Vorlage (Kennung)", max = 16, width = 24 },
      { id = "trains", label = "Zuege (Kennungen mit ; trennen)", max = 80, width = 48 },
      { id = "interval", label = "Takt in Sekunden (Betriebszeit)", max = 6, width = 12, default = "300" },
      { id = "priority", label = "Prioritaet: normal oder bevorzugt", max = 10, width = 14, default = "normal" },
    },
    edit = function(line) return { id = line.id, title = line.title, template = line.template, trains = table.concat(line.trains, "; "), interval = line.interval, priority = line.priority } end,
    on_save = function(values)
      local trains = {}
      for part in (values.trains or ""):gmatch("[^;]+") do
        local id = part:match("^%s*(.-)%s*$")
        if id ~= "" then trains[#trains + 1] = id end
      end
      for _, id in ipairs(trains) do
        if not role.register.get(id) then return nil, "Der Zug " .. id .. " ist nicht angemeldet." end
      end
      if not role.orders.template(values.template) then return nil, "Die Vorlage " .. tostring(values.template) .. " gibt es nicht." end
      return role.lines.set({ id = values.id, title = values.title, template = values.template, trains = trains, interval = tonumber(values.interval), priority = values.priority ~= "" and values.priority or "normal" })
    end,
    extra = {
      { id = "aus", label = "Ein/Aus", run = function(v, line)
          line.active = not line.active
          role.lines.save()
          return line.active and "Linie laeuft." or "Linie angehalten: keine neuen Termine."
        end },
      { id = "loeschen", label = "Loeschen", kind = "danger", run = function(v, line) local ok, err = role.lines.remove(line.id) return ok and "Linie geloescht (laufende Auftraege bleiben)." or err end },
    },
  })

  -- Tafel: Plan und Ist getrennt ------------------------------------------------------------------------------------------------------
  pages[#pages + 1] = {
    id = "tafel", title = "Tafel",
    render = function(v, rect)
      local rows = role.board()
      if #rows == 0 then
        W.label(v, rect.x + 1, rect.y + 1, "Noch keine Linie. Die Tafel zeigt Plan (Termin) und Ist (Zug) getrennt.", "dim", rect.w - 2)
        return
      end
      local y = rect.y
      for _, row in ipairs(rows) do
        if y + 1 > rect.y + rect.h - 1 then break end
        W.label(v, rect.x + 1, y, row.title .. (row.active and "" or " [aus]"), "hell", rect.w - 2)
        W.label(v, rect.x + 1, y + 1, "Plan:  naechster Termin in " .. math.max(0, math.floor(row.in_seconds)) .. " s (alle " .. row.interval .. " s)" .. (row.missed > 0 and (", ausgelassen " .. row.missed) or ""), "text", rect.w - 2)
        local ist = "kein Zug unterwegs"
        local kind = "dim"
        if row.order then
          ist = row.order.train .. ": " .. (STATE_TEXT[row.order.state] or row.order.state) .. " (Halt " .. math.min(row.order.leg, row.order.legs) .. "/" .. row.order.legs .. ")"
          kind = STATE_KIND[row.order.state] or "text"
        end
        if y + 2 <= rect.y + rect.h - 1 then W.label(v, rect.x + 1, y + 2, "Ist:   " .. ist, kind, rect.w - 2) end
        y = y + 4
      end
    end,
  }

  role.pages = pages
  return role
end

return M
