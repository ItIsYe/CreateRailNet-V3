--[[
Purpose: Vorlagen des Bereichsassistenten (Konzept 12.3): Strecke mit Nebenanschluss, Verzweigung, freie Einrichtung. Sie erzeugen bearbeitbare Objekte, sind alles oder nichts, schlagen Fahrwege nur vor und raten keine Verbindungen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local netzlib = require("domain.netz")
local storelib = require("core.store")
local cc = dofile("tests/fakes/cc.lua")

local function snapshot(netz)
  local ser = require("core.ser")
  return ser.encode({ a = netz.areas(), s = netz.stations(), j = netz.junctions(), rev = netz.revision() })
end

return {
  { "Nebenanschluss: Hauptstrecke, Bahnhof am Nebengleis mit Verbindung zu genau einem Hauptgleis und seinen Fahrtrichtungen", function()
    local netz = netzlib.new({})
    local made = assert(netz.template_siding({
      name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2,
      siding = { name = "Hafen", kind = "gueterbahnhof", track = "Gleis 1", directions = { "ostbahnhof" } },
    }))
    t.eq(made.area, "B0001"); t.eq(made.station, "BF0001"); t.eq(made.track, "A0001")
    local st = netz.station("BF0001")
    t.eq(st.links[1].track, "A0001"); t.eq(st.links[1].relation, "verbindung"); t.eq(st.links[1].directions[1], "Ostbahnhof")
    t.eq(#st.links, 1, "keine Verbindung zu den parallelen Gleisen")
    t.eq(#netz.area("B0001").tracks, 2)
    -- nummer statt name, beide Richtungen
    local made2 = assert(netz.template_siding({
      name = "Nord-Sued", ends = { "Nord", "Sued" }, count = 3,
      siding = { name = "Hafen", kind = "gueterbahnhof", track = "2", directions = { "beide" } },
    }))
    t.eq(made2.station, "BF0001", "eine vorhandene Betriebsstelle gleichen Namens wird verwendet")
    t.eq(#netz.station("BF0001").links, 2)
    t.eq(#netz.station("BF0001").links[2].directions, 2)
  end },
  { "Nebenanschluss: jeder Fehler laesst alles unveraendert (auch nichts auf der Platte)", function()
    local fs = cc.fs()
    fs.makeDir("/crn_data")
    local store = storelib.new(fs)
    local netz = netzlib.new({ store = store, path = "/crn_data/netz.lua" })
    assert(netz.add_area({ name = "Vorhanden", ends = { "A", "B" }, count = 1 }))
    local before = snapshot(netz)
    local on_disk = fs.open("/crn_data/netz.lua", "r").readAll()
    local function bad(spec, why)
      local made, err = netz.template_siding(spec)
      t.eq(made, nil, why)
      t.eq(snapshot(netz), before, "unveraendert nach: " .. why)
      t.eq(fs.open("/crn_data/netz.lua", "r").readAll(), on_disk, "Datei unveraendert nach: " .. why)
      return err
    end
    t.contains(bad({ name = "West-Ost", ends = { "W", "O" }, count = 2 }, "ohne Nebenanschluss"), "Nebenanschluss fehlt")
    t.contains(bad({ name = "West-Ost", ends = { "W", "O" }, count = 2, siding = { name = "Hafen", kind = "gueterbahnhof", track = "Gleis 9" } }, "Hauptgleis unbekannt"), "gibt es im neuen Bereich nicht")
    t.contains(bad({ name = "West-Ost", ends = { "W", "O" }, count = 2, siding = { name = "Hafen", kind = "unsinn", track = "1" } }, "falsche Art"), "personenbahnhof, gueterbahnhof oder depot")
    t.contains(bad({ name = "West-Ost", ends = { "W", "O" }, count = 2, siding = { name = "Hafen", kind = "depot", track = "1", directions = { "Nirgendwo" } } }, "falsche Richtung"), "kein Anschluss")
    t.contains(bad({ name = "Vorhanden", ends = { "W", "O" }, count = 2, siding = { name = "Hafen", kind = "depot", track = "1" } }, "Name belegt"), "gibt es schon")
    t.contains(bad({ name = "X", ends = { "W", "W" }, count = 2, siding = { name = "Hafen", kind = "depot", track = "1" } }, "gleiche Anschluesse"), "verschiedene Namen")
  end },
  { "Verzweigung: ein Bereich je Anschluss, Knoten mit Anschlussgruppen, Fahrwege und Konflikte nur vorgeschlagen", function()
    local netz = netzlib.new({})
    local made = assert(netz.template_branch({ name = "Kreuz", connections = { { name = "West", count = 2 }, { name = "Ost", count = 2 }, { name = "Sued", count = 1 } } }))
    t.eq(#made.areas, 3)
    local j = netz.junction(made.junction)
    t.eq(#j.connections, 3)
    t.ok(made.routes > 0)
    t.eq(j.unconfirmed, #j.routes + #j.conflicts, "alles unbestaetigt")
    t.eq(#netz.junction_part(made.junction, "fahrwege").routes, 0, "Nodes erhalten nichts Unbestaetigtes")
    -- Namen der Bereiche und ihre Anschlussenden
    local a = netz.area(made.areas[1])
    t.eq(a.name, "Kreuz West"); t.eq(a.ends[1], "West"); t.eq(a.ends[2], "Kreuz")
    -- nach dem Bestaetigen sind sie fuer Nodes sichtbar
    assert(netz.confirm_junction(made.junction))
    t.ok(#netz.junction_part(made.junction, "fahrwege").routes > 0)
  end },
  { "Verzweigung mit zwei Anschluessen schlaegt nur durchgehende Fahrwege vor; Fehler und zu viele Fahrwege machen nichts", function()
    local netz = netzlib.new({})
    local made = assert(netz.template_branch({ name = "Weiche", connections = { { name = "West", count = 2 }, { name = "Ost", count = 2 } } }))
    t.eq(made.routes, 4, "durchgehend: beide Richtungen, gleicher Index")
    local before = snapshot(netz)
    local function bad(spec, expect)
      local r, err = netz.template_branch(spec)
      t.eq(r, nil); t.contains(err, expect)
      t.eq(snapshot(netz), before)
    end
    bad({ name = "Einzeln", connections = { { name = "West", count = 2 } } }, "mindestens zwei")
    bad({ name = "Doppelt", connections = { { name = "West", count = 2 }, { name = "West", count = 2 } } }, "gibt es")
    bad({ name = "Zahl", connections = { { name = "West", count = 0 }, { name = "Ost", count = 2 } } }, "Gleisanzahl")
    bad({ name = "Weiche", connections = { { name = "West", count = 2 }, { name = "Ost", count = 2 } } }, "Knoten Weiche gibt es schon")
    bad({ name = "Gleich", connections = { { name = "Gleich", count = 1 }, { name = "Ost", count = 2 } } }, "verschiedene Namen")
    bad({ name = "Viele", connections = { { name = "A", count = 6 }, { name = "B", count = 6 }, { name = "C", count = 6 } } }, "Fahrwege")
  end },
  { "Freie Einrichtung: Gleise mit eigenen Namen und Richtungen, Gross-/Kleinschreibung der Richtung egal, doppelte Namen abgelehnt", function()
    local netz = netzlib.new({})
    local made = assert(netz.template_free({ name = "Rangierbezirk", ends = { "Einfahrt", "Ausfahrt" }, tracks = {
      { name = "Hauptgleis", direction = "ausfahrt" }, { name = "Gegengleis", direction = "EINFAHRT" }, { name = "Abstellgleis", direction = "beide" }, { name = "Ladegleis" } } }))
    local tracks = netz.area(made.area).tracks
    t.eq(#tracks, 4)
    t.eq(tracks[1].name, "Hauptgleis"); t.eq(tracks[1].direction, "Ausfahrt")
    t.eq(tracks[2].direction, "Einfahrt"); t.eq(tracks[3].direction, "beide"); t.eq(tracks[4].direction, "beide")
    local before = snapshot(netz)
    local r, err = netz.template_free({ name = "Doppelt", ends = { "A", "B" }, tracks = { { name = "Gleis 1" }, { name = "gleis 1" } } })
    t.eq(r, nil); t.contains(err, "doppelt")
    r, err = netz.template_free({ name = "Richtung", ends = { "A", "B" }, tracks = { { name = "Gleis 1", direction = "C" } } })
    t.eq(r, nil); t.contains(err, "kein Anschluss")
    r, err = netz.template_free({ name = "Leer", ends = { "A", "B" }, tracks = {} })
    t.eq(r, nil); t.contains(err, "Gleisliste")
    t.eq(snapshot(netz), before)
    -- die Ergebnisse sind normale Objekte: aenderbar
    assert(netz.set_track(tracks[1].id, { name = "Neu benannt" }))
    assert(netz.add_track(made.area, "Zusatzgleis", "Einfahrt"))
  end },
  { "Seite Assistent: Vorlage waehlen, Formular, Fehlertexte, Nebenanschluss und Verzweigung und freie Einrichtung", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    h.step(2)
    local netz = z.node.roles.zentrale.netz
    local v = H.open_page(z, "assistent")
    t.contains(z.text(v), "Nebenanschluss"); t.contains(z.text(v), "Verzweigung"); t.contains(z.text(v), "Freie Einrichtung")
    -- Nebenanschluss
    z.tap(v, "act:neu")
    z.type(v, "name", "West-Ost"); z.type(v, "anschluesse", "Westbahnhof; Ostbahnhof")
    z.tap(v, "act:f_weiter")
    z.type(v, "gleise", "2"); z.type(v, "neben", "Hafen; gueter; Gleis 1; Ostbahnhof")
    z.tap(v, "act:f_speichern")
    t.eq(#netz.areas(), 1, v.hint)
    t.eq(netz.station("BF0001").kind, "gueterbahnhof"); t.eq(netz.station("BF0001").links[1].directions[1], "Ostbahnhof")
    -- Fehlertext bei falscher Eingabe, Formular bleibt
    z.tap(v, "act:neu")
    z.type(v, "name", "Falsch"); z.type(v, "anschluesse", "nur einer")
    z.tap(v, "act:f_weiter"); z.type(v, "gleise", "2"); z.type(v, "neben", "Hafen; gueter; 1")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "zwei Namen")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- Verzweigung ueber die Auswahl der Vorlage
    z.tap(v, "sel:assistent:2"); z.tap(v, "act:bearbeiten")
    t.contains(z.text(v), "Vorlage")
    z.type(v, "name", "Kreuz"); z.type(v, "anschluesse", "West:2; Ost:2; Sued:1")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.eq(#netz.junctions(), 1, v.hint)
    t.eq(netz.junctions()[1].unconfirmed > 0, true)
    -- falsche Anschlussschreibweise
    z.tap(v, "sel:assistent:2"); z.tap(v, "act:bearbeiten")
    z.type(v, "name", "Kaputt"); z.type(v, "anschluesse", "West; Ost")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.contains(v.hint, "Name:Gleisanzahl")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- freie Einrichtung
    z.tap(v, "sel:assistent:3"); z.tap(v, "act:bearbeiten")
    z.type(v, "name", "Rangieren"); z.type(v, "anschluesse", "Ein; Aus")
    z.tap(v, "act:f_weiter"); z.type(v, "gleise", "Hauptgleis:Aus; Gegengleis:Ein; Abstell:beide")
    z.tap(v, "act:f_speichern")
    local found
    for _, a in ipairs(netz.areas()) do if a.name == "Rangieren" then found = netz.area(a.id) end end
    t.ok(found, v.hint); t.eq(#found.tracks, 3); t.eq(found.tracks[2].direction, "Ein")
    -- unbekannte Vorlage
    z.tap(v, "act:neu"); z.type(v, "vorlage", "gerade")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.contains(v.hint, "nebenanschluss, verzweigung, frei oder teilen")
  end },
}
