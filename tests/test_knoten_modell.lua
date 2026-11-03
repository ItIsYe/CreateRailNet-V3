--[[
Purpose: Knoten aus dem Verzeichnis fuer die Knoten-Node (Konzept 7): Uebersetzung in das Knotenmodell (Anschluesse, Verbindungen, Konflikte, Ein-/Ausfahrten) und Anforderung einer Node-Kennung fuer einen vollstaendig bestaetigten Knoten.
]]

local t = dofile("tests/lib/t.lua")
local model = require("setup.model")
local netzlib = require("domain.netz")

local function directory_junction()
  return {
    id = "K0001", name = "Kreuzung", rev = 3,
    connections = {
      { name = "West", tracks = { { id = "A0001", name = "Gleis 1", area = "Kreuzung" }, { id = "A0002", name = "Gleis 2", area = "Kreuzung" } } },
      { name = "Ost", tracks = { { id = "A0003", name = "Gleis 3", area = "Kreuzung" }, { id = "A0004", name = "Gleis 4", area = "Kreuzung" } } },
    },
    routes = { { id = "F0001", from = "A0001", to = "A0003" }, { id = "F0002", from = "A0004", to = "A0002" } },
    conflicts = { { a = "F0001", b = "F0002" } },
  }
end

local function track_by_id(result, id)
  for _, tr in ipairs(result.tracks) do if tr.id == id then return tr end end
end

