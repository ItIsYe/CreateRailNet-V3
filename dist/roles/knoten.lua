--[[
Purpose: Knotenpunkt-Node (Konzept 4.6, 11): haelt alle Einfahrtssignale des Knotens zusaetzlich gesperrt und gibt eine Einfahrt nur frei, wenn der Konfliktbereich nach Nachweis frei ist. Ein Zug kuendigt sich an, indem sein Einfahrtsbeobachter ihn meldet; die Einfahrt wird erst nach "train_passed" am Einfahrtsbeobachter als erfolgt gewertet (dann wird die Einfahrt wieder gesperrt), die Raeumung erst nach "train_passed" am erwarteten Ausgangsbeobachter. Keine Freigabe durch Zeitablauf; unklare Nutzungen bleiben stehen, bis ein Nachweis kommt oder der Bediener nach Pruefung entscheidet.
API: knoten_role.new(node, signals) -> role; role.areas; role.observe(geraet, zug, art); role.tick(); role.on_event(ev); role.pages
Notes: Die Software stellt keine Weichen und ersetzt die Create-Signalisierung nicht; sie legt zusaetzliche Betriebsregeln darueber (11.1). Die Reihenfolge wartender Zuege ist die der Ankuendigung; Prioritaeten der Leitstelle wirken hier nicht. Beobachter sind Meldepunkte, keine Blockfreimeldung (20.3): ohne den Raeumungsnachweis bleibt der Bereich belegt.
]]

local observerlib = require("dev.observer")
local areaslib = require("domain.areas")
local W = require("ui.widgets")

local M = {}

local HEARTBEAT = 5
local OWNER = "knoten"
local DEDUPE = 5

