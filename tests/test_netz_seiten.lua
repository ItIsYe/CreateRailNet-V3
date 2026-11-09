--[[
Purpose: Seiten der Leitstelle rund um das Netzverzeichnis: es gibt acht Seiten in fester Reihenfolge; Betriebsstellen, Standorte, Bereiche, Gleise, Anschluesse, Beziehungen, Knoten, Assistent und Signale gibt es nicht mehr.
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
  { "Die Seiten der Leitstelle: acht in fester Reihenfolge, ohne Betriebsstellen", function()
    local h, z = network()
    local ids = {}
    for _, p in ipairs(z.node.roles.zentrale.pages) do ids[#ids + 1] = p.id end
    local joined = table.concat(ids, ",")
    t.eq(joined, "zuege,auftraege,netz,vorlagen,bahnhoefe,linien,depot,stoerungen")
    for _, gone in ipairs({ "betriebsstellen", "bereiche", "gleise", "anschluesse", "beziehungen", "knoten", "assistent", "signale" }) do
      t.ok(not (("," .. joined .. ","):find("," .. gone .. ",", 1, true)), gone .. " gibt es noch: " .. joined)
    end
  end },
  { "Netz-Verzeichnis ohne Betriebsstellen: es gibt keine Verwaltung dafuer mehr (kein add_station, keine Standorte)", function()
    local h, z, netz = network()
    for _, gone in ipairs({ "add_station", "set_station", "remove_station", "stations", "station", "sites" }) do
      t.eq(netz[gone], nil, gone .. " gibt es nicht mehr")
    end
  end },
}
