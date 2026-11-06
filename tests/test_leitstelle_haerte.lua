--[[
Purpose: Die Leitstelle haelt Funkfehler aus: jede Frage bekommt eine Antwort (auch unbekannte Arten und fehlgeschlagene Bearbeitung), eine Antwort gilt nur vom befragten Node, und die Epoche faellt auch nach Datenverlust nie unter die laufender Nodes.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", known = {} } },
  })
  local f = h.add_node({ id = "fremd", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Fremdhof", known = {} } } })
  h.step(15)
  local replies = {}
  local real = z.node.reply
  z.node.reply = function(m, status, payload)
    replies[#replies + 1] = { kind = m.payload.kind, status = status, grund = payload.grund }
    return real(m, status, payload)
  end
  return h, z, w, f, replies
end

return {
  { "Unbekannte Abfragen und Auftraege werden abgelehnt, nicht ignoriert", function()
    local h, z, w, f, replies = build()
    local zentrale = z.node.roles.zentrale
    zentrale.on_message(w.node.factory.make("abfrage", "hauptstelle", { kind = "gibt_es_nicht" }), "ok")
    t.eq(#replies, 1); t.eq(replies[1].status, "abgelehnt"); t.contains(replies[1].grund, "Unbekannte Abfrage")
    zentrale.on_message(w.node.factory.make("auftrag", "hauptstelle", { kind = "gibt_es_nicht" }), "ok")
    t.eq(#replies, 2); t.eq(replies[2].status, "abgelehnt"); t.contains(replies[2].grund, "Unbekannter Auftrag")
    -- Unsinn als Art
    zentrale.on_message(w.node.factory.make("abfrage", "hauptstelle", { kind = { 1 } }), "ok")
    t.eq(#replies, 3); t.eq(replies[3].status, "abgelehnt")
    -- bekannte Arten laufen weiter
    zentrale.on_message(w.node.factory.make("abfrage", "hauptstelle", { kind = "netze" }), "ok")
    t.eq(replies[#replies].status, "ok")
    -- Meldungen unbekannter Art werden nicht beantwortet (es fragt niemand)
    local before = #replies
    zentrale.on_message(w.node.factory.make("meldung", "hauptstelle", { kind = "gibt_es_nicht" }), "ok")
    t.eq(#replies, before)
  end },
  { "Scheitert die Bearbeitung einer Frage, bekommt der Fragende eine Fehlerantwort und die Leitstelle meldet den Fehler", function()
    local h, z, w, f, replies = build()
    local zentrale = z.node.roles.zentrale
    zentrale.orders.templates = function() error("kaputt") end
    local before = #z.node.messages
    zentrale.on_message(w.node.factory.make("abfrage", "hauptstelle", { kind = "vorlagen" }), "ok")
    t.eq(#replies, 1)
    t.eq(replies[1].status, "abgelehnt")
    t.contains(replies[1].grund, "nicht bearbeiten")
    t.contains(replies[1].grund, "kaputt")
    t.eq(#z.node.messages, before + 1)
    t.eq(z.node.messages[#z.node.messages].level, "fehler")
    t.contains(z.node.messages[#z.node.messages].text, "vorlagen")
    -- hat der Handler schon geantwortet, kommt keine zweite Antwort
    local m = w.node.factory.make("abfrage", "hauptstelle", { kind = "tafel" })
    zentrale.board = function() z.node.reply(m, "ok", { rows = {} }) error("danach") end
    local count = #replies
    zentrale.on_message(m, "ok")
    t.eq(#replies, count + 1, "genau die eine Antwort des Handlers, keine zweite Fehlerantwort")
    t.eq(replies[#replies].status, "ok")
  end },
  { "Eine Antwort gilt nur vom befragten Node", function()
    local h, z, w, f, replies = build()
    local zentrale = z.node.roles.zentrale
    -- die Antworten der Nodes werden abgefangen, damit die Frage offen bleibt
    h.bus.filter = function(from, to, text) return to == z.cid end
    t.ok(zentrale.read_sample("Weizenhof", "7"))
    local asked
    for id, p in pairs(zentrale.info().pending) do if p.target == "weizenhof" then asked = id end end
    t.ok(asked, "offene Frage an weizenhof")
    local warnings = #z.node.messages
    local forged = f.node.factory.make("bestaetigung", "hauptstelle", { kind = "antwort", status = "abgelehnt", antwort_auf = "lesen", grund = "fremd" }, { correlationId = asked })
    zentrale.on_message(forged, "ok")
    t.ok(zentrale.info().pending[asked], "die Frage bleibt offen")
    t.contains(z.node.messages[#z.node.messages].text, "wird nicht gewertet")
    t.eq(zentrale.sample_status.kind, "wait", "Zustand unveraendert")
    local real = w.node.factory.make("bestaetigung", "hauptstelle", { kind = "antwort", status = "abgelehnt", antwort_auf = "lesen", grund = "echt" }, { correlationId = asked })
    zentrale.on_message(real, "ok")
    t.eq(zentrale.info().pending[asked], nil, "die Antwort des befragten Nodes beendet die Frage")
    t.contains(zentrale.sample_status.text, "echt")
  end },
  { "Epoche: ohne Wanduhr zaehlt jeder Start um eins hoch, mit Wanduhr nie unter die Weltzeit", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local first = z.node.own_epoch
    h.restart("hauptstelle")
    t.eq(z.node.own_epoch, first + 1, "ohne Wanduhr: +1")
    z.utc_seconds = function() return 1700000000 end
    h.restart("hauptstelle")
    t.eq(z.node.own_epoch, 1700000000, "mit Wanduhr: mindestens die Weltzeit")
    h.restart("hauptstelle")
    t.eq(z.node.own_epoch, 1700000001, "im selben Moment erneut gestartet: +1, nie gleich")
    z.utc_seconds = function() return 1700000500 end
    h.restart("hauptstelle")
    t.eq(z.node.own_epoch, 1700000500)
  end },
  { "Nach Datenverlust der Leitstelle (Epoche beginnt neu) werden ihre Nachrichten von laufenden Nodes weiter angenommen", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local w = h.add_node({ id = "weizenhof", roles = { "gueterbahnhof" }, central = "hauptstelle",
      tracks = { { name = "Gleis 1", station_name = "Weizenhof", known = {} } } })
    z.utc_seconds = function() return 1700000000 + h.t end
    h.restart("hauptstelle")
    h.step(20)
    local old_epoch = z.node.own_epoch
    t.ok(w.node.inbox.epoch() == old_epoch, "der Bahnhof kennt die Epoche der Leitstelle: " .. tostring(w.node.inbox.epoch()) .. " / " .. old_epoch)
    -- die Leitstelle verliert ihre Daten (neuer Computer): Epochendatei weg, spaeter neu gestartet
    t.ok(z.fs.exists("/crn_data/epoche.lua"))
    z.fs.delete("/crn_data/epoche.lua")
    h.step(30)
    h.restart("hauptstelle")
    h.step(20)
    t.ok(z.node.own_epoch > old_epoch, "neue Epoche liegt ueber der alten: " .. z.node.own_epoch .. " / " .. old_epoch)
    -- die Leitstelle erreicht den Bahnhof wieder (die Nachricht wird angenommen, nicht als veraltet verworfen)
    local m = z.node.send_to("weizenhof", "abfrage", { kind = "lesen", track = "gleis_01" })
    local answered
    table.insert(z.node.hooks.on_message, 1, function(r, status) if r.correlationId == m.messageId then answered = status end end)
    h.step(3)
    t.eq(answered, "ok", "Antwort des Bahnhofs auf die Frage der neuen Leitstelle")
    t.eq(w.node.inbox.epoch(), z.node.own_epoch, "der Bahnhof folgt der neuen Epoche")
  end },
}
