--[[
Purpose: Verdacht auf doppelte Verantwortung (Konzept 9.3, 15): zwei Nodes mit Bahnhofsrolle am selben Gleis des Verzeichnisses, zwei Nodes mit einem Signal gleicher Funktion, Wirkrichtung und gleichen Standorts am selben Gleis; Meldung einmal, Anzeige unter Stoerungen, nichts bei erlaubter Aufteilung.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function signal_spec(id, track_name, effect, place, dir)
  return { id = id, roles = { "signal" }, central = "hauptstelle", tracks = {
    { name = track_name, signals = { "Sig_" .. id }, signal_info = { use = "strecke", effect = effect, place = place }, dir = { id = dir, area = "B0001", direction = effect, rev = 1 } },
  } }
end

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
  return h, z, netz
end

local function notes(z, text)
  local n = 0
  for _, m in ipairs(z.node.messages) do if m.text:find(text, 1, true) then n = n + 1 end end
  return n
end

return {
  { "Zwei Nodes melden dasselbe Signal (gleiches Gleis, Wirkrichtung, Standort): Verdacht, einmal gemeldet, unter Stoerungen sichtbar", function()
    local h, z, netz = build()
    h.add_node(signal_spec("sigA", "Gleis 1", "Ostbahnhof", "Ostbahnhof", "A0001"))
    h.step(5)
    t.eq(#z.node.roles.zentrale.responsibility_warnings(), 0, "ein Melder ist kein Verdacht")
    h.add_node(signal_spec("sigB", "Gleis 1", "Ostbahnhof", "Ostbahnhof", "A0001"))
    h.step(70)
    local warnings = z.node.roles.zentrale.responsibility_warnings()
    t.eq(#warnings, 1); t.contains(warnings[1].text, "sigA und sigB"); t.contains(warnings[1].text, "Gleis 1")
    t.eq(notes(z, "Geraeteverantwortung"), 1)
    h.step(200)
    t.eq(notes(z, "Geraeteverantwortung"), 1, "nicht wiederholt gemeldet")
    local v = H.open_page(z, "stoerungen")
    t.contains(z.text(v), "sigA,sigB")
  end },
  { "Erlaubte Aufteilungen sind kein Verdacht: anderer Standort, andere Wirkrichtung, anderes Gleis, andere Funktion", function()
    local h, z, netz = build()
    h.add_node(signal_spec("sigA", "Gleis 1", "Ostbahnhof", "Ostbahnhof", "A0001"))
    h.add_node(signal_spec("sigB", "Gleis 1", "Ostbahnhof", "Westbahnhof", "A0001"))     -- anderer Standort
    h.add_node(signal_spec("sigC", "Gleis 1", "Westbahnhof", "Ostbahnhof", "A0001"))     -- andere Wirkrichtung
    h.add_node(signal_spec("sigD", "Gleis 2", "Ostbahnhof", "Ostbahnhof", "A0002"))      -- anderes Gleis
    local spec = signal_spec("sigE", "Gleis 1", "Ostbahnhof", "Ostbahnhof", "A0001")
    spec.tracks[1].signal_info.use = "einfahrt"                                          -- andere Funktion
    h.add_node(spec)
    h.step(70)
    t.eq(#z.node.roles.zentrale.responsibility_warnings(), 0)
    t.eq(notes(z, "Geraeteverantwortung"), 0)
  end },
  { "Signale ohne Angaben (bisherige Einrichtung) und Nodes ohne Verzeichnis loesen nie einen Verdacht aus", function()
    local h, z, netz = build()
    h.add_node({ id = "alt1", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Gleis 1", signals = { "Sig_a" } } } })
    h.add_node({ id = "alt2", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Gleis 1", signals = { "Sig_b" } } } })
    h.step(70)
    t.eq(#z.node.roles.zentrale.responsibility_warnings(), 0)
  end },
  { "Zwei Nodes mit Bahnhofsrolle am selben Gleis: Verdacht; verworfene Anforderungen und Signal-Nodes zaehlen nicht", function()
    local h, z, netz = build()
    local role = z.node.roles.zentrale
    assert(netz.claim_node({ claim = "verantw-claim-1", role = "passagierbahnhof", area = "B0001", tracks = { "A0001", "A0002" } }))
    assert(netz.claim_node({ claim = "verantw-claim-2", role = "signal", area = "B0001", tracks = { "A0001" } }))
    t.eq(#role.responsibility_warnings(), 0, "Bahnhof und Signal am selben Gleis ist normal")
    local second = assert(netz.claim_node({ claim = "verantw-claim-3", role = "depot", area = "B0001", tracks = { "A0002" } }))
    local warnings = role.responsibility_warnings()
    t.eq(#warnings, 1); t.contains(warnings[1].text, "Bahnhofsgleis"); t.contains(warnings[1].text, "N0001 und N0003")
    assert(netz.discard_node(second.id))
    t.eq(#role.responsibility_warnings(), 0)
  end },
}
