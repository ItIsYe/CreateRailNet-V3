--[[
Purpose: Seiten Betriebsstellen, Beziehungen und Anschluesse der Leitstelle (Netzverzeichnis, Konzept 4.3, 6): Anlegen, Aendern mit Stand, Fehlertexte, Loeschen nach zweitem Druck, Namen und Richtungen folgen Umbenennungen, Zustand "im bau".
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function network()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  h.step(2)
  return h, z, z.node.roles.zentrale.netz
end

return {
  { "Seite Betriebsstellen: anlegen mit Art-Kurzform und Standort, aendern, doppelter Name, loeschen nach zweitem Druck", function()
    local h, z, netz = network()
    local v = H.open_page(z, "betriebsstellen")
    t.ok(z.has(v, "Noch keine Betriebsstelle"), z.text(v))
    z.tap(v, "act:neu")
    z.type(v, "name", "Patrick Personen")
    z.type(v, "art", "personen")
    z.type(v, "standort", "Patrick")
    z.tap(v, "act:f_speichern")
    t.eq(#netz.stations(), 1, v.hint .. z.text(v))
    t.eq(netz.station("BF0001").kind, "personenbahnhof"); t.eq(netz.station("BF0001").site_name, "Patrick")
    t.ok(z.has(v, "Patrick Personen"), z.text(v))
    -- doppelter Name: Hinweis
    z.tap(v, "act:neu")
    z.type(v, "name", "patrick personen"); z.type(v, "art", "depot")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibt es schon")
    z.tap(v, "act:f_zurueck")
    -- aendern: Art
    z.tap(v, "act:bearbeiten")
    z.type(v, "art", "gueter")
    z.tap(v, "act:f_speichern")
    t.eq(netz.station("BF0001").kind, "gueterbahnhof", v.hint)
    -- loeschen
    z.tap(v, "act:loeschen")
    t.contains(v.hint, "Nochmal druecken")
    t.eq(#netz.stations(), 1)
    z.tap(v, "act:loeschen")
    t.eq(#netz.stations(), 0)
  end },
  { "Seite Beziehungen: vorbei, verbindung mit Fahrtrichtungen, bahnhofsgleis; Fehlertexte; loesen", function()
    local h, z, netz = network()
    local a = netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
    local bf = netz.add_station({ name = "Hafen", kind = "gueterbahnhof" })
    local v = H.open_page(z, "beziehungen")
    t.ok(z.has(v, "Noch keine Beziehung"), z.text(v))
    z.tap(v, "act:neu")
    z.type(v, "betriebsstelle", "hafen"); z.type(v, "bereich", "west-ost"); z.type(v, "gleis", "gleis 1")
    z.tap(v, "act:f_weiter")
    z.type(v, "beziehung", "verbindung"); z.type(v, "richtungen", "ostbahnhof")
    z.tap(v, "act:f_speichern")
    t.eq(#netz.station(bf).links, 1, v.hint .. z.text(v))
    local link = netz.station(bf).links[1]
    t.eq(link.relation, "verbindung"); t.eq(link.directions[1], "Ostbahnhof", "kanonische Schreibweise")
    t.ok(z.has(v, "Hafen / West-Ost"), z.text(v))
    -- Fehler: Gleis gibt es nicht
    z.tap(v, "act:neu")
    z.type(v, "betriebsstelle", "Hafen"); z.type(v, "bereich", "West-Ost"); z.type(v, "gleis", "Gleis 9")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibt es in diesem Bereich nicht")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- loesen
    z.tap(v, "act:loesen"); t.contains(v.hint, "Nochmal")
    z.tap(v, "act:loesen")
    t.eq(#netz.station(bf).links, 0)
  end },
  { "Seite Anschluesse: Betriebsstelle als Anschluss (Name und Richtungen folgen), offenes Ende setzt 'im bau', Freigeben", function()
    local h, z, netz = network()
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 2 })
    local bf = netz.add_station({ name = "Ostbahnhof", kind = "personenbahnhof" })
    local v = H.open_page(z, "anschluesse")
    t.ok(z.has(v, "West-Ost / Anschluss 1: West"), z.text(v))
    z.tap(v, "sel:anschluesse:2")
    z.tap(v, "act:bearbeiten")
    z.type(v, "art", "betriebsstelle")
    z.tap(v, "act:f_weiter")
    z.type(v, "ziel", "Ostbahnhof")
    z.tap(v, "act:f_speichern")
    t.eq(netz.area(a).ends[2], "Ostbahnhof", v.hint)
    t.eq(netz.area(a).end_kinds[2], "betriebsstelle")
    t.eq(netz.track("A0001").direction, "Ostbahnhof")
    -- offenes Ende
    z.tap(v, "sel:anschluesse:1")
    z.tap(v, "act:bearbeiten")
    z.type(v, "art", "offen")
    z.tap(v, "act:f_weiter"); z.type(v, "ziel", "Verlaengerung")
    z.tap(v, "act:f_speichern")
    t.eq(netz.area(a).state, "im bau", v.hint)
    t.ok(z.has(v, "Freigeben"), "die Aktion bietet das Freigeben an: " .. z.text(v))
    -- Freigeben geht erst, wenn kein Ende mehr offen ist
    z.tap(v, "act:bau")
    t.contains(v.hint, "offenes Ende")
    z.tap(v, "act:bearbeiten")
    z.type(v, "art", "name")
    z.tap(v, "act:f_weiter"); z.type(v, "ziel", "West")
    z.tap(v, "act:f_speichern")
    z.tap(v, "act:bau")
    t.eq(netz.area(a).state, "betriebsbereit")
    -- unbekannte Betriebsstelle
    z.tap(v, "act:bearbeiten")
    z.type(v, "art", "betriebsstelle")
    z.tap(v, "act:f_weiter"); z.type(v, "ziel", "Nirgends")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibt es nicht")
  end },
  { "Die Seiten des Verzeichnisses stehen hinter den Betriebsseiten", function()
    local h, z = network()
    local ids = {}
    for _, p in ipairs(z.node.roles.zentrale.pages) do ids[#ids + 1] = p.id end
    local joined = table.concat(ids, ",")
    t.ok(joined:find("stoerungen,bereiche", 1, true), joined)
    t.ok(joined:find("^zuege,auftraege,netz"), joined)
  end },
}
