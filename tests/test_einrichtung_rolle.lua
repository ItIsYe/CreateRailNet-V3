--[[
Purpose: Rolle vorbelegen (Konzept 12.2): ist auf dem Computer nur ein passendes Rollenpaket installiert, entfaellt die Rollenauswahl und die Rolle ist gesetzt; bei mehreren Rollen bleibt die Auswahl.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function build(installed)
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  z.node.roles.zentrale.netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
  local d = h.add_blank({ id = "neu", installed = installed })
  d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
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
  { "Nur Signal installiert: keine Rollenauswahl, der Ablauf geht gleich zum Bereich", function()
    local h, z, d, v = build({ "signal" })
    join_to_network(h, d, v)
    h.step(3); d.node.render()
    t.eq(screen(d), "2.bereich", d.text(v))
    t.eq(#d.node.setup.session().wiz.roles, 1); t.eq(d.node.setup.session().wiz.roles[1], "signal")
  end },
  { "Zurueck vom Bereich geht ueber die Rollenseite hinweg zur Netzwahl", function()
    local h, z, d, v = build({ "signal" })
    join_to_network(h, d, v)
    h.step(3); d.node.render()
    d.tap(v, "act:zurueck")
    t.eq(screen(d), "1.netzwahl", d.text(v))
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "2.bereich")
    t.eq(#d.node.setup.session().wiz.roles, 1, "die Rolle wird nicht doppelt gesetzt")
  end },
  { "Station installiert (mehrere Rollen moeglich): die Auswahl bleibt", function()
    local h, z, d, v = build({ "station" })
    join_to_network(h, d, v)
    t.eq(screen(d), "2.rollen", d.text(v))
    t.ok(d.has(v, "Personenbahnhof") or d.has(v, "bahnhof"), d.text(v))
    t.eq(#d.node.setup.session().wiz.roles, 0)
  end },
  { "Ohne Installationsverzeichnis (Entwicklung): alle Rollen, Auswahl bleibt", function()
    local h, z, d, v = build(nil)
    join_to_network(h, d, v, 2)
    t.eq(screen(d), "2.rollen", d.text(v))
  end },
  { "Nur Leitstelle installiert: 'Erste Leitstelle erstellen' setzt die Rolle, 'Beitreten' laesst die Auswahl (und meldet die zweite Leitstelle)", function()
    local h, z, d, v = build({ "zentrale" })
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")          -- erste Leitstelle erstellen
    t.eq(screen(d), "1.netz", d.text(v))
    d.type(v, "netz", "Neues Netz"); d.tap(v, "act:weiter")
    t.eq(screen(d), "2.name", d.text(v))
    t.eq(d.node.setup.session().wiz.roles[1], "zentrale")
    -- zurueck bis zur Betriebsart und stattdessen beitreten: jetzt widerspricht die Rolle der Betriebsart, die Auswahl bleibt
    d.tap(v, "act:zurueck"); d.tap(v, "act:zurueck")
    t.eq(screen(d), "1.modus", d.text(v))
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    t.eq(screen(d), "2.rollen", d.text(v))
    d.tap(v, "act:weiter")
    t.contains(d.text(v), "zweite Leitstelle")
  end },
}
