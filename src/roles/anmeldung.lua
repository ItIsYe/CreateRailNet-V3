--[[
Purpose: Anmelde- und Auftrags-Node (Konzept 4.7, 7.1, 9.3): einfache Eingabestelle. Zuganmeldung an der gewaehlten Station (Kennung, Create-Zugname, Anzeigename, Laenge, Verwendung, Betriebsart) und Bedarfstasten wie "Weizen liefern". Ein Tastendruck ist ein Bedienwunsch: er wird zu genau einem Auftrag; weitere Druecke zeigen den laufenden Auftrag. Ohne Antwort steht dort "Rueckmeldung fehlt", nicht "fehlgeschlagen"; ein erneuter Druck sendet dieselbe Anforderung noch einmal.
API: anmeldung_role.new(node) -> role; role.on_message(m, status); role.tick(); role.pages; role.submit_registration(fields) -> Nachricht; role.press(template_id) -> Text
Notes: Dieser Node greift nicht selbst auf fremde Geraete zu (4.7): Namensaenderung, Fahrplan und Warteauftrag fuehrt der verantwortliche Bahnhofs-Node auf Anweisung der Leitstelle aus. Er liest nur den Zustand der Anmeldestation, um die Eingabe vorzubelegen.
]]

local stationlib = require("dev.station")
local W = require("ui.widgets")
local registerlib = require("domain.register")

local M = {}

local REFRESH = 10      -- Sekunden zwischen Abfragen der Vorlagen
local REPLY_WAIT = 8
local RETRY_LATER = 5

