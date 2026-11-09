--[[
Purpose: Rolle vorbelegen (Konzept 12.2): ist auf dem Computer nur ein passendes Rollenpaket installiert, entfaellt die Rollenauswahl und die Rolle ist gesetzt; bei mehreren Rollen bleibt die Auswahl.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function build(installed)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local d = h.add_blank({ id = "neu", installed = installed })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v
end

local function join_to_network(h, d, v, option)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:" .. (option or 1)); d.tap(v, "act:weiter")       -- beitreten (ist die Leitstelle nicht installiert, ist es die einzige Wahl)
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
end

local function screen(d) return d.node.setup.session().screen end

return {
  { "Bahnhof und Anmeldung installiert (mehrere Rollen moeglich): die Auswahl bleibt", function()
    local h, z, d, v = build({ "station", "anmeldung" })
    join_to_network(h, d, v)
    t.eq(screen(d), "2.rollen", d.text(v))
    t.ok(d.has(v, "Bahnhof") and d.has(v, "Anmeldung"), d.text(v))
    t.eq(#d.node.setup.session().wiz.roles, 0)
  end },
  { "Nur die Station installiert: es gibt nur die Rolle Bahnhof, sie ist gesetzt und die Rollenauswahl entfaellt", function()
    local h, z, d, v = build({ "station" })
    join_to_network(h, d, v)
    t.ok(screen(d) ~= "2.rollen", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().wiz.roles[1], "bahnhof")
  end },
  { "Ohne Installationsverzeichnis (Entwicklung): alle Rollen, Auswahl bleibt", function()
    local h, z, d, v = build(nil)
    join_to_network(h, d, v, 2)
    t.eq(screen(d), "2.rollen", d.text(v))
  end },
  { "Nur Leitstelle installiert: es gibt nur 'Erste Leitstelle erstellen' (vorgewaehlt), 'Beitreten' fehlt, weil keine andere Rolle zum Beitreten da ist", function()
    local h, z, d, v = build({ "zentrale" })
    d.tap(v, "act:start")
    t.eq(screen(d), "1.modus", d.text(v))
    t.contains(d.text(v), "(o) Erste Leitstelle dieses Netzes erstellen")
    t.not_contains(d.text(v), "bestehenden Netz beitreten")
    t.ok(not d.area(v, "sel:modus:2"), "keine zweite Wahl: " .. d.text(v))
    d.tap(v, "act:weiter")                                   -- erste Leitstelle erstellen
    t.eq(screen(d), "1.netz", d.text(v))
    d.type(v, "netz", "Neues Netz"); d.tap(v, "act:weiter")
    t.eq(screen(d), "2.name", d.text(v))
    t.eq(d.node.setup.session().wiz.roles[1], "zentrale")
    -- zurueck bis zur Betriebsart: dieselbe einzige Wahl
    d.tap(v, "act:zurueck"); d.tap(v, "act:zurueck")
    t.eq(screen(d), "1.modus", d.text(v))
    t.contains(d.text(v), "(o) Erste Leitstelle dieses Netzes erstellen")
  end },
  { "Keine Train Station / kein Beobachter am Computer: der Hinweis sagt anschliessen und Neu lesen, nicht auswaehlen", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local d = h.add_blank({ id = "neu" })
    h.step(1)
    local v = d.view(); v.set_page("einrichtung")
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter"); h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap_row(v, "rollen", "Bahnhof"); d.tap(v, "act:weiter"); h.step(3); d.node.render()
    d.tap(v, "act:weiter"); h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "3.geraete")
    t.contains(v.hint, "Keine Train Station am Computer gefunden")
    t.contains(v.hint, "Neu lesen")
    -- angeschlossen: ohne Auswahl heisst es wieder "auswaehlen"
    d.world.add_station("Create_Station_1", { station_name = "Hof" })
    d.tap(v, "act:neu_scannen")
    d.tap(v, "act:weiter")
    t.contains(v.hint, "Mindestens eine Train Station muss ausgewaehlt werden")
  end },
}
