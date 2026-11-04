--[[
Purpose: Uebernahme einer bereits eingerichteten Node (ohne Netzverzeichnis) in das Verzeichnismodell (Konzept 18): "Einrichtung aendern" fuehrt durch Bereich und Gleise, die bisherigen Gleise werden nach Namen zugeordnet und behalten ihre Geraete, die Node behaelt ihre Kennung, das Verzeichnis kennt sie unter der neuen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = opts.tracks or 2 })
  local tracks = opts.legacy_tracks or { { name = "Gleis 1", signals = { "Sig_1" } }, { name = "gleis 2", signals = { "Sig_2" } } }
  local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = tracks })
  h.step(40)
  return h, z, netz, s
end

local function screen(s) return s.node.setup.session().screen end

-- Einrichtung aendern bis "Bereich waehlen" (das Netz steht schon fest: von Hand eingeben, Felder sind vorbelegt)
local function to_area(h, s)
  local v = H.open_page(s, "einrichtung")
  s.tap(v, "act:start")
  s.tap(v, "act:weiter")                              -- Modus: beitreten ist vorbelegt
  s.tap(v, "sel:netzwahl:1"); s.tap(v, "act:weiter")  -- Netz von Hand
  s.tap(v, "act:weiter")                              -- Netzname vorbelegt
  s.tap(v, "act:weiter")                              -- Leitstelle vorbelegt
  s.tap(v, "act:weiter")                              -- Rolle Signal ist gesetzt
  h.step(3); s.node.render()
  return v
end

