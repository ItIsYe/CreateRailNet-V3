--[[
Purpose: Anmeldung und kombinierte Rollen im Verzeichnis-Ablauf (Konzept 9.1, 12.1): Bahnhof und Depot auf einem Computer, die Anmeldung allein bei einer Betriebsstelle und zusammen mit einem Bahnhof; Kennung, Name, Label und Zustaendigkeit; Funkabfragen der Leitstelle.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  assert(netz.add_station({ name = "Westbahnhof", kind = "personenbahnhof" }))
  assert(netz.add_station({ name = "Hafen", kind = "gueterbahnhof" }))
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B" } })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

local function join(h, d, v, roles, before_roles)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  if before_roles then before_roles() end
  for _, r in ipairs(roles) do d.tap_row(v, "rollen", r) end
  d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

return {
  { "Bahnhof und Anmeldung zusammen: nach den Gleisen folgt die Wahl der Anmeldestation", function()
    local h, z, d, v, netz = setup()
    join(h, d, v, { "Bahnhof", "Anmeldung" })
    t.eq(screen(d), "2.kennung", d.text(v))
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").label, "N0001 | BHF ANM")
    d.tap_row(v, "geraete", "Create_Station_1"); d.tap_row(v, "geraete", "Create_Station_2")
    d.tap(v, "act:weiter")
    for _, station in ipairs({ "Create_Station_1", "Create_Station_2" }) do
      d.tap(v, "act:neues_gleis"); d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
      d.tap_row(v, "bahnhof", station); d.tap(v, "act:weiter")
    end
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.anmeldung", d.text(v))
  end },
  { "Anmeldung allein: Betriebsstelle waehlen, Kennung, Geraete, Anmeldestation, Pruefung, aktiv", function()
    local h, z, d, v, netz = setup()
    join(h, d, v, { "Anmeldung" })
    t.eq(screen(d), "2.station", d.text(v))
    t.contains(d.text(v), "Westbahnhof"); t.contains(d.text(v), "Hafen")
    d.tap(v, "act:weiter")
    t.contains(v.hint, "Bitte eine Betriebsstelle")
    d.tap(v, "sel:station_wahl:1")
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "anmeldung"); t.eq(netz.node("N0001").station, "BF0001")
    d.tap_row(v, "geraete", "Create_Station_1")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.anmeldung", d.text(v))
    d.tap_row(v, "anmeldung", "Create_Station_1")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen")
    d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.label:match("ANM") ~= nil, true)
    t.eq(config.node.station, netz.node("N0001").station)
  end },
  { "Anmeldung: leeres Netz zeigt einen Hinweis, 'Von Hand' geht den bisherigen Weg, Ausfall der Leitstelle meldet", function()
    local h, z, d, v, netz = setup()
    for _, st in ipairs(netz.stations()) do assert(netz.remove_station(st.id)) end
    join(h, d, v, { "Anmeldung" })
    t.contains(d.text(v), "noch keine Betriebsstelle")
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
    local h2, z2, d2, v2 = setup()
    join(h2, d2, v2, { "Anmeldung" }, function() z2.node.handle = function() end end)
    h2.step(12); d2.node.render()
    t.contains(d2.text(v2), "antwortet nicht")
  end },
  { "Wire: Betriebsstellen seitenweise, ungueltige Anfragen abgelehnt", function()
    local h, z, d, v, netz = setup()
    local role = z.node.roles.zentrale
    d.node.directory_stations("hauptstelle"); h.step(3)
    local replies = {}
    local real = z.node.reply
    z.node.reply = function(m, status, payload) replies[#replies + 1] = { status = status, payload = payload } return real(m, status, payload) end
    local function ask(payload)
      role.on_message(d.node.replace_factory.make("abfrage", "hauptstelle", payload), "ok")
      return replies[#replies]
    end
    local first = ask({ kind = "betriebsstellen_liste" })
    t.eq(first.status, "ok"); t.eq(#first.payload.stations, 2); t.eq(first.payload.stations[1].name, "Westbahnhof")
    local after = ask({ kind = "betriebsstellen_liste", after = "BF0001" })
    t.eq(#after.payload.stations, 1); t.eq(after.payload.stations[1].id, "BF0002")
    t.eq(#ask({ kind = "betriebsstellen_liste", after = 7 }).payload.stations, 2, "falscher Typ wird wie 'ab Anfang' behandelt")
    t.eq(ask({ kind = "node_anfordern", claim = "wire-claim-001", role = "anmeldung", station = 5 }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "wire-claim-001", roles = "depot" }).status, "abgelehnt")
    local ok = ask({ kind = "node_anfordern", claim = "wire-claim-001", role = "anmeldung", station = "BF0001" })
    t.eq(ok.status, "ok"); t.eq(ok.payload.node.label, "N0001 | ANM | BF0001")
  end },
}
