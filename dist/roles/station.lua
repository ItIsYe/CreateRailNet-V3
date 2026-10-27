--[[
Purpose: Bahnhofs-Node (Konzept 4.2, 4.3, 8): verwaltet die Haltegleise dieses Nodes: erkennt anwesende Zuege, fuehrt je Gleis Aufenthalte (jede Ankunft ist ein neuer Aufenthalt), uebernimmt Warteauftrag und Fahrplan auf Anforderung der Leitstelle (nie blind, nie wiederholt), setzt und nimmt die Abfahrtsfreigabe (create:powered ueber den Gleisausgang) zurueck und meldet Ankunft, Abfahrt und Zustand mit Nachweis. Jede wichtige Aktion steht vorher als Absicht im Journal und danach mit Ergebnis.
API: station_role.new(node) -> role; role.tracks; role.hello(); role.tick(); role.on_event(ev); role.on_message(m, status, extra); role.page
Notes: Freigabe, Fahrplan und Umbenennung sind Aufgaben der Leitstelle, ausgefuehrt wird hier (genau ein verantwortlicher Node je Geraet, Konzept 3.2). Eine Freigabe gilt fuer Node, Zug, Aufenthalt (Nummer der Ankunft) und Fahrplanschritt (13.3): ein alter Auftrag kann keinen spaeteren Zug starten. Das Zuruecksetzen des Ausgangs stoppt den abgefahrenen Zug nicht (8.5). Nach einem Neustart werden Ausgaenge nie pauschal auf false gesetzt (14.2): offene Vorgaenge im Journal werden gegen den gelesenen Ist-Zustand abgeglichen.
]]

local stationlib = require("dev.station")
local outlib = require("dev.out")
local observerlib = require("dev.observer")
local schedulelib = require("domain.schedule")
local W = require("ui.widgets")
local ser = require("core.ser")

local M = {}

local HEARTBEAT = 5          -- Sekunden Betriebszeit zwischen Zustandsmeldungen
local HELLO_REPEAT = 30
local STATE_FILE = "/crn_data/station.lua"

