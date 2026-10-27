--[[
Purpose: Funkverkehr (src/core/net.lua) ueber einen Fake-Bus: Modemwahl, Austausch, gelernte Gegenstellen, doppelte Auftraege, Verlust/Verdopplung/Vertauschen (feste Zufallsmuster), Node mit zwei Computern, zu grosse und kaputte Nachrichten.
]]

local t = dofile("tests/lib/t.lua")
local busLib = dofile("tests/fakes/bus.lua")
local msg = require("core.msg")
local netlib = require("core.net")

local function node(bus, cid, node_id, opts)
  opts = opts or {}
  local now = { v = 0 }
  local rednet = bus.attach(cid)
  local factory = msg.new({ node_id = node_id, boot_id = opts.boot or 1, epoch = opts.epoch or 0 })
  local inbox = msg.inbox({ node_id = node_id, central_id = "zentrale-1" })
  local n = netlib.new({ rednet = rednet, factory = factory, inbox = inbox, clock = { now = function() return now.v end } })
  return { cid = cid, id = node_id, net = n, factory = factory, inbox = inbox, now = now, rednet = rednet }
end

-- verarbeitet alles, was fuer den Node im Bus liegt; handler(m) liefert die fachliche Antwort
local function pump(bus, nd, handler, log)
  local count = 0
  while true do
    local ev = bus.pop(nd.cid)
    if not ev then return count end
    local m, status, extra = nd.net.receive(ev)
    if m then
      log[#log + 1] = { node = nd.id, id = m.messageId, status = status }
      if status == "ok" and m.messageType == "auftrag" then
        nd.net.reply(m, handler(m))
      end
    end
    count = count + 1
  end
end

local function modems(list)
  local peripheral = {}
  function peripheral.getNames()
    local names = {}
    for _, m in ipairs(list) do names[#names + 1] = m.name end
    return names
  end
  function peripheral.getType(name) return "modem" end
  function peripheral.call(name, method)
    for _, m in ipairs(list) do
      if m.name == name then
        if m.err then error(m.err) end
        return m.wireless
      end
    end
  end
  return peripheral
end

return {
  { "Modemwahl: Funk wird geoeffnet, Kabel nicht", function()
    local bus = busLib.new()
    local rednet = bus.attach(1)
    local info = netlib.open({ rednet = rednet, peripheral = modems({ { name = "left", wireless = true }, { name = "right", wireless = false } }) })
    t.eq(#info.opened, 1)
    t.eq(info.opened[1], "left")
    t.eq(info.wired[1], "right")
    t.eq(info.fallback, nil)
    t.eq(rednet._box.opened[1], "left")
  end },
  { "ohne Funk: Kabel als Notloesung mit Hinweis", function()
    local bus = busLib.new()
    local rednet = bus.attach(1)
    local info = netlib.open({ rednet = rednet, peripheral = modems({ { name = "right", wireless = false } }) })
    t.eq(info.opened[1], "right")
    t.eq(info.fallback, true)
  end },
  { "kein Modem: nichts geoeffnet", function()
    local bus = busLib.new()
    local info = netlib.open({ rednet = bus.attach(1), peripheral = modems({}) })
    t.eq(#info.opened, 0)
  end },
  { "defektes Modem wird nicht als Funk gezaehlt", function()
    local bus = busLib.new()
    local info = netlib.open({ rednet = bus.attach(1), peripheral = modems({ { name = "a", wireless = true, err = "kaputt" } }) })
    t.eq(#info.wireless, 0)
  end },
  { "Auftrag und Antwort, danach wird gerichtet gesendet", function()
    local bus = busLib.new()
    local z = node(bus, 1, "zentrale-1")
    local b = node(bus, 2, "bahnhof-1")
    local log = {}
    local request = b.factory.make("auftrag", "zentrale-1", { kind = "ping" }, { requestId = "R1" })
    t.eq(b.net.send("zentrale-1", request), "rundruf", "erster Kontakt ohne bekannte Gegenstelle")
    pump(bus, z, function() return "angenommen" end, log)
    pump(bus, b, function() end, log)
    t.eq(b.net.peer("zentrale-1"), 1, "Gegenstelle gelernt")
    t.eq(z.net.peer("bahnhof-1"), 2)
    t.eq(b.net.send("zentrale-1", b.factory.make("meldung", "zentrale-1", {})), "gerichtet")
    t.eq(log[1].status, "ok")
    -- die Antwort ist fachlich (nicht nur technisch) und gehoert zur Anfrage
    local reply = z.inbox.reply_for(request.messageId)
    t.eq(reply.payload.status, "angenommen")
    t.eq(reply.correlationId, request.messageId)
    t.eq(reply.requestId, "R1")
  end },
  { "wiederholter Auftrag: bekannte Antwort kommt erneut, der Handler laeuft nicht noch einmal", function()
    local bus = busLib.new()
    local z = node(bus, 1, "zentrale-1")
    local b = node(bus, 2, "bahnhof-1")
    local log = {}
    local runs = 0
    local request = b.factory.make("auftrag", "zentrale-1", { kind = "fahrt" }, { requestId = "R9" })
    b.net.send("zentrale-1", request)
    pump(bus, z, function() runs = runs + 1; return "angenommen" end, log)
    b.net.send("zentrale-1", request)   -- gleiche Nachricht noch einmal
    b.net.send("zentrale-1", request)
    pump(bus, z, function() runs = runs + 1; return "angenommen" end, log)
    t.eq(runs, 1)
    -- b bekommt dieselbe Antwort dreimal (einmal regulaer, zweimal als Wiederholung); gezaehlt wird nur einmal
    local ok_count, duplicate_count = 0, 0
    while true do
      local ev = bus.pop(2)
      if not ev then break end
      local m, status = b.net.receive(ev)
      if m and m.messageType == "bestaetigung" and m.payload.status == "angenommen" then
        if status == "ok" then ok_count = ok_count + 1 elseif status == "duplicate" then duplicate_count = duplicate_count + 1 end
      end
    end
    t.eq(ok_count, 1)
    t.eq(duplicate_count, 2)
  end },
  { "zwei Computer mit derselben Node-Kennung werden erkannt, ein Ersatz nach der Wartezeit uebernimmt", function()
    local bus = busLib.new()
    local z = node(bus, 1, "zentrale-1")
    local a = node(bus, 2, "bahnhof-1")
    local b = node(bus, 3, "bahnhof-1", { boot = 7 })
    a.net.send("zentrale-1", a.factory.make("meldung", "zentrale-1", {}))
    local m1, s1 = z.net.receive(bus.pop(1))
    t.eq(s1, "ok")
    z.now.v = 5
    b.net.send("zentrale-1", b.factory.make("meldung", "zentrale-1", {}))
    local m2, s2, extra = z.net.receive(bus.pop(1))
    t.eq(s2, "node_conflict")
    t.eq(extra.first, 2); t.eq(extra.second, 3)
    t.eq(z.net.peer("bahnhof-1"), 2, "die alte Zuordnung bleibt")
    t.eq(z.net.conflicts(), 1)
    z.now.v = 100   -- der alte Computer meldet sich lange nicht mehr
    b.net.send("zentrale-1", b.factory.make("meldung", "zentrale-1", {}))
    local _, s3 = z.net.receive(bus.pop(1))
    t.eq(s3, "ok")
    t.eq(z.net.peer("bahnhof-1"), 3, "Ersatzcomputer uebernimmt")
  end },
  { "fremdes Protokoll und Muell werden ignoriert", function()
    local bus = busLib.new()
    local z = node(bus, 1, "zentrale-1")
    t.eq((z.net.receive({ "rednet_message", 5, "x", "anderes" })), nil)
    t.eq((z.net.receive({ "key", 5 })), nil)
    local m, status = z.net.receive({ "rednet_message", 5, "{{{", "crn1" })
    t.eq(m, nil); t.eq(status, "invalid")
    -- eine gueltige CRN-Nachricht auf fremdem Protokoll wird nicht angenommen und nicht gelernt
    local b = node(bus, 2, "bahnhof-1")
    local text = require("core.ser").encode(b.factory.make("meldung", "zentrale-1", {}))
    t.eq((z.net.receive({ "rednet_message", 2, text, "anderes" })), nil)
    t.eq(z.net.peer("bahnhof-1"), nil)
  end },
  { "zu grosse Nachricht wird nicht gesendet", function()
    local bus = busLib.new()
    local b = node(bus, 2, "bahnhof-1")
    local m = b.factory.make("meldung", "*", { text = string.rep("x", 7000) })
    t.raises(function() b.net.send("zentrale-1", m) end, "zu gross")
  end },
  { "technische Empfangsbestaetigung ist keine fachliche Antwort", function()
    local bus = busLib.new()
    local z = node(bus, 1, "zentrale-1")
    local b = node(bus, 2, "bahnhof-1")
    local m = b.factory.make("auftrag", "zentrale-1", {})
    b.net.send("zentrale-1", m)
    local got = z.net.receive(bus.pop(1))
    local ack = z.net.ack(got)
    t.eq(ack.payload.kind, "ack")
    t.eq(ack.payload.status, nil)
    t.eq(ack.correlationId, m.messageId)
  end },
  { "Zufallslauf mit Verlust, Verdopplung und Vertauschen: jeder Auftrag wird hoechstens einmal ausgefuehrt", function()
    for seed = 1, 30 do
      local bus = busLib.new({ seed = seed, drop = 0.2, dup = 0.3, reorder = true })
      local z = node(bus, 1, "zentrale-1")
      local b = node(bus, 2, "bahnhof-1")
      local executed = {}
      local log = {}
      local sent = {}
      for i = 1, 25 do
        local m = b.factory.make("auftrag", "zentrale-1", { n = i }, { requestId = "R" .. i })
        sent[#sent + 1] = m
        b.net.send("zentrale-1", m)
        if i % 3 == 0 then
          -- Wiederholung wegen vermuteter Antwortverluste
          b.net.send("zentrale-1", sent[math.max(1, i - 2)])
        end
        pump(bus, z, function(req) executed[req.payload.n] = (executed[req.payload.n] or 0) + 1; return "angenommen" end, log)
        pump(bus, b, function() end, log)
      end
      for _ = 1, 5 do
        pump(bus, z, function(req) executed[req.payload.n] = (executed[req.payload.n] or 0) + 1; return "angenommen" end, log)
        pump(bus, b, function() end, log)
      end
      for n, count in pairs(executed) do
        t.ok(count == 1, "Auftrag " .. n .. " wurde " .. count .. "-mal ausgefuehrt (Seed " .. seed .. ")")
      end
    end
  end },
}
