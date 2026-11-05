--[[
Purpose: "Einrichtung aendern" auf einer schon eingerichteten und laufenden Node: das Netz der Node ist im Schritt Netz vorgewaehlt (kein erneutes Suchen, keine Sackgasse "Dieser Computer ist schon eingerichtet"), der Bereich ist im Schritt Aufgabe vorgewaehlt, und der Assistent laeuft ohne Umweg bis zum erneuten Aktivieren durch, ohne eine zweite Kennung zu erzeugen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function screen(d) return d.node.setup.session().screen end

-- Bahnhof mit zwei Gleisen aus dem Verzeichnis einrichten und aktivieren (wie im Spiel); danach laeuft die Node im Netz
local function activated()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Hauptbahnhof", ends = { "Einfahrt", "Ausfahrt" }, count = 2, pattern = "gleich" })
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B" } })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", "Passagierbahnhof"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
  d.tap(v, "act:weiter")
  for i = 1, 2 do
    d.tap(v, "sel:gleise:" .. i); d.tap(v, "act:bearbeiten")
    d.tap_row(v, "bahnhof", "Create_Station_" .. i); d.tap(v, "act:weiter")
  end
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  t.eq(screen(d), "6.fertig", d.text(v))
  d.tap(v, "act:speichern")
  t.eq(d.node.config.status, "aktiv")
  h.step(30)
  return h, z, d, v, netz
end

return {
  { "Einrichtung aendern: das eigene Netz ist vorgewaehlt, Weiter geht ohne Netzsuche und ohne Handeingabe", function()
    local h, z, d, v = activated()
    d.tap(v, "act:start")
    t.eq(screen(d), "1.modus", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "1.netzwahl", d.text(v))
    t.contains(d.text(v), "gehoert schon zu diesem Netz")
    t.contains(d.text(v), "(o) Testnetz")
    t.not_contains(d.text(v), "schon eingerichtet", "keine Sackgasse")
    t.ok(not d.area(v, "act:neu_suchen"), "Neu suchen entfaellt: " .. d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.rollen", d.text(v))
    -- Zurueck und wieder vor: die Auswahl bleibt
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "1.netzwahl")
    t.contains(d.text(v), "(o) Testnetz")
    -- "von Hand" bleibt moeglich, wer das Netz wechseln will
    d.tap(v, "sel:netzwahl:2")
    t.contains(d.text(v), "(o) Netz von Hand eingeben")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "1.netz", d.text(v))
    t.contains(d.text(v), "Testnetz", "der Netzname ist vorbelegt")
  end },
  { "Einrichtung aendern: Bereich vorgewaehlt, der Assistent laeuft bis zum Aktivieren durch, die Kennung bleibt N0001", function()
    local h, z, d, v, netz = activated()
    local id_before = d.node.config.node.id
    d.tap(v, "act:start")
    d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.rollen", d.text(v))
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "2.bereich", d.text(v))
    t.contains(d.text(v), "(o) Hauptbahnhof", "der Bereich der Node ist vorgewaehlt: " .. d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.gleise", d.text(v))
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv", d.text(v))
    t.eq(d.node.config.node.id, id_before, "dieselbe Kennung")
    local count = 0
    for _ in ipairs(netz.nodes()) do count = count + 1 end
    t.eq(count, 1, "keine zweite Node im Verzeichnis")
  end },
}
