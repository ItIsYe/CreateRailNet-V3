--[[
Purpose: Erstaufbau eines Systems an einem Computer mit 51x19 Zeichen: die erste Leitstelle wird ohne Umwege eingerichtet (Rolle vorbelegt, keine abgeschnittenen Anleitungstexte), eine frische Leitstelle sagt, was als Naechstes zu tun ist, und leere Listen erklaeren sich vollstaendig.
]]

local t = dofile("tests/lib/t.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local W = require("ui.widgets")

local function fresh()
  local w = create.world()
  w.add_modem("left", true)
  local d = drv.new({ world = w, monitors = {} })
  d.restart()
  return d, d.view()
end

-- Zeilen, die mit "~" enden: dort wurde Text abgeschnitten
local function truncated(d, v)
  local out = {}
  for line in (d.text(v) .. "\n"):gmatch("(.-)\n") do
    if line:match("~%s*$") then out[#out + 1] = line end
  end
  return out
end

return {
  { "Erste Leitstelle: die Rolle Leitstelle ist vorbelegt, der Assistent fuehrt ohne Umweg bis zum aktiven Node", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().screen, "2.rollen", d.text(v))
    t.contains(d.text(v), "[x] Leitstelle")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptstelle"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")                               -- Geraete (keine noetig)
    d.tap(v, "act:weiter")                               -- Test
    t.contains(d.text(v), "diese Node ist die Leitstelle")
    d.tap(v, "act:speichern")
    t.eq(d.node.config.status, "aktiv")
    t.eq(d.node.config.node.roles[1], "zentrale")
  end },
  { "Beitreten setzt keine Rolle: die Auswahl bleibt leer", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.type(v, "zentrale", "hauptstelle"); d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().screen, "2.rollen", d.text(v))
    t.contains(d.text(v), "[ ] Leitstelle")
    t.eq(#d.node.setup.session().wiz.roles, 0)
  end },
  { "Die ersten Bildschirme der Einrichtung schneiden keinen Anleitungstext ab", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    t.eq(#truncated(d, v), 0, d.text(v))
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    t.contains(d.text(v), "Wie heisst das Netz?")
    t.contains(d.text(v), "Buchstaben, Ziffern, Leerzeichen, - und _")
    t.contains(d.text(v), "keine Verschluesselung")
    t.eq(#truncated(d, v), 0, d.text(v))
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    t.eq(#truncated(d, v), 0, d.text(v))
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptstelle"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    t.contains(d.text(v), "Lesen sofort, Schalten erst nach Bestaetigung.")
    t.eq(#truncated(d, v), 0, d.text(v))
    d.tap(v, "act:weiter")
    t.eq(#truncated(d, v), 0, d.text(v))
  end },
  { "Frische Leitstelle: die Uebersicht nennt den naechsten Schritt, bis Strecke und Nodes da sind", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptstelle"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    v.set_page("uebersicht"); d.node.render()
    t.contains(d.text(v), "Naechster Schritt: Strecke anlegen")
    t.contains(d.text(v), "Bereiche")
    t.eq(#truncated(d, v), 0, d.text(v))
    local zentrale = d.node.roles.zentrale
    t.contains(zentrale.next_step(), "Strecke anlegen")
    zentrale.netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
    d.node.render()
    t.contains(zentrale.next_step(), "andere Computer einrichten")
    t.contains(d.text(v), "andere Computer einrichten")
    -- eine Node hat sich gemeldet: keine Anweisung mehr
    zentrale.info().nodes.strecke = { name = "Strecke", last_seen = 0 }
    t.eq(zentrale.next_step(), nil)
    d.node.render()
    t.ok(not d.text(v):find("Naechster Schritt", 1, true))
  end },
  { "Leere Listen der Leitstelle erklaeren sich vollstaendig (umgebrochen statt abgeschnitten)", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptstelle"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    local expect = {
      bereiche = "mit ihren Gleisen", gleise = "oder ergaenzen", knoten = "zusammen", beziehungen = "oder dazu gehoert",
      betriebsstellen = "einmal", linien = "im Takt aus", tafel = "getrennt", bahnhoefe = "Einzelne",
    }
    for page, tail in pairs(expect) do
      v.set_page(page); d.node.render()
      t.contains(d.text(v), tail)
      t.eq(#truncated(d, v), 0, page .. ":\n" .. d.text(v))
    end
  end },
  { "W.fit: kurzer Text bleibt, eine nachgestellte Klammer entfaellt zuerst, sonst wird am Wort gekuerzt", function()
    t.eq(W.fit("kurz", 10), "kurz")
    t.eq(W.fit("Netzname (Buchstaben, Ziffern)", 12), "Netzname")
    t.eq(W.fit("Welche zwei Verbindungen schliessen sich aus? (nacheinander antippen)", 49), "Welche zwei Verbindungen schliessen sich aus?")
    local cut = W.fit("Welcher Ausgang gibt Gleis eins frei? Jeder Ausgang nur einmal.", 49)
    t.ok(#cut <= 49, #cut)
    t.eq(cut:sub(-1), "~")
    t.ok(cut:sub(1, 20) == "Welcher Ausgang gibt", cut)
    t.ok(not cut:match("%sGl~$"), "nicht mitten im Wort: " .. cut)
    t.eq(W.fit("abcd efgh ijkl", 10), "abcd efgh~", "ein vollstaendiges letztes Wort bleibt")
    t.eq(W.fit("abcdef ghijk lmn", 12), "abcdef~", "ein angeschnittenes letztes Wort entfaellt")
    t.eq(W.fit("ab cdefghijklmnop", 10), "ab cdefgh~", "ist nur wenig vom Rest uebrig, wird mitten im Wort gekuerzt")
    t.eq(W.fit("abcdefghijkl", 5), "abcd~")
    t.eq(W.fit("abc", 1), "~")
    t.eq(W.fit("(nur Klammer) und mehr text dahinter ist lang", 10), "(nur Klam~")
  end },
  { "Antwortet die Leitstelle beim Einrichten nicht (zum Beispiel Chunk nicht geladen), steht die ganze Meldung mit dem Hinweis auf dem Bildschirm", function()
    local H = dofile("tests/lib/harness.lua")
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    z.node.roles.zentrale.netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
    local d = h.add_blank({ id = "neu" })
    d.world.add_signal("Create_Signal_1")
    h.step(1)
    local v = d.view()
    v.set_page("einrichtung")
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
    h.unload("hauptstelle")                         -- Chunk der Leitstelle nicht geladen
    h.step(12); d.node.render()
    t.eq(d.node.setup.session().screen, "2.bereich", d.text(v))
    t.contains(d.text(v), "antwortet nicht")
    t.contains(d.text(v), "(Chunk")                   -- umgebrochen: "Laeuft sie (Chunk" / "geladen), ist ein Ender-Modem in Reichweite?"
    t.contains(d.text(v), "geladen), ist ein Ender-Modem in Reichweite?")
    t.eq(#truncated(d, v), 0, d.text(v))
  end },
  { "'Erste Leitstelle erstellen' ueberschreibt eine schon getroffene Rollenwahl nicht", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    local wiz = d.node.setup.session().wiz
    wiz.toggle_role("zentrale"); wiz.toggle_role("signal")          -- abgewaehlt, andere Rolle gewaehlt
    d.tap(v, "act:zurueck"); d.tap(v, "act:zurueck")
    d.tap(v, "sel:modus:1")
    t.eq(#wiz.roles, 1); t.eq(wiz.roles[1], "signal")
  end },
  { "Lange Namen: Zusammenfassung und Kopfzeilen werden umgebrochen beziehungsweise am Wort gekuerzt, nicht mitten im Wort", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptbahnhof-Nordwest-Ausfahrt"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    t.eq(d.node.setup.session().screen, "6.fertig", d.text(v))
    t.contains(d.text(v), "Node: Hauptbahnhof-Nordwest-Ausfahrt")
    t.contains(d.text(v), "(hauptbahnhof-nordwest-ausfahrt)")
    t.contains(d.text(v), "Rolle: Leitstelle")
    t.eq(#truncated(d, v), 0, d.text(v))
  end },
  { "Lange Kopfzeile eines Einrichtungsschritts: gekuerzt am Wortende, mit Marke", function()
    local H = dofile("tests/lib/harness.lua")
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    z.node.roles.zentrale.netz.add_area({ name = "Hauptbahnhof-Nordwest-Ausfahrt", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
    local d = h.add_blank({ id = "neu" })
    d.world.add_signal("Create_Signal_1"); d.world.add_signal("Create_Signal_2")
    h.step(1)
    local v = d.view()
    v.set_page("einrichtung")
    d.tap(v, "act:start")
    d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
    h.step(5); d.node.render()
    d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
    d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(d.node.setup.session().screen, "2.gleise", d.text(v))
    t.contains(d.text(v), "Hauptbahnhof-Nordwest-Ausfahrt: welche Gleise~")
  end },
  { "Listenzeilen: die Einzelheit bekommt den Platz, den der kurze Titel frei laesst, nicht nur die halbe Zeile", function()
    local d, v = fresh()
    d.tap(v, "nav:einrichtung"); d.tap(v, "act:start")
    d.tap(v, "sel:modus:1"); d.tap(v, "act:weiter")
    d.type(v, "netz", "Testnetz"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter")
    d.type(v, "name", "Hauptstelle"); d.tap(v, "act:weiter")
    d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
    d.tap(v, "act:speichern")
    local zentrale = d.node.roles.zentrale
    zentrale.netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ost" }, count = 2 })
    v.set_page("bereiche"); d.node.render()
    t.contains(d.text(v), "West-Ost")
    t.contains(d.text(v), "Westbahnhof - Ost, 2 Gleis(e)")        -- 29 Zeichen: frueher bei 24 abgeschnitten
    -- langer Titel: die Einzelheit bekommt mindestens die halbe Zeile, der Titel den Rest
    zentrale.netz.add_area({ name = "Hauptbahnhof-Nordwest-Ausfahrt", ends = { "Nordwestbahnhof", "Suedostbahnhof" }, count = 4 })
    d.node.render()
    local text = d.text(v)
    t.contains(text, "Hauptbahnhof-Nordwest-A")
    t.contains(text, "Nordwestbahnhof - Sued")
  end },
}
