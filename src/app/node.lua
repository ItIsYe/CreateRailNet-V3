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
local pruefunglib = require("setup.pruefung")
local version = require("core.version")
local envcheck = require("core.envcheck")
local dataformat = require("core.dataformat")
local model = require("setup.model")
local ser = require("core.ser")
local chunks = require("core.chunks")
local adler = require("core.adler")

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
    role_available = function(role)
      if not env.fs.exists("/crn/manifest.lua") then return true end
      local files = { zentrale="zentrale", passagierbahnhof="station", gueterbahnhof="station", depot="station", anmeldung="anmeldung", signal="signal", knoten="knoten" }
      return files[role] ~= nil and env.fs.exists("/crn/roles/" .. files[role] .. ".lua")
    end,
    notify = n.notify,
    fetch_config = function(central_id, node_id) return n.fetch_config(central_id, node_id) end,
    fetch_status = function() return n.fetch_state end,
    search_networks = function() return n.search_networks() end,
    search_status = function() return n.search_status() end,
    mark_dirty = function() n.dirty = true end,
    directory_areas = function(central_id) return n.directory_areas(central_id) end,
    directory_tracks = function(central_id, area_id) return n.directory_tracks(central_id, area_id) end,
    directory_claim = function(central_id, claim, role, area_id, track_ids, junction_id, legacy_id, extra) return n.directory_claim(central_id, claim, role, area_id, track_ids, junction_id, legacy_id, extra) end,
    directory_stations = function(central_id) return n.directory_stations(central_id) end,
    directory_backups = function(central_id) return n.directory_backups(central_id) end,
    directory_junctions = function(central_id) return n.directory_junctions(central_id) end,
    directory_junction = function(central_id, junction_id) return n.directory_junction(central_id, junction_id) end,
    directory_area_create = function(central_id, token, spec) return n.directory_area_create(central_id, token, spec) end,
    directory_track_change = function(central_id, claim, track_id, fields, if_rev) return n.directory_track_change(central_id, claim, track_id, fields, if_rev) end,
    directory_status = function() return n.directory_status() end,
    directory_reset = function() return n.directory_reset() end,
    new_claim = function() return n.new_claim() end,
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
    -- Nachrichtenkennungen zaehlen weiter, auch wenn die Dienste ohne Neustart neu aufgebaut werden (Einrichtung geaendert): sonst wuerden die Empfaenger
    -- die ersten Nachrichten danach als Wiederholung verwerfen
    if not (n.factory and n.factory_id == n.config.node.id) then
      n.factory = msg.new({ node_id = n.config.node.id, boot_id = n.clock.boot_id(), epoch = function() return n.own_epoch or n.inbox.epoch() end })
      n.factory_id = n.config.node.id
    end
    n.inbox = msg.inbox({ node_id = n.config.node.id, central_id = n.config.network.central_id or n.config.node.id })
    n.net = netlib.new({ rednet = env.rednet, factory = n.factory, inbox = n.inbox, clock = n.clock })
    if #info.opened == 0 then n.notify("fehler", "Kein Modem fuer den Funk gefunden.")
    elseif info.fallback then n.notify("warnung", "Kein Funkmodem: es wird das Kabelmodem benutzt.") end
  end

  function n.save_config() return store.save(CONFIG, n.config) end

  function n.set_label(text)
    if type(text) == "string" and env.set_label then return pcall(env.set_label, text) end
    return false
  end

  function n.start_services()
    if n.config and n.config.status == "aktiv" and n.config.node.label then n.set_label(n.config.node.label) end
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

  -- die Einrichtung (Antworten der Leitstelle, schrittweise Abschlusspruefung) laeuft im Sekundentakt mit
  table.insert(n.hooks.tick, function()
    if n.setup and n.setup.tick then n.setup.tick() end
  end)


  -- Konfigurationssicherung und Ersatzcomputer (29.2, A17) ----------------------------------------------------------------------------------
  -- Jede aktive Node (ausser der Leitstelle) schickt ihre Konfiguration nach jeder Aenderung an die Leitstelle. Ein Ersatzcomputer holt sie dort ab,
  -- sobald die alte Node dort stillgelegt ist oder sich nicht mehr meldet; danach werden die Geraete gegen den realen Anschluss geprueft.
  -- Die Konfiguration geht in Teilen (eine Funknachricht fasst hoechstens 6000 Zeichen); gesichert ist sie, wenn die Leitstelle den vollstaendigen Satz
  -- bestaetigt ("fertig"). Ohne Bestaetigung wird nach 30 Sekunden alles noch einmal geschickt; eine Ablehnung wird einmal gemeldet und erst nach einer
  -- neuen Fassung der Konfiguration wiederholt.
  local BACKUP_PAYLOAD_LIMIT = 5000
  local backup = { acked = nil, sent = -9999, ids = {}, failed = nil }       -- ids: Nachrichtenkennung -> Stand, auf den sich die Quittung bezieht
  table.insert(n.hooks.tick, function()
    if not n.config or n.config.status ~= "aktiv" or not n.net then return end
    for _, r in ipairs(n.config.node.roles) do if r == "zentrale" then return end end
    local rev = n.config.revision
    if backup.acked == rev or backup.failed == rev then return end
    local t = n.clock.now()
    if t - backup.sent < 30 then return end
    backup.sent = t          -- vor dem Senden: ein Fehler darf nicht jede Sekunde wiederholt werden
    local text = ser.encode(n.config)
    local sum, id = adler.hex(text), n.config.node.id
    local parts, why = chunks.parts_text(text, function(piece, i, count)
      return { kind = "konfig", node = id, revision = rev, part = i, parts = count, sum = sum, config = piece }
    end, BACKUP_PAYLOAD_LIMIT, ser)
    if not parts then
      backup.failed = rev
      n.notify("fehler", "Die Konfiguration laesst sich nicht sichern: " .. tostring(why))
      return
    end
    local known = 0
    for _ in pairs(backup.ids) do known = known + 1 end
    if known > 200 then backup.ids = {} end
    for _, payload in ipairs(parts) do
      local m = n.send_to(n.central_id(), "meldung", payload)
      if m then backup.ids[m.messageId] = rev end
    end
  end)
  table.insert(n.hooks.on_message, function(m, status)
    if (status ~= "ok" and status ~= "old_sequence") or m.messageType ~= "bestaetigung" then return end
    local rev = backup.ids[m.correlationId]
    local p = m.payload
    -- Quittungen auch frueherer Versuche zaehlen; gesichert ist der Stand, auf den sich die Quittung bezieht
    if rev == nil or type(p) ~= "table" then return end
    if p.status == "ok" and p.fertig == true then
      backup.acked = rev
    elseif p.status == "abgelehnt" and backup.failed ~= rev then
      backup.failed = rev
      n.notify("warnung", "Die Leitstelle hat die Konfigurationssicherung abgelehnt: " .. tostring(p.grund))
    end
  end)

  -- Computer ohne Einrichtung sprechen mit einer vorlaeufigen Kennung (Ersatz holen, Netz suchen)
  local function temporary_net(central_id)
    if not n.replace_net then
      local boot = n.clock.boot_id()
      local me = "neu-" .. tostring(boot)
      n.replace_factory = msg.new({ node_id = me, boot_id = boot, epoch = function() return 0 end })
      n.replace_net = netlib.new({ rednet = env.rednet, factory = n.replace_factory, inbox = msg.inbox({ node_id = me, central_id = central_id }), clock = n.clock })
    end
    return n.replace_net
  end

  -- Netzsuche (Assistent, Beitreten): Rundruf, die Leitstellen in Reichweite nennen Netzname und Kennung
  local SEARCH_SECONDS = 4
  n.search_state = nil
  function n.search_networks()
    if n.net then n.search_state = { kind = "halt", text = "Dieser Computer ist schon eingerichtet.", networks = {} } return end
    local info = netlib.open({ rednet = env.rednet, peripheral = env.peripheral })
    if #info.opened == 0 then n.search_state = { kind = "halt", text = "Kein Modem gefunden: das Netz von Hand eingeben.", networks = {} } return end
    local net = temporary_net(nil)
    local m = n.replace_factory.make("abfrage", "*", { kind = "netze" })
    net.broadcast(m)
    n.search_req, n.search_until = m.messageId, n.clock.now() + SEARCH_SECONDS
    n.search_state = { kind = "wait", text = "Suche laeuft ...", networks = {} }
  end

  function n.search_status()
    local st = n.search_state
    if st and st.kind == "wait" and n.clock.now() >= n.search_until then
      if #st.networks > 0 then
        st.kind, st.text = "ok", #st.networks .. " Netz(e) gefunden."
      else
        st.kind, st.text = "halt", "Kein Netz gefunden. Leitstelle in Funkreichweite (Ender-Modem)? Sonst von Hand eingeben."
      end
    end
    return st
  end

  -- Antworten sind unbeglaubigt (Rednet ist keine Anmeldung): nur Name und Kennung in der erlaubten Form werden uebernommen
  local function collect_network(m)
    local st, p = n.search_state, m.payload
    if not st or st.kind ~= "wait" or type(p) ~= "table" or p.status ~= "ok" then return end
    local name, central = p.netz, p.zentrale
    if type(name) ~= "string" or type(central) ~= "string" then return end
    if #name == 0 or #name > 30 or not name:match("^[%w _%-]+$") then return end
    if #central == 0 or #central > 30 or not central:match("^[%w_%-]+$") then return end
    for _, known in ipairs(st.networks) do if known.zentrale == central then return end end
    st.networks[#st.networks + 1] = { netz = name, zentrale = central, nodes = tonumber(p.nodes) or 0 }
    table.sort(st.networks, function(a, b) if a.netz ~= b.netz then return a.netz < b.netz end return a.zentrale < b.zentrale end)
    n.dirty = true
  end

  n.fetch_state = nil
  local function fetch_request(central_id, node_id, part)
    local m = n.replace_factory.make("abfrage", central_id, { kind = "konfig_holen", node = node_id, part = part })
    n.replace_net.send(central_id, m)
    n.replace_req = m.messageId
    n.fetch = { central = central_id, node = node_id, part = part }
  end

  function n.fetch_config(central_id, node_id)
    if n.net then n.fetch_state = { kind = "halt", text = "Dieser Computer ist schon eingerichtet." } return end
    local info = netlib.open({ rednet = env.rednet, peripheral = env.peripheral })
    if #info.opened == 0 then n.fetch_state = { kind = "halt", text = "Kein Modem gefunden." } return end
    temporary_net(central_id)
    n.fetch_chunks = chunks.new({ max_parts = 40, max_bytes = 60000, max_keys = 2, ttl = 300, now = function() return n.clock.now() end })
    fetch_request(central_id, node_id, 1)
    n.fetch_state = { kind = "wait", text = "Anfrage an " .. central_id .. " gesendet ..." }
  end

  -- Netzverzeichnis der Leitstelle (Signal-Einrichtung): Bereiche, Gleise eines Bereichs, Node-Kennung anfordern. Die Antworten sind unbeglaubigt
  -- (Rednet ist keine Anmeldung): nur Werte in der erlaubten Form (Kennungen, Namen aus Buchstaben, Ziffern, Leerzeichen, - und _) werden uebernommen.
  local DIR_TIMEOUT = 8
  local DIR_MAX_AREAS = 400
  n.dir_state = nil

  local function dir_id(v, prefix) return type(v) == "string" and v:match("^" .. prefix .. "%d%d%d%d+$") ~= nil and #v <= 12 end
  local function dir_name(v) return type(v) == "string" and #v > 0 and #v <= 30 and v:match("^[%w _%-]+$") ~= nil end

  -- Eine bereits eingerichtete Node fragt ueber ihren Funk mit ihrer Kennung (Einrichtung aendern, Uebernahme ins Verzeichnis); ein neuer Computer benutzt die
  -- vorlaeufige Kennung. Die Antwort kommt in beiden Faellen ueber dir_reply.
  local function dir_send(central_id, payload, handler)
    local m
    if n.net and n.factory then
      m = n.send_to(central_id, "abfrage", payload)
      if not m then n.dir_state = { kind = "halt", text = "Kein Funk." } return end
    else
      local info = netlib.open({ rednet = env.rednet, peripheral = env.peripheral })
      if #info.opened == 0 then n.dir_state = { kind = "halt", text = "Kein Modem gefunden." } return end
      temporary_net(central_id)
      m = n.replace_factory.make("abfrage", central_id, payload)
      n.replace_net.send(central_id, m)
    end
    n.dir_req, n.dir_until, n.dir_handler = m.messageId, n.clock.now() + DIR_TIMEOUT, handler
    n.dir_state = { kind = "wait", text = "Frage die Leitstelle ..." }
  end

  local function dir_bad(text)
    n.dir_state = { kind = "halt", text = text or "Unerwartete Antwort der Leitstelle." }
  end

  function n.directory_areas(central_id)
    local acc = {}
    local function page(after)
      dir_send(central_id, { kind = "verzeichnis", after = after }, function(p)
        if type(p.areas) ~= "table" then return dir_bad() end
        for _, a in ipairs(p.areas) do
          if type(a) ~= "table" or not dir_id(a.id, "B") or not dir_name(a.name) or type(a.ends) ~= "table" or not dir_name(a.ends[1]) or not dir_name(a.ends[2])
            or type(a.tracks) ~= "number" or a.tracks < 0 or a.tracks > 40 then
            return dir_bad()
          end
          acc[#acc + 1] = { id = a.id, name = a.name, ends = { a.ends[1], a.ends[2] }, tracks = a.tracks, state = (a.state == "im bau") and "im bau" or nil }
        end
        if p.more and #acc < DIR_MAX_AREAS and #acc > 0 then return page(acc[#acc].id) end
        n.dir_state = { kind = "ok", text = #acc .. " Bereich(e) im Netz.", areas = acc }
      end)
    end
    page(nil)
  end

  function n.directory_tracks(central_id, area_id)
    dir_send(central_id, { kind = "verzeichnis_gleise", area = area_id }, function(p)
      local a = p.area
      if type(a) ~= "table" or not dir_id(a.id, "B") or not dir_name(a.name) or type(a.ends) ~= "table" or not dir_name(a.ends[1]) or not dir_name(a.ends[2])
        or type(a.tracks) ~= "table" or #a.tracks > 40 then
        return dir_bad()
      end
      local tracks = {}
      for _, t in ipairs(a.tracks) do
        if type(t) ~= "table" or not dir_id(t.id, "A") or not dir_name(t.name) or not (t.direction == "beide" or t.direction == a.ends[1] or t.direction == a.ends[2]) then
          return dir_bad()
        end
        tracks[#tracks + 1] = { id = t.id, name = t.name, direction = t.direction, rev = (type(t.rev) == "number" and t.rev >= 0 and t.rev < 1e9) and math.floor(t.rev) or 0 }
      end
      n.dir_state = { kind = "ok", text = #tracks .. " Gleis(e).", area = { id = a.id, name = a.name, ends = { a.ends[1], a.ends[2] }, tracks = tracks } }
    end)
  end

  -- Knoten des Verzeichnisses (Konzept 7): Liste, dann Anschluesse, Fahrwege und Konflikte eines Knotens. Es kommt nur Bestaetigtes an.
  function n.directory_junctions(central_id)
    dir_send(central_id, { kind = "knoten_liste" }, function(p)
      if type(p.junctions) ~= "table" or #p.junctions > 100 then return dir_bad() end
      local list = {}
      for _, j in ipairs(p.junctions) do
        if type(j) ~= "table" or not dir_id(j.id, "K") or not dir_name(j.name) or type(j.connections) ~= "number" or type(j.open) ~= "number" then return dir_bad() end
        list[#list + 1] = { id = j.id, name = j.name, connections = math.floor(j.connections), open = math.floor(j.open) }
      end
      n.dir_state = { kind = "ok", text = #list .. " Knoten im Netz.", junctions = list }
    end)
  end

  -- Formpruefung der drei Teile eines Knotens (Antworten sind unbeglaubigt); liefern die geprueften Daten oder nil. Der Assistent und der Abgleich der
  -- Knoten-Node benutzen dieselben Pruefungen.
  function n.parse_junction_connections(part, junction_id)
    if type(part) ~= "table" or part.id ~= junction_id then return nil end
    if not dir_name(part.name) or type(part.rev) ~= "number" or type(part.connections) ~= "table" or #part.connections > 20 then return nil end
    local conns, total = {}, 0
    for _, c in ipairs(part.connections) do
      if type(c) ~= "table" or not dir_name(c.name) or type(c.tracks) ~= "table" or #c.tracks > 40 then return nil end
      local ends = {}
      for _, t in ipairs(c.tracks) do
        if type(t) ~= "table" or not dir_id(t.id, "A") or not dir_name(t.name) or not dir_name(t.area) then return nil end
        ends[#ends + 1] = { id = t.id, name = t.name, area = t.area }
        total = total + 1
      end
      conns[#conns + 1] = { name = c.name, tracks = ends }
    end
    if total > 60 then return nil end
    return { id = junction_id, name = part.name, rev = math.floor(part.rev), connections = conns }
  end

  function n.parse_junction_routes(part, junction_id)
    if type(part) ~= "table" or part.id ~= junction_id or type(part.routes) ~= "table" or #part.routes > 60 then return nil end
    local routes = {}
    for _, r in ipairs(part.routes) do
      if type(r) ~= "table" or not dir_id(r.id, "F") or not dir_id(r.from, "A") or not dir_id(r.to, "A") then return nil end
      routes[#routes + 1] = { id = r.id, from = r.from, to = r.to }
    end
    return routes
  end

  function n.parse_junction_conflicts(part, junction_id)
    if type(part) ~= "table" or part.id ~= junction_id or type(part.conflicts) ~= "table" or #part.conflicts > 90 then return nil end
    local conflicts = {}
    for _, c in ipairs(part.conflicts) do
      if type(c) ~= "table" or not dir_id(c.a, "F") or not dir_id(c.b, "F") then return nil end
      conflicts[#conflicts + 1] = { a = c.a, b = c.b }
    end
    return conflicts
  end

  function n.directory_junction(central_id, junction_id)
    local result
    local function ask(part, handler)
      dir_send(central_id, { kind = "knoten_teil", junction = junction_id, part = part }, function(p)
        if type(p.part) ~= "table" or p.part.id ~= junction_id then return dir_bad() end
        handler(p.part)
      end)
    end
    ask("anschluesse", function(part)
      result = n.parse_junction_connections(part, junction_id)
      if not result then return dir_bad() end
      ask("fahrwege", function(routes_part)
        local routes = n.parse_junction_routes(routes_part, junction_id)
        if not routes then return dir_bad() end
        result.routes = routes
        ask("konflikte", function(conflict_part)
          local conflicts = n.parse_junction_conflicts(conflict_part, junction_id)
          if not conflicts then return dir_bad() end
          result.conflicts = conflicts
          n.dir_state = { kind = "ok", text = "Knoten " .. result.name .. " geladen.", junction = result }
        end)
      end)
    end)
  end

  -- Betriebsstellen des Netzes (seitenweise), zum Beispiel fuer die Einrichtung einer Anmeldung
  function n.directory_stations(central_id)
    local acc = {}
    local function page(after)
      dir_send(central_id, { kind = "betriebsstellen_liste", after = after }, function(p)
        if type(p.stations) ~= "table" then return dir_bad() end
        for _, st in ipairs(p.stations) do
          if type(st) ~= "table" or not dir_id(st.id, "BF") or not dir_name(st.name) or not (st.kind == "personenbahnhof" or st.kind == "gueterbahnhof" or st.kind == "depot") then
            return dir_bad()
          end
          acc[#acc + 1] = { id = st.id, name = st.name, kind = st.kind }
        end
        if p.more and #acc < 300 and #acc > 0 then return page(acc[#acc].id) end
        n.dir_state = { kind = "ok", text = #acc .. " Betriebsstelle(n) im Netz.", stations = acc }
      end)
    end
    page(nil)
  end

  -- Nodes mit Sicherung in der Leitstelle (Ersatzcomputer, Konzept 11.4): Kennung, Name und Zustand; die Antwort ist unbeglaubigt, also werden nur Werte
  -- in der erlaubten Form uebernommen
  local BACKUP_STATES = { stillgelegt = true, ausgefallen = true, aktiv = true }
  function n.directory_backups(central_id)
    local acc = {}
    local function page(after)
      dir_send(central_id, { kind = "ersatz_liste", after = after }, function(p)
        if type(p.backups) ~= "table" then return dir_bad() end
        for _, b in ipairs(p.backups) do
          if type(b) ~= "table" or type(b.id) ~= "string" or #b.id == 0 or #b.id > 30 or not b.id:match("^[%w_%-]+$") or not BACKUP_STATES[b.state] then
            return dir_bad()
          end
          local name = (type(b.name) == "string" and #b.name <= 60 and b.name:match("^[%w _%-]*$")) and b.name or ""
          acc[#acc + 1] = { id = b.id, name = name, state = b.state }
        end
        if p.more and #acc < 100 and #acc > 0 then return page(acc[#acc].id) end
        n.dir_state = { kind = "ok", text = #acc .. " Node(s) mit Sicherung.", backups = acc }
      end)
    end
    page(nil)
  end

  -- extra = { roles = Liste, station = Kennung } fuer kombinierte Rollen beziehungsweise die Anmeldung
  function n.directory_claim(central_id, claim, role, area_id, track_ids, junction_id, legacy_id, extra)
    extra = extra or {}
    dir_send(central_id, { kind = "node_anfordern", claim = claim, role = role, roles = extra.roles, area = area_id, tracks = track_ids, junction = junction_id, station = extra.station, legacy = legacy_id }, function(p)
      local node = p.node
      if type(node) ~= "table" or not dir_id(node.id, "N") or type(node.name) ~= "string" or #node.name > 60 or not node.name:match("^[%w _%-]+$")
        or type(node.label) ~= "string" or #node.label > 60 or not node.label:match("^[%w _%-|]+$") then
        return dir_bad()
      end
      n.dir_state = { kind = "ok", text = "Kennung " .. node.id .. " vergeben.", node = { id = node.id, name = node.name, label = node.label } }
    end)
  end

  -- Name oder Richtung eines Gleises aendern (Konzept 12.4); die Leitstelle prueft, dass das Gleis zur Anforderung gehoert und der Stand noch aktuell ist
  function n.directory_track_change(central_id, claim, track_id, fields, if_rev)
    dir_send(central_id, { kind = "gleis_aendern", claim = claim, track = track_id, name = fields.name, direction = fields.direction, if_rev = if_rev }, function(p)
      local t = p.track
      if type(t) ~= "table" or not dir_id(t.id, "A") or t.id ~= track_id or not dir_name(t.name) or not dir_name(t.direction) then return dir_bad() end
      n.dir_state = { kind = "ok", text = "Gleis geaendert.", track = { id = t.id, name = t.name, direction = t.direction, rev = (type(t.rev) == "number" and t.rev >= 0 and t.rev < 1e9) and math.floor(t.rev) or 0 } }
    end)
  end

  -- Bereich von der Node aus anlegen (Konzept 10.2); die Kennung bleibt bei Wiederholung gleich, die Leitstelle legt dann nichts doppelt an
  function n.directory_area_create(central_id, token, spec)
    dir_send(central_id, { kind = "bereich_anlegen", token = token, name = spec.name, ends = spec.ends, count = spec.count, pattern = spec.pattern }, function(p)
      local a = p.area
      if type(a) ~= "table" or not dir_id(a.id, "B") or not dir_name(a.name) then return dir_bad() end
      n.dir_state = { kind = "ok", text = (p.created == false) and "Bereich war schon angelegt." or "Bereich angelegt.", created = { id = a.id, name = a.name } }
    end)
  end

  function n.directory_status()
    local st = n.dir_state
    if st and st.kind == "wait" and n.clock.now() >= n.dir_until then
      n.dir_req, n.dir_handler = nil, nil
      n.dir_state = { kind = "halt", text = "Die Leitstelle antwortet nicht. Laeuft sie, und ist sie in Funkreichweite (Ender-Modem)?" }
      st = n.dir_state
    end
    return st
  end

  function n.directory_reset() n.dir_req, n.dir_handler, n.dir_state = nil, nil, nil end

  -- eine Anforderungskennung, die bei jedem Versuch gleich bleibt (der Assistent merkt sie sich im Entwurf)
  function n.new_claim()
    return string.format("c%d-%06d%06d", n.clock.boot_id(), math.random(0, 999999), math.random(0, 999999))
  end

  -- Antwort auf eine Verzeichnisfrage (neuer Computer ueber die vorlaeufige Kennung, eingerichtete Node ueber ihren Funk)
  local function dir_reply(m, status)
    if not (n.dir_req and m.correlationId == n.dir_req) then return false end
    if status ~= "ok" then return true end
    local handler = n.dir_handler
    n.dir_req, n.dir_handler = nil, nil
    local p = m.payload
    if type(p) ~= "table" or p.status ~= "ok" then
      n.dir_state = { kind = "halt", text = "Abgelehnt: " .. tostring(type(p) == "table" and p.grund or "keine Begruendung") }
    else
      local ok = pcall(handler, p)
      if not ok then dir_bad() end
    end
    n.dirty = true
    if n.setup and n.setup.poll then n.setup.poll() end
    return true
  end
  n.hooks.on_message[#n.hooks.on_message + 1] = function(m, status)
    if m.messageType == "bestaetigung" then dir_reply(m, status) end
  end

  function n.replace_receive(ev)
    local m, status = n.replace_net.receive(ev)
    if not m then return end
    if dir_reply(m, status) then return end
    if m.correlationId == n.search_req then
      if status == "ok" then collect_network(m) end
      return
    end
    if m.correlationId ~= n.replace_req then return end
    local p = m.payload
    if p.status ~= "ok" then
      n.fetch_state = { kind = "halt", text = "Abgelehnt: " .. tostring(p.grund) }
      return
    end
    -- die Konfiguration kommt in Teilen: Teil fuer Teil anfordern, geprueft zusammensetzen
    local text = p.config
    local fetch = n.fetch
    if type(p.parts) == "number" and p.parts > 1 then
      if not fetch or p.part ~= fetch.part then
        n.fetch_state = { kind = "halt", text = "Unerwartete Antwort der Leitstelle." }
        return
      end
      local assembled, why = n.fetch_chunks.add("holen", p.revision, p.part, p.parts, p.config, p.sum)
      if not assembled then
        if why ~= "offen" then
          n.fetch_state = { kind = "halt", text = "Teile unvollstaendig: " .. tostring(why) }
          return
        end
        fetch_request(fetch.central, fetch.node, p.part + 1)
        n.fetch_state = { kind = "wait", text = "Empfange Konfiguration: Teil " .. p.part .. " von " .. p.parts .. " ..." }
        return
      end
      text = assembled
    end
    local config = type(text) == "string" and ser.decode(text) or nil
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
        -- ein Fehler in einem Ereignis (Touch, Funk, Geraet) beendet das Programm nicht; er wird gemeldet, hoechstens einmal je Minute je Text
        local handled, problem = pcall(n.handle, ev)
        if not handled then
          local text = "Ereignis " .. tostring(ev[1]) .. ": " .. tostring(problem)
          local at = n.clock.now()
          if n.last_problem ~= text or at - (n.last_problem_at or -999) >= 60 then
            n.last_problem, n.last_problem_at = text, at
            n.notify("fehler", text)
          end
        end
        if n.dirty then n.render() end
      end
    end)
    n.shutdown()
    if not ok and tostring(err) ~= "Terminated" then error(err, 0) end
  end

  n.rebuild_views()
  -- Absturz mitten in der Abschlusspruefung (Konzept 13.4): eine stehengebliebene eigene Testsperre erkennen, aufheben und melden
  if n.config and n.config.pruefung and n.config.pruefung.lauf then
    local check = pruefunglib.new({
      env = env, config = function() return n.config end, now = function() return n.clock.now() end,
      scan = function() return detect.scan(env.peripheral) end,
      persist = function() return store.save(CONFIG, n.config) end,
    })
    local note, ok = check.recover()
    if note then n.notify(ok and "warnung" or "fehler", note) end
  end

  n.start_services()
  if n.config and n.config.status ~= "aktiv" then n.notify("warnung", "Die Einrichtung ist nur ein Entwurf: die Betriebsfunktion bleibt inaktiv.") end
  if n.env_hold then n.notify("warnung", "Die Umgebung (Modpack/Schnittstellen) hat sich geaendert: neue Abfahrten bleiben aus, bis die Pruefung auf der Seite Uebersicht bestanden ist.") end
  return n
end

return M
