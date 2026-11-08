--[[
Purpose: Seite Betriebsstellen der Leitstelle (Node-Verzeichnis): Anlegen, Aendern mit Stand, Fehlertexte, Loeschen nach zweitem Druck; die Seiten fuer Bereiche, Gleise, Knoten und Signale sind entfallen.
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
  { "Die Seite Betriebsstellen steht hinter den Betriebsseiten; Bereiche, Gleise, Anschluesse, Beziehungen, Knoten, Assistent und Signale gibt es nicht mehr", function()
    local h, z = network()
    local ids = {}
    for _, p in ipairs(z.node.roles.zentrale.pages) do ids[#ids + 1] = p.id end
    local joined = table.concat(ids, ",")
    t.ok(joined:find("stoerungen,betriebsstellen$"), joined)
    t.ok(joined:find("^zuege,auftraege,netz"), joined)
    for _, gone in ipairs({ "bereiche", "gleise", "anschluesse", "beziehungen", "knoten", "assistent", "signale" }) do
      t.ok(not (("," .. joined .. ","):find("," .. gone .. ",", 1, true)), gone .. " gibt es noch: " .. joined)
    end
  end },
}
