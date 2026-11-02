--[[
Purpose: Netzverzeichnis in der Leitstelle: Antworten auf Abfragen neuer Computer (Bereiche seitenweise, Gleise, Node anfordern), Meldung einer angeforderten Node im Betrieb, und die Seiten Bereiche, Gleise und Netz zum Anlegen, Aendern, Loeschen und Verwerfen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function network()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Nord", signals = { "Sig_N" } } } })
  h.step(3)
  local replies = {}
  local real = z.node.reply
  z.node.reply = function(m, status, payload)
    if m.payload.kind == "verzeichnis" or m.payload.kind == "verzeichnis_gleise" or m.payload.kind == "node_anfordern" then
      replies[#replies + 1] = { status = status, payload = payload }
    end
    return real(m, status, payload)
  end
  local function ask(payload)
    local m = s.node.factory.make("abfrage", "hauptstelle", payload)
    z.node.roles.zentrale.on_message(m, "ok")
    return replies[#replies]
  end
  return h, z, s, ask
end

return {
  { "Abfrage 'verzeichnis': Bereiche seitenweise (20 je Antwort), mit Kennung und Gleiszahl", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    for i = 1, 21 do netz.add_area({ name = "Bereich " .. i, ends = { "West", "Ost" }, count = 2 }) end
    local first = ask({ kind = "verzeichnis" })
    t.eq(first.status, "ok")
    t.eq(#first.payload.areas, 20); t.eq(first.payload.more, true)
    t.eq(first.payload.areas[1].id, "B0001"); t.eq(first.payload.areas[1].tracks, 2)
    t.eq(first.payload.areas[1].ends[1], "West")
    local second = ask({ kind = "verzeichnis", after = first.payload.areas[20].id })
    t.eq(#second.payload.areas, 1); t.eq(second.payload.more, nil)
    t.eq(second.payload.areas[1].id, "B0021")
    t.eq(ask({ kind = "verzeichnis", after = 42 }).payload.areas[1].id, "B0001", "Unsinn als Cursor wird ignoriert")
    t.eq(first.payload.revision, netz.revision())
  end },
  { "Abfrage 'verzeichnis_gleise': Gleise eines Bereichs mit Richtung; unbekannter Bereich und falsche Typen werden abgelehnt", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 })
    local r = ask({ kind = "verzeichnis_gleise", area = a })
    t.eq(r.status, "ok")
    t.eq(r.payload.area.name, "West-Ost"); t.eq(#r.payload.area.tracks, 4)
    t.eq(r.payload.area.tracks[1].id, "A0001"); t.eq(r.payload.area.tracks[1].direction, "Ostbahnhof")
    t.eq(r.payload.area.tracks[4].direction, "Westbahnhof")
    t.eq(ask({ kind = "verzeichnis_gleise", area = "B9999" }).status, "abgelehnt")
    t.eq(ask({ kind = "verzeichnis_gleise", area = 7 }).status, "abgelehnt")
    t.eq(ask({ kind = "verzeichnis_gleise" }).status, "abgelehnt")
  end },
  { "Antworten bleiben unter der Funkgrenze: 30 Bereiche, 40 Gleise", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    local ser = require("core.ser")
    for i = 1, 30 do netz.add_area({ name = "Langer Bereichsname Nr " .. i, ends = { "Sehr langer Anschlussname Nord", "Sehr langer Anschlussname Sued" }, count = 1 }) end
    t.ok(#ser.encode(ask({ kind = "verzeichnis" }).payload) < 5000, "Bereiche")
    local a = netz.add_area({ name = "Gross", ends = { "Sehr langer Anschlussname Nord", "Sehr langer Anschlussname Sued" }, count = 40 })
    for i = 1, 40 do netz.set_track("A" .. string.format("%04d", 30 + i), { name = "Gleis mit langem Namen Nummer " .. i }) end
    t.ok(#ser.encode(ask({ kind = "verzeichnis_gleise", area = a }).payload) < 5500, "Gleise")
  end },
  { "Abfrage 'node_anfordern': Kennung, Name, Label; wiederholbar; Fehler werden begruendet abgelehnt", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 2 })
    local r = ask({ kind = "node_anfordern", claim = "claim-aaaa-0001", role = "signal", area = a, tracks = { "A0001", "A0002" } })
    t.eq(r.status, "ok")
    t.eq(r.payload.node.id, "N0001"); t.eq(r.payload.node.name, "Signal West-Ost N0001"); t.eq(r.payload.node.label, "N0001 | SIG | B0001")
    local again = ask({ kind = "node_anfordern", claim = "claim-aaaa-0001", role = "signal", area = a, tracks = { "A0001" } })
    t.eq(again.payload.node.id, "N0001")
    local bad = ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "signal", area = a, tracks = { "A0099" } })
    t.eq(bad.status, "abgelehnt"); t.contains(bad.payload.grund, "gehoert nicht")
    t.eq(ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "signal", area = a, tracks = "A0001" }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern" }).status, "abgelehnt")
    t.eq(#netz.nodes(), 1, "abgelehnte Anforderungen hinterlassen nichts")
  end },
  { "Meldet sich die angeforderte Node im Betrieb, wird die Reservierung aktiv", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 2 })
    ask({ kind = "node_anfordern", claim = "claim-aaaa-0001", role = "signal", area = a, tracks = { "A0001" } })
    t.eq(netz.node("N0001").state, "reserviert")
    h.add_node({ id = "N0001", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Gleis 1", signals = { "Sig_1" } } } })
    h.step(12)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Seite Bereiche: anlegen mit Vorlage, aendern, Fehlertext bei falscher Eingabe, loeschen nur nach zweitem Druck", function()
    local h, z = network()
    local netz = z.node.roles.zentrale.netz
    local v = H.open_page(z, "bereiche")
    t.ok(z.has(v, "Noch kein Bereich"), z.text(v))
    z.tap(v, "act:neu")
    z.type(v, "name", "West-Ost")
    z.type(v, "ende1", "Westbahnhof")
    z.type(v, "ende2", "Ostbahnhof")
    z.tap(v, "act:f_weiter")
    z.tap(v, "act:f_speichern")
    t.eq(#netz.areas(), 1, v.hint .. "\n" .. z.text(v))
    t.eq(netz.area("B0001").name, "West-Ost")
    t.eq(#netz.area("B0001").tracks, 2, "Standard: zwei Gleise")
    t.ok(z.has(v, "West-Ost"), z.text(v))
    t.ok(z.has(v, "(B0001)"), "die Kennung steht in der Liste: " .. z.text(v))
    -- falsche Eingabe: Hinweis, nichts angelegt
    z.tap(v, "act:neu")
    z.type(v, "name", "West-Ost")
    z.type(v, "ende1", "A"); z.type(v, "ende2", "B")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibt es schon")
    t.eq(#netz.areas(), 1)
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- aendern
    z.tap(v, "act:bearbeiten")
    z.type(v, "name", "Nord")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.ok(netz.area("B0001").name:find("Nord"), netz.area("B0001").name)
    -- loeschen: erster Druck warnt, zweiter loescht
    z.tap(v, "act:loeschen")
    t.contains(v.hint, "Nochmal druecken")
    t.eq(#netz.areas(), 1)
    z.tap(v, "act:loeschen")
    t.eq(#netz.areas(), 0)
  end },
  { "Seite Gleise: Gleis ergaenzen, umbenennen, Richtung (Gross-/Kleinschreibung egal), benutzte Gleise nicht loeschen", function()
    local h, z = network()
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })
    local v = H.open_page(z, "gleise")
    t.ok(z.has(v, "West-Ost / Gleis 1"), z.text(v))
    z.tap(v, "act:neu")
    z.type(v, "bereich", "west-ost")
    z.type(v, "name", "Ueberholgleis")
    z.type(v, "richtung", "ostbahnhof")
    z.tap(v, "act:f_speichern")
    t.eq(#netz.area(a).tracks, 3, v.hint)
    t.eq(netz.track("A0003").direction, "Ostbahnhof", "kanonische Schreibweise")
    -- unbekannter Bereich
    z.tap(v, "act:neu")
    z.type(v, "bereich", "Nirgendwo")
    z.type(v, "name", "X")
    z.tap(v, "act:f_speichern")
    t.contains(v.hint, "gibt es nicht")
    z.tap(v, "act:f_zurueck")
    -- ein benutztes Gleis laesst sich nicht loeschen
    netz.claim_node({ claim = "claim-ok-0001", role = "signal", area = a, tracks = { "A0001" } })
    z.tap(v, "act:loeschen"); z.tap(v, "act:loeschen")
    t.contains(v.hint, "N0001")
    t.ok(netz.track("A0001"))
  end },
  { "Seite Netz: reservierte Kennung ohne Meldung wird gezeigt und nach zweitem Druck verworfen", function()
    local h, z = network()
    local netz = z.node.roles.zentrale.netz
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 1 })
    netz.claim_node({ claim = "claim-ok-0001", role = "signal", area = a, tracks = { "A0001" } })
    local v = H.open_page(z, "netz")
    t.ok(z.has(v, "N0001 Signal West-Ost"), z.text(v))
    t.ok(z.has(v, "RESERVIERT"), z.text(v))
    -- die reservierte Zeile waehlen (nach dem laufenden Node strecke)
    z.key(v, "down")
    z.tap(v, "act:stilllegen")
    t.contains(v.hint, "Nochmal druecken")
    t.eq(netz.node("N0001").state, "reserviert")
    z.tap(v, "act:stilllegen")
    t.eq(netz.node("N0001").state, "verworfen")
  end },
}