function M.new(node, signals)
  local role = {}
  local config = node.config
  local env = node.env
  local now = function() return node.clock.now() end
  local junction = config.junction
  local confirm = {}
  local last_beat = -9999
  local dirty = true

  role.areas = areaslib.new({
    connections = junction.connections, moves = junction.moves, conflicts = junction.conflicts, now = now,
    store = node.store, path = "/crn_data/knoten.lua",
  })

  -- Einfahrten und Ausfahrten aus der Konfiguration ---------------------------------------------------------------------------------------
  local points = {}      -- Beobachter-Geraet -> { conn, kind = "ein" | "aus", track, observer, last }
  local entries = {}     -- Anschluss -> Liste Einfahrtsgleise { track, signals = { id... } }
  local tids = {}
  for id in pairs(config.tracks) do tids[#tids + 1] = id end
  table.sort(tids)
  for _, tid in ipairs(tids) do
    local spec = config.tracks[tid]
    local jn = spec.junction
    if jn and junction.connections[jn.connection] then
      local obs_ids = {}
      for _, oid in ipairs(spec.observers or {}) do
        if config.devices[oid] then
          local name = config.devices[oid].device
          points[oid] = { conn = jn.connection, kind = jn.role, track = tid, track_name = spec.name, observer = observerlib.new(env, name), device = name, last = nil }
          obs_ids[#obs_ids + 1] = oid
        end
      end
      if jn.role == "ein" then
        entries[jn.connection] = entries[jn.connection] or {}
        entries[jn.connection][#entries[jn.connection] + 1] = { track = tid, name = spec.name, signals = spec.signals or {} }
      end
    end
  end

  -- Sperren der Einfahrten ----------------------------------------------------------------------------------------------------------------
  local function entry_track(conn, track_id)
    for _, e in ipairs(entries[conn] or {}) do if e.track == track_id then return e end end
  end

  local function lock_entry(e, reason)
    for _, sid in ipairs(e.signals) do
      local ok, err = signals.lock(sid, OWNER, reason)
      if not ok then node.notify("fehler", "Einfahrt " .. e.name .. ": " .. tostring(err)) end
    end
  end

  local function unlock_entry(e)
    for _, sid in ipairs(e.signals) do
      local ok, err = signals.unlock(sid, OWNER)
      if not ok then node.notify("fehler", "Einfahrt " .. e.name .. ": Freigabe nicht bestaetigt: " .. tostring(err)) end
    end
  end

  local function grant_pending()
    for _, use in ipairs(role.areas.next_grants()) do
      local e = entry_track(use.entry, use.track)
      if e then unlock_entry(e) end
      dirty = true
    end
  end

  -- Beobachtungen ---------------------------------------------------------------------------------------------------------------------------
  -- art: "passing" (Spitze) oder "passed" (Ende des Zuges vorbei)
  function role.observe(oid, train, kind)
    local p = points[oid]
    if not p then return end
    -- Ereignis und Abfrage melden dasselbe: gleiche Beobachtung innerhalb weniger Sekunden zaehlt einmal
    local key = kind .. ":" .. tostring(train)
    local t = now()
    p.seen = p.seen or {}
    if p.seen[key] and t - p.seen[key] < DEDUPE then return end
    p.seen[key] = t
    if kind == "passing" then p.last = train elseif p.last == train then p.last = nil end
    dirty = true
    if p.kind == "ein" then
      if kind == "passing" and train then
        role.areas.announce(p.conn, train, p.track)
        grant_pending()
      elseif kind == "passed" then
        local use, unplanned = role.areas.entered(p.conn, train, p.track)
        local e = entry_track(p.conn, p.track)
        if e then lock_entry(e, "Einfahrt gesperrt") end
        if unplanned then
          node.notify("warnung", "Knoten: " .. tostring(train) .. " ist an " .. p.conn .. " eingefahren, ohne dass die Einfahrt freigegeben war.")
        end
      end
    else
      local use, state = role.areas.exited(p.conn, train, kind)
      if not use then
        node.notify("warnung", "Knoten: Ausfahrt " .. p.conn .. " von " .. tostring(train) .. " ohne passende Einfahrt (" .. tostring(state) .. ").")
      else
        grant_pending()
      end
    end
  end

  function role.on_event(ev)
    if ev.kind ~= "observer" or ev.problem then return end
    if ev.type == "train_passing" then role.observe(ev.id, ev.train, "passing")
    elseif ev.type == "train_passed" then role.observe(ev.id, ev.train, "passed") end
  end

  -- Abfrage der Beobachter: faengt verlorene Ereignisse ab (Zug steht am Beobachter / ist abgefahren)
  local function poll()
    for oid, p in pairs(points) do
      local st = p.observer.read()
      if st.available then
        if st.passing and st.train and p.last ~= st.train then
          role.observe(oid, st.train, "passing")
        elseif not st.passing and p.last ~= nil then
          role.observe(oid, p.last, "passed")
        end
      end
    end
  end

  -- Start: alle Einfahrten zusaetzlich sperren, ausser eine freigegebene Nutzung wartet noch auf den Zug (kein pauschales Freigeben, kein pauschales Sperren gegen Bestand)
  local function initial_locks()
    local open = {}
    for _, u in ipairs(role.areas.status()) do
      if u.state == "freigegeben" and u.track then open[u.entry .. "/" .. u.track] = true end
    end
    local conns = {}
    for conn in pairs(entries) do conns[#conns + 1] = conn end
    table.sort(conns)
    for _, conn in ipairs(conns) do
      for _, e in ipairs(entries[conn]) do
        if not open[conn .. "/" .. e.track] then lock_entry(e, "Einfahrt gesperrt") end
      end
    end
  end

  function role.tick()
    poll()
    grant_pending()
    local t = now()
    if dirty or t - last_beat >= HEARTBEAT then
      node.send_to(node.central_id(), "meldung", { kind = "knoten", node = config.node.id, uses = role.areas.status(), t = t })
      last_beat, dirty = t, false
    end
  end

  -- Seite ---------------------------------------------------------------------------------------------------------------------------------------
  local STATE_TEXT = { angekuendigt = "angekuendigt, wartet", freigegeben = "Einfahrt freigegeben", eingefahren = "eingefahren", ausgefahren = "Spitze ausgefahren, Ende fehlt" }
  role.page = {
    id = "knoten", title = "Knoten",
    render = function(v, rect)
      local state = v.page_state("knoten")
      state.list = state.list or { index = 1 }
      state.uses = {}
      local items = {}
      for i, u in ipairs(role.areas.status()) do
        items[i] = {
          text = u.id .. " " .. tostring(u.train) .. " an " .. u.entry,
          detail = (u.long and "LANGE BELEGT: " or "") .. (STATE_TEXT[u.state] or u.state) .. (u.unplanned and ", ungeplant" or ""),
          kind = u.long and "halt" or (u.state == "angekuendigt" and "wait" or "text"),
        }
        state.uses[i] = u
      end
      W.list(v, "knoten", rect, items, state.list, { empty = "Der Knoten ist frei (nachgewiesen)." })
    end,
    actions = function(v)
      local state = v.page_state("knoten")
      local u = state.uses and state.uses[(state.list or { index = 1 }).index]
      return { { id = "aufloesen", label = confirm.armed and "Wirklich?" or "Pruefen+frei", kind = "danger", enabled = u ~= nil, reason = "Keine Nutzung gewaehlt." } }
    end,
    on_action = function(v, id)
      if id ~= "act:aufloesen" then return end
      local state = v.page_state("knoten")
      local u = state.uses and state.uses[state.list.index]
      if not u then return true end
      if not confirm.armed then
        confirm.armed = true
        v.hint = "Nur nach Sichtpruefung: der Bereich gilt dann als frei. Nochmal druecken."
      else
        confirm.armed = false
        local ok, err = role.areas.clear(u.id, "Bediener nach Pruefung")
        if ok then
          local e = u.track and entry_track(u.entry, u.track)
          if e then lock_entry(e, "Einfahrt gesperrt") end
          grant_pending()
          v.hint = "Nutzung aufgeloest (protokolliert)."
        else
          v.hint = err
        end
      end
      return true
    end,
  }

  initial_locks()
  return role
end

return M
