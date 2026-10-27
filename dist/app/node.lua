--[[
Purpose: Laufzeit eines Nodes: laedt Konfiguration, Uhr, Journal und Aufgabenplaner, baut die Ansichten (Terminal und jeden Monitor der Konfiguration), verarbeitet alle Ereignisse in einer Schleife (Eingabe, Funk, Create-Ereignisse, Zeit, Geraeteaenderung) und stellt Anschlussstellen fuer die Rollen bereit. Ohne Konfiguration startet die Seite "Einrichtung".
API: node.new(env) -> n; n.handle(ev); n.render(); n.run(); n.shutdown(); n.notify(level, text); n.status(); n.hooks = { on_event = {}, on_message = {}, tick = {}, pages = {} } (Rollen tragen sich dort ein)
Notes: env = { fs, peripheral, redstone, rednet, raw_clock, term, wrap(name), pull_event() -> Ereignis, start_timer(sekunden) }. Zustand liegt in /crn_data (config.lua, clock.lua, journal.log). Nach einem Neustart wird die Konfiguration geheilt (store.heal), alle offenen Journal-Vorgaenge bleiben sichtbar. Ein Fehler in einer Rollen-Verbindung stoppt weder die Schleife noch andere Rollen (er wird als Meldung gezeigt).
]]

local storelib = require("core.store")
local clocklib = require("core.clock")
local tickerlib = require("core.ticker")
local journallib = require("core.journal")
local msg = require("core.msg")
local netlib = require("core.net")
local detect = require("dev.detect")
local bind = require("dev.bind")
local eventslib = require("dev.events")
local viewlib = require("ui.view")
local W = require("ui.widgets")
local setup_page = require("setup.page")
local version = require("core.version")
local envcheck = require("core.envcheck")
local dataformat = require("core.dataformat")
local model = require("setup.model")
local ser = require("core.ser")

local M = {}

local DATA = "/crn_data"
local CONFIG = DATA .. "/config.lua"
local MAX_MESSAGES = 60

local UI_EVENTS = { key = true, char = true, mouse_click = true, monitor_touch = true }

