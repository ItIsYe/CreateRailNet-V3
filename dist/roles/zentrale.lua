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
local MAX_TRIES = 12         -- bei Verlusten bleibt der Auftrag lange offen ("Rueckmeldung fehlt"), statt vorschnell zur Klaerung zu werden
local RETRY_WAITING = 10      -- Sekunden bis ein wartender Auftrag neu geprueft wird
local EVENT_KINDS = { ankunft = true, abfahrt = true, zug_weg = true, zug_umbenannt = true }
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
  local operation = node.store.load(DATA .. "/betrieb.lua") or { hold = false }    -- Wartung/Stoerung: neue Abfahrten zurueckhalten
  local retired = node.store.load(DATA .. "/stillgelegt.lua") or {}                -- Node-Kennung -> true: ausdruecklich stillgelegt (Ersatz)
  local later = {}                                                                 -- { at, fn }: spaetere Wiederholungen (z.B. Node gleicht sich noch ab)
  local closed = node.store.load(DATA .. "/gesperrt.lua") or {}    -- Create-Bahnhofsname -> true (betriebliche Sperre)

  local nodes = {}        -- node_id -> { name, roles, tracks = {...}, last_seen, active }
  local dir = {}          -- Bahnhofsname -> { node, track, ambiguous }
  local track_state = {}  -- "node:gleis" -> letzter Zustandsbericht
  local signal_state = {} -- node -> { t, signals = {...} } (Meldung "signale")
  local knoten_state = {} -- node -> { t, uses = {...} }
  local pending = {}      -- messageId -> { m, order, sent, tries, on_reply }
  local waiting = {}      -- Auftrag -> true, solange eine Anfrage offen ist
  local flags = {}        -- Auftrag -> { unconfirmed = true }
  local unknown_seen = {}
  local seen_stay = {}        -- "node:gleis" -> hoechster verarbeiteter Aufenthalt (spaet eintreffende alte Ereignisse bewirken nichts)
  local boots = {}            -- node -> Startkennung der zuletzt gesehenen Nachricht
  local unknown_trains = {}   -- Name -> { node, track, since, last, present } (fremde Zuege: Belegung, keine Zuordnung)
  local silent_notified = {}

  local function notify(level, text) node.notify(level, text) end

  -- Neue Abfahrten sind zurueckgehalten, wenn der Bediener es verlangt (Wartung, Stoerung) oder die Umgebung sich geaendert hat (14.1)
  local function held()
    if operation.hold then return true, operation.reason or "vom Bediener" end
    if node.env_hold then return true, "Umgebung geaendert: Schnittstellen pruefen" end
    return false
  end

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

  -- Antworten auf eine Anfrage gelten nur, solange der Auftrag noch im Zustand und auf dem Abschnitt ist, fuer den sie gestellt wurde
  -- (eine verspaetete Antwort auf eine wiederholte Anfrage darf nichts zuruecksetzen)
  local function guarded(order, fn)
    local state, leg = order.state, order.leg
    return function(payload)
      if order.state ~= state or order.leg ~= leg then return end
      return fn(payload)
    end
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
    local tstate = track_state[entry.node .. ":" .. entry.track]
    if tstate and tstate.available == false then return { problem = "Geraet nicht verfuegbar" } end
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
    if train.state ~= "gesteuert" or train.mode == "manuell" then
      return role.orders.transition(order.id, "abgelehnt", "Der Zug " .. train.id .. " ist nicht im gesteuerten Betrieb (" .. train.state .. ", " .. tostring(train.mode) .. ").")
    end
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
    order.arrivals = { [order.start.node .. ":" .. order.start.track] = payload.stay }
    order.leg = 1
    order.min_stay = entries[1].wait or 0
    role.orders.save()
    role.orders.transition(order.id, "vorbereitet", "Zug und Auftrag sind zugeordnet")
  end

  local function handle_schedule_reply(order, payload)
    if payload.status == "zurueckgestellt" then
      order.retry_at = now() + (payload.retry_in or 5)
      return
    end
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
    local template = role.orders.template(order.template)
    if payload.status == "uebergeben" then
      if template and template.kind == "abstellen" then
        if train then role.register.set_state(train.id, "abgestellt") end
        role.orders.transition(order.id, "abgeschlossen", "Abgestellt, Warteauftrag erteilt")
      else
        if train then role.register.set_state(train.id, "gesteuert") end
        role.orders.transition(order.id, "abgeschlossen", "Rueckkehr bestaetigt, Warteauftrag erteilt")
      end
    elseif payload.status == "zurueckgestellt" then
      order.retry_at = now() + (payload.retry_in or 5)       -- der Node gleicht sich noch mit der Leitstelle ab
    else
      to_clarification(order, "Warteauftrag am Ziel nicht erteilt: " .. tostring(payload.grund))
    end
  end

  drive = function(order)
    if waiting[order.id] then return end
    local template = role.orders.template(order.template)
    if not template then return role.orders.transition(order.id, "abgelehnt", "Die Vorlage gibt es nicht mehr.") end
    local state = order.state
    -- zurueckgehalten: Fahrplanuebergabe und Freigaben bleiben aus; Pruefungen, Fahrten und Abschluss laufen weiter
    if held() then
      local entries_n = #template.stops + ((template.return_to_start ~= false) and 1 or 0)
      if state == "vorbereitet" or state == "fahrplan_uebergeben" or (state == "am_ziel" and order.leg < entries_n) then return end
    end
    if order.retry_at and now() < order.retry_at and (state == "vorbereitet" or state == "am_ziel") then return end
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
      ask(start.node, "abfrage", { kind = "pruefen", track = start.track, targets = targets }, order, guarded(order, function(payload) handle_check_reply(order, payload) end))
    elseif state == "vorbereitet" then
      local train = role.register.get(order.train)
      ask(order.start.node, "auftrag", { kind = "fahrplan", orderId = order.id, track = order.start.track, train = train.create_name, schedule = order.schedule }, order,
        guarded(order, function(payload) handle_schedule_reply(order, payload) end))
    elseif state == "fahrplan_uebergeben" or (state == "am_ziel" and order.leg < #entries) then
      if order.retry_at and now() < order.retry_at then return end
      order.retry_at = nil
      local at = order.at or order.start
      local entry = { track = at.track }
      ask(at.node, "auftrag", release_message(order, entry, order.stay), order, guarded(order, function(payload) handle_release_reply(order, payload) end))
    elseif state == "am_ziel" and order.leg >= #entries then
      local at = order.at
      local train = role.register.get(order.train)
      ask(at.node, "auftrag", { kind = "warteauftrag", track = at.track, train = train.create_name, wait = 0, expect = order.schedule and schedulelib.hash(order.schedule) or nil }, order, guarded(order, function(payload) handle_wait_reply(order, payload) end))
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

  local function remember_unknown(name, node_id, track_id, present, t)
    if not name then return end
    local entry = unknown_trains[name]
    if not entry then
      entry = { since = t or now() }
      unknown_trains[name] = entry
    end
    entry.node, entry.track, entry.last, entry.present = node_id, track_id, t or now(), present
  end

  local function on_arrival(m)
    local p = m.payload
    local where = p.node .. ":" .. p.track
    -- eine verspaetete Meldung eines frueheren Aufenthalts darf die Position nicht zuruecksetzen
    local stale = p.stay ~= nil and seen_stay[where] ~= nil and p.stay < seen_stay[where]
    if p.stay then seen_stay[where] = math.max(seen_stay[where] or 0, p.stay) end
    local train = (not stale) and set_position(p.train, "am_bahnhof", where, "meldung", p.t) or role.register.by_create_name(p.train)
    if not train then
      remember_unknown(p.train, p.node, p.track, true, p.t)
      if not unknown_seen[where .. ":" .. tostring(p.train)] then
        unknown_seen[where .. ":" .. tostring(p.train)] = true
        notify("warnung", "Unerwarteter Zug " .. tostring(p.train) .. " auf Gleis " .. p.track .. " (" .. p.node .. "). Er wird als Belegung beachtet, aber keinem Auftrag zugeordnet.")
      end
      return
    end
    for _, order in ipairs(orders_of_train(p.train)) do
      local template = role.orders.template(order.template)
      local entries = entries_of(template)
      order.arrivals = order.arrivals or {}
      local done = order.arrivals[where]
      if order.state == "unterwegs" and not (p.stay ~= nil and done ~= nil and p.stay <= done) then
        local expected = order.plan and order.plan[order.leg + 1]
        if expected and p.station_name == expected.station then
          order.leg = order.leg + 1
          order.at = { node = p.node, track = p.track }
          order.stay = p.stay
          order.arrivals[where] = p.stay
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
    if not train and unknown_trains[p.train] then remember_unknown(p.train, p.node, p.track, false, p.t) end
    for _, order in ipairs(orders_of_train(p.train)) do
      local at_ = order.at or order.start
      local stale = order.state == "abfahrt_freigegeben" and ((p.stay ~= nil and order.stay ~= nil and p.stay ~= order.stay) or (at_ ~= nil and (at_.node ~= p.node or at_.track ~= p.track)))
      if stale then
        -- Abfahrt eines frueheren Aufenthalts: bewirkt nichts
      elseif order.state == "abfahrt_freigegeben" and p.released then
        role.orders.transition(order.id, "unterwegs", "Abfahrt bestaetigt")
      elseif p.released and p.stay ~= nil and p.stay == order.stay and (order.state == "fahrplan_uebergeben" or order.state == "am_ziel")
        and (function() local at = order.at or order.start return at ~= nil and at.node == p.node and at.track == p.track end)() then
        -- die Freigabe-Antwort ging verloren, die Abfahrt mit gesetzter Freigabe des Bahnhofs belegt sie
        role.orders.transition(order.id, "abfahrt_freigegeben", "Freigabe durch die Abfahrtsmeldung belegt")
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
      -- Geraet des Bahnhofs verschwunden: das Gleis ist ungeklaert; keine Fahrplanaenderung auf Verdacht (14.1)
      if tr.available == false then
        local where = p.node .. ":" .. tr.id
        for _, train in ipairs(role.register.list()) do
          if train.position and train.position.kind == "am_bahnhof" and train.position.where == where then
            role.register.set_position(train.id, "unbekannt", nil, "meldung", p.t)
          end
        end
        for _, order in ipairs(role.orders.active()) do
          local at = order.at or order.start
          if at and at.node == p.node and at.track == tr.id and (order.state == "fahrplan_uebergeben" or order.state == "abfahrt_freigegeben" or order.state == "vorbereitet") then
            to_clarification(order, "Das Geraet am Gleis " .. tostring(tr.name) .. " ist nicht verfuegbar: Lage klaeren.")
          end
        end
      end
      -- fremde Zuege, die laut Zustandsbericht nicht mehr am Gleis stehen (auch ohne Abfahrtsmeldung oder nach Umbenennung)
      for name, e in pairs(unknown_trains) do
        if e.present and e.node == p.node and e.track == tr.id and (not tr.present or tr.train ~= name) then e.present = false end
      end
      -- verlorene Abfahrts- oder Verschwindensmeldung: der Zustandsbericht traegt die letzte Abfahrt nach
      local exit = tr.last_exit
      if exit and not tr.present and exit.train then
        for _, order in ipairs(orders_of_train(exit.train)) do
          if order.stay == exit.stay and (order.state == "abfahrt_freigegeben" or order.state == "fahrplan_uebergeben" or order.state == "vorbereitet") then
            local pp = { node = p.node, track = tr.id, train = exit.train, released = exit.released, stay = exit.stay, t = p.t }
            if exit.vanished then on_vanished({ payload = pp }) else on_departure({ payload = pp }) end
          end
        end
      end
      if tr.present and tr.train then
        local train = set_position(tr.train, "am_bahnhof", p.node .. ":" .. tr.id, "meldung", p.t)
        if not train then remember_unknown(tr.train, p.node, tr.id, true, p.t) end
        if not train and not unknown_seen[p.node .. ":" .. tr.id .. ":" .. tostring(tr.train)] then
          unknown_seen[p.node .. ":" .. tr.id .. ":" .. tostring(tr.train)] = true
          notify("warnung", "Unerwarteter Zug " .. tostring(tr.train) .. " auf Gleis " .. tr.id .. " (" .. p.node .. ").")
        end
        -- verpasste Ankunftsmeldung: der Zustand beweist die Ankunft (nur wenn dieser Aufenthalt noch nicht verarbeitet ist)
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
    local old = nodes[p.node]
    nodes[p.node] = { name = p.name, roles = p.roles, tracks = p.tracks, last_seen = now(), active = p.active, revision = p.revision, signals = old and old.signals }
    silent_notified[p.node] = nil
    rebuild_dir()
    node.reply(m, "ok", {})
  end

  -- Ein Signal-Node mit hunderten Signalen meldet in Teilen (first = Startposition, total = Gesamtzahl): jeder Teil wird an seine Stelle gesetzt.
  -- Ohne first kommt die ganze Liste (aelteres Format). Fehlende Teile bleiben Luecken, bis der naechste vollstaendige Durchlauf sie fuellt.
  local MAX_SIGNALS = 5000
  local function merge_slice(list, p)
    local incoming = p.signals or {}
    if p.first == nil then return incoming end
    local first, total = p.first, p.total or (p.first + #incoming - 1)
    if type(first) ~= "number" or type(total) ~= "number" or first < 1 or total < 0 or first ~= math.floor(first) or total ~= math.floor(total)
      or first > MAX_SIGNALS or total > MAX_SIGNALS then
      return list
    end
    list = list or {}
    for i, sg in ipairs(incoming) do
      if first + i - 1 <= MAX_SIGNALS then list[first + i - 1] = sg end
    end
    for i = total + 1, math.max(list.n or 0, #list) do list[i] = nil end
    list.n = total
    return list
  end

  -- Signal-Nodes melden sich getrennt (ein Computer kann Bahnhof und Signale tragen)
  local function on_hello_signals(m)
    local p = m.payload
    local entry = nodes[p.node]
    if not entry then
      entry = { name = p.name or p.node, roles = p.roles or {}, tracks = {}, last_seen = now(), active = p.active, revision = p.revision, provisional = p.name == nil or nil }
      nodes[p.node] = entry
    elseif p.name ~= nil and entry.provisional then
      -- der erste Teil kam nach einem spaeteren Teil an: jetzt stimmen die Angaben des Nodes
      entry.name, entry.roles, entry.active, entry.revision, entry.provisional = p.name, p.roles or {}, p.active, p.revision, nil
    end
    entry.last_seen = now()
    entry.roles = entry.roles or p.roles
    entry.signals = merge_slice(entry.signals, p)
    silent_notified[p.node] = nil
    if (p.first or 1) == 1 then node.reply(m, "ok", {}) end
  end

  local function on_signals(m)
    local p = m.payload
    local entry = signal_state[p.node] or { signals = {} }
    entry.t = now()
    entry.signals = merge_slice(entry.signals, p)
    signal_state[p.node] = entry
    for _, sg in ipairs(p.signals or {}) do
      if sg.invalid and not unknown_seen["inv:" .. p.node .. sg.id] then
        unknown_seen["inv:" .. p.node .. sg.id] = true
        notify("fehler", "Signal " .. tostring(sg.track_name) .. " (" .. p.node .. ") meldet INVALID: Bereich gestoert.")
      elseif not sg.invalid then
        unknown_seen["inv:" .. p.node .. sg.id] = nil
      end
    end
  end

  local function on_knoten(m)
    knoten_state[m.payload.node] = { t = now(), uses = m.payload.uses }
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
      unknown_trains[p.current_name] = nil              -- jetzt registriert, nicht mehr fremd
      unknown_trains[p.create_name] = nil
      -- vereinbarter Warteauftrag; Uebergabe ist durch die Anmeldung vor Ort bestaetigt
      role.adopt(p.id, entry.node, entry.track)
    end
    if p.current_name ~= p.create_name then
      ask(entry.node, "auftrag", { kind = "umbenennen", track = entry.track, from = p.current_name, to = p.create_name }, nil, function(payload)
        if payload.status == "ok" then finish()
        elseif payload.status == "zurueckgestellt" then node.reply(m, "spaeter", { grund = "Der Bahnhof gleicht sich noch mit der Leitstelle ab." })
        else node.reply(m, "abgelehnt", { grund = "Umbenennen nicht moeglich: " .. tostring(payload.grund) }) end
      end)
    else
      finish()
    end
  end

  -- Anforderung einer Vorlage: nur fuer Zuege im gesteuerten Betrieb (7.3, 7.4)
  function role.demand(template_id, request_id, extra)
    local is_held, why = held()
    if is_held then return nil, "Der Betrieb ist zurueckgehalten (" .. why .. "): neue Fahrten werden nicht angenommen." end
    local template = role.orders.template(template_id)
    if template then
      local train = role.register.get((extra and extra.train) or template.train)
      if train and train.state ~= "gesteuert" then return nil, "Der Zug " .. train.id .. " ist nicht im gesteuerten Betrieb (" .. train.state .. ")." end
      if train and train.mode == "manuell" then return nil, "Der Zug " .. train.id .. " wird manuell gefahren und bekommt keine automatischen Auftraege." end
    end
    return role.orders.request(template_id, request_id, extra)
  end

  local function handle_demand(m)
    local order, new = role.demand(m.payload.template, m.payload.requestId or m.requestId, { source = "bedarf" })
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
    -- ein Berichtsteil der Signalliste (hallo_signale) ist unveraenderliche Stammdaten: auch verspaetet an seine Stelle setzen
    if status == "old_sequence" and m.messageType == "meldung" and m.payload.kind == "hallo_signale" then return on_hello_signals(m) end
    -- Ereignismeldungen gelten auch verspaetet (sie werden vom Bahnhof wiederholt, bis sie bestaetigt sind)
    if status == "old_sequence" and m.messageType == "meldung" and EVENT_KINDS[m.payload.kind] then status = "ok" end
    if status ~= "ok" then return end
    if retired[m.senderNodeId] then
      -- stillgelegt: nur die Anmeldung wird beantwortet (mit Hinweis), sonst nichts
      if m.messageType == "meldung" and (m.payload.kind == "hallo" or m.payload.kind == "hallo_signale") then node.reply(m, "ok", { stillgelegt = true }) end
      return
    end
    -- neuer Start des Absenders: seine Aufenthaltszaehler koennen von vorn beginnen (z.B. nach Ersatz des Computers)
    local boot = tostring(m.messageId):match("^[^:]*:([^:]*):")
    if boot and boots[m.senderNodeId] ~= boot then
      boots[m.senderNodeId] = boot
      for key in pairs(seen_stay) do
        if key:sub(1, #m.senderNodeId + 1) == m.senderNodeId .. ":" then seen_stay[key] = nil end
      end
    end
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
      elseif kind == "hallo_signale" then on_hello_signals(m)
      elseif kind == "signale" then on_signals(m)
      elseif kind == "knoten" then on_knoten(m)
      elseif kind == "konfig" then role.on_config(m)
      elseif kind == "zustand" then on_state(m)
      elseif kind == "ankunft" then on_arrival(m)
      elseif kind == "abfahrt" then on_departure(m)
      elseif kind == "zug_weg" then on_vanished(m)
      elseif kind == "zug_umbenannt" then
        notify("warnung", "Der Zug " .. tostring(m.payload.before) .. " heisst jetzt " .. tostring(m.payload.train) .. " (" .. tostring(m.payload.node) .. "): die Zuordnung ist ungeklaert.")
        -- 14.1: nicht allein anhand alter Namen fortfahren; kein anderer Zug wird "aehnlich" zugeordnet
        local train = role.register.by_create_name(m.payload.before)
        if train then role.register.set_position(train.id, "unbekannt", nil, "meldung", m.payload.t) end
        for _, order in ipairs(orders_of_train(m.payload.before)) do
          to_clarification(order, "Der Zug heisst jetzt " .. tostring(m.payload.train) .. " statt " .. tostring(m.payload.before) .. ": Zuordnung klaeren.")
        end
      end
      -- Ereignismeldungen werden bestaetigt; der Bahnhof wiederholt sie sonst (verlorene Meldung)
      if EVENT_KINDS[kind] then node.reply(m, "ok", {}) end
      drive_all()
    elseif m.messageType == "auftrag" then
      local kind = m.payload.kind
      if kind == "anmelden" then handle_register(m)
      elseif kind == "bedarf" then handle_demand(m)
      elseif kind == "stornieren" then handle_cancel(m) end
    elseif m.messageType == "abfrage" then
      if m.payload.kind == "vorlagen" then handle_templates_query(m)
      elseif m.payload.kind == "konfig_holen" then role.handle_fetch_config(m)
      elseif m.payload.kind == "netze" then
        -- Netzsuche eines neuen Computers (Rundruf): nur Name und Kennung dieser Leitstelle, nichts Betriebliches
        local count = 0
        for _ in pairs(nodes) do count = count + 1 end
        node.reply(m, "ok", { netz = node.config.network.name, zentrale = node.config.node.id, nodes = count })
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
      if train and train.state == "gesteuert" and train.mode ~= "manuell" and not busy then
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
      if held() then
        role.lines.note(line.id, "Termin ausgelassen: Betrieb zurueckgehalten.")
      elseif not template then
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
    local t = now()
    for i = #later, 1, -1 do
      if t >= later[i].at then
        local item = table.remove(later, i)
        local ok, err = pcall(item.fn)
        if not ok then notify("fehler", "Wiederholung: " .. tostring(err)) end
      end
    end
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
    return { nodes = nodes, dir = dir, track_state = track_state, pending = pending, flags = flags, samples = samples, signal_state = signal_state, knoten_state = knoten_state }
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

  -- Depot und manuelle Zuege (7.2 bis 7.5) -----------------------------------------------------------------------------------------------------
  role.depot_status = nil
  local function depot_say(kind, text) role.depot_status = { kind = kind, text = text } return text end

  local function station_of(node_id, track_id)
    local info = nodes[node_id]
    for _, tr in ipairs(info and info.tracks or {}) do if tr.id == track_id then return tr.station_name end end
  end

  local function split_where(where)
    if type(where) ~= "string" then return nil end
    return where:match("^(.-):(.+)$")
  end

  local function active_order_of(train_id)
    for _, order in ipairs(role.orders.active()) do if order.train == train_id then return order end end
  end

  -- Aufnahme in den gesteuerten Betrieb: der vereinbarte Warteauftrag wird hergestellt; die Uebergabe wurde vor Ort bestaetigt
  function role.adopt(train_id, node_id, track_id)
    local train = role.register.get(train_id)
    if not train then return nil, "Unbekannter Zug." end
    ask(node_id, "auftrag", { kind = "warteauftrag", track = track_id, train = train.create_name, wait = 0, handover = true }, nil, function(payload)
      if payload.status == "zurueckgestellt" then
        later[#later + 1] = { at = now() + (payload.retry_in or 5), fn = function() role.adopt(train_id, node_id, track_id) end }
      elseif payload.status == "uebergeben" then
        role.register.set_state(train_id, "gesteuert")
        role.register.set_position(train_id, "am_bahnhof", node_id .. ":" .. track_id, "abfrage", now())
        if train.mode == "manuell" then role.register.set_mode(train_id, "bedarf") end
        depot_say("ok", "Zug " .. train_id .. " ist aufgenommen (gesteuert).")
      else
        notify("warnung", "Zug " .. train_id .. ": Warteauftrag nicht erteilt (" .. tostring(payload.grund) .. ").")
        depot_say("halt", "Aufnahme nicht bestaetigt: " .. tostring(payload.grund))
      end
    end)
    return true
  end

  -- Abstellen ist ein normaler Auftrag zu einer Abstellstation; erst nach Ankunft und erteiltem Warteauftrag gilt der Zug als abgestellt
  function role.park(train_id, target)
    local train = role.register.get(train_id)
    if not train then return nil, depot_say("halt", "Unbekannter Zug.") end
    if train.state ~= "gesteuert" then return nil, depot_say("halt", "Der Zug ist nicht im gesteuerten Betrieb (" .. train.state .. ").") end
    if active_order_of(train_id) then return nil, depot_say("halt", "Der Zug hat noch einen laufenden Auftrag.") end
    local node_id, track_id = split_where(train.position and train.position.kind == "am_bahnhof" and train.position.where)
    if not node_id then return nil, depot_say("halt", "Der Zug steht nicht nachweislich an einem Bahnhof.") end
    local from = station_of(node_id, track_id)
    if not from then return nil, depot_say("halt", "Der Startbahnhof ist unbekannt.") end
    if role.stations.candidates(target)[1] == nil or (not role.stations.get(target) and not dir[target]) then
      return nil, depot_say("halt", "Die Abstellstation " .. tostring(target) .. " ist unbekannt.")
    end
    local id = "abstellen-" .. train_id
    local ok, err = role.orders.add_template({ id = id, title = "Abstellen " .. train_id, train = train_id, kind = "abstellen", return_to_start = false, stops = { { station = from, wait = 0 }, { station = target, wait = 0 } } })
    if not ok then return nil, depot_say("halt", err) end
    local order, new = role.orders.request(id, nil, { train = train_id, source = "abstellen" })
    if not order then return nil, depot_say("halt", tostring(new)) end
    drive_all()
    return order, depot_say("wait", (new and "Abstellauftrag " or "Laeuft schon: ") .. order.id)
  end

  -- Aktivieren: ausdrueckliche Anforderung; Verfuegbarkeit und Identitaet werden neu geprueft
  function role.activate(train_id)
    local train = role.register.get(train_id)
    if not train then return nil, depot_say("halt", "Unbekannter Zug.") end
    if train.state ~= "abgestellt" then return nil, depot_say("halt", "Der Zug ist nicht abgestellt (" .. train.state .. ").") end
    local node_id, track_id = split_where(train.position and train.position.kind == "am_bahnhof" and train.position.where)
    if not node_id or not reachable(node_id) then return nil, depot_say("halt", "Der Abstellort ist nicht erreichbar oder unbekannt.") end
    depot_say("wait", "Pruefung laeuft ...")
    ask(node_id, "abfrage", { kind = "pruefen", track = track_id, targets = {} }, nil, function(payload)
      if payload.status ~= "ok" or not payload.available or not payload.present then
        return depot_say("halt", "Aktivierung abgelehnt: kein Zug am Abstellgleis.")
      end
      if payload.train ~= train.create_name then
        return depot_say("halt", "Aktivierung abgelehnt: am Abstellgleis steht " .. tostring(payload.train) .. ", nicht " .. train.create_name .. ".")
      end
      if payload.has_schedule and not payload.waiting_ok then
        return depot_say("halt", "Aktivierung abgelehnt: der Fahrplan entspricht nicht dem Warteauftrag (Aufnehmen mit Uebergabe noetig).")
      end
      role.register.set_state(train_id, "gesteuert")
      depot_say("ok", "Zug " .. train_id .. " ist aktiv (gesteuert).")
    end)
    return true
  end

  -- Ausschleusen: die automatische Verantwortung endet nach ausdruecklicher Bestaetigung an einem Haltepunkt
  function role.eject(train_id)
    local train = role.register.get(train_id)
    if not train then return nil, depot_say("halt", "Unbekannter Zug.") end
    if train.state ~= "gesteuert" and train.state ~= "abgestellt" then return nil, depot_say("halt", "Der Zug ist schon nicht mehr im gesteuerten Betrieb (" .. train.state .. ").") end
    if active_order_of(train_id) then return nil, depot_say("halt", "Der Zug hat noch einen laufenden Auftrag: erst beenden oder abbrechen und die Lage klaeren.") end
    if not train.position or train.position.kind ~= "am_bahnhof" then return nil, depot_say("halt", "Ausgeschleust wird nur an einem bestaetigten Haltepunkt.") end
    local ok, err = role.register.set_state(train_id, "ausgeschleust")
    if not ok then return nil, depot_say("halt", err) end
    role.register.set_mode(train_id, "manuell")
    return true, depot_say("ok", "Zug " .. train_id .. " ist ausgeschleust. Sein Create-Fahrplan bleibt unveraendert; die Belegung gilt weiter.")
  end

  -- Wiederaufnahme eines ausgeschleusten oder ungeklaerten Zuges an seinem Haltepunkt (ausdrueckliche, ortsbestaetigte Uebergabe)
  function role.take_over(train_id)
    local train = role.register.get(train_id)
    if not train then return nil, depot_say("halt", "Unbekannter Zug.") end
    if train.state == "gesteuert" then return nil, depot_say("halt", "Der Zug ist schon im gesteuerten Betrieb.") end
    if train.state == "abgestellt" then return nil, depot_say("halt", "Ein abgestellter Zug wird aktiviert, nicht aufgenommen.") end
    local node_id, track_id = split_where(train.position and train.position.kind == "am_bahnhof" and train.position.where)
    if not node_id then return nil, depot_say("halt", "Der Zug steht nicht nachweislich an einem Bahnhof.") end
    local st = track_state[node_id .. ":" .. track_id]
    if not st or not st.present or st.train ~= train.create_name then
      return nil, depot_say("halt", "Am Haltepunkt ist der Zug " .. train.create_name .. " nicht nachgewiesen.")
    end
    depot_say("wait", "Aufnahme laeuft ...")
    return role.adopt(train_id, node_id, track_id)
  end

  function role.cycle_mode(train_id)
    local train = role.register.get(train_id)
    if not train then return nil, depot_say("halt", "Unbekannter Zug.") end
    if active_order_of(train_id) then return nil, depot_say("halt", "Waehrend eines Auftrags wechselt die Betriebsart nicht.") end
    local nxt = ({ bedarf = "linie", linie = "manuell", manuell = "bedarf" })[train.mode] or "bedarf"
    if nxt ~= "manuell" and train.state ~= "gesteuert" then return nil, depot_say("halt", "Nur ein gesteuerter Zug wechselt zwischen Bedarfs- und Linienbetrieb.") end
    local ok, err = role.register.set_mode(train_id, nxt)
    if not ok then return nil, depot_say("halt", err) end
    return true, depot_say("ok", "Betriebsart von " .. train_id .. ": " .. nxt)
  end

  function role.unknown_list()
    local names = {}
    for name in pairs(unknown_trains) do names[#names + 1] = name end
    table.sort(names)
    local out = {}
    for _, name in ipairs(names) do
      local e = unknown_trains[name]
      out[#out + 1] = { name = name, node = e.node, track = e.track, station = station_of(e.node, e.track), present = e.present, since = e.since, last = e.last }
    end
    return out
  end

  function role.forget_unknown(name)
    local e = unknown_trains[name]
    if not e then return nil, "Den Zug kenne ich nicht." end
    if e.present then return nil, "Der Zug steht noch am Gleis: Belegung bleibt." end
    unknown_trains[name] = nil
    return true
  end

  -- Stoerungen und Wartung (14, 29.2) ------------------------------------------------------------------------------------------------------
  function role.set_hold(on, reason)
    local previous = { hold = operation.hold, reason = operation.reason, since = operation.since }
    operation.hold, operation.reason, operation.since = on and true or false, on and (reason or "vom Bediener") or nil, on and now() or nil
    local ok, err = node.store.save(DATA .. "/betrieb.lua", operation)
    if not ok then
      operation.hold, operation.reason, operation.since = previous.hold, previous.reason, previous.since
      return nil, err
    end
    return true
  end

  function role.hold_state() return held() end

  -- Fahrten, die nach einer Wartung neu geprueft werden muessen: Anzahl der Auftraege an einer Festlegung
  function role.drain_state()
    local active, committed = 0, 0
    for _, order in ipairs(role.orders.active()) do
      active = active + 1
      if order.state == "abfahrt_freigegeben" or order.state == "unterwegs" then committed = committed + 1 end
    end
    return { active = active, committed = committed }
  end

  -- alles, was heute nicht in Ordnung oder ungeklaert ist, mit Ursache (14.1)
  function role.faults()
    local list = {}
    local function add(kind, who, text) list[#list + 1] = { kind = kind, who = who, text = text } end
    local is_held, why = held()
    if is_held then add("attention", "Betrieb", "Neue Abfahrten zurueckgehalten: " .. why) end
    local ids = {}
    for id in pairs(nodes) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local info = nodes[id]
      if retired[id] then
        add("dim", id, "stillgelegt")
      elseif not reachable(id) then
        add("halt", id, "meldet sich nicht (keine neuen zentral abhaengigen Freigaben)")
      end
      for _, tr in ipairs(info.tracks or {}) do
        local st = track_state[id .. ":" .. tr.id]
        if st and st.available == false then add("halt", id .. "/" .. tr.name, "Bahnhof-Geraet nicht verfuegbar: Gleis ungeklaert, keine Fahrplanaenderung") end
      end
    end
    for _, row in ipairs(role.signal_overview()) do
      local sg = row.signal
      if sg.invalid then add("halt", row.node .. "/" .. tostring(sg.track_name), "Signal INVALID: Bereich gestoert") end
      if sg.foreign then add("attention", row.node .. "/" .. tostring(sg.track_name), "fremde Sperre (wird nicht aufgehoben)") end
      if sg.missing then add("attention", row.node .. "/" .. tostring(sg.track_name), "eigene Sperre fehlt am Signal") end
      if not sg.available then add("halt", row.node .. "/" .. tostring(sg.track_name), "Signal nicht verfuegbar") end
    end
    for id, entry in pairs(knoten_state) do
      for _, u in ipairs(entry.uses or {}) do
        if u.long then add("halt", id, "Knoten: " .. tostring(u.train) .. " an " .. tostring(u.entry) .. " bleibt lange belegt (kein Nachweis)") end
      end
    end
    for _, order in ipairs(role.orders.active()) do
      if order.state == "klaerung" then add("halt", order.id, "Klaerung: " .. tostring(order.reason))
      elseif order.state == "wartend" then add("wait", order.id, "wartet: " .. tostring(order.reason)) end
    end
    for _, row in ipairs(role.unknown_list()) do
      if row.present then add("attention", row.name, "fremder Zug an " .. tostring(row.station or row.track) .. " (Belegung)") end
    end
    return list
  end

  -- alle Nodes bitten, ihren Zustand sofort zu melden (Geraete erneut pruefen)
  function role.refresh_all()
    local count = 0
    for id in pairs(nodes) do
      if reachable(id) then
        node.send_to(id, "abfrage", { kind = "zustand_senden" })
        count = count + 1
      end
    end
    return count
  end

  -- Konfigurationssicherung und Ersatz (29.2) ------------------------------------------------------------------------------------------------
  local BACKUP_DIR = DATA .. "/nodesich"
  local function backup_path(id) return BACKUP_DIR .. "/" .. tostring(id):gsub("[^%w%-_]", "_") .. ".lua" end

  -- Die Konfiguration kommt in Teilen (part von parts, je ein Stueck Text); beantwortet wird der letzte Teil: "ok" nur, wenn alle da waren
  local CONFIG_PART, MAX_CONFIG_PARTS = 2000, 100
  local config_parts = {}                                 -- Node -> { revision, parts, pieces, count }

  function role.on_config(m)
    local p = m.payload
    local parts, part = p.parts or 1, p.part or 1
    if type(p.config) ~= "string" or type(parts) ~= "number" or type(part) ~= "number" or parts ~= math.floor(parts) or part ~= math.floor(part)
      or part < 1 or part > parts or parts > MAX_CONFIG_PARTS then
      return node.reply(m, "abgelehnt", { grund = "Die Konfigurationssicherung ist ungueltig oder zu gross." })
    end
    if parts > 1 then
      local asm = config_parts[p.node]
      if not asm or asm.revision ~= p.revision or asm.parts ~= parts then
        asm = { revision = p.revision, parts = parts, pieces = {}, count = 0 }
        config_parts[p.node] = asm
      end
      if asm.pieces[part] == nil then asm.count = asm.count + 1 end
      asm.pieces[part] = p.config
      if part < parts then return end                     -- Zwischenteil: noch keine Antwort
      config_parts[p.node] = nil
      if asm.count < parts then return node.reply(m, "unvollstaendig", { grund = "Es fehlen Teile der Konfiguration." }) end
      p = { node = p.node, revision = p.revision, config = table.concat(asm.pieces) }
    end
    local fs = node.env.fs
    if not fs.exists(BACKUP_DIR) then fs.makeDir(BACKUP_DIR) end
    local count = #fs.list(BACKUP_DIR)
    if count >= 60 and not fs.exists(backup_path(p.node)) then
      return node.reply(m, "abgelehnt", { grund = "Zu viele gesicherte Nodes." })
    end
    local ok, err = node.store.save(backup_path(p.node), { revision = p.revision, config = p.config, t = now() })
    node.reply(m, ok and "ok" or "abgelehnt", { grund = err })
  end

  function role.backup_of(id) return node.store.load(backup_path(id)) end

  function role.retire(id)
    if not nodes[id] then return nil, "Den Node kenne ich nicht." end
    retired[id] = true
    nodes[id].retired = true
    local ok, err = node.store.save(DATA .. "/stillgelegt.lua", retired)
    if not ok then retired[id], nodes[id].retired = nil, nil return nil, err end
    return true
  end

  function role.unretire(id)
    retired[id] = nil
    if nodes[id] then nodes[id].retired = nil end
    return node.store.save(DATA .. "/stillgelegt.lua", retired)
  end

  function role.handle_fetch_config(m)
    local id = m.payload.node
    local entry = role.backup_of(id)
    if not entry then return node.reply(m, "abgelehnt", { grund = "keine Sicherung von " .. tostring(id) .. "." }) end
    if nodes[id] and not retired[id] and reachable(id) then
      return node.reply(m, "abgelehnt", { grund = "Die Node " .. id .. " ist noch aktiv: erst ausschalten oder in der Leitstelle stilllegen." })
    end
    -- Uebergabe: ab jetzt gilt der Ersatz; die alte Node darf nicht mehr laufen (Doppelbetrieb wird als Konflikt gemeldet)
    role.unretire(id)
    notify("warnung", "Die Konfiguration von " .. id .. " wurde an einen Ersatzcomputer uebergeben. Die alte Node darf nicht mehr laufen.")
    -- lange Konfigurationen gehen in Teilen (jeder Teil ist eine eigene Antwort auf dieselbe Anfrage)
    local text = entry.config
    local parts = math.max(1, math.ceil(#text / CONFIG_PART))
    for i = 1, parts do
      node.reply(m, "ok", { config = text:sub((i - 1) * CONFIG_PART + 1, i * CONFIG_PART), revision = entry.revision, part = i, parts = parts })
    end
  end

  -- Signale (Zusatzsperre eines Signal-Nodes setzen oder aufheben; ausgefuehrt wird dort, bestaetigt erst nach dem Zuruecklesen)
  role.signal_status = nil
  function role.signal_lock(node_id, signal_id, action)
    if not reachable(node_id) then
      role.signal_status = { kind = "halt", text = "Der Node " .. node_id .. " meldet sich nicht." }
      return nil, role.signal_status.text
    end
    role.signal_status = { kind = "wait", text = "Wird ausgefuehrt ..." }
    ask(node_id, "auftrag", { kind = "sperre", signal = signal_id, action = action, owner = "bediener", reason = "von der Leitstelle" }, nil, function(payload)
      if payload.status == "ok" then
        role.signal_status = { kind = "ok", text = (action == "setzen" and "Sperre gesetzt." or "Sperre des Bedieners aufgehoben.") }
      else
        role.signal_status = { kind = "halt", text = "Nicht bestaetigt: " .. tostring(payload.grund) }
      end
    end)
    return true
  end

  function role.signal_overview()
    local out = {}
    local ids = {}
    for id in pairs(signal_state) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      local entry = signal_state[id]
      local list = entry.signals or {}
      for i = 1, list.n or #list do
        local sg = list[i]
        if sg then out[#out + 1] = { node = id, signal = sg, fresh = reachable(id) and now() - entry.t < NODE_SILENT } end
      end
    end
    return out
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
      state.ids = {}
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
        items[#items + 1] = { text = id .. " " .. (info.name or ""), detail = (retired[id] and "STILLGELEGT" or (ok and "erreichbar" or "NICHT ERREICHBAR")) .. ", " .. #tracks .. " Gleise" .. (#tracks > 0 and (": " .. table.concat(tracks, ",")) or ""), kind = retired[id] and "dim" or (ok and "ok" or "halt") }
        state.ids = state.ids or {}
        state.ids[#items] = id
      end
      W.list(v, "netz", rect, items, state.list, { empty = "Noch kein Node hat sich gemeldet." })
    end,
    actions = function(v)
      local state = v.page_state("netz")
      local id = state.ids and state.ids[(state.list or { index = 1 }).index]
      return { { id = "stilllegen", label = id and retired[id] and "Aktivieren" or (arm.retire and "Wirklich?" or "Stilllegen"), kind = "danger", enabled = id ~= nil, reason = "Erst einen Node waehlen." } }
    end,
    on_action = function(v, action)
      if action ~= "act:stilllegen" then return end
      local state = v.page_state("netz")
      local id = state.ids and state.ids[state.list.index]
      if not id then return true end
      if retired[id] then
        local ok, err = role.unretire(id)
        v.hint = ok and ("Node " .. id .. " ist wieder aktiv.") or err
      elseif not arm.retire then
        arm.retire = true
        v.hint = "Nochmal druecken: " .. id .. " wird stillgelegt (nur fuer den Ersatz durch einen anderen Computer). Meldungen von ihr werden nicht mehr beachtet."
      else
        arm.retire = false
        local ok, err = role.retire(id)
        v.hint = ok and ("Node " .. id .. " ist stillgelegt.") or err
      end
      return true
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
        local order, new = role.demand(info.id, nil)
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

  -- Signale aller Signal-Nodes -----------------------------------------------------------------------------------------------------------
  pages[#pages + 1] = {
    id = "signale", title = "Signale",
    render = function(v, rect)
      local state = v.page_state("signale")
      state.list = state.list or { index = 1 }
      state.rows = {}
      local items = {}
      for i, row in ipairs(role.signal_overview()) do
        local sg = row.signal
        local detail = {}
        if not row.fresh then detail[#detail + 1] = "VERALTET" end
        if sg.forced then detail[#detail + 1] = "gesperrt" end
        if sg.owners and #sg.owners > 0 then detail[#detail + 1] = "von " .. table.concat(sg.owners, ",") end
        if sg.foreign then detail[#detail + 1] = "FREMDE SPERRE" end
        if sg.missing then detail[#detail + 1] = "Sperre fehlt" end
        if sg.invalid then detail[#detail + 1] = "GESTOERT" end
        local kind = (sg.invalid or not sg.available or not row.fresh) and "halt" or (sg.foreign or sg.missing) and "attention" or (sg.forced and "wait" or "ok")
        items[i] = { text = row.node .. " / " .. tostring(sg.track_name) .. "  " .. (sg.available and tostring(sg.state) or "nicht verfuegbar"), detail = #detail > 0 and table.concat(detail, ", ") or "keine zusaetzliche Sperre", kind = kind }
        state.rows[i] = row
      end
      W.list(v, "signale", { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 }, items, state.list, { empty = "Noch kein Signal-Node hat sich gemeldet." })
      if role.signal_status then W.label(v, rect.x + 1, rect.y + rect.h - 1, role.signal_status.text, role.signal_status.kind, rect.w - 2) end
    end,
    actions = function(v)
      local state = v.page_state("signale")
      local row = state.rows and state.rows[(state.list or { index = 1 }).index]
      return {
        { id = "sig_sperre", label = "Sperre", enabled = row ~= nil, reason = "Erst ein Signal waehlen." },
        { id = "sig_aufheben", label = "Aufheben", kind = "secondary", enabled = row ~= nil and row.signal.owners ~= nil and #row.signal.owners > 0, reason = "Das Signal hat keine Sperre eines Besitzers." },
      }
    end,
    on_action = function(v, id)
      local state = v.page_state("signale")
      local row = state.rows and state.rows[state.list.index]
      if not row then return true end
      if id == "act:sig_sperre" then
        local ok, why = role.signal_lock(row.node, row.signal.id, "setzen")
        if not ok then v.hint = why end
        return true
      elseif id == "act:sig_aufheben" then
        local ok, why = role.signal_lock(row.node, row.signal.id, "loesen")
        if not ok then v.hint = why end
        return true
      end
    end,
  }

  -- Depot: abstellen, aktivieren, ausschleusen, aufnehmen, Betriebsart ---------------------------------------------------------------------
  local ZSTATE = { registriert = "registriert", gesteuert = "gesteuert", uebergabe = "Uebergabe offen", abgestellt = "abgestellt", ausgeschleust = "ausgeschleust" }
  local depot_arm = {}
  pages[#pages + 1] = {
    id = "depot", title = "Depot",
    render = function(v, rect)
      local state = v.page_state("depot")
      state.list = state.list or { index = 1 }
      state.screen = state.screen or "liste"
      state.target = state.target or { value = "", max = 40 }
      if state.screen == "abstellen" then
        W.label(v, rect.x + 1, rect.y, "Zug abstellen: " .. tostring(state.train_id), "hell", rect.w - 2)
        W.field(v, "ziel", rect.x + 1, rect.y + 2, math.min(40, rect.w - 2), "Abstellstation (Bahnhof oder Gleis-Name)", state.target)
        W.label(v, rect.x + 1, rect.y + 5, "Der Zug faehrt als normaler Auftrag dorthin und wartet dort.", "dim", rect.w - 2)
        return
      end
      local items = {}
      state.trains = {}
      for i, train in ipairs(role.register.list()) do
        local pos = train.position
        local where = pos and (pos.kind == "am_bahnhof" and ("am Bahnhof " .. tostring(pos.where)) or pos.kind) or "unbekannt"
        local order = active_order_of(train.id)
        local kind = train.state == "gesteuert" and "text" or (train.state == "abgestellt" and "dim" or "attention")
        items[#items + 1] = { text = train.id .. " " .. train.display_name, detail = (ZSTATE[train.state] or train.state) .. ", " .. tostring(train.mode) .. ", " .. where .. (order and (", Auftrag " .. order.id) or ""), kind = kind }
        state.trains[i] = train
      end
      local list_rect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 }
      W.list(v, "depot", list_rect, items, state.list, { empty = "Noch kein Zug angemeldet." })
      if role.depot_status then W.label(v, rect.x + 1, rect.y + rect.h - 1, role.depot_status.text, role.depot_status.kind, rect.w - 2) end
    end,
    actions = function(v)
      local state = v.page_state("depot")
      if state.screen == "abstellen" then
        return { { id = "dp_los", label = "Abstellen", side = "rechts" }, { id = "dp_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" } }
      end
      local train = state.trains and state.trains[(state.list or { index = 1 }).index]
      local list = {}
      local s = train and train.state
      local busy = train and active_order_of(train.id) ~= nil
      if s == "gesteuert" then
        list[#list + 1] = { id = "dp_abstellen", label = "Abstellen", enabled = not busy, reason = "Der Zug hat einen laufenden Auftrag." }
        list[#list + 1] = { id = "dp_ausschleusen", label = depot_arm.eject and "Wirklich?" or "Ausschleusen", kind = "danger", enabled = not busy, reason = "Der Zug hat einen laufenden Auftrag." }
        list[#list + 1] = { id = "dp_art", label = "Art", kind = "secondary", enabled = not busy, reason = "Waehrend eines Auftrags wechselt die Betriebsart nicht." }
      elseif s == "abgestellt" then
        list[#list + 1] = { id = "dp_aktivieren", label = "Aktivieren" }
        list[#list + 1] = { id = "dp_ausschleusen", label = depot_arm.eject and "Wirklich?" or "Ausschleusen", kind = "danger" }
      elseif train then
        list[#list + 1] = { id = "dp_aufnehmen", label = depot_arm.take and "Wirklich?" or "Aufnehmen", kind = "primary" }
      else
        list[#list + 1] = { id = "dp_aufnehmen", label = "Aufnehmen", enabled = false, reason = "Erst einen Zug waehlen." }
      end
      return list
    end,
    on_action = function(v, id)
      local state = v.page_state("depot")
      local train = state.trains and state.trains[state.list.index]
      local function say(ok, err) v.hint = ok and (role.depot_status and role.depot_status.text) or err return true end
      if id == "act:dp_abstellen" and train then
        state.screen, state.train_id, state.target.value = "abstellen", train.id, ""
        return true
      elseif id == "act:dp_zurueck" then
        state.screen = "liste"
        return true
      elseif id == "act:dp_los" then
        local order, why = role.park(state.train_id, state.target.value)
        if order then state.screen = "liste" end
        v.hint = why
        return true
      elseif id == "act:dp_aktivieren" and train then
        local ok, why = role.activate(train.id)
        return say(ok, why)
      elseif id == "act:dp_art" and train then
        local ok, why = role.cycle_mode(train.id)
        return say(ok, why)
      elseif id == "act:dp_ausschleusen" and train then
        if not depot_arm.eject then
          depot_arm.eject = true
          v.hint = "Nochmal druecken, wenn der Fahrbetrieb des Zuges geklaert ist (Fahrplan, Freigabe). Der Create-Fahrplan bleibt im Zug."
        else
          depot_arm.eject = false
          local ok, why = role.eject(train.id)
          say(ok, why)
        end
        return true
      elseif id == "act:dp_aufnehmen" and train then
        if not depot_arm.take then
          depot_arm.take = true
          v.hint = "Nochmal druecken: der Zug steht am Haltepunkt, der Fahrbetrieb ist geklaert, der Warteauftrag darf erteilt werden."
        else
          depot_arm.take = false
          local ok, why = role.take_over(train.id)
          say(ok, why)
        end
        return true
      end
    end,
  }

  -- Unbekannte Zuege: reale Beobachtungen, keine Zuordnung --------------------------------------------------------------------------------
  pages[#pages + 1] = {
    id = "unbekannt", title = "Fremde",
    render = function(v, rect)
      local state = v.page_state("unbekannt")
      state.list = state.list or { index = 1 }
      state.rows = {}
      local items = {}
      for i, row in ipairs(role.unknown_list()) do
        items[i] = { text = row.name, detail = (row.present and "steht " or "war ") .. "an " .. tostring(row.station or row.track) .. " (" .. tostring(row.node) .. ")", kind = row.present and "attention" or "dim" }
        state.rows[i] = row
      end
      W.list(v, "unbekannt", rect, items, state.list, { empty = "Keine fremden Zuege beobachtet." })
    end,
    actions = function(v)
      local state = v.page_state("unbekannt")
      local row = state.rows and state.rows[(state.list or { index = 1 }).index]
      return { { id = "vergessen", label = "Vergessen", kind = "secondary", enabled = row ~= nil and not row.present, reason = "Nur Zuege, die nicht mehr am Gleis stehen." } }
    end,
    on_action = function(v, id)
      if id ~= "act:vergessen" then return end
      local state = v.page_state("unbekannt")
      local row = state.rows and state.rows[state.list.index]
      if row then
        local ok, why = role.forget_unknown(row.name)
        v.hint = ok and "Aus der Liste genommen; Belegungen bleiben ueber ihre eigenen Meldungen bestehen." or why
      end
      return true
    end,
  }

  -- Stoerungen und Wartung -------------------------------------------------------------------------------------------------------------------
  local hold_arm = {}
  pages[#pages + 1] = {
    id = "stoerungen", title = "Stoerungen",
    render = function(v, rect)
      local state = v.page_state("stoerungen")
      state.list = state.list or { index = 1 }
      local items = {}
      for i, f in ipairs(role.faults()) do items[i] = { text = f.who, detail = f.text, kind = f.kind } end
      local drain = role.drain_state()
      W.list(v, "stoerungen", { x = rect.x, y = rect.y, w = rect.w, h = rect.h - 1 }, items, state.list, { empty = "Keine Stoerung bekannt." })
      W.label(v, rect.x + 1, rect.y + rect.h - 1, "Auftraege: " .. drain.active .. " offen, " .. drain.committed .. " mit Freigabe/unterwegs", "dim", rect.w - 2)
    end,
    actions = function(v)
      local is_held = held()
      return {
        { id = "halten", label = is_held and (hold_arm.resume and "Wirklich?" or "Fortsetzen") or "Halten", kind = is_held and "primary" or "danger" },
        { id = "pruefen", label = "Pruefen", kind = "secondary" },
      }
    end,
    on_action = function(v, id)
      if id == "act:halten" then
        if operation.hold then
          if not hold_arm.resume then
            hold_arm.resume = true
            v.hint = "Nochmal druecken: neue Abfahrten werden wieder freigegeben."
          else
            hold_arm.resume = false
            local ok, err = role.set_hold(false)
            v.hint = ok and "Betrieb fortgesetzt." or err
          end
        else
          local ok, err = role.set_hold(true, "vom Bediener")
          v.hint = ok and "Neue Abfahrten sind zurueckgehalten; Fahrten unterwegs laufen weiter." or err
        end
        return true
      elseif id == "act:pruefen" then
        v.hint = "Zustandsabfrage an " .. role.refresh_all() .. " Nodes gesendet."
        return true
      end
    end,
  }

  role.pages = pages
  return role
end

return M