return {
  { "Uebersetzung: Anschluesse, Verbindungen (sortiert), Konflikte, Einfahrten und Ausfahrten", function()
    local r = assert(model.junction_from_directory(directory_junction()))
    t.eq(r.connections.West, true); t.eq(r.connections.Ost, true)
    t.eq(#r.moves, 2); t.eq(r.moves[1].from, "Ost"); t.eq(r.moves[1].to, "West"); t.eq(r.moves[2].from, "West"); t.eq(r.moves[2].to, "Ost")
    t.eq(#r.conflicts, 1); t.eq(r.conflicts[1].moves[1], 1); t.eq(r.conflicts[1].moves[2], 2)
    t.eq(track_by_id(r, "A0001").role, "ein"); t.eq(track_by_id(r, "A0003").role, "aus")
    t.eq(track_by_id(r, "A0004").role, "ein"); t.eq(track_by_id(r, "A0002").role, "aus")
    t.eq(track_by_id(r, "A0001").name, "West Gleis 1"); t.eq(track_by_id(r, "A0001").connection, "West")
    t.eq(r.unused, 0)
  end },
  { "Mehrere Fahrwege zwischen denselben Anschluessen ergeben eine Verbindung; Konflikt innerhalb einer Verbindung entfaellt", function()
    local j = directory_junction()
    j.routes[#j.routes + 1] = { id = "F0003", from = "A0002", to = "A0004" }       -- West Gleis 2 -> Ost Gleis 4: wieder West>Ost
    j.conflicts[#j.conflicts + 1] = { a = "F0001", b = "F0003" }                    -- beide West>Ost: kein eigener Konflikt
    local r, why = model.junction_from_directory(j)
    t.eq(r, nil); t.contains(why, "Ein- und Ausfahrt")                              -- A0002 ist Ziel von F0002 und Start von F0003
    j.routes[3] = { id = "F0003", from = "A0001", to = "A0004" }
    j.conflicts[2] = { a = "F0001", b = "F0003" }
    j.routes[2] = { id = "F0002", from = "A0004", to = "A0002" }
    local r2, why2 = model.junction_from_directory(j)
    t.eq(r2, nil); t.contains(why2, "Ein- und Ausfahrt")                            -- A0004 ist Ziel von F0003 und Start von F0002
    local k = directory_junction()
    k.routes = { { id = "F0001", from = "A0001", to = "A0003" }, { id = "F0003", from = "A0002", to = "A0004" } }
    k.conflicts = { { a = "F0001", b = "F0003" } }
    local r3 = assert(model.junction_from_directory(k))
    t.eq(#r3.moves, 1, "beide Fahrwege sind West>Ost")
    t.eq(#r3.conflicts, 0, "ein Konflikt innerhalb derselben Verbindung ist schon durch die Einfahrt abgedeckt")
  end },
  { "Fehler: ohne Fahrweg, Fahrweg ausserhalb, am selben Anschluss, Gleis in zwei Anschluessen", function()
    local j = directory_junction(); j.routes = {}
    local r, why = model.junction_from_directory(j)
    t.eq(r, nil); t.contains(why, "keinen bestaetigten Fahrweg")
    j = directory_junction(); j.routes[1].to = "A0099"
    r, why = model.junction_from_directory(j)
    t.eq(r, nil); t.contains(why, "ausserhalb")
    j = directory_junction(); j.routes[1].to = "A0002"
    r, why = model.junction_from_directory(j)
    t.eq(r, nil); t.contains(why, "selben Anschluss")
    j = directory_junction(); j.connections[2].tracks[1].id = "A0001"
    r, why = model.junction_from_directory(j)
    t.eq(r, nil); t.contains(why, "zwei Anschluessen")
  end },
  { "Gleisenden ohne Fahrweg bleiben unberuecksichtigt; gleiche Gleisnamen bekommen den Bereich dazu", function()
    local j = directory_junction()
    j.connections[1].tracks[#j.connections[1].tracks + 1] = { id = "A0005", name = "Gleis 5", area = "Kreuzung" }
    local r = assert(model.junction_from_directory(j))
    t.eq(r.unused, 1); t.eq(#r.tracks, 4)
    j = directory_junction()
    j.connections[1].tracks[2].name = "Gleis 1"; j.connections[1].tracks[2].area = "Anderer Bereich"
    local r2 = assert(model.junction_from_directory(j))
    t.eq(track_by_id(r2, "A0001").name, "West Gleis 1 Kreuzung")
    t.eq(track_by_id(r2, "A0002").name, "West Gleis 1 Anderer Bereich")
  end },
  { "Verzeichnis: Anforderung fuer einen bestaetigten Knoten; Label und Name; alle Gleisenden; wiederholbar", function()
    local netz = netzlib.new({})
    netz.add_area({ name = "Kreuzung", ends = { "A", "B" }, count = 4 })
    local k = assert(netz.add_junction({ name = "Hauptknoten" }))
    assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
    assert(netz.add_route(k, "A0001", "A0003", true))
    local node = assert(netz.claim_node({ claim = "knoten-claim-1", role = "knoten", junction = k }))
    t.eq(node.id, "N0001"); t.eq(node.label, "N0001 | KNO | K0001"); t.eq(node.name, "Knoten Hauptknoten N0001")
    t.eq(node.junction, k); t.eq(node.area, nil)
    t.eq(#node.tracks, 4); t.eq(node.tracks[1], "A0001"); t.eq(node.tracks[4], "A0004")
    local again = assert(netz.claim_node({ claim = "knoten-claim-1", role = "knoten", junction = k }))
    t.eq(again.id, "N0001"); t.eq(#netz.nodes(), 1)
    -- der Knoten laesst sich nicht loeschen, solange die Node ihn nutzt; ihre Gleise auch nicht
    local ok, why = netz.remove_junction(k)
    t.eq(ok, nil); t.contains(why, "N0001")
    ok, why = netz.remove_track("A0001")
    t.eq(ok, nil); t.contains(why, "N0001")
    assert(netz.discard_node("N0001"))
    assert(netz.remove_junction(k))
  end },
  { "Verzeichnis: die gemeldeten Gleise sind aufsteigend sortiert, unabhaengig von der Reihenfolge der Anschluesse", function()
    local netz = netzlib.new({})
    netz.add_area({ name = "Kreuzung", ends = { "A", "B" }, count = 4 })
    local k = assert(netz.add_junction({ name = "Hauptknoten" }))
    assert(netz.add_connection(k, "Zeta", { "A0004", "A0003" })); assert(netz.add_connection(k, "Alpha", { "A0002", "A0001" }))
    assert(netz.add_route(k, "A0001", "A0003", true))
    local node = assert(netz.claim_node({ claim = "knoten-claim-9", role = "knoten", junction = k }))
    t.eq(table.concat(node.tracks, ","), "A0001,A0002,A0003,A0004")
  end },
  { "Verzeichnis: unvollstaendige oder falsche Anforderungen werden abgelehnt", function()
    local netz = netzlib.new({})
    netz.add_area({ name = "Kreuzung", ends = { "A", "B" }, count = 4 })
    local k = assert(netz.add_junction({ name = "Hauptknoten" }))
    local function claim(spec) spec.claim = spec.claim or "knoten-claim-2"; return netz.claim_node(spec) end
    local node, why = claim({ role = "knoten", junction = k })
    t.eq(node, nil); t.contains(why, "mindestens zwei Anschluesse")
    assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
    node, why = claim({ role = "knoten", junction = k })
    t.eq(node, nil); t.contains(why, "keinen Fahrweg")
    assert(netz.add_route(k, "A0001", "A0003"))                                    -- unbestaetigt
    node, why = claim({ role = "knoten", junction = k })
    t.eq(node, nil); t.contains(why, "unbestaetigte")
    assert(netz.confirm_junction(k))
    node, why = claim({ role = "knoten", junction = "K9999" })
    t.eq(node, nil); t.contains(why, "gibt es nicht")
    node, why = claim({ role = "knoten" })
    t.eq(node, nil); t.contains(why, "gibt es nicht")
    node, why = claim({ role = "knoten", junction = k, area = "B0001", tracks = { "A0001" } })
    t.eq(node, nil); t.contains(why, "ohne Bereich")
    node, why = claim({ role = "signal", area = "B0001", tracks = { "A0001" }, junction = k })
    t.eq(node, nil); t.contains(why, "Nur die Rolle knoten")
    t.eq(#netz.nodes(), 0, "nichts angelegt")
    node = assert(claim({ role = "knoten", junction = k }))
    t.eq(node.id, "N0001")
  end },
  { "Ein spaeter geaenderter Knoten laesst die Anforderung unveraendert, bis sie erneut gestellt wird", function()
    local netz = netzlib.new({})
    netz.add_area({ name = "Kreuzung", ends = { "A", "B" }, count = 6 })
    local k = assert(netz.add_junction({ name = "Hauptknoten" }))
    assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
    assert(netz.add_route(k, "A0001", "A0003", true))
    local node = assert(netz.claim_node({ claim = "knoten-claim-3", role = "knoten", junction = k }))
    t.eq(#node.tracks, 4)
    assert(netz.add_connection(k, "Nord", { "A0005", "A0006" }))
    t.eq(#netz.node("N0001").tracks, 4)
    local rev = netz.junction(k).rev
    local again = assert(netz.claim_node({ claim = "knoten-claim-3", role = "knoten", junction = k }))
    t.eq(#again.tracks, 6, "erneut angefordert: die Gleise des erweiterten Knotens")
    t.ok(rev >= 1)
  end },
}