return {
  { "Bisherige Gleise und Signale bleiben: Zuordnung nach Namen, Kennung bleibt, das Verzeichnis kennt die Node", function()
    local h, z, netz, s = setup()
    local v = to_area(h, s)
    t.eq(screen(s), "2.bereich", s.text(v))
    s.tap(v, "sel:bereich:1"); h.step(3); s.node.render()
    s.tap(v, "act:weiter")
    s.tap(v, "act:weiter")                            -- Gleise uebernehmen: Kennung anfordern
    h.step(3); s.node.render()
    t.eq(screen(s), "4.zuordnung", s.text(v) .. v.hint)
    t.ok(not s.has(v, "Signal fehlt"), "die bisherigen Signale sind noch zugeordnet: " .. s.text(v))
    t.contains(s.text(v), "Sig_1"); t.contains(s.text(v), "Sig_2")
    t.eq(netz.node("N0001").legacy, "strecke")
    local wiz = s.node.setup.session().wiz
    local count = 0
    for _ in pairs(wiz.config.tracks) do count = count + 1 end
    t.eq(count, 2, "keine doppelten Gleise")
    for _, row in ipairs(wiz.guided_rows()) do
      t.ok(row.signals[1].effect, "Wirkrichtung vorbelegt: " .. row.name)
    end
    -- pruefen und aktivieren; die Node behaelt ihre bisherige Kennung
    s.tap(v, "act:weiter")
    t.eq(screen(s), "5.pruefen", s.text(v))
    s.tap(v, "act:pruefen")
    for _ = 1, 40 do h.step(1) if s.node.config.status == "aktiv" and not s.node.setup.session().wiz then break end end
    local config = s.node.config
    t.eq(config.node.id, "strecke", "bisherige Kennung bleibt")
    t.eq(config.node.claimed, true); t.eq(config.node.label, "N0001 | SIG | B0001")
    t.eq(config.status, "aktiv", s.text(v))
    -- die Leitstelle fuehrt die Node nach ihrer Meldung als aktiv (unter der bisherigen Kennung gemeldet, im Verzeichnis N0001)
    h.step(30)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Dienste neu aufgebaut (Einrichtung geaendert, kein Neustart): die Nachrichtenzaehler laufen weiter, nichts gilt als Wiederholung", function()
    local h, z, netz, s = setup()
    local first = s.node.factory.make("meldung", "hauptstelle", { kind = "x" })
    local before = s.node.factory
    s.node.start_services()
    t.ok(s.node.factory == before, "dieselbe Kennungsquelle")
    local second = s.node.factory.make("meldung", "hauptstelle", { kind = "x" })
    t.ok(first.messageId ~= second.messageId, first.messageId .. " / " .. second.messageId)
    -- eine neue Node-Kennung bekommt eine eigene Kennungsquelle
    s.node.config.node.id = "anders"
    s.node.start_services()
    t.ok(s.node.factory ~= before)
    s.node.config.node.id = "strecke"
  end },
  { "Ein bisheriges Gleis ohne Gegenstueck im Bereich: Meldung vor der Anforderung, nichts wird angefordert", function()
    local h, z, netz, s = setup({ legacy_tracks = { { name = "Gleis 1", signals = { "Sig_1" } }, { name = "Abstellgleis", signals = { "Sig_2" } } } })
    local v = to_area(h, s)
    s.tap(v, "sel:bereich:1"); h.step(3); s.node.render()
    s.tap(v, "act:weiter")
    s.tap(v, "act:weiter")
    t.contains(v.hint, "Abstellgleis")
    t.contains(v.hint, "gibt es im Bereich nicht")
    t.eq(screen(s), "2.gleise")
    t.eq(#netz.nodes(), 0, "keine Kennung reserviert")
  end },
  { "Nach der Uebernahme bleibt die Node im gefuehrten Ablauf konsistent: eine zweite Node mit derselben Kennung bekommt keine neue Anforderung", function()
    local h, z, netz, s = setup()
    local role = z.node.roles.zentrale
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = { status = status, payload = payload } return real(m, status, payload) end
    local function ask(payload)
      role.on_message(s.node.factory.make("abfrage", "hauptstelle", payload), "ok")
      return replies[#replies]
    end
    local first = ask({ kind = "node_anfordern", claim = "alt-claim-0001", role = "signal", area = "B0001", tracks = { "A0001" }, legacy = "strecke" })
    t.eq(first.status, "ok"); t.eq(first.payload.node.id, "N0001")
    local other = ask({ kind = "node_anfordern", claim = "alt-claim-0002", role = "signal", area = "B0001", tracks = { "A0002" }, legacy = "strecke" })
    t.eq(other.status, "abgelehnt"); t.contains(other.payload.grund, "schon als N0001")
    t.eq(ask({ kind = "node_anfordern", claim = "alt-claim-0003", role = "signal", area = "B0001", tracks = { "A0002" }, legacy = "Boese Kennung!" }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "alt-claim-0003", role = "signal", area = "B0001", tracks = { "A0002" }, legacy = 5 }).status, "abgelehnt")
    -- dieselbe Anforderung wiederholt: dieselbe Kennung
    local again = ask({ kind = "node_anfordern", claim = "alt-claim-0001", role = "signal", area = "B0001", tracks = { "A0001", "A0002" }, legacy = "strecke" })
    t.eq(again.status, "ok"); t.eq(again.payload.node.id, "N0001")
    -- verworfen: die bisherige Kennung ist wieder frei
    assert(netz.discard_node("N0001"))
    t.eq(ask({ kind = "node_anfordern", claim = "alt-claim-0004", role = "signal", area = "B0001", tracks = { "A0002" }, legacy = "strecke" }).status, "ok")
  end },
  { "Bisherige Station/Knoten-Einrichtung wird nie vermischt: Knoten mit eigenen Gleisen wird abgewiesen, 'Von Hand' behaelt sie", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local netz = z.node.roles.zentrale.netz
    netz.add_area({ name = "Kreuzung", ends = { "Nord", "Sued" }, count = 4 })
    local k = assert(netz.add_junction({ name = "Hauptknoten" }))
    assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
    assert(netz.add_route(k, "A0001", "A0003", true)); assert(netz.add_route(k, "A0004", "A0002", true))
    local tee = h.add_node({
      id = "tee", roles = { "knoten" }, central = "hauptstelle",
      junction = { connections = { West = true, Ost = true }, moves = { { from = "West", to = "Ost" } }, conflicts = {} },
      tracks = {
        { name = "West ein", signals = { "Sig_West" }, observers = { "Obs_West_ein" }, junction = { connection = "West", role = "ein" } },
        { name = "Ost aus", observers = { "Obs_Ost_aus" }, junction = { connection = "Ost", role = "aus" } },
      },
    })
    h.step(40)
    local v = H.open_page(tee, "einrichtung")
    tee.tap(v, "act:start"); tee.tap(v, "act:weiter")
    tee.tap(v, "sel:netzwahl:1"); tee.tap(v, "act:weiter")
    tee.tap(v, "act:weiter"); tee.tap(v, "act:weiter"); tee.tap(v, "act:weiter")
    h.step(3); tee.node.render()
    t.eq(screen(tee), "2.knoten", tee.text(v))
    tee.tap(v, "sel:knoten_wahl:1"); h.step(5); tee.node.render()
    tee.tap(v, "act:weiter")
    tee.tap(v, "act:weiter")
    t.contains(v.hint, "eigene Einrichtung")
    t.eq(#netz.nodes(), 0)
  end },
}
