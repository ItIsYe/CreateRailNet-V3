--[[
Purpose: Netzsuche beim Beitreten: ein neuer Computer ruft per Funk, die Leitstellen in Reichweite nennen Netzname und Kennung, der Assistent bietet sie zur Auswahl an (Name und Leitstelle muessen nicht getippt werden). Gefaelschte oder unbrauchbare Antworten werden ignoriert, ohne Treffer bleibt die Eingabe von Hand.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local ser = require("core.ser")

-- Netz mit einer Leitstelle (und optional einer zweiten Leitstelle eines anderen Netzes) plus ein leerer Computer
local function build(opts)
  opts = opts or {}
  local h = H.new(opts)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local z2
  if opts.second then z2 = h.add_node({ id = "nordnetz", roles = { "zentrale" }, tracks = {} }) end
  local fresh = h.add_blank({ id = "neu", stations = {} })
  return h, z, z2, fresh
end

-- Netzname einer Test-Leitstelle ist "Testnetz" (harness); fuer das zweite Netz einen anderen Namen setzen
local function rename_network(node, name)
  node.node.config.network.name = name
end

local function start_join(d)
  local v = d.view()
  d.tap(v, "nav:einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2")
  d.tap(v, "act:weiter")
  return v
end

return {
  { "Leitstelle antwortet auf den Rundruf mit Netzname und Kennung, sonst nichts", function()
    local h, z, _, fresh = build()
    local v = start_join(fresh)
    h.step(6)
    local st = fresh.node.search_status()
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.networks, 1)
    t.eq(st.networks[1].netz, "Testnetz")
    t.eq(st.networks[1].zentrale, "hauptstelle")
    -- die Antwort enthaelt nur diese Felder (kein Betriebszustand, keine Konfiguration)
    local allowed = { netz = true, zentrale = true, nodes = true }
    for k in pairs(st.networks[1]) do t.ok(allowed[k], "unerwartetes Feld " .. k) end
  end },
  { "Assistent zeigt die gefundenen Netze, Auswahl ersetzt Netzname und Leitstellen-Eingabe", function()
    local h, z, _, fresh = build()
    local v = start_join(fresh)
    h.step(6)
    fresh.node.render()
    local text = fresh.text(v)
    t.contains(text, "1 Netz(e) gefunden.")
    t.contains(text, "Testnetz")
    t.contains(text, "Netz von Hand eingeben")
    fresh.tap(v, "act:weiter")
    t.contains(fresh.text(v), "Bitte ein Netz waehlen", "ohne Auswahl geht es nicht weiter")
    fresh.tap_row(v, "netzwahl", "Testnetz")
    fresh.tap(v, "act:weiter")
    t.eq(fresh.node.setup.session().screen, "2.rollen", "Netzname und Leitstelle werden nicht mehr abgefragt")
    local wiz = fresh.node.setup.session().wiz
    t.eq(wiz.network_name, "Testnetz")
    t.eq(wiz.central_id, "hauptstelle")
    -- zurueck fuehrt wieder zur Netzwahl
    fresh.tap(v, "act:zurueck")
    t.eq(fresh.node.setup.session().screen, "1.netzwahl")
  end },
  { "zwei Netze in Reichweite werden beide angeboten", function()
    local h, z, z2, fresh = build({ second = true })
    rename_network(z2, "Nordnetz")
    local v = start_join(fresh)
    h.step(6)
    local st = fresh.node.search_status()
    t.eq(#st.networks, 2)
    t.eq(st.networks[1].netz, "Nordnetz")
    t.eq(st.networks[1].zentrale, "nordnetz")
    t.eq(st.networks[2].netz, "Testnetz")
    fresh.node.render()
    fresh.tap_row(v, "netzwahl", "Nordnetz")
    fresh.tap(v, "act:weiter")
    local wiz = fresh.node.setup.session().wiz
    t.eq(wiz.central_id, "nordnetz")
    t.eq(wiz.network_name, "Nordnetz")
  end },
  { "ohne Leitstelle in Reichweite: Hinweis, Eingabe von Hand bleibt moeglich", function()
    local h = H.new()
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = start_join(fresh)
    h.step(6)
    fresh.node.render()
    t.contains(fresh.text(v), "Kein Netz gefunden")
    fresh.tap(v, "sel:netzwahl:1")
    fresh.tap(v, "act:weiter")
    t.eq(fresh.node.setup.session().screen, "1.netz")
    fresh.tap(v, "act:zurueck")
    fresh.tap(v, "act:neu_suchen")
    t.eq(fresh.node.search_status().kind, "wait", "Neu suchen startet die Suche erneut")
  end },
  { "ohne laufende Leitstelle (nur leere Computer) bleibt die Liste leer", function()
    local h = H.new()
    local fresh = h.add_blank({ id = "neu", stations = {} })
    h.add_blank({ id = "neu2", stations = {} })
    start_join(fresh)
    h.step(6)
    t.eq(#fresh.node.search_status().networks, 0)
  end },
  { "gefaelschte Antworten werden ignoriert: falsche Zeichen, zu lang, falscher Typ, fremde Korrelation, kein ok", function()
    local h = H.new()
    local fresh = h.add_blank({ id = "neu", stations = {} })
    start_join(fresh)
    local node = fresh.node
    local req = node.search_req
    t.ok(req, "Suche laeuft")
    local function reply(payload, corr, target)
      local m = { protocolVersion = 1, messageId = "evil:1:" .. tostring(math.random(1e9)), senderNodeId = "evil", targetNodeId = target or node.replace_factory.node_id,
        messageType = "bestaetigung", sequence = 1, centralEpoch = 0, correlationId = corr or req, payload = payload }
      node.handle({ "rednet_message", 99, ser.encode(m), "crn1" })
    end
    reply({ kind = "antwort", status = "ok", netz = "<script>", zentrale = "evil" })
    reply({ kind = "antwort", status = "ok", netz = string.rep("x", 31), zentrale = "evil" })
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = "ev il" })
    reply({ kind = "antwort", status = "ok", netz = 5, zentrale = "evil" })
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = {} })
    reply({ kind = "antwort", status = "abgelehnt", netz = "Gut", zentrale = "evil" })
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = "evil" }, "anderes:1:1")
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = "evil" }, nil, "ein-anderer-computer")
    t.eq(#node.search_state.networks, 0, "nichts davon wird angeboten (auch nicht, was an einen anderen Computer gerichtet ist)")
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = "evil" })
    t.eq(#node.search_state.networks, 1, "eine gueltige Antwort wird angeboten")
    reply({ kind = "antwort", status = "ok", netz = "Gut", zentrale = "evil" })
    t.eq(#node.search_state.networks, 1, "dieselbe Leitstelle erscheint nicht doppelt")
  end },
  { "eingerichtete Computer suchen nicht", function()
    local h, z = build()
    z.node.search_networks()
    t.eq(z.node.search_state.kind, "halt")
    t.contains(z.node.search_state.text, "schon eingerichtet")
  end },
  { "ohne Modem: Hinweis statt Suche", function()
    local h = H.new()
    local fresh = h.add_blank({ id = "neu", stations = {} })
    fresh.world.detach("left"); fresh.world.detach("right")
    fresh.node.search_networks()
    t.eq(fresh.node.search_state.kind, "halt")
    t.contains(fresh.node.search_state.text, "Kein Modem")
  end },
}
