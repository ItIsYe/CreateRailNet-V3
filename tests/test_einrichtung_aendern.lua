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

-- Knoten-Node aus dem Verzeichnis einrichten bis zum Bildschirm "Test" (activate = true: aktivieren und im Betrieb laufen lassen)
local function knoten_node(activate)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Kreuzung", ends = { "Nord", "Sued" }, count = 4 })
  local k = assert(netz.add_junction({ name = "Hauptknoten" }))
  assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
  assert(netz.add_route(k, "A0001", "A0003", true)); assert(netz.add_route(k, "A0004", "A0002", true))
  assert(netz.add_conflict(k, "F0001", "F0002", true))
  local d = h.add_blank({ id = "neu" })
  for i = 1, 2 do d.world.add_signal("Create_Signal_" .. i) end
  for i = 1, 4 do d.world.add_observer("Create_TrainObserver_" .. i) end
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", "Knotenpunkt"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:knoten_wahl:1"); h.step(5); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap_row(v, "geraete", "Create_Signal_1"); d.tap_row(v, "geraete", "Create_Signal_2")
  for i = 1, 4 do d.tap_row(v, "geraete", "Create_TrainObserver_" .. i) end
  d.tap(v, "act:weiter")
  t.eq(screen(d), "4.gleise", d.text(v))
  -- Einfahrten brauchen ein Signal, alle Gleise einen Beobachter
  local wiz = d.node.setup.session().wiz
  local signal_no, observer_no = 0, 0
  for i, tid in ipairs(wiz.tracks()) do
    d.tap(v, "sel:gleise:" .. i); d.tap(v, "act:bearbeiten")
    if wiz.config.tracks[tid].junction.role == "ein" then
      signal_no = signal_no + 1
      d.tap_row(v, "signale", "Create_Signal_" .. signal_no); d.tap(v, "act:weiter")
    end
    observer_no = observer_no + 1
    d.tap_row(v, "beobachter", "Create_TrainObserver_" .. observer_no); d.tap(v, "act:weiter")
  end
  d.tap(v, "act:weiter")
  t.eq(screen(d), "5.test", d.text(v))
  if activate then
    d.tap(v, "act:alle_pruefen"); d.tap(v, "act:alle_starten")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv", d.text(v))
    h.step(40)
  end
  return h, d, v
end

-- Einrichtung aendern an der laufenden Knoten-Node bis zum Bildschirm "Test"
local function to_knoten_tests(h, d, v)
  d.tap(v, "act:start")
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")                      -- Modus, Netz (das eigene Netz ist vorgewaehlt)
  d.tap(v, "act:weiter")                                              -- Rolle
  h.step(3); d.node.render()
  t.eq(screen(d), "2.knoten", d.text(v))
  d.tap(v, "sel:knoten_wahl:1"); h.step(5); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  t.eq(screen(d), "3.geraete", d.text(v))
  d.tap(v, "act:weiter")
  t.eq(screen(d), "4.gleise", d.text(v))
  d.tap(v, "act:weiter")
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
  { "Einrichtung aendern an einer laufenden Knoten-Node: die im Betrieb gesperrten Einfahrtsignale blockieren die Pruefung nicht", function()
    local h, d, v = knoten_node(true)
    -- im Betrieb sind die Einfahrtsignale gesperrt
    local locked = 0
    for i = 1, 2 do if d.world.devices["Create_Signal_" .. i].state.forced then locked = locked + 1 end end
    t.ok(locked > 0, "die Knoten-Node sperrt ihre Einfahrt im Betrieb")
    to_knoten_tests(h, d, v)
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", "die Ergebnisse der unveraenderten Geraete bleiben gueltig: " .. d.text(v))
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv", d.text(v))
    t.eq(d.node.config.node.id, "N0001")
  end },
  { "Sind die Ergebnisse trotzdem verfallen, gilt ein im Betrieb gesperrtes Signal der laufenden Node als geprueft (Sperre bleibt)", function()
    local h, d, v = knoten_node(true)
    to_knoten_tests(h, d, v)
    d.node.setup.session().wiz.config.tests = {}
    d.tap(v, "act:alle_pruefen")
    t.eq(screen(d), "5.alle_bestaetigen", d.text(v))
    d.tap(v, "act:alle_starten")
    for _, id in ipairs({ "sperre:signal1", "sperre:signal2" }) do
      local w = d.node.setup.session().wiz
      local state, text = w.test_state(id)
      t.eq(state, "ok", id .. ": " .. tostring(text))
      t.contains(text, "gesperrt")
    end
    t.ok(d.world.devices["Create_Signal_1"].state.forced or d.world.devices["Create_Signal_2"].state.forced, "die Betriebssperre bleibt")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
  end },
  { "Neue Einrichtung: ein fremd gesperrtes Signal lehnt die Sperrpruefung ab, und der Hinweis nennt die Pruefung", function()
    local h, d, v = knoten_node(false)
    d.world.devices["Create_Signal_1"].state.forced = true
    d.tap(v, "act:alle_pruefen"); d.tap(v, "act:alle_starten")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    t.contains(v.hint, "Sperre: Create_Signal_1 fehlgeschlagen")
    t.not_contains(v.hint, "~")
  end },
}