function M.new(node)
  local role = { tracks = {} }
  local config = node.config
  local env = node.env
  local now = function() return node.clock.now() end
  local persisted = node.store.load(STATE_FILE) or { tracks = {} }
  persisted.tracks = persisted.tracks or {}
  local hello_acked, last_hello, last_beat = false, -9999, -9999
  local dirty_report = false
  local confirm_reset = {}

  local function save() node.store.save(STATE_FILE, persisted) end

  -- Gleise aus der Konfiguration ------------------------------------------------------------------------------------------------------
  local ids = {}
  for id, track in pairs(config.tracks) do
    if track.station and config.devices[track.station] then ids[#ids + 1] = id end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local spec = config.tracks[id]
    local device = config.devices[spec.station].device
    local tr = {
      id = id, name = spec.name, spec = spec, device_id = spec.station, device = device,
      station = stationlib.new(env, device),
      out = spec.release and outlib.new(env, spec.release) or nil,
      observers = {},
      present = false, train = nil, since = 0, restored = false, available = true,
      last_passing = nil,
    }
    for _, oid in ipairs(spec.observers or {}) do
      if config.devices[oid] then tr.observers[#tr.observers + 1] = observerlib.new(env, config.devices[oid].device) end
    end
    persisted.tracks[id] = persisted.tracks[id] or { stay = 0, release_set = false }
    tr.p = persisted.tracks[id]
    role.tracks[id] = tr
    role.tracks[#role.tracks + 1] = tr
  end

  local function by_device_id(device_id)
    for _, tr in ipairs(role.tracks) do if tr.device_id == device_id then return tr end end
  end

  -- Berichte --------------------------------------------------------------------------------------------------------------------------
  local function central() return node.central_id() end

  local function track_report(tr)
    return {
      id = tr.id, name = tr.name, station_name = tr.station_name, present = tr.present, train = tr.train, stay = tr.p.stay,
      release_set = tr.p.release_set, release_train = tr.p.release_train, output = tr.out and tr.out.get() or nil,
      available = tr.available, restored = tr.restored or nil, waiting = tr.p.waiting_schedule ~= nil, last_exit = tr.last_exit,
    }
  end

  local function send_state()
    local list = {}
    for _, tr in ipairs(role.tracks) do list[#list + 1] = track_report(tr) end
    node.send_to(central(), "meldung", { kind = "zustand", node = config.node.id, tracks = list, t = now() })
    last_beat = now()
    dirty_report = false
  end

  function role.hello()
    local list = {}
    for _, tr in ipairs(role.tracks) do
      list[#list + 1] = {
        id = tr.id, name = tr.name, station_name = tr.station_name, has_output = tr.out ~= nil, direction = tr.spec.direction,
        length = tr.spec.length,
      }
    end
    node.send_to(central(), "meldung", {
      kind = "hallo", node = config.node.id, name = config.node.name, roles = config.node.roles, revision = config.revision,
      tracks = list, active = config.status == "aktiv",
    })
    last_hello = now()
  end

  local function report(kind, tr, extra)
    local payload = { kind = kind, node = config.node.id, track = tr.id, stay = tr.p.stay, train = tr.train, station_name = tr.station_name, t = now() }
    for k, v in pairs(extra or {}) do payload[k] = v end
    node.send_to(central(), "meldung", payload)
  end

  -- Zustand lesen ---------------------------------------------------------------------------------------------------------------------
  local function refresh_names()
    for _, tr in ipairs(role.tracks) do
      local name = tr.station.station_name()
      if name then tr.station_name = name end
    end
  end

  -- eine Ankunft ist ein neuer Aufenthalt
  local function open_stay(tr, train, restored)
    tr.present, tr.train, tr.since, tr.restored = true, train, now(), restored or false
    tr.p.stay = tr.p.stay + 1
    -- Freigabe eines frueheren Aufenthalts gilt nicht fuer diesen
    if tr.p.release_set and tr.p.release_stay ~= tr.p.stay and not restored then
      node.notify("warnung", tr.name .. ": Ausgang war noch eingeschaltet, als ein neuer Zug kam.")
    end
    save()
    report("ankunft", tr, { restored = restored or nil })
    dirty_report = true
  end

  local function reset_output(tr, reason)
    if not tr.out then tr.p.release_set = false save() return true end
    local id = node.journal.begin("freigabe.zuruecknehmen", { track = tr.id, grund = reason })
    local result = tr.out.set(false)
    node.journal.finish(id, { confirmed = result.confirmed })
    if result.confirmed then
      tr.p.release_set, tr.p.release_train, tr.p.release_stay, tr.p.release_order = false, nil, nil, nil
      save()
      return true
    end
    node.notify("fehler", tr.name .. ": Der Freigabeausgang liess sich nicht zuruecknehmen.")
    return false
  end

  local function close_stay(tr, planned, train)
    local was_released = tr.p.release_set
    -- die letzte Abfahrt steht in jedem Zustandsbericht, damit eine verlorene Abfahrtsmeldung nicht zum Stillstand fuehrt
    tr.last_exit = { stay = tr.p.stay, train = train or tr.train, released = was_released and true or false }
    report("abfahrt", tr, { train = train or tr.train, released = was_released, unplanned = not was_released or nil })
    tr.present, tr.train = false, nil
    if was_released then reset_output(tr, "abgefahren") end
    dirty_report = true
  end

  -- Ereignisse -------------------------------------------------------------------------------------------------------------------------
  function role.on_event(ev)
    if ev.kind == "station" then
      local tr = by_device_id(ev.id)
      if not tr then return end
      if ev.type == "train_arrival" then
        open_stay(tr, ev.train, false)
      elseif ev.type == "train_departure" then
        if tr.present then close_stay(tr, true, ev.train) end
      elseif ev.type == "train_imminent" then
        tr.imminent = ev.train
        report("angekuendigt", tr, { train = ev.train })
      end
    elseif ev.kind == "observer" then
      for _, tr in ipairs(role.tracks) do
        tr.last_passing = { type = ev.type, train = ev.train, t = ev.t }
      end
    end
  end

  -- Abgleich mit dem Ist-Zustand (verlorene Ereignisse, Neustart) -------------------------------------------------------------------------
  local function reconcile(tr)
    local state = tr.station.read()
    tr.available = state.available == true
    if not state.available then return end
    if state.present and not tr.present then
      open_stay(tr, state.train, true)
    elseif not state.present and tr.present then
      -- Zug nicht mehr da, aber keine Abfahrtsmeldung: nichts als Erfolg werten
      tr.last_exit = { stay = tr.p.stay, train = tr.train, vanished = true }
      report("zug_weg", tr, { train = tr.train })
      tr.present, tr.train = false, nil
      if tr.p.release_set then reset_output(tr, "zug_weg") end
      dirty_report = true
    elseif state.present and tr.present and state.train ~= tr.train then
      node.notify("warnung", tr.name .. ": Der Zug heisst jetzt " .. tostring(state.train) .. " statt " .. tostring(tr.train) .. ".")
      report("zug_umbenannt", tr, { train = state.train, before = tr.train })
      tr.train = state.train
      dirty_report = true
    end
  end

  function role.tick()
    if node.net == nil then return end
    local t = now()
    if t - last_hello >= (hello_acked and 120 or HELLO_REPEAT) then role.hello() end
    for _, tr in ipairs(role.tracks) do reconcile(tr) end
    if dirty_report or t - last_beat >= HEARTBEAT then send_state() end
  end

  -- Aufgaben der Leitstelle ---------------------------------------------------------------------------------------------------------------
  local function find_track(id) return role.tracks[id] end

  local function reply(m, status, payload) node.reply(m, status, payload) end

  local function current_matches(tr, known)
    if not known then return false end
    local current = tr.station.schedule()
    return current ~= nil and schedulelib.same(current, known)
  end

  local function handle_pruefen(m)
    local p = m.payload
    local tr = find_track(p.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    local state = tr.station.read()
    local info = { track = tr.id, available = state.available == true, present = state.present == true, train = state.train, stay = tr.p.stay,
      has_schedule = state.has_schedule, output = tr.out and tr.out.get() or nil, release_set = tr.p.release_set, station_name = tr.station_name }
    if state.present then
      local current = tr.station.schedule()
      info.waiting_ok = current ~= nil and tr.p.waiting_schedule ~= nil and schedulelib.same(current, tr.p.waiting_schedule)
      info.order_schedule_ok = current ~= nil and tr.p.order_schedule ~= nil and schedulelib.same(current, tr.p.order_schedule)
      info.reach = {}
      for _, target in ipairs(p.targets or {}) do
        local ok, why = tr.station.can_reach(target)
        info.reach[target] = { ok = ok, reason = why }
      end
    end
    reply(m, "ok", info)
  end

  local function precondition(m, tr, state)
    if not state.available then return "Bahnhof nicht verfuegbar" end
    if not state.present then return "kein Zug am Bahnhof" end
    if m.payload.train and state.train ~= m.payload.train then return "am Bahnhof steht " .. tostring(state.train) .. ", nicht " .. tostring(m.payload.train) end
    return nil
  end

  local function handle_fahrplan(m)
    local p = m.payload
    local tr = find_track(p.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    local state = tr.station.read()
    local why = precondition(m, tr, state)
    if why then return reply(m, "abgelehnt", { grund = why }) end
    local problems = schedulelib.check(p.schedule)
    if #problems > 0 then return reply(m, "abgelehnt", { grund = "Fahrplan unzulaessig: " .. problems[1] }) end
    -- nie blind ueberschreiben: der Zug muss im bekannten Wartezustand sein (Konzept 8.2)
    local current = tr.station.schedule()
    local already = current ~= nil and schedulelib.same(current, p.schedule)
    if not already and not p.handover and not current_matches(tr, tr.p.waiting_schedule) then
      return reply(m, "abgelehnt", { grund = "Ausgangslage unklar: der Fahrplan des Zuges weicht vom Warteauftrag ab (Uebergabe noetig).", klaerung = true })
    end
    local jid = node.journal.begin("fahrplan.setzen", { order = p.orderId, track = tr.id, train = state.train, hash = schedulelib.hash(p.schedule) })
    local result, err = tr.station.set_schedule(p.schedule)
    node.journal.finish(jid, { result = result, error = err })
    if not result then return reply(m, "abgelehnt", { grund = err or "Fahrplan nicht uebernommen" }) end
    tr.p.waiting_schedule = nil
    tr.p.order_schedule = p.schedule
    tr.p.order = p.orderId
    save()
    reply(m, "uebergeben", { track = tr.id, train = state.train, ergebnis = result })
  end

  local function handle_warteauftrag(m)
    local p = m.payload
    local tr = find_track(p.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    local state = tr.station.read()
    local why = precondition(m, tr, state)
    if why then return reply(m, "abgelehnt", { grund = why }) end
    refresh_names()
    local station_name = tr.station_name
    if not station_name then return reply(m, "abgelehnt", { grund = "Der Bahnhofsname ist nicht lesbar." }) end
    local wanted = schedulelib.waiting(station_name, p.wait or 0)
    local current = tr.station.schedule()
    local known = current ~= nil and (schedulelib.same(current, wanted) or current_matches(tr, tr.p.order_schedule))
    if not known and not p.handover and state.has_schedule then
      return reply(m, "abgelehnt", { grund = "Ausgangslage unklar: der Zug hat einen unbekannten Fahrplan (Uebergabe noetig).", klaerung = true })
    end
    if tr.out and tr.out.get() == true then
      return reply(m, "abgelehnt", { grund = "Der Freigabeausgang ist eingeschaltet: ein Warteauftrag waere sofort erfuellt." })
    end
    local jid = node.journal.begin("fahrplan.setzen", { order = "warten", track = tr.id, train = state.train, hash = schedulelib.hash(wanted) })
    local result, err = tr.station.set_schedule(wanted)
    node.journal.finish(jid, { result = result, error = err })
    if not result then return reply(m, "abgelehnt", { grund = err or "Warteauftrag nicht uebernommen" }) end
    tr.p.waiting_schedule = wanted
    tr.p.order_schedule, tr.p.order = nil, nil
    save()
    reply(m, "uebergeben", { track = tr.id, train = state.train, ergebnis = result })
  end

  local function handle_freigabe(m)
    local p = m.payload
    local tr = find_track(p.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    if not tr.out then return reply(m, "abgelehnt", { grund = "Dieses Gleis hat keinen Freigabeausgang." }) end
    if tr.p.release_set and tr.p.release_stay == p.stay and tr.p.release_train == p.train then
      return reply(m, "freigabe_gesetzt", { track = tr.id, hinweis = "schon gesetzt", abfahrt_bestaetigt = false })
    end
    local state = tr.station.read()
    local why = precondition(m, tr, state)
    if why then return reply(m, "abgelehnt", { grund = why }) end
    if p.stay ~= nil and p.stay ~= tr.p.stay then
      return reply(m, "abgelehnt", { grund = "anderer Aufenthalt: erwartet " .. tostring(p.stay) .. ", aktuell " .. tostring(tr.p.stay) })
    end
    local waited = now() - tr.since
    if p.min_stay and waited < p.min_stay then
      return reply(m, "zurueckgestellt", { grund = "Mindestaufenthalt", retry_in = p.min_stay - waited })
    end
    if tr.out.get() == true and not tr.p.release_set then
      return reply(m, "abgelehnt", { grund = "Der Ausgang ist schon aus anderem Grund eingeschaltet." })
    end
    local jid = node.journal.begin("freigabe.setzen", { order = p.orderId, track = tr.id, train = state.train, stay = tr.p.stay })
    local result = tr.out.set(true)
    node.journal.finish(jid, { confirmed = result.confirmed, error = result.error })
    if not result.confirmed then return reply(m, "abgelehnt", { grund = "Ausgang nicht bestaetigt" .. (result.error and (": " .. result.error) or "") }) end
    tr.p.release_set, tr.p.release_train, tr.p.release_stay, tr.p.release_order = true, state.train, tr.p.stay, p.orderId
    save()
    dirty_report = true
    -- Sollzustand: das ist noch keine bestaetigte Abfahrt
    reply(m, "freigabe_gesetzt", { track = tr.id, stay = tr.p.stay, abfahrt_bestaetigt = false })
  end

  local function handle_umbenennen(m)
    local p = m.payload
    local tr = find_track(p.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    local state = tr.station.read()
    if not state.present then return reply(m, "abgelehnt", { grund = "kein Zug am Bahnhof" }) end
    if state.train == p.to then return reply(m, "ok", { train = p.to, hinweis = "schon so benannt" }) end
    if state.train ~= p.from then return reply(m, "abgelehnt", { grund = "am Bahnhof steht " .. tostring(state.train) .. ", nicht " .. tostring(p.from) }) end
    local jid = node.journal.begin("zug.umbenennen", { track = tr.id, von = p.from, nach = p.to })
    local ok, err = tr.station.rename_train(p.to)
    node.journal.finish(jid, { ok = ok, error = err })
    if not ok then return reply(m, "abgelehnt", { grund = err or "Umbenennen fehlgeschlagen" }) end
    tr.train = p.to
    dirty_report = true
    reply(m, "ok", { train = p.to })
  end

  local HANDLERS = {
    pruefen = handle_pruefen, fahrplan = handle_fahrplan, warteauftrag = handle_warteauftrag,
    freigabe = handle_freigabe, umbenennen = handle_umbenennen,
  }

  -- Fahrplan des stehenden Zuges lesen (Mengenmuster fuer die Leitstelle); aendert nichts
  local function handle_lesen(m)
    local tr = find_track(m.payload.track)
    if not tr then return reply(m, "abgelehnt", { grund = "Gleis unbekannt" }) end
    local state = tr.station.read()
    if not state.present then return reply(m, "abgelehnt", { grund = "kein Zug am Bahnhof" }) end
    local current = tr.station.schedule()
    if not current then return reply(m, "abgelehnt", { grund = "Der Zug hat keinen Fahrplan." }) end
    reply(m, "ok", { track = tr.id, train = state.train, schedule = current })
  end
  HANDLERS.lesen = handle_lesen

  function role.on_message(m, status)
    if status ~= "ok" then return end
    if m.messageType == "bestaetigung" and m.payload.kind == "antwort" and m.payload.antwort_auf == "hallo" then
      hello_acked = true
      return
    end
    if m.messageType ~= "auftrag" and m.messageType ~= "abfrage" then return end
    local handler = HANDLERS[m.payload.kind]
    if handler then handler(m) end
  end

  -- Wiederanlauf: offene Vorgaenge gegen den gelesenen Zustand abgleichen (14.2) --------------------------------------------------------
  function role.recover()
    refresh_names()
    for _, entry in ipairs(node.journal.pending()) do
      local k = entry.kind
      if k == "freigabe.setzen" or k == "freigabe.zuruecknehmen" or k == "fahrplan.setzen" or k == "zug.umbenennen" then
        local tr = find_track(entry.payload.track)
        local result = { abgeglichen = true }
        if tr then
          local state = tr.station.read()
          if k == "freigabe.setzen" then
            local actual = tr.out and tr.out.get()
            result.output = actual
            if actual == true and state.present and state.train == entry.payload.train and tr.p.stay == entry.payload.stay then
              tr.p.release_set, tr.p.release_train, tr.p.release_stay, tr.p.release_order = true, state.train, tr.p.stay, entry.payload.order
              save()
            elseif actual == true then
              node.notify("warnung", tr.name .. ": Ausgang eingeschaltet, aber kein passender Zug: bitte pruefen.")
            end
          elseif k == "freigabe.zuruecknehmen" then
            local actual = tr.out and tr.out.get()
            result.output = actual
            if actual == true then reset_output(tr, "abgleich") else tr.p.release_set = false save() end
          elseif k == "fahrplan.setzen" then
            local current = state.present and tr.station.schedule() or nil
            result.passt = current ~= nil and schedulelib.hash(current) == entry.payload.hash
            if not result.passt then node.notify("warnung", tr.name .. ": Fahrplanuebergabe war unklar und ist nicht nachweisbar.") end
          else
            result.train = state.train
          end
        end
        node.journal.finish(entry.id, result)
      end
    end
    -- Zustand der Ausgaenge ohne Freigabe: nichts anfassen, aber melden
    for _, tr in ipairs(role.tracks) do
      if tr.out and tr.out.get() == true and not tr.p.release_set then
        node.notify("warnung", tr.name .. ": Der Freigabeausgang ist eingeschaltet, ohne dass eine Freigabe bekannt ist.")
      end
    end
  end

  -- Seite --------------------------------------------------------------------------------------------------------------------------------
  role.page = {
    id = "gleise", title = "Gleise",
    render = function(v, rect)
      local state = v.page_state("gleise")
      state.list = state.list or { index = 1 }
      local items = {}
      state.tracks = {}
      for i, tr in ipairs(role.tracks) do
        local status, kind
        if not tr.available then status, kind = "Geraet nicht verfuegbar", "halt"
        elseif tr.p.release_set then status, kind = "Abfahrt freigegeben, noch nicht bestaetigt", "wait"
        elseif tr.present then status, kind = "Zug " .. tostring(tr.train) .. ", Aufenthalt " .. tr.p.stay, "ok"
        else status, kind = "frei", "dim" end
        items[#items + 1] = { text = tr.name, detail = status, kind = kind }
        state.tracks[i] = tr
      end
      W.list(v, "gleise", rect, items, state.list, { empty = "Keine Gleise eingerichtet." })
    end,
    actions = function(v)
      local state = v.page_state("gleise")
      local tr = state.tracks and state.tracks[(state.list or { index = 1 }).index]
      local can = tr ~= nil and tr.out ~= nil and tr.p.release_set
      return { { id = "ausgang_weg", label = confirm_reset.armed and "Wirklich?" or "Ausgang aus", kind = "danger", enabled = can,
        reason = "Der Ausgang dieses Gleises ist nicht eingeschaltet." } }
    end,
    on_action = function(v, id)
      if id == "act:ausgang_weg" then
        local state = v.page_state("gleise")
        local tr = state.tracks and state.tracks[state.list.index]
        if not tr then return true end
        if not confirm_reset.armed then
          confirm_reset.armed = true
          v.hint = "Nochmal druecken: der Ausgang wird ausgeschaltet (der Zug wird dadurch nicht gestoppt)."
        else
          confirm_reset.armed = false
          v.hint = reset_output(tr, "bediener") and "Ausgang ausgeschaltet." or "Ausschalten nicht bestaetigt."
        end
        return true
      end
    end,
  }

  -- Start -------------------------------------------------------------------------------------------------------------------------------
  refresh_names()
  for _, tr in ipairs(role.tracks) do
    local state = tr.station.read()
    tr.available = state.available == true
    if state.present then
      tr.present, tr.train, tr.since, tr.restored = true, state.train, now(), true
      -- eine Ankunft vor dem Neustart bleibt derselbe Aufenthalt, sofern ein Stand gespeichert ist
      if tr.p.stay == 0 then tr.p.stay = 1 end
    end
  end
  role.recover()
  return role
end

return M
