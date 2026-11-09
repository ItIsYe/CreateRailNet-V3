--[[
Purpose: Node-Verzeichnis in der Leitstelle: Antworten auf Abfragen neuer Computer (Node anfordern, Bahnhoefe seitenweise), die entfallenen Abfragen (Bereiche, Gleise, Knoten) werden abgelehnt, Meldung einer angeforderten Node im Betrieb, und die Seite Netz mit reservierten Kennungen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function network()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local s = h.add_node({ id = "strecke", roles = { "bahnhof" }, central = "hauptstelle", tracks = { { name = "Nord", station_name = "Nord Bahnhof" } } })
  h.step(3)
  local replies = {}
  local real = z.node.reply
  z.node.reply = function(m, status, payload)
    replies[#replies + 1] = { status = status, payload = payload, kind = m.payload.kind }
    return real(m, status, payload)
  end
  local function ask(payload)
    local before = #replies
    local m = s.node.factory.make("abfrage", "hauptstelle", payload)
    z.node.roles.zentrale.on_message(m, "ok")
    for i = #replies, before + 1, -1 do
      if replies[i].kind == payload.kind then return replies[i] end
    end
    return replies[#replies]
  end
  return h, z, s, ask
end

return {
  { "Abfrage 'bahnhoefe_liste': die Bahnhoefe des Netzes seitenweise (20 je Antwort), Gruppen statt ihrer Gleise, Unsinn als Cursor wird ignoriert", function()
    local h, z, s, ask = network()
    local zentrale = z.node.roles.zentrale
    local one = ask({ kind = "bahnhoefe_liste" })
    t.eq(one.status, "ok")
    t.eq(#one.payload.stations, 1); t.eq(one.payload.stations[1].name, "Nord Bahnhof")
    -- ein Bahnhof mit mehreren Gleisen erscheint mit seinem Namen, nicht mit dem Gleis
    t.eq(zentrale.stations.set("Nord Haupt", { "Nord Bahnhof", "Nord 2" }), true)
    local grouped = ask({ kind = "bahnhoefe_liste" })
    t.eq(#grouped.payload.stations, 1); t.eq(grouped.payload.stations[1].name, "Nord Haupt")
    for i = 1, 21 do zentrale.stations.set("Bahnhof " .. i, { "Gleis " .. i }) end
    local first = ask({ kind = "bahnhoefe_liste" })
    t.eq(first.status, "ok")
    t.eq(#first.payload.stations, 20); t.eq(first.payload.more, true)
    t.eq(first.payload.stations[1].name, "Bahnhof 1"); t.eq(first.payload.stations[2].name, "Bahnhof 10")
    local second = ask({ kind = "bahnhoefe_liste", after = first.payload.stations[20].name })
    t.eq(#second.payload.stations, 2); t.eq(second.payload.more, nil)
    t.eq(second.payload.stations[2].name, "Nord Haupt")
    t.eq(ask({ kind = "bahnhoefe_liste", after = 42 }).payload.stations[1].name, "Bahnhof 1")
    t.eq(first.payload.revision, zentrale.netz.revision())
    t.eq(ask({ kind = "betriebsstellen_liste" }).status, "abgelehnt", "die alte Abfrage gibt es nicht mehr")
  end },
  { "Antworten bleiben unter der Funkgrenze: 300 Bahnhoefe mit langen Namen kommen seitenweise vollstaendig an", function()
    local h, z, s, ask = network()
    local zentrale = z.node.roles.zentrale
    local ser = require("core.ser")
    for i = 1, 299 do zentrale.stations.set(string.format("Langer Name des Bahnhofs Nr %03d", i), { "G" .. i }) end
    local got, after = 0, nil
    for _ = 1, 40 do
      local r = ask({ kind = "bahnhoefe_liste", after = after })
      t.eq(r.status, "ok")
      t.ok(#ser.encode(r.payload) < 5000, "Seite zu gross")
      got = got + #r.payload.stations
      if not r.payload.more then break end
      after = r.payload.stations[#r.payload.stations].name
    end
    t.eq(got, 300, "299 Gruppen und der gemeldete Bahnhof")
  end },
  { "Abfrage 'node_anfordern': Kennung, Name, Label; wiederholbar; Fehler werden begruendet abgelehnt", function()
    local h, z, s, ask = network()
    local netz = z.node.roles.zentrale.netz
    local r = ask({ kind = "node_anfordern", claim = "claim-aaaa-0001", role = "bahnhof", roles = { "bahnhof" } })
    t.eq(r.status, "ok")
    t.eq(r.payload.node.id, "N0001"); t.eq(r.payload.node.name, "Bahnhof N0001"); t.eq(r.payload.node.label, "N0001 | BHF")
    local again = ask({ kind = "node_anfordern", claim = "claim-aaaa-0001", role = "bahnhof", legacy = "alt" })
    t.eq(again.payload.node.id, "N0001")
    local bad = ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "anmeldung", station = "Gibtsnicht" })
    t.eq(bad.status, "abgelehnt"); t.contains(bad.payload.grund, "kennt die Leitstelle nicht")
    local none = ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "anmeldung" })
    t.eq(none.status, "abgelehnt"); t.contains(none.payload.grund, "Bahnhof")
    local good = ask({ kind = "node_anfordern", claim = "claim-aaaa-0003", role = "anmeldung", station = "Nord Bahnhof" })
    t.eq(good.status, "ok"); t.eq(good.payload.node.id, "N0002"); t.eq(good.payload.node.name, "Anmeldung Nord Bahnhof N0002"); t.eq(good.payload.node.label, "N0002 | ANM")
    t.eq(netz.node("N0002").station, "Nord Bahnhof")
    t.eq(ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "depot", roles = "alle" }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "depot", station = 5 }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "depot", legacy = 5 }).status, "abgelehnt")
    t.eq(ask({ kind = "node_anfordern", claim = "claim-aaaa-0002", role = "signal" }).status, "abgelehnt", "die Rolle signal gibt es nicht mehr")
    t.eq(ask({ kind = "node_anfordern" }).status, "abgelehnt")
    t.eq(#netz.nodes(), 2, "abgelehnte Anforderungen hinterlassen nichts")
  end },
  { "Entfallene Abfragen (Bereiche, Gleise, Knoten, Bereich anlegen, Gleis aendern) werden als unbekannt abgelehnt", function()
    local h, z, s, ask = network()
    for _, kind in ipairs({ "verzeichnis", "verzeichnis_gleise", "knoten_liste", "knoten_teil", "bereich_anlegen", "gleis_aendern" }) do
      local r = ask({ kind = kind, area = "B0001" })
      t.eq(r.status, "abgelehnt", kind)
      t.contains(r.payload.grund, "Unbekannte")
    end
  end },
  { "Seite Netz: reservierte Kennung ohne Meldung wird gezeigt und nach zweitem Druck verworfen", function()
    local h, z = network()
    local netz = z.node.roles.zentrale.netz
    netz.claim_node({ claim = "claim-ok-0001", role = "depot" })
    local v = H.open_page(z, "netz")
    t.ok(z.has(v, "N0001 Bahnhof N0001"), z.text(v))
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
