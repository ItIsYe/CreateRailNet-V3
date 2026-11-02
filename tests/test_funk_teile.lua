--[[
Purpose: Grosse Nachrichten in Teilen (Konfigurationssicherung, Signalstatus, Anmeldung der Signale, Ersatz-Holen): eine Signal-Node mit 40 Signalen (4 Gleise zu je 10) arbeitet ohne Fehlermeldung, Verlust, Doppelung und fremde oder unvollstaendige Teile fuehren nicht zu falschen Daten.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")
local adler = require("core.adler")

local function signal_spec(tracks_n, per, extra)
  local tr = {}
  for i = 1, tracks_n do
    local sigs = {}
    for j = 1, per do sigs[j] = string.format("Create_Signal_%d_%d", i, j) end
    tr[i] = { name = "Gleis " .. i, signals = sigs, signal_info = { use = "strecke", effect = "Ostbahnhof", place = "mitte" } }
  end
  local spec = { id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = tr }
  for k, v in pairs(extra or {}) do spec[k] = v end
  return spec
end

local function build(tracks_n, per, opts)
  local h = H.new(opts)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local s = h.add_node(signal_spec(tracks_n, per))
  return h, z, s
end

local function count_errors(s, text)
  local n = 0
  for _, m in ipairs(s.node.messages) do if m.level == "fehler" and (not text or m.text:find(text, 1, true)) then n = n + 1 end end
  return n
end

local function overview_count(zentrale, node_id)
  local n = 0
  for _, row in ipairs(zentrale.signal_overview()) do if row.node == node_id then n = n + 1 end end
  return n
end

-- verwirft Nachrichten an einen Computer, auf die pred(nachricht) zutrifft (nur bis max Stueck); gibt einen Zaehler { n = Anzahl } zurueck
local function lose(h, cid, pred, max)
  local counter = { n = 0 }
  h.bus.filter = function(from, to, text)
    if to ~= cid or counter.n >= (max or 1) then return false end
    local ok, m = pcall(ser.decode, text)
    if ok and type(m) == "table" and type(m.payload) == "table" and pred(m) then counter.n = counter.n + 1 return true end
    return false
  end
  return counter
end

return {
  { "40 Signale an einer Node: Anmeldung, Status und Sicherung kommen vollstaendig an, ohne Fehlermeldung", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(80)
    t.eq(count_errors(s), 0, "keine Fehlermeldung")
    t.eq(#zentrale.info().nodes.strecke.signals, 40, "Anmeldung vollstaendig")
    t.eq(overview_count(zentrale, "strecke"), 40, "Status vollstaendig")
    local backup = zentrale.backup_of("strecke")
    t.ok(backup, "Sicherung gespeichert")
    t.eq(backup.revision, s.node.config.revision)
    t.eq(backup.config, ser.encode(s.node.config), "Text unveraendert")
    local restored = ser.decode(backup.config)
    t.eq(restored.node.id, "strecke")
    local devices = 0
    for _ in pairs(restored.devices) do devices = devices + 1 end
    t.eq(devices, 40)
    -- die Node hat die Sicherung bestaetigt bekommen: keine Wiederholung nach 30 Sekunden
    local seen_before = h.bus.sent
    h.step(40)
    local konfig = 0
    for _, m in ipairs(z.node.messages or {}) do if tostring(m.text):find("konfig", 1, true) then konfig = konfig + 1 end end
    t.eq(konfig, 0)
    t.ok(h.bus.sent - seen_before < 200, "ruhiger Funk nach der Sicherung: " .. (h.bus.sent - seen_before))
  end },
  { "Jede einzelne Funknachricht bleibt unter dem Limit von 6000 Zeichen (auch die Huelle)", function()
    local h, z, s = build(4, 11)               -- 44 Signale
    local biggest, kinds = 0, {}
    local real = ser.encode
    ser.encode = function(v, ...)
      local text = real(v, ...)
      if type(v) == "table" and v.messageType and type(v.payload) == "table" then
        local k = tostring(v.payload.kind)
        kinds[k] = math.max(kinds[k] or 0, #text)
        biggest = math.max(biggest, #text)
      end
      return text
    end
    local ok, err = pcall(function() h.step(80) end)
    ser.encode = real
    assert(ok, err)
    t.ok(biggest <= 6000, "groesste Nachricht " .. biggest)
    t.ok(kinds.konfig and kinds.konfig < 6000)
    t.ok(kinds.signale and kinds.signale < 6000)
    t.ok(kinds.hallo_signale and kinds.hallo_signale < 6000)
    t.eq(count_errors(s), 0)
    t.eq(overview_count(z.node.roles.zentrale, "strecke"), 44)
  end },
  { "Verlust, Doppelung und vertauschte Reihenfolge auf dem Funk: am Ende stimmt alles", function()
    local h, z, s = build(4, 10, { bus = { seed = 7, drop = 0.25, dup = 0.15, reorder = true } })
    local zentrale = z.node.roles.zentrale
    h.step(300)
    t.eq(#zentrale.info().nodes.strecke.signals, 40)
    t.eq(overview_count(zentrale, "strecke"), 40)
    local backup = zentrale.backup_of("strecke")
    t.ok(backup, "Sicherung kam trotz Verlust an")
    t.eq(backup.config, ser.encode(s.node.config))
  end },
  { "Geht ein Teil der Sicherung verloren, wird nach 30 Sekunden alles noch einmal geschickt; vorher ist nichts gesichert", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    local lost = lose(h, z.cid, function(m) return m.payload.kind == "konfig" and m.payload.part == 2 end, 1)
    h.step(25)
    t.eq(lost.n, 1, "ein Teil ging verloren")
    t.eq(zentrale.backup_of("strecke"), nil, "unvollstaendig: nichts gesichert")
    h.step(45)
    t.ok(zentrale.backup_of("strecke"), "nach der Wiederholung gesichert")
    t.eq(zentrale.backup_of("strecke").config, ser.encode(s.node.config))
  end },
  { "Geht ein Teil der Anmeldung verloren, bleibt die Node unbekannt und meldet sich nach zehn Sekunden vollstaendig neu", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    local lost = lose(h, z.cid, function(m) return m.payload.kind == "hallo_signale" and m.payload.part == 3 end, 1)
    h.step(8)
    t.eq(lost.n, 1, "ein Teil ging verloren")
    local known = zentrale.info().nodes.strecke
    t.ok(known == nil or #(known.signals or {}) ~= 40, "unvollstaendig: Node nicht mit allen Signalen bekannt")
    h.step(30)
    t.eq(#(zentrale.info().nodes.strecke.signals), 40, "nach der Wiederholung vollstaendig")
  end },
  { "Ein halber Status ersetzt den bisherigen nicht; erst der vollstaendige Satz gilt", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(40)
    t.eq(overview_count(zentrale, "strecke"), 40)
    -- eine neue Statusmeldung mit nur einem Teil von dreien
    s.node.send_to("hauptstelle", "meldung", { kind = "signale", node = "strecke", set = "x.1", part = 1, parts = 3, signals = { { id = "nur", track_name = "Gleis 9" } }, t = 1 })
    h.step(2)
    t.eq(overview_count(zentrale, "strecke"), 40, "bisheriger Stand bleibt")
    for _, row in ipairs(zentrale.signal_overview()) do t.ok(row.signal.id ~= "nur") end
  end },
  { "Ein verspaeteter, aelterer Statussatz ersetzt keinen neueren", function()
    local h, z, s = build(2, 2)
    local zentrale = z.node.roles.zentrale
    h.step(40)
    -- die echten Statusmeldungen der Node werden unterdrueckt, damit nur die gefaelschten Saetze zaehlen
    local forged = { neu = true, alt = true, neuer = true, neustart = true }
    h.bus.filter = function(from, to, text)
      local ok, m = pcall(ser.decode, text)
      if not (ok and type(m) == "table" and type(m.payload) == "table" and m.payload.kind == "signale") then return false end
      local first = m.payload.signals and m.payload.signals[1]
      return not (first and forged[first.id])
    end
    local function status(set, id)
      s.node.send_to("hauptstelle", "meldung", { kind = "signale", node = "strecke", set = set, part = 1, parts = 1, signals = { { id = id, track_name = "Gleis 1" } }, t = 1 })
    end
    local function ids()
      local out = {}
      for _, row in ipairs(zentrale.signal_overview()) do if row.node == "strecke" then out[#out + 1] = row.signal.id end end
      return table.concat(out, ",")
    end
    status("9.5", "neu"); h.step(1)
    t.eq(ids(), "neu")
    status("9.4", "alt"); h.step(1)
    t.eq(ids(), "neu", "der aeltere Satz (Zaehler 4 nach 5) wird ignoriert")
    status("9.6", "neuer"); h.step(1)
    t.eq(ids(), "neuer")
    -- nach einem Neustart der Node (neue Startkennung) zaehlt wieder von vorn
    status("10.1", "neustart"); h.step(1)
    t.eq(ids(), "neustart")
  end },
  { "Fremde Nachrichten: eine Node sichert nur ihre eigene Konfiguration, kaputte Satzteile und falsche Summen werden abgelehnt", function()
    local h, z, s = build(2, 2)
    local zentrale = z.node.roles.zentrale
    h.step(60)
    local own = zentrale.backup_of("strecke")
    t.ok(own)
    local thief = h.add_node({ id = "dieb", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = {} })
    h.step(60)
    local legit_before = zentrale.backup_of("dieb")
    t.ok(legit_before, "die Node hat ihre eigene, ehrliche Sicherung")
    local function send(payload)
      local replies = {}
      local real = z.node.reply
      z.node.reply = function(m, status, p)
        if m.senderNodeId == "dieb" and m.payload.kind == "konfig" then replies[#replies + 1] = { status = status, grund = p and p.grund } end
        return real(m, status, p)
      end
      thief.node.send_to("hauptstelle", "meldung", payload)
      h.step(3)
      z.node.reply = real
      return replies[1]
    end
    local fake = ser.encode({ node = { id = "strecke" }, revision = 99 })
    local r = send({ kind = "konfig", node = "strecke", revision = 99, part = 1, parts = 1, sum = adler.hex(fake), config = fake })
    t.eq(r.status, "abgelehnt"); t.contains(r.grund, "eigene")
    t.eq(zentrale.backup_of("strecke").revision, own.revision, "fremde Sicherung unveraendert")
    -- falsche Pruefsumme (eigene Kennung)
    local mine = ser.encode({ node = { id = "dieb" }, revision = 1 })
    r = send({ kind = "konfig", node = "dieb", revision = 1, part = 1, parts = 2, sum = adler.hex(mine), config = mine:sub(1, 5) })
    t.eq(r.status, "ok"); t.eq(r.grund, nil)
    r = send({ kind = "konfig", node = "dieb", revision = 1, part = 2, parts = 2, sum = adler.hex(mine), config = "kaputt" })
    t.eq(r.status, "abgelehnt"); t.contains(r.grund, "Pruefsumme")
    t.eq(zentrale.backup_of("dieb").config, legit_before.config, "die ehrliche Sicherung bleibt")
    -- Konfiguration einer anderen Node unter der eigenen Kennung
    local other = ser.encode({ node = { id = "strecke" }, revision = 1 })
    r = send({ kind = "konfig", node = "dieb", revision = 1, part = 1, parts = 1, sum = adler.hex(other), config = other })
    t.eq(r.status, "abgelehnt"); t.contains(r.grund, "nicht lesbar")
    -- zu viele Teile, falsche Teilnummer, fehlender Stand, nicht lesbar
    r = send({ kind = "konfig", node = "dieb", revision = 1, part = 1, parts = 500, config = "x" })
    t.eq(r.status, "abgelehnt")
    r = send({ kind = "konfig", node = "dieb", revision = 1, part = 9, parts = 2, config = "x" })
    t.eq(r.status, "abgelehnt")
    r = send({ kind = "konfig", node = "dieb", config = "x" })
    t.eq(r.status, "abgelehnt"); t.contains(r.grund, "Stand")
    r = send({ kind = "konfig", node = "dieb", revision = 1, config = "kein Lua {" })
    t.eq(r.status, "abgelehnt")
    -- ein Satz, der die Obergrenze (60000 Zeichen) ueberschreitet: spaetestens der Teil, der sie reisst, wird abgelehnt
    local refused
    for i = 1, 20 do
      r = send({ kind = "konfig", node = "dieb", revision = 1, part = i, parts = 20, config = string.rep("x", 3500) })
      if r.status == "abgelehnt" then refused = r break end
    end
    t.ok(refused, "Obergrenze greift"); t.contains(refused.grund, "zu gross")
    -- eine einzelne Nachricht in alter Form mit ueberlanger Konfiguration (in Teilen gesendet kann sie nicht kommen): direkt an die Leitstelle
    local direct = z.node.roles.zentrale
    local replied
    local real2 = z.node.reply
    z.node.reply = function(m, status, p) replied = { status = status, grund = p and p.grund } return real2(m, status, p) end
    direct.on_config({ senderNodeId = "dieb", messageId = "dieb:1:1", payload = { node = "dieb", revision = 1, config = string.rep("x", 70000) } })
    z.node.reply = real2
    t.eq(replied.status, "abgelehnt"); t.contains(replied.grund, "zu gross")
    t.eq(zentrale.backup_of("dieb").config, legit_before.config, "nichts davon wurde gesichert")
    -- eine gueltige Sicherung ohne Teile (alte Form) wird weiter angenommen
    local legit = ser.encode({ node = { id = "dieb" }, revision = 77 })
    r = send({ kind = "konfig", node = "dieb", revision = 77, config = legit })
    t.eq(r.status, "ok")
    t.eq(zentrale.backup_of("dieb").revision, 77)
  end },
  { "Ersatz: eine grosse Konfiguration (40 Signale) wird in Teilen geholt und vollstaendig uebernommen", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(80)
    t.ok(zentrale.backup_of("strecke"))
    -- der alte Computer faellt aus
    s.node.handle = function() end
    h.step(75)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "strecke")
    fresh.tap(v, "act:r_holen")
    h.step(2)
    fresh.node.render()
    t.ok(fresh.has(v, "Teil") or fresh.has(v, "empfangen"), fresh.text(v))
    h.step(30)
    fresh.node.render()
    t.ok(fresh.has(v, "empfangen"), fresh.text(v))
    local handovers = 0
    for _, m in ipairs(z.node.messages) do if m.text:find("an einen Ersatzcomputer uebergeben", 1, true) then handovers = handovers + 1 end end
    t.eq(handovers, 1, "die Uebergabe wird bei mehreren Teilen nur einmal gemeldet")
    fresh.tap(v, "act:r_uebernehmen")
    local wiz = fresh.node.setup.session().wiz
    t.eq(wiz.config.node.id, "strecke")
    local devices = 0
    for _ in pairs(wiz.config.devices) do devices = devices + 1 end
    t.eq(devices, 40, "alle Geraete uebernommen")
  end },
  { "Ersatz: bei Verlust eines Teils bleibt es bei 'nicht empfangen'; ein neuer Versuch gelingt", function()
    local h, z, s = build(4, 10)
    h.step(80)
    s.node.handle = function() end
    h.step(75)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "strecke")
    local lost = lose(h, fresh.cid, function(m) return m.payload.part == 2 end, 1)
    fresh.tap(v, "act:r_holen")
    h.step(10)
    fresh.node.render()
    t.eq(lost.n, 1, "Teil 2 ging verloren")
    t.ok(not fresh.has(v, "empfangen"), "unvollstaendig ist nicht empfangen: " .. fresh.text(v))
    t.ok(fresh.has(v, "Teil 1 von"), "Fortschritt wird gezeigt: " .. fresh.text(v))
    h.bus.filter = nil
    fresh.tap(v, "act:r_holen")
    h.step(30)
    fresh.node.render()
    t.ok(fresh.has(v, "empfangen"), fresh.text(v))
  end },
  { "Lehnt die Leitstelle die Sicherung ab, wird das einmal gemeldet und nicht jede halbe Minute wiederholt; ein neuer Stand wird wieder versucht", function()
    local h, z, s = build(4, 10)
    local real = z.node.reply
    z.node.reply = function(m, status, p)
      if m.payload.kind == "konfig" then return real(m, "abgelehnt", { grund = "Testgrund" }) end
      return real(m, status, p)
    end
    local sent = 0
    h.bus.filter = function(from, to, text)
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and type(m.payload) == "table" and m.payload.kind == "konfig" then sent = sent + 1 end
      return false
    end
    h.step(40)
    local first_burst = sent
    t.ok(first_burst >= 2, "mehrere Teile gesendet")
    h.step(150)
    t.eq(sent, first_burst, "keine Wiederholung nach der Ablehnung")
    local notes = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Konfigurationssicherung abgelehnt", 1, true) then notes = notes + 1; t.contains(m.text, "Testgrund") end end
    t.eq(notes, 1, "einmal gemeldet, nicht je Teil")
    -- neuer Stand der Konfiguration: neuer Versuch
    s.node.config.revision = s.node.config.revision + 1
    h.step(40)
    t.ok(sent > first_burst, "neuer Stand wird wieder gesendet")
    z.node.reply = real
  end },
  { "Laesst sich die Konfiguration gar nicht teilen, steht ein Fehler da und es gibt keine Wiederholung im Sekundentakt", function()
    local chunks = require("core.chunks")
    local real = chunks.parts_text
    local calls = 0
    chunks.parts_text = function() calls = calls + 1 return nil, "Testfehler" end
    local h, z, s = build(2, 2)
    local ok, err = pcall(function() h.step(120) end)
    chunks.parts_text = real
    assert(ok, err)
    t.eq(calls, 1, "nur ein Versuch je Stand")
    local notes = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("laesst sich nicht sichern", 1, true) then notes = notes + 1; t.contains(m.text, "Testfehler") end end
    t.eq(notes, 1)
  end },
  { "Auch bei vertauschter Reihenfolge (ohne Verlust) keine unnoetige Wiederholung der Sicherung", function()
    local function run(opts)
      local h, z, s = build(4, 10, opts)
      local sent = 0
      h.bus.filter = function(from, to, text)
        local ok, m = pcall(ser.decode, text)
        if ok and type(m) == "table" and type(m.payload) == "table" and m.payload.kind == "konfig" then sent = sent + 1 end
        return false
      end
      h.step(150)
      assert(z.node.roles.zentrale.backup_of("strecke"), "gesichert")
      return sent
    end
    local clean = run(nil)
    for seed = 1, 6 do
      t.eq(run({ bus = { seed = seed, reorder = true } }), clean, "Startwert " .. seed .. ": gleich viele Teile wie ohne Vertauschen")
    end
  end },
  { "Ein stillgelegter Node meldet sich nicht im Zehn-Sekunden-Takt weiter an", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(40)
    t.eq(zentrale.retire("strecke"), true)
    s.restart()           -- neuer Start: die Anmeldung ist wieder unbestaetigt
    h.step(15)
    local hello = 0
    h.bus.filter = function(from, to, text)
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and type(m.payload) == "table" and m.payload.kind == "hallo_signale" then hello = hello + 1 end
      return false
    end
    h.step(60)
    t.ok(hello <= 5, "hoechstens eine Anmeldung (in Teilen) in 60 s, nicht alle 10 s: " .. hello)
  end },
  { "Faellt die Leitstelle lange aus, sichert die Node nach ihrer Rueckkehr trotzdem und der Speicher waechst nicht ohne Grenze", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    local real = z.node.handle
    z.node.handle = function() end
    h.step(3400)           -- gut 110 erfolglose Versuche
    t.eq(zentrale.backup_of("strecke"), nil)
    z.node.handle = real
    h.step(80)
    t.ok(zentrale.backup_of("strecke"), "nach der Rueckkehr gesichert")
    t.eq(zentrale.backup_of("strecke").config, ser.encode(s.node.config))
  end },
  { "Status und Anmeldung tragen bei jeder Sendung eine neue Satzkennung", function()
    local h, z, s = build(4, 10)
    local sets = {}
    local count = 0
    h.bus.filter = function(from, to, text)
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and type(m.payload) == "table" and (m.payload.kind == "signale" or m.payload.kind == "hallo_signale") then
        sets[m.payload.kind .. m.payload.set] = true
        count = count + 1
      end
      return false
    end
    h.step(30)
    local distinct = 0
    for _ in pairs(sets) do distinct = distinct + 1 end
    t.ok(distinct >= 4, "mehrere verschiedene Saetze: " .. distinct)
    t.ok(count > distinct, "mehrere Teile je Satz")
  end },
  { "Laesst sich der Status nicht teilen, wird der Fehler einmal gemeldet, nicht im Fuenf-Sekunden-Takt", function()
    local chunks = require("core.chunks")
    local real = chunks.parts_list
    chunks.parts_list = function() return nil, "Testfehler" end
    local h, z, s = build(2, 2)
    local ok, err = pcall(function() h.step(60) end)
    chunks.parts_list = real
    assert(ok, err)
    local notes = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Signalmeldung nicht moeglich", 1, true) then notes = notes + 1 end end
    t.eq(notes, 1)
  end },
  { "Quittungen, die mit vertauschter Reihenfolge ankommen, zaehlen trotzdem: die Sicherung wird nicht erneut geschickt", function()
    local h, z, s = build(4, 10)
    local held, sent = {}, 0
    h.bus.filter = function(from, to, text, proto)
      local ok, m = pcall(ser.decode, text)
      if not (ok and type(m) == "table" and type(m.payload) == "table") then return false end
      if m.payload.kind == "konfig" then sent = sent + 1 end
      if to == s.cid and m.messageType == "bestaetigung" and m.payload.antwort_auf == "konfig" then held[#held + 1] = m return true end
      return false
    end
    h.step(40)
    local after_two_attempts = sent
    t.ok(#held >= 2, "Quittungen zurueckgehalten")
    t.ok(after_two_attempts > 5, "ohne Quittung wird nach 30 Sekunden wiederholt: " .. after_two_attempts)
    -- jetzt kommen die Quittungen verspaetet an (Status old_sequence)
    for _, m in ipairs(held) do
      for _, fn in ipairs(s.node.hooks.on_message) do fn(m, "old_sequence") end
    end
    h.step(100)
    t.eq(sent, after_two_attempts, "nach den Quittungen keine weitere Wiederholung")
  end },
  { "Ersatz: eine Antwort mit zu viel Inhalt (ueber der Obergrenze) wird abgebrochen", function()
    local h, z, s = build(4, 10)
    h.step(80)
    s.node.handle = function() end
    h.step(75)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "strecke")
    local zentrale = z.node.roles.zentrale
    local real = zentrale.handle_fetch_config
    zentrale.handle_fetch_config = function(m)
      local k = m.payload.part or 1
      z.node.reply(m, "ok", { config = string.rep("a", 3000), revision = 1, part = k, parts = 25 })
    end
    fresh.tap(v, "act:r_holen")
    h.step(40)
    fresh.node.render()
    zentrale.handle_fetch_config = real
    t.ok(fresh.has(v, "unvollstaendig"), fresh.text(v))
    t.ok(fresh.has(v, "zu gross"), fresh.text(v))
    t.ok(not fresh.has(v, "empfangen"))
  end },
  { "Ersatz: falsche Teilnummer, verfaelschte Pruefsumme und zu viele Teile in der Antwort werden erkannt", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(80)
    s.node.handle = function() end
    h.step(75)
    local real_reply = z.node.reply
    -- ein Ersatzcomputer fragt nacheinander (gleiche vorlaeufige Kennung: neue Fragen, nicht dieselbe noch einmal)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "strecke")
    local function attempt(tamper)
      z.node.reply = function(m, status, p)
        if m.payload.kind == "konfig_holen" and status == "ok" then p = tamper(m, p) end
        return real_reply(m, status, p)
      end
      fresh.tap(v, "act:r_holen")
      h.step(30)
      fresh.node.render()
      z.node.reply = real_reply
      return fresh, v
    end
    -- falsche Teilnummer im ersten Teil
    attempt(function(m, p) local q = {} for k, x in pairs(p) do q[k] = x end q.part = 2 return q end)
    t.ok(fresh.has(v, "Unerwartete Antwort"), fresh.text(v))
    -- verfaelschter letzter Teil
    attempt(function(m, p)
      local q = {} for k, x in pairs(p) do q[k] = x end
      if q.part == q.parts then q.config = q.config .. "x" end
      return q
    end)
    t.ok(fresh.has(v, "unvollstaendig"), fresh.text(v))
    t.ok(fresh.has(v, "Pruefsumme"), fresh.text(v))
    t.ok(not fresh.has(v, "empfangen"))
    -- unsinnig viele Teile
    attempt(function(m, p) local q = {} for k, x in pairs(p) do q[k] = x end q.parts = 500 return q end)
    t.ok(fresh.has(v, "unvollstaendig"), fresh.text(v))
    t.ok(not fresh.has(v, "empfangen"))
  end },
  { "Ersatz: ein teilweiser Satz mit zu grosser Summe wird begrenzt", function()
    local chunks = require("core.chunks")
    local c = chunks.new({ max_parts = 40, max_bytes = 60000, max_keys = 2, now = function() return 0 end })
    local r, why = c.add("holen", 1, 1, 41, "x")
    t.eq(r, nil); t.contains(why, "Teilnummer")
  end },
  { "Ersatz: ein Teil, den die Leitstelle nicht kennt, und eine wieder laufende alte Node werden abgelehnt", function()
    local h, z, s = build(4, 10)
    local zentrale = z.node.roles.zentrale
    h.step(80)
    s.node.handle = function() end
    h.step(75)
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, p)
      if m.payload.kind == "konfig_holen" then replies[#replies + 1] = { status = status, grund = p and p.grund, part = p and p.part, parts = p and p.parts } end
      return real(m, status, p)
    end
    fresh.node.send_to = fresh.node.send_to
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.type(v, "r_central", "hauptstelle")
    fresh.type(v, "r_node", "strecke")
    fresh.tap(v, "act:r_holen")
    h.step(2)
    t.eq(replies[1].status, "ok"); t.eq(replies[1].part, 1)
    t.ok(replies[1].parts >= 2, "mehrere Teile")
    -- direkte Abfragen: Teil 0, Teil 99, Teil 1.5
    local function ask(part)
      local before = #replies
      local ok = pcall(function()
        local f = require("core.msg").new({ node_id = "neu-x", boot_id = 1, epoch = function() return 0 end })
        local m = f.make("abfrage", "hauptstelle", { kind = "konfig_holen", node = "strecke", part = part })
        z.node.roles.zentrale.handle_fetch_config(m)
      end)
      return replies[before + 1]
    end
    local r0 = ask(0); t.eq(r0.status, "abgelehnt"); t.contains(r0.grund, "ungueltig")
    local r99 = ask(99); t.eq(r99.status, "abgelehnt"); t.contains(r99.grund, "gibt es nicht")
    local rf = ask(1.5); t.eq(rf.status, "abgelehnt")
    -- die alte Node laeuft wieder: weitere Teile werden nicht herausgegeben
    s.node.handle = nil
    s.restart()
    h.step(30)
    local r2 = ask(2)
    t.eq(r2.status, "abgelehnt"); t.contains(r2.grund, "noch aktiv")
    z.node.reply = real
  end },
}
