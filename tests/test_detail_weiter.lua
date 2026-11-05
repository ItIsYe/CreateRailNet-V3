--[[
Purpose: Der Bildschirm "Signal-Eigenschaften" (4.z.detail) hat eine Taste Weiter: sie fuehrt direkt dorthin, wo es ohne diesen Bildschirm weiterginge. Im Gleis-Ablauf (Gleisliste > Bahnhof > Signale > Eigenschaften) geht es zum Beobachter oder zurueck zur Gleisliste, aus der Signalzuordnung zurueck zur Zuordnung. Mehrfaches Zurueck ist nicht noetig. Solange die Reihenfolge der Signale offen ist, bleibt Weiter gesperrt und nennt den Grund.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local G = dofile("tests/lib/guided.lua")

local function screen(d) return d.node.setup.session().screen end

-- Bahnhof-Einrichtung bis zur Gleisliste: zwei Gleise aus dem Verzeichnis, zwei Stationen, zwei Signale, optional ein Beobachter
local function to_tracks(observer)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  z.node.roles.zentrale.netz.add_area({ name = "Hauptbahnhof", ends = { "Einfahrt", "Ausfahrt" }, count = 2, pattern = "gleich" })
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B" } })
  d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
  if observer then d.world.add_observer("Create_TrainObserver_1") end
  d.restart()
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
  d.tap_row(v, "geraete", "Create_Signal_1"); d.tap_row(v, "geraete", "Create_Signal_2")
  if observer then d.tap_row(v, "geraete", "Create_TrainObserver_1") end
  d.tap(v, "act:weiter")
  t.eq(screen(d), "4.gleise", d.text(v))
  return h, d, v
end

-- Gleis 1: Bahnhof und beide Signale, dann Weiter bis zum Bildschirm "Signal-Eigenschaften"
local function to_detail(d, v)
  d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
  d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
  t.eq(screen(d), "4.g.signale", d.text(v))
  d.tap_row(v, "signale", "Create_Signal_1"); d.tap_row(v, "signale", "Create_Signal_2"); d.tap(v, "act:weiter")
  t.eq(screen(d), "4.z.detail", d.text(v))
end

return {
  { "Gleis-Ablauf ohne Beobachter: Weiter nach der Reihenfolge fuehrt direkt zur Gleisliste, der Weg dorthin ist leer", function()
    local h, d, v = to_tracks(false)
    to_detail(d, v)
    t.ok(d.area(v, "act:weiter"), "die Taste Weiter ist da: " .. d.text(v))
    t.ok(d.area(v, "act:zurueck"), "Zurueck bleibt")
    -- die Reihenfolge ist offen: Weiter geht nicht und nennt den Grund
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.z.detail")
    t.contains(v.hint, "Reihenfolge der Signale bestaetigen")
    d.tap(v, "act:d_reihenfolge")
    t.contains(v.hint, "bestaetigt")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", "ein Druck auf Weiter genuegt: " .. d.text(v))
    t.eq(#d.node.setup.session().stack, 0, "keine alten Bildschirme im Rueckweg")
    -- Gleis 1 ist fertig, das naechste Gleis kann angelegt werden
    d.tap(v, "sel:gleise:2"); d.tap(v, "act:bearbeiten")
    t.eq(screen(d), "4.g.bahnhof", d.text(v))
  end },
  { "Gleis-Ablauf mit Beobachter: nach den Eigenschaften folgt der Beobachter, danach die Gleisliste", function()
    local h, d, v = to_tracks(true)
    to_detail(d, v)
    d.tap(v, "act:d_reihenfolge")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.g.beobachter", d.text(v))
    d.tap_row(v, "beobachter", "Create_TrainObserver_1"); d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.eq(#d.node.setup.session().stack, 0)
    -- Zurueck vom Beobachter fuehrt weiterhin zu den Signalen
    d.tap(v, "sel:gleise:1"); d.tap(v, "act:bearbeiten")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.g.signale", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.g.beobachter", "Reihenfolge ist bestaetigt: es geht ohne Umweg weiter")
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "4.g.signale")
  end },
  { "Zurueck bleibt wie bisher einen Schritt: von den Eigenschaften zu den Signalen", function()
    local h, d, v = to_tracks(false)
    to_detail(d, v)
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "4.g.signale", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.z.detail", "ohne bestaetigte Reihenfolge fuehrt Weiter wieder dorthin")
  end },
  { "Signalzuordnung: Details und dann Weiter fuehrt zurueck zur Zuordnung (wie Zurueck), nur mit bestaetigter Reihenfolge", function()
    local h, z, d, v = G.setup({ tracks = 2, signals = 6, pattern = "gegenlaeufig" })
    t.eq(G.screen(d), "4.zuordnung", d.text(v))
    for _ = 1, 2 do d.tap(v, "sel:zuordnung:1"); d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1") end
    d.tap(v, "sel:zuordnung:1"); d.tap(v, "act:signal_details")
    t.eq(G.screen(d), "4.z.detail", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(G.screen(d), "4.z.detail", "Reihenfolge offen: " .. d.text(v))
    t.contains(v.hint, "Reihenfolge der Signale bestaetigen")
    d.tap(v, "act:d_reihenfolge")
    d.tap(v, "act:weiter")
    t.eq(G.screen(d), "4.zuordnung", d.text(v))
  end },
}
