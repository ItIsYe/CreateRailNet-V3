--[[
Purpose: Ein Bahnhof mit vielen Gleisen meldet Anmeldung und Zustand in Teilen (eine Funknachricht fasst hoechstens 6000 Zeichen): auch bei Verlust, Doppelung und Vertauschung kennt die Leitstelle am Ende alle Gleise; die Anmeldung gilt erst, wenn der ganze Satz da ist; eine stillgelegte Node wird durch eine verspaetete Anmeldung nicht wiederbelebt.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")

local function tracks_spec(count)
  local list = {}
  for i = 1, count do
    list[i] = { name = string.format("Gleis %02d %s", i, string.rep("N", 20)), station_name = string.format("Bahnhof %02d %s", i, string.rep("S", 20)), release_side = "back", known = {} }
  end
  return list
end

local function build(count, opts)
  local h = H.new(opts)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local b = h.add_node({ id = "grossbahnhof", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = tracks_spec(count) })
  return h, z, b
end

local function known_tracks(z, id)
  local info = z.node.roles.zentrale.info()
  local node = info.nodes[id]
  local count = 0
  for _ in pairs(info.track_state) do count = count + 1 end
  return node and #(node.tracks or {}) or 0, count
end

return {
  { "Bahnhof mit 45 Gleisen: Anmeldung und Zustand kommen in Teilen an, alle Gleise sind der Leitstelle bekannt", function()
    local h, z, b = build(45)
    local sizes, parted = {}, 0
    h.bus.filter = function(from, to, text)
      if to ~= z.cid then return false end
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and m.messageType == "meldung" then
        sizes[#sizes + 1] = #text
        if m.payload.parts then parted = parted + 1 end
      end
      return false
    end
    h.step(30)
    local hello, states = known_tracks(z, "grossbahnhof")
    t.eq(hello, 45, "Anmeldung vollstaendig")
    t.eq(states, 45, "Zustand aller Gleise")
    t.ok(parted > 0, "mehrere Teile gesendet")
    for _, size in ipairs(sizes) do t.ok(size <= 6000, "Nachricht " .. size .. " Zeichen") end
    -- die Anmeldung ist bestaetigt: der Bahnhof nimmt Aufgaben an (nicht "gleicht sich noch ab")
    local m = z.node.send_to("grossbahnhof", "abfrage", { kind = "lesen", track = "gleis_01" })
    local answer
    table.insert(z.node.hooks.on_message, 1, function(r) if r.correlationId == m.messageId then answer = r.payload end end)
    h.step(3)
    t.ok(answer, "Antwort")
    t.ok(answer.grund == nil or not tostring(answer.grund):find("gleicht sich noch", 1, true), tostring(answer.grund))
  end },
  { "Wenige Gleise: Anmeldung und Zustand bleiben je eine Nachricht ohne Teilangaben", function()
    local h, z, b = build(3)
    local seen = { hallo = 0, zustand = 0 }
    h.bus.filter = function(from, to, text)
      if to ~= z.cid then return false end
      local ok, m = pcall(ser.decode, text)
      if ok and type(m) == "table" and m.messageType == "meldung" and seen[m.payload.kind] then
        t.eq(m.payload.parts, nil, m.payload.kind .. " ohne Teile")
        seen[m.payload.kind] = seen[m.payload.kind] + 1
      end
      return false
    end
    h.step(20)
    t.ok(seen.hallo >= 1 and seen.zustand >= 1)
    t.eq((known_tracks(z, "grossbahnhof")), 3)
  end },
  { "Anmeldung in Teilen unter Verlust, Doppelung und Vertauschung: am Ende kennt die Leitstelle alle Gleise", function()
    for seed = 1, 10 do
      local h, z, b = build(40, { seed = seed, drop = 0.25, dup = 0.3, reorder = true })
      local ok = h.until_true(function()
        local hello, states = known_tracks(z, "grossbahnhof")
        return hello == 40 and states == 40
      end, 600)
      local hello, states = known_tracks(z, "grossbahnhof")
      t.ok(ok, "Zufallsmuster " .. seed .. ": Anmeldung " .. hello .. "/40, Zustand " .. states .. "/40")
      -- stabil: nach weiterer Laufzeit bleibt der Stand vollstaendig
      h.step(60)
      hello, states = known_tracks(z, "grossbahnhof")
      t.eq(hello, 40, "Zufallsmuster " .. seed .. " stabil (Anmeldung)")
      t.eq(states, 40, "Zufallsmuster " .. seed .. " stabil (Zustand)")
    end
  end },
  { "Anmeldung in Teilen: unvollstaendiger Satz gilt nicht und wird nicht als angekommen quittiert, der vollstaendige gilt", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "sender", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = tracks_spec(1) })
    h.step(3)
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload)
      if m.payload.kind == "hallo" and m.payload.node == "fremd" then replies[#replies + 1] = { status = status, payload = payload } end
      return real(m, status, payload)
    end
    local function send(part, parts, set, list)
      local m = s.node.factory.make("meldung", "hauptstelle", { kind = "hallo", node = "fremd", name = "Fremd", roles = { "gueterbahnhof" }, revision = 1, set = set, part = part, parts = parts, tracks = list, active = true })
      z.node.roles.zentrale.on_message(m, "ok")
    end
    send(1, 2, "9.1", { { id = "a", name = "A" } })
    t.eq(replies[1].status, "ok"); t.eq(replies[1].payload.fertig, false)
    t.eq(z.node.roles.zentrale.info().nodes.fremd, nil, "noch nicht uebernommen")
    send(1, 2, "9.1", { { id = "a", name = "A" } })      -- doppelt
    t.eq(replies[2].payload.fertig, false)
    send(2, 2, "9.1", { { id = "b", name = "B" } })
    t.eq(replies[3].payload.fertig, true)
    local node = z.node.roles.zentrale.info().nodes.fremd
    t.ok(node and #node.tracks == 2 and node.tracks[1].id == "a" and node.tracks[2].id == "b", "beide Teile in Reihenfolge")
    -- ungueltiger Teil: abgelehnt
    send(3, 2, "9.2", { { id = "c" } })
    t.eq(replies[4].status, "abgelehnt")
    -- ein anderer Satz ersetzt den angefangenen
    send(1, 2, "9.3", { { id = "x" } })
    send(2, 2, "9.4", { { id = "y" } })
    t.eq(replies[6].payload.fertig, false, "Teile verschiedener Saetze setzen sich nicht zusammen")
  end },
  { "Eine stillgelegte Node wird durch eine verspaetete Anmeldung nicht wiederbelebt", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "sender", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = tracks_spec(1) })
    h.step(10)
    local zentrale = z.node.roles.zentrale
    t.ok(zentrale.info().nodes.sender)
    t.eq(zentrale.retire("sender"), true)
    t.eq(zentrale.info().nodes.sender.retired, true)
    local answers = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) answers[#answers + 1] = payload return real(m, status, payload) end
    local m = s.node.factory.make("meldung", "hauptstelle", { kind = "hallo", node = "sender", name = "Sender", roles = { "gueterbahnhof" }, revision = 1, tracks = {}, active = true })
    zentrale.on_message(m, "old_sequence")
    t.eq(zentrale.info().nodes.sender.retired, true, "bleibt stillgelegt")
    t.eq(answers[#answers].stillgelegt, true)
    -- dieselbe Anmeldung als gueltige Nachricht: ebenso
    zentrale.on_message(m, "ok")
    t.eq(zentrale.info().nodes.sender.retired, true)
  end },
  { "Verspaetet eintreffende Anmeldungsteile zaehlen, Teile verschiedener Nodes mischen sich nicht", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "sender", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = tracks_spec(1) })
    h.step(3)
    local zentrale = z.node.roles.zentrale
    local function part(node_id, nr, parts, set, id)
      return s.node.factory.make("meldung", "hauptstelle", { kind = "hallo", node = node_id, name = node_id, roles = { "gueterbahnhof" }, revision = 1, set = set, part = nr, parts = parts, tracks = { { id = id } }, active = true })
    end
    -- verspaetet (old_sequence) trotzdem angenommen
    zentrale.on_message(part("spaet", 1, 2, "5.1", "a"), "old_sequence")
    zentrale.on_message(part("spaet", 2, 2, "5.1", "b"), "old_sequence")
    t.eq(#zentrale.info().nodes.spaet.tracks, 2, "verspaetete Teile zaehlen")
    -- zwei Nodes gleichzeitig, Teile verschraenkt
    zentrale.on_message(part("eins", 1, 2, "6.1", "e1"), "ok")
    zentrale.on_message(part("zwei", 1, 2, "6.1", "z1"), "ok")
    zentrale.on_message(part("eins", 2, 2, "6.1", "e2"), "ok")
    zentrale.on_message(part("zwei", 2, 2, "6.1", "z2"), "ok")
    t.eq(zentrale.info().nodes.eins.tracks[2].id, "e2")
    t.eq(zentrale.info().nodes.zwei.tracks[2].id, "z2")
  end },
  { "Der Bahnhof nimmt Aufgaben erst an, wenn die Leitstelle die Anmeldung vollstaendig und angenommen quittiert hat", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local b = h.add_node({ id = "grossbahnhof", roles = { "gueterbahnhof" }, central = "hauptstelle", tracks = tracks_spec(2) })
    z.node.handle = function() end          -- die Leitstelle antwortet nicht von selbst
    h.step(1)
    local station = b.node.roles.station
    local answers = {}
    local real = b.node.reply
    b.node.reply = function(m, status, payload) answers[#answers + 1] = { status = status, grund = payload.grund } return real(m, status, payload) end
    local function task()
      answers = {}
      station.on_message(z.node.factory.make("auftrag", "grossbahnhof", { kind = "freigabe", track = "gleis_01" }), "ok")
      return answers[#answers]
    end
    local function hello_reply(payload)
      local body = { kind = "antwort", antwort_auf = "hallo" }
      for k, v in pairs(payload) do body[k] = v end
      station.on_message(z.node.factory.make("bestaetigung", "grossbahnhof", body, { correlationId = "x" }), "ok")
    end
    local function gated(answer) return answer and answer.status == "zurueckgestellt" and tostring(answer.grund):find("gleicht sich noch", 1, true) ~= nil end
    t.ok(gated(task()), "ohne Quittung zurueckgestellt")
    hello_reply({ status = "ok", fertig = false })
    t.ok(gated(task()), "Teilquittung genuegt nicht")
    hello_reply({ status = "abgelehnt", grund = "kaputt" })
    t.ok(gated(task()), "eine Ablehnung ist keine Annahme")
    hello_reply({ status = "ok", fertig = true })
    t.ok(not gated(task()), "ganze Quittung: Aufgaben werden angenommen")
  end },
  { "Jede Anmeldung ist ein neuer Satz: Teile einer abgebrochenen Anmeldung vermischen sich nicht mit der neuen", function()
    local h, z, b = build(45)
    local dropping = true
    h.bus.filter = function(from, to, text)
      if not dropping or to ~= z.cid then return false end
      local ok, m = pcall(ser.decode, text)
      -- die erste Anmeldung kommt nur bis zum ersten Teil
      return ok and type(m) == "table" and m.messageType == "meldung" and m.payload.kind == "hallo" and m.payload.parts ~= nil and m.payload.part > 1
    end
    h.step(5)
    t.eq((known_tracks(z, "grossbahnhof")), 0, "unvollstaendig: noch nicht uebernommen")
    dropping = false
    local station = b.node.roles.station
    station.tracks[1].name = "Umbenannt"
    station.hello()
    h.step(3)
    local node = z.node.roles.zentrale.info().nodes.grossbahnhof
    t.ok(node and #node.tracks == 45, "alle Gleise")
    t.eq(node.tracks[1].name, "Umbenannt", "der Teil der neuen Anmeldung gilt, nicht der alte")
  end },
  { "node.send_parts: zu grosses Element wird einmal gemeldet; Satzkennungen wachsen mit jedem Satz", function()
    local h, z, b = build(1)
    h.step(3)
    local before = #b.node.messages
    local function make(piece) return { kind = "zustand", node = "grossbahnhof", tracks = piece } end
    t.eq(b.node.send_parts("hauptstelle", { { name = string.rep("a", 6000) } }, make, "Test"), false)
    t.eq(#b.node.messages, before + 1)
    t.contains(b.node.messages[#b.node.messages].text, "Test nicht moeglich")
    t.eq(b.node.send_parts("hauptstelle", { { name = string.rep("a", 6000) } }, make, "Test"), false)
    t.eq(#b.node.messages, before + 1, "die Stoerung wird nicht bei jedem Aufruf gemeldet")
    t.eq(b.node.send_parts("hauptstelle", { { name = "klein" } }, make, "Test"), true)
    t.eq(b.node.send_parts("hauptstelle", { { name = string.rep("a", 6000) } }, make, "Test"), false)
    t.eq(#b.node.messages, before + 2, "nach einer Erholung wird eine neue Stoerung wieder gemeldet")
    local a1, a2 = b.node.next_set(), b.node.next_set()
    local boot1, n1 = a1:match("^(%d+)%.(%d+)$")
    local boot2, n2 = a2:match("^(%d+)%.(%d+)$")
    t.ok(boot1 and boot1 == boot2 and tonumber(n2) == tonumber(n1) + 1, a1 .. " / " .. a2)
  end },
}