function M.new(env)
  local n = {}
  n.hooks = { on_event = {}, on_message = {}, tick = {}, pages = {} }
  n.messages = {}
  n.running = false

  if not env.fs.exists(DATA) then env.fs.makeDir(DATA) end
  local store = storelib.new(env.fs)
  store.heal(CONFIG)
  store.heal(DATA .. "/clock.lua")
  n.store = store
  n.clock = clocklib.new({ raw = env.raw_clock, store = store, path = DATA .. "/clock.lua" })
  n.journal = journallib.new({ fs = env.fs, path = DATA .. "/journal.log", now = n.clock.now })
  n.ticker = tickerlib.new(n.clock)
  n.config = store.load(CONFIG)
  n.scan = detect.scan(env.peripheral)

  -- Datenformat (29.2): neuere Daten als dieses Programm kennt -> Automatik bleibt aus, bis eine passende Sicherung zurueckgespielt ist
  local format_status, format_old = dataformat.check(env.fs, store, { program = version.number })
  n.format_status, n.format_old = format_status, format_old
  n.format_blocked = format_status == "zu_neu"

  -- Schnittstellen (14.1, A18): nach einem Modpack-Update wartet die Automatik auf die bestandene Pruefung
  n.env_hold = false
  if n.config and n.config.status == "aktiv" then
    local status = envcheck.check(store, DATA .. "/umgebung.lua", n.scan, env.host)
    n.env_status = status
    n.env_hold = status == "geaendert"
  end

  function n.notify(level, text)
    n.messages[#n.messages + 1] = { level = level, text = text, t = n.clock.now(), acked = false }
    if #n.messages > MAX_MESSAGES then table.remove(n.messages, 1) end
    n.dirty = true
  end

  function n.status()
    if not n.config then return { text = "Einrichtung", kind = "wait" } end
    if n.format_blocked then return { text = "Datenformat zu neu", kind = "halt" } end
    if n.config.status ~= "aktiv" then return { text = "Entwurf", kind = "attention" } end
    if n.env_hold then return { text = "Pruefung noetig", kind = "attention" } end
    return { text = "Bereit", kind = "ok" }
  end

  local function role_text()
    if not n.config then return "nicht eingerichtet" end
    local names = {}
    for _, r in ipairs(n.config.node.roles) do names[#names + 1] = r end
    return table.concat(names, "+")
  end

  local ctx = {
    title = function()
      if not n.config then return "CRN - noch nicht eingerichtet" end
      return n.config.node.name .. " - " .. role_text()
    end,
    status = function() return n.status() end,
    on_action = function(v, id)
      if id == "back" then v.set_page("uebersicht") end
    end,
    node = n,
  }

  -- Netzverbindung (Funk) nur mit eingerichteter Node; Stufen 4 bis 9 haengen sich ueber hooks an
  local function wireless(name)
    local ok, w = pcall(env.peripheral.call, name, "isWireless")
    return ok and w == true
  end

  -- Pruefung nach Modpack-Update: alle eingerichteten Geraete muessen da sein, die richtige Art haben und alle erwarteten Methoden bieten
  function n.confirm_environment()
    if not n.env_hold then return true, "Es ist keine Pruefung noetig." end
    n.scan = detect.scan(env.peripheral)
    for _, p in ipairs(model.validate(n.config, n.scan)) do
      if p.code == "geraet_fehlt" or p.code == "geraet_art" or p.code == "geraet_methoden" then
        return false, "Pruefung nicht bestanden: " .. p.text
      end
    end
    envcheck.accept(store, DATA .. "/umgebung.lua", n.scan, env.host)
    n.env_hold, n.env_status = false, "gleich"
    n.notify("info", "Schnittstellenpruefung bestanden: die Automatik laeuft wieder.")
    return true, "Pruefung bestanden."
  end

  -- Seiten ------------------------------------------------------------------------------------------------------------------------------
  local pages = {}

  pages[#pages + 1] = {
    id = "uebersicht", title = "Uebersicht",
    render = function(v, rect)
      local y = rect.y
      local function line(text, kind) W.label(v, rect.x + 1, y, text, kind or "text", rect.w - 2) y = y + 1 end
      line(version.name .. " " .. version.number, "hell")
      if n.config then
        line("Node: " .. n.config.node.name .. " (" .. n.config.node.id .. ")")
        line("Rolle: " .. role_text())
        line("Netz: " .. n.config.network.name .. (n.config.network.central_id and ("   Leitstelle: " .. n.config.network.central_id) or "   (Leitstelle)"))
        line("Zustand: " .. n.config.status .. "   Einrichtung Nr. " .. tostring(n.config.revision))
      else
        line("Dieser Computer ist noch nicht eingerichtet.", "attention")
        line("Weiter mit der Seite 'Einrichtung'.")
      end
      y = y + 1
      local seconds = math.floor(n.clock.now())
      line(string.format("Betriebszeit: %d:%02d:%02d%s", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60,
        n.clock.resumed() and " (fortgesetzt)" or ""), "dim")
      line("Freier Platz: " .. env.fs.getFreeSpace("/") .. " Byte", "dim")
      local counts = { station = 0, signal = 0, observer = 0 }
      for _, d in ipairs(n.scan) do if counts[d.kind] then counts[d.kind] = counts[d.kind] + 1 end end
      line(string.format("Geraete: %d Bahnhof, %d Signal, %d Beobachter", counts.station, counts.signal, counts.observer), "dim")
      local radio = {}
      for _, d in ipairs(n.scan) do if d.kind == "modem" and wireless(d.name) then radio[#radio + 1] = d.name end end
      line("Funk: " .. (#radio > 0 and table.concat(radio, ",") or "KEIN FUNKMODEM"), #radio > 0 and "dim" or "attention")
      local open = #n.journal.pending()
      if open > 0 then line(open .. " offene Vorgaenge im Journal", "wait") end
      if n.format_blocked then line("Die Daten haben ein neueres Format (" .. tostring(n.format_old) .. ") als dieses Programm: Automatik aus.", "halt") end
      if n.env_hold then line("Modpack oder Schnittstellen haben sich geaendert: Automatik wartet auf die Pruefung.", "attention") end
      if n.format_status == "migriert" then line("Daten auf das neue Format gebracht; Sicherung: sicherung_f" .. tostring(n.format_old), "dim") end
    end,
    actions = function(v)
      if n.env_hold then return { { id = "umgebung", label = "Pruefen", kind = "primary" } } end
      return {}
    end,
    on_action = function(v, id)
      if id == "act:umgebung" then
        local ok, text = n.confirm_environment()
        v.hint = text
        return true
      end
    end,
  }

  pages[#pages + 1] = {
    id = "geraete", title = "Geraete",
    render = function(v, rect)
      local state = v.page_state("geraete")
      state.list = state.list or { index = 1 }
      local checks = n.config and bind.check(n.config.devices, n.scan) or {}
      local by_device = {}
      if n.config then
        for id, spec in pairs(n.config.devices) do by_device[spec.device] = { id = id, check = checks[id] } end
      end
      local items = {}
      for _, d in ipairs(n.scan) do
        local bound = by_device[d.name]
        local detail = table.concat(d.types, ",")
        local kind = "dim"
        if bound then
          detail = detail .. " -> " .. bound.id .. " (" .. bound.check.status .. ")"
          if bound.check.status ~= "ok" then kind = "attention" end
        end
        items[#items + 1] = { text = d.name, detail = detail, kind = kind }
      end
      -- gebundene, aber fehlende Geraete stehen ebenfalls in der Liste
      if n.config then
        for id, check in pairs(checks) do
          if check.status == "fehlt" then items[#items + 1] = { text = n.config.devices[id].device, detail = "FEHLT (" .. id .. ")", kind = "halt" } end
        end
      end
      W.list(v, "geraete", rect, items, state.list, { empty = "Keine Geraete angeschlossen." })
    end,
  }

  pages[#pages + 1] = {
    id = "meldungen", title = "Meldungen",
    render = function(v, rect)
      local state = v.page_state("meldungen")
      state.list = state.list or { index = 1 }
      local items = {}
      for i = #n.messages, 1, -1 do
        local m = n.messages[i]
        local kind = m.acked and "dim" or (m.level == "fehler" and "halt" or m.level == "warnung" and "attention" or "text")
        items[#items + 1] = { text = m.text, detail = string.format("%d s%s", math.floor(m.t), m.acked and " (quittiert)" or ""), kind = kind, index = i }
      end
      state.items = items
      W.list(v, "meldungen", rect, items, state.list, { empty = "Keine Meldungen." })
    end,
    actions = function(v)
      local state = v.page_state("meldungen")
      local selected = state.items and state.items[(state.list or { index = 1 }).index]
      return { { id = "quittieren", label = "Quittieren", enabled = selected ~= nil, reason = "Keine Meldung gewaehlt." } }
    end,
    on_action = function(v, id)
      if id == "act:quittieren" then
        local state = v.page_state("meldungen")
        local selected = state.items and state.items[state.list.index]
        if selected then
          n.messages[selected.index].acked = true
          v.hint = "Quittiert; Belegung und Signale bleiben."
        end
        return true
      end
    end,
    hint = function() return "Quittieren aendert nie Belegung oder Signal." end,
  }

  n.setup = setup_page.new({
    scan = function() n.scan = detect.scan(env.peripheral) return n.scan end,
    env = env,
    now = function() return n.clock.now() end,
    store = store,
    config_path = CONFIG,
    config = function() return n.config end,
    modem_is_wireless = wireless,
    notify = n.notify,
    fetch_config = function(central_id, node_id) return n.fetch_config(central_id, node_id) end,
    fetch_status = function() return n.fetch_state end,
    on_saved = function(config)
      n.config = config
      n.rebuild_views()
      n.start_services()
      n.dirty = true
    end,
  })
  pages[#pages + 1] = n.setup

  function n.all_pages()
    local list = {}
    for _, p in ipairs(pages) do list[#list + 1] = p end
    for _, p in ipairs(n.hooks.pages) do list[#list + 1] = p end
    return list
  end

  -- Ansichten: Terminal und je ein Monitor aus der Konfiguration -----------------------------------------------------------------
  n.views = {}
  function n.rebuild_views()
    local old = {}
    for _, v in ipairs(n.views) do old[v.name or "terminal"] = v end
    n.views = {}
    local function add(name, target)
      local v = old[name or "terminal"]
      if v then
        v.target = target
        v.pages = n.all_pages()
      else
        v = viewlib.new({ target = target, name = name, ctx = ctx, pages = n.all_pages() })
        if not n.config then v.set_page("einrichtung") end
      end
      n.views[#n.views + 1] = v
    end
    add(nil, env.term)
    if n.config then
      local ids = {}
      for id, d in pairs(n.config.devices) do if d.kind == "monitor" then ids[#ids + 1] = id end end
      table.sort(ids)
      for _, id in ipairs(ids) do
        local name = n.config.devices[id].device
        local target = env.wrap and env.wrap(name)
        if target then add(name, target) end
      end
    end
  end

  function n.render()
    for _, v in ipairs(n.views) do
      local ok, err = pcall(v.render)
      if not ok then n.notify("fehler", "Anzeige " .. tostring(v.name or "Terminal") .. ": " .. tostring(err)) end
    end
    n.dirty = false
  end

  -- Netz ----------------------------------------------------------------------------------------------------------------------------------
  local function setup_net()
    if not n.config or n.config.status ~= "aktiv" then return end
    local info = netlib.open({ rednet = env.rednet, peripheral = env.peripheral })
    n.net_info = info
    n.factory = msg.new({ node_id = n.config.node.id, boot_id = n.clock.boot_id(), epoch = function() return n.own_epoch or n.inbox.epoch() end })
    n.inbox = msg.inbox({ node_id = n.config.node.id, central_id = n.config.network.central_id or n.config.node.id })
    n.net = netlib.new({ rednet = env.rednet, factory = n.factory, inbox = n.inbox, clock = n.clock })
    if #info.opened == 0 then n.notify("fehler", "Kein Modem fuer den Funk gefunden.")
    elseif info.fallback then n.notify("warnung", "Kein Funkmodem: es wird das Kabelmodem benutzt.") end
  end

  function n.start_services()
    setup_net()
    n.router = eventslib.router({ bindings = n.config and bind.routes(n.config.devices) or {}, now = n.clock.now })
    n.attach_roles()
  end

  -- Dienste fuer die Rollen -----------------------------------------------------------------------------------------------------------------
  n.env = env
  local local_queue = {}

  function n.central_id()
    if n.config and n.config.network.central_id then return n.config.network.central_id end
    return n.config and n.config.node.id
  end

  -- Nachricht ausliefern: an sich selbst lokal (mehrere Rollen auf einem Computer), sonst ueber Funk
  function n.send_message(m)
    if n.config and m.targetNodeId == n.config.node.id then
      local_queue[#local_queue + 1] = m
      return "lokal"
    end
    if not n.net then return nil end
    return n.net.send(m.targetNodeId, m)
  end

  function n.send_to(target, message_type, payload, extra)
    if not n.factory then return nil end
    local m = n.factory.make(message_type, target, payload, extra)
    n.send_message(m)
    return m
  end

  -- fachliche Antwort; wird fuer wiederholte Anfragen gemerkt (13.3)
  function n.reply(m, status, payload)
    local body = { kind = "antwort", status = status, antwort_auf = m.payload.kind }
    for k, v in pairs(payload or {}) do body[k] = v end
    local reply = n.factory.make("bestaetigung", m.senderNodeId, body, { correlationId = m.messageId, requestId = m.requestId })
    n.inbox.remember(m.messageId, reply)
    n.send_message(reply)
    return reply
  end

  -- Ereignisse ---------------------------------------------------------------------------------------------------------------------------
  local function run_hooks(list, ...)
    for i, fn in ipairs(list) do
      local ok, err = pcall(fn, ...)
      if not ok then n.notify("fehler", "Rolle " .. i .. ": " .. tostring(err)) end
    end
  end

  -- lokal gesendete Nachrichten (an die eigene Kennung) wie empfangene behandeln; begrenzt gegen Endlosschleifen
  local function deliver_local()
    local rounds = 0
    while #local_queue > 0 and rounds < 200 do
      rounds = rounds + 1
      local m = table.remove(local_queue, 1)
      local status, extra = n.inbox.accept(m)
      run_hooks(n.hooks.on_message, m, status, extra)
    end
  end

  function n.handle(ev)
    local kind = ev[1]
    if UI_EVENTS[kind] then
      for _, v in ipairs(n.views) do
        if v.handle(ev) then n.dirty = true end
      end
    elseif kind == "rednet_message" then
      if not n.net and n.replace_net then n.replace_receive(ev) end
      if n.net then
        local m, status, extra = n.net.receive(ev)
        if m then
          if status == "node_conflict" then n.notify("fehler", "Zwei Computer melden sich als " .. m.senderNodeId .. ".") end
          run_hooks(n.hooks.on_message, m, status, extra)
        end
      end
    elseif kind == "peripheral" or kind == "peripheral_detach" then
      local before = n.scan
      n.scan = detect.scan(env.peripheral)
      local added, removed = detect.diff(before, n.scan)
      for _, name in ipairs(added) do n.notify("info", "Geraet angeschlossen: " .. name) end
      for _, name in ipairs(removed) do n.notify("warnung", "Geraet entfernt: " .. name) end
      n.dirty = true
    elseif kind == "monitor_resize" then
      n.dirty = true
    elseif n.router then
      local routed = n.router.route(ev)
      if routed then
        if routed.problem then n.notify("warnung", routed.problem .. ": " .. tostring(routed.device)) end
        run_hooks(n.hooks.on_event, routed)
        n.dirty = true
      end
    end
    deliver_local()
    n.ticker.poll()
  end

  function n.tick()
    run_hooks(n.hooks.tick)
  end


  -- Konfigurationssicherung und Ersatzcomputer (29.2, A17) ----------------------------------------------------------------------------------
  -- Jede aktive Node (ausser der Leitstelle) schickt ihre Konfiguration nach jeder Aenderung an die Leitstelle. Ein Ersatzcomputer holt sie dort ab,
  -- sobald die alte Node dort stillgelegt ist oder sich nicht mehr meldet; danach werden die Geraete gegen den realen Anschluss geprueft.
  local backup = { acked = nil, sent = -9999, id = nil, rev = nil }
  table.insert(n.hooks.tick, function()
    if not n.config or n.config.status ~= "aktiv" or not n.net then return end
    for _, r in ipairs(n.config.node.roles) do if r == "zentrale" then return end end
    if backup.acked == n.config.revision then return end
    local t = n.clock.now()
    if t - backup.sent < 30 then return end
    local m = n.send_to(n.central_id(), "meldung", { kind = "konfig", node = n.config.node.id, revision = n.config.revision, config = ser.encode(n.config) })
    if m then backup.id, backup.rev, backup.sent = m.messageId, n.config.revision, t end
  end)
  table.insert(n.hooks.on_message, function(m, status)
    if status == "ok" and m.messageType == "bestaetigung" and backup.id and m.correlationId == backup.id then backup.acked = backup.rev end
  end)

  n.fetch_state = nil
  function n.fetch_config(central_id, node_id)
    if n.net then n.fetch_state = { kind = "halt", text = "Dieser Computer ist schon eingerichtet." } return end
    local info = netlib.open({ rednet = env.rednet, peripheral = env.peripheral })
    if #info.opened == 0 then n.fetch_state = { kind = "halt", text = "Kein Modem gefunden." } return end
    if not n.replace_net then
      local boot = n.clock.boot_id()
      local me = "ersatz-" .. tostring(boot)
      n.replace_factory = msg.new({ node_id = me, boot_id = boot, epoch = function() return 0 end })
      n.replace_net = netlib.new({ rednet = env.rednet, factory = n.replace_factory, inbox = msg.inbox({ node_id = me, central_id = central_id }), clock = n.clock })
    end
    local m = n.replace_factory.make("abfrage", central_id, { kind = "konfig_holen", node = node_id })
    n.replace_net.send(central_id, m)
    n.replace_req = m.messageId
    n.fetch_state = { kind = "wait", text = "Anfrage an " .. central_id .. " gesendet ..." }
  end

  function n.replace_receive(ev)
    local m = n.replace_net.receive(ev)
    if not m or m.correlationId ~= n.replace_req then return end
    local p = m.payload
    if p.status ~= "ok" then
      n.fetch_state = { kind = "halt", text = "Abgelehnt: " .. tostring(p.grund) }
      return
    end
    local config = ser.decode(p.config)
    if type(config) ~= "table" or not config.node then
      n.fetch_state = { kind = "halt", text = "Die Konfiguration ist nicht lesbar." }
      return
    end
    config.status = "entwurf"
    n.fetch_state = { kind = "ok", text = "Konfiguration von " .. tostring(config.node.id) .. " (Stand " .. tostring(config.revision) .. ") empfangen.", config = config }
  end

  -- Rollen anschliessen (nach Aktivierung und beim Start einer aktiven Node)
  local attached = {}
  function n.attach_roles()
    for _, entry in ipairs(attached) do
      for _, list in ipairs({ "on_event", "on_message", "tick" }) do
        for i = #n.hooks[list], 1, -1 do
          if n.hooks[list][i] == entry[list] then table.remove(n.hooks[list], i) end
        end
      end
      for _, page in ipairs(entry.page_list) do
        for i = #n.hooks.pages, 1, -1 do
          if n.hooks.pages[i] == page then table.remove(n.hooks.pages, i) end
        end
      end
    end
    attached = {}
    n.roles = {}
    if not n.config or n.config.status ~= "aktiv" or not n.net then return end
    if n.format_blocked then
      n.notify("fehler", "Die Daten stammen von einem neueren Programm (Format " .. tostring(n.format_old) .. "). Die Automatik startet nicht. Mit 'crn/app/main daten-zurueck N' wird eine Sicherung zurueckgespielt.")
      return
    end
    local modules = {}
    for _, role in ipairs(n.config.node.roles) do
      if role == "passagierbahnhof" or role == "gueterbahnhof" or role == "depot" then modules.station = "roles.station"
      elseif role == "zentrale" then modules.zentrale = "roles.zentrale"
      elseif role == "anmeldung" then modules.anmeldung = "roles.anmeldung"
      elseif role == "signal" or role == "knoten" then modules.signal = "roles.signal"
        if role == "knoten" then modules.knoten = "roles.knoten" end
      end
    end
    -- feste Reihenfolge: der Knoten braucht den Signal-Dienst, der vor ihm entstehen muss
    local names = {}
    for _, name in ipairs({ "station", "zentrale", "anmeldung", "signal", "knoten" }) do
      if modules[name] then names[#names + 1] = name end
    end
    for _, name in ipairs(names) do
      local ok, obj = pcall(function()
        if name == "knoten" then return require(modules[name]).new(n, n.roles.signal) end
        return require(modules[name]).new(n)
      end)
      if not ok then
        n.notify("fehler", "Rolle " .. name .. " konnte nicht starten: " .. tostring(obj))
      else
        n.roles[name] = obj
        local entry = { on_event = obj.on_event, on_message = obj.on_message, tick = obj.tick, page_list = {} }
        if obj.on_event then n.hooks.on_event[#n.hooks.on_event + 1] = obj.on_event end
        if obj.on_message then n.hooks.on_message[#n.hooks.on_message + 1] = obj.on_message end
        if obj.tick then n.hooks.tick[#n.hooks.tick + 1] = obj.tick end
        for _, p in ipairs(obj.pages or {}) do entry.page_list[#entry.page_list + 1] = p end
        if obj.page then entry.page_list[#entry.page_list + 1] = obj.page end
        for _, p in ipairs(entry.page_list) do n.hooks.pages[#n.hooks.pages + 1] = p end
        attached[#attached + 1] = entry
      end
    end
    n.rebuild_views()
  end

  n.ticker.every("uhr", 30, function() n.clock.save() end)
  n.ticker.every("anzeige", 1, function() n.dirty = true end)
  n.ticker.every("takt", 1, function() n.tick() end)

  function n.shutdown()
    n.clock.save()
    n.running = false
  end

  function n.run()
    n.running = true
    n.render()
    local timer = env.start_timer(1)
    local ok, err = pcall(function()
      while n.running do
        local ev = env.pull_event()
        if ev[1] == "timer" then
          timer = env.start_timer(1)
        end
        n.handle(ev)
        if n.dirty then n.render() end
      end
    end)
    n.shutdown()
    if not ok and tostring(err) ~= "Terminated" then error(err, 0) end
  end

  n.rebuild_views()
  n.start_services()
  if n.config and n.config.status ~= "aktiv" then n.notify("warnung", "Die Einrichtung ist nur ein Entwurf: die Betriebsfunktion bleibt inaktiv.") end
  if n.env_hold then n.notify("warnung", "Die Umgebung (Modpack/Schnittstellen) hat sich geaendert: neue Abfahrten bleiben aus, bis die Pruefung auf der Seite Uebersicht bestanden ist.") end
  return n
end

return M