function M.new(node)
  local role = {}
  local config = node.config
  local now = function() return node.clock.now() end
  local reg_device = config.registration_station and config.devices[config.registration_station] and config.devices[config.registration_station].device
  local station = reg_device and stationlib.new(node.env, reg_device) or nil
  local templates, last_query = {}, -9999
  local demands = {}          -- Vorlage -> { m, sent, tries, answered }
  local registration = nil    -- { m, sent, tries, result }
  local counter = 0

  local function central() return node.central_id() end

  local function query_templates()
    node.send_to(central(), "abfrage", { kind = "vorlagen" })
    last_query = now()
  end

  function role.station_state()
    if not station then return nil end
    return station.read(), station.station_name()
  end

  -- Anmeldung -----------------------------------------------------------------------------------------------------------------------
  function role.submit_registration(fields)
    local state, name = role.station_state()
    if not state or not state.present then return nil, "An der Anmeldestation steht kein Zug." end
    counter = counter + 1
    local payload = {
      kind = "anmelden", id = fields.id, create_name = fields.create_name, display_name = fields.display_name, usage = fields.usage,
      mode = fields.mode, length = tonumber(fields.length) or 1, station_name = name, current_name = state.train,
    }
    local m = node.send_to(central(), "auftrag", payload, { requestId = "reg-" .. tostring(node.clock.boot_id()) .. "-" .. counter })
    registration = { m = m, sent = now(), tries = 1, fields = fields }
    return m
  end

  -- Bedarfstaste -------------------------------------------------------------------------------------------------------------------------
  local function active_of(template_id)
    for _, t in ipairs(templates) do
      if t.id == template_id then return t.active end
    end
  end

  function role.press(template_id)
    local active = active_of(template_id)
    if active then
      return "Auftrag " .. active.id .. " laeuft: " .. active.state .. (active.unconfirmed and " (Rueckmeldung fehlt)" or "")
    end
    local d = demands[template_id]
    if d and not d.answered then
      -- keine Antwort bisher: dieselbe Anforderung noch einmal, nie eine zweite Fahrt
      node.send_message(d.m)
      d.sent, d.tries = now(), d.tries + 1
      return "Rueckmeldung fehlt noch: Anforderung erneut gesendet."
    end
    counter = counter + 1
    local m = node.send_to(central(), "auftrag", { kind = "bedarf", template = template_id },
      { requestId = "bedarf-" .. template_id .. "-" .. tostring(node.clock.boot_id()) .. "-" .. counter })
    demands[template_id] = { m = m, sent = now(), tries = 1, answered = false }
    return "Angefordert."
  end

  function role.demand_state(template_id)
    local d = demands[template_id]
    if d and not d.answered and now() - d.sent >= REPLY_WAIT then return "Rueckmeldung fehlt" end
    return nil
  end

  function role.on_message(m, status)
    if status ~= "ok" and status ~= "duplicate" then return end
    if m.messageType ~= "bestaetigung" or not m.correlationId then return end
    if registration and registration.m.messageId == m.correlationId then
      registration.result = { status = m.payload.status, grund = m.payload.grund }
    end
    for id, d in pairs(demands) do
      if d.m.messageId == m.correlationId then
        d.answered = true
        d.result = { status = m.payload.status, grund = m.payload.grund, order = m.payload.order }
        query_templates()
      end
    end
    if m.payload.antwort_auf == "vorlagen" and m.payload.templates then templates = m.payload.templates end
  end

  function role.tick()
    local t = now()
    if t - last_query >= REFRESH then query_templates() end
    -- Wiederholung unbeantworteter Anmeldungen: dieselbe Nachricht
    if registration and not registration.result and t - registration.sent >= REPLY_WAIT and registration.tries < 6 then
      node.send_message(registration.m)
      registration.sent, registration.tries = t, registration.tries + 1
    end
    -- unbeantwortete Anforderung: dieselbe Nachricht, begrenzt; danach hilft nur ein erneutes Druecken
    for _, d in pairs(demands) do
      if not d.answered and d.tries < 3 and t - d.sent >= REPLY_WAIT then
        node.send_message(d.m)
        d.sent, d.tries = t, d.tries + 1
      end
    end
    -- "spaeter": neue Anfrage (eine wiederholte wuerde dieselbe Antwort bekommen)
    if registration and registration.result and registration.result.status == "spaeter" and registration.tries < 24 and t - registration.sent >= RETRY_LATER then
      local tries = registration.tries
      local m = role.submit_registration(registration.fields)
      if m then registration.tries = tries + 1 end
    end
  end

  -- Seiten -----------------------------------------------------------------------------------------------------------------------------
  local USAGE = { { id = "fracht", text = "Fracht" }, { id = "personen", text = "Personen" } }
  local MODES = { { id = "bedarf", text = "Bedarfsbetrieb" }, { id = "linie", text = "Linienbetrieb" }, { id = "manuell", text = "manuell gefahren" } }

  local pages = {}

  pages[#pages + 1] = {
    id = "anmeldung", title = "Anmeldung",
    render = function(v, rect)
      local st = v.page_state("anmeldung")
      st.screen = st.screen or "start"
      st.fields = st.fields or {
        id = { value = "", max = 16 }, create_name = { value = "", max = 30 }, display_name = { value = "", max = 30 }, length = { value = "1", max = 3 },
      }
      st.lists = st.lists or {}
      local function lst(id) st.lists[id] = st.lists[id] or { index = 1 }; return st.lists[id] end
      local sub = { x = rect.x, y = rect.y + 3, w = rect.w, h = rect.h - 3 }
      W.label(v, rect.x + 1, rect.y, "Zuganmeldung", "hell")
      if st.screen == "start" then
        local state, name = role.station_state()
        if not station then
          W.label(v, rect.x + 1, rect.y + 2, "Keine Anmeldestation eingerichtet (Einrichtung, Schritt 4).", "attention", rect.w - 2)
        elseif not state.available then
          W.label(v, rect.x + 1, rect.y + 2, "Die Anmeldestation ist nicht erreichbar.", "halt", rect.w - 2)
        else
          W.label(v, rect.x + 1, rect.y + 2, "Station: " .. tostring(name), "text", rect.w - 2)
          if state.present then
            W.label(v, rect.x + 1, rect.y + 3, "Zug erkannt: " .. tostring(state.train), "ok", rect.w - 2)
            if state.train == registerlib.DEFAULT_NAME then
              W.label(v, rect.x + 1, rect.y + 4, "Der Standardname ist nicht eindeutig: ein neuer Create-Zugname wird vergeben.", "wait", rect.w - 2)
            end
          else
            W.label(v, rect.x + 1, rect.y + 3, "Kein Zug an der Station.", "dim", rect.w - 2)
          end
        end
        if registration and registration.result then
          local r = registration.result
          local text = r.status == "angenommen" and ("Angemeldet: " .. tostring(registration.fields.id)) or ("Abgelehnt: " .. tostring(r.grund))
          if r.status == "spaeter" then text = "Noch nicht moeglich: " .. tostring(r.grund) end
          W.label(v, rect.x + 1, rect.y + 6, text, r.status == "angenommen" and "ok" or (r.status == "spaeter" and "wait" or "halt"), rect.w - 2)
        elseif registration then
          W.label(v, rect.x + 1, rect.y + 6, now() - registration.sent >= REPLY_WAIT and "Rueckmeldung fehlt." or "Anmeldung gesendet ...", "wait", rect.w - 2)
        end
      elseif st.screen == "f1" then
        W.field(v, "id", rect.x + 1, rect.y + 2, math.min(30, rect.w - 2), "Kennung (z.B. GZ-001)", st.fields.id)
        W.field(v, "create_name", rect.x + 1, rect.y + 5, math.min(34, rect.w - 2), "Create-Zugname (eindeutig)", st.fields.create_name)
      elseif st.screen == "f2" then
        W.field(v, "display_name", rect.x + 1, rect.y + 2, math.min(34, rect.w - 2), "Anzeigename (frei)", st.fields.display_name)
        W.field(v, "length", rect.x + 1, rect.y + 5, 12, "Laenge (Wagen)", st.fields.length)
      elseif st.screen == "verwendung" then
        local items = {}
        for _, u in ipairs(USAGE) do items[#items + 1] = { text = (st.usage == u.id and "(o) " or "( ) ") .. u.text } end
        W.list(v, "verwendung", sub, items, lst("verwendung"), { row_h = 1 })
      elseif st.screen == "modus" then
        local items = {}
        for _, mo in ipairs(MODES) do items[#items + 1] = { text = (st.mode == mo.id and "(o) " or "( ) ") .. mo.text } end
        W.list(v, "modus", sub, items, lst("modus"), { row_h = 1 })
      elseif st.screen == "senden" then
        local f = st.fields
        local lines = {
          "Kennung: " .. f.id.value, "Create-Zugname: " .. f.create_name.value, "Anzeigename: " .. (f.display_name.value ~= "" and f.display_name.value or f.create_name.value),
          "Laenge: " .. f.length.value, "Verwendung: " .. tostring(st.usage) .. "  Betrieb: " .. tostring(st.mode),
        }
        for i, line in ipairs(lines) do W.label(v, rect.x + 1, rect.y + 1 + i, line, "text", rect.w - 2) end
      end
    end,
    actions = function(v)
      local st = v.page_state("anmeldung")
      local screen = st.screen or "start"
      if screen == "start" then
        local state = role.station_state()
        return { { id = "anmelden", label = "Zug anmelden", enabled = state ~= nil and state.present == true, reason = "An der Anmeldestation steht kein Zug." } }
      end
      local list = { { id = "reg_zurueck", label = "Zurueck", kind = "secondary", side = "rechts" } }
      list[#list + 1] = { id = screen == "senden" and "reg_senden" or "reg_weiter", label = screen == "senden" and "Anmelden" or "Weiter", side = "rechts" }
      list[#list + 1] = { id = "reg_abbruch", label = "Abbrechen", kind = "danger", side = "rechts" }
      return list
    end,
    on_action = function(v, id)
      local st = v.page_state("anmeldung")
      st.screen = st.screen or "start"
      local order = { "start", "f1", "f2", "verwendung", "modus", "senden" }
      local function index() for i, s in ipairs(order) do if s == st.screen then return i end end end
      local n = id:match("^sel:verwendung:(%d+)$")
      if n then st.usage = USAGE[tonumber(n)].id return true end
      n = id:match("^sel:modus:(%d+)$")
      if n then st.mode = MODES[tonumber(n)].id return true end
      if id == "act:anmelden" then
        local state = role.station_state()
        registration = nil
        st.fields.id.value = ""
        st.fields.create_name.value = (state and state.train ~= registerlib.DEFAULT_NAME) and state.train or ""
        st.fields.display_name.value = ""
        st.usage, st.mode = "fracht", "bedarf"
        st.screen = "f1"
        return true
      elseif id == "act:reg_weiter" then
        if st.screen == "f1" and (st.fields.id.value == "" or st.fields.create_name.value == "") then v.hint = "Kennung und Create-Zugname sind noetig." return true end
        st.screen = order[index() + 1]
        return true
      elseif id == "act:reg_zurueck" then
        st.screen = order[math.max(1, index() - 1)]
        return true
      elseif id == "act:reg_abbruch" then
        st.screen = "start"
        return true
      elseif id == "act:reg_senden" then
        local f = st.fields
        local m, why = role.submit_registration({
          id = f.id.value, create_name = f.create_name.value, display_name = f.display_name.value ~= "" and f.display_name.value or f.create_name.value,
          length = f.length.value, usage = st.usage, mode = st.mode,
        })
        v.hint = m and "Anmeldung gesendet." or why
        st.screen = "start"
        return true
      end
    end,
  }

  pages[#pages + 1] = {
    id = "fahrten", title = "Fahrten",
    render = function(v, rect)
      local st = v.page_state("fahrten")
      st.list = st.list or { index = 1 }
      st.templates = {}
      local items = {}
      for i, t in ipairs(templates) do
        local detail
        if t.active then
          detail = "Auftrag " .. t.active.id .. ": " .. t.active.state .. (t.active.unconfirmed and " - Rueckmeldung fehlt" or "")
        else
          detail = role.demand_state(t.id) or "bereit"
        end
        items[#items + 1] = { text = t.title, detail = detail, kind = t.active and "wait" or "dim" }
        st.templates[i] = t
      end
      W.list(v, "fahrten", rect, items, st.list, { empty = "Noch keine Vorlagen von der Leitstelle." })
    end,
    actions = function(v)
      local st = v.page_state("fahrten")
      local t = st.templates and st.templates[(st.list or { index = 1 }).index]
      local label = (t and t.active) and "Status" or "Anfordern"
      return { { id = "druck", label = label, enabled = t ~= nil, reason = "Erst eine Fahrt waehlen." } }
    end,
    on_action = function(v, id)
      if id == "act:druck" then
        local st = v.page_state("fahrten")
        local t = st.templates and st.templates[st.list.index]
        if t then v.hint = role.press(t.id) end
        return true
      end
    end,
  }

  role.pages = pages
  return role
end

return M
