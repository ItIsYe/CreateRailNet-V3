--[[
Purpose: Seite Knoten der Leitstelle und die Funkabfragen fuer Nodes (Konzept 7): Knoten anlegen, Anschluesse aus Gleisenden, Fahrwege und Konflikte eintragen, Vorschlaege unbestaetigt, Bestaetigen, Loeschen nach zweitem Druck; Nodes bekommen Liste und Teile (nur Bestaetigtes).
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function network()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Nord", signals = { "Sig_N" } } } })
  h.step(2)
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West", ends = { "a", "b" }, count = 2 })       -- A0001 A0002
  netz.add_area({ name = "Ost", ends = { "c", "d" }, count = 2 })        -- A0003 A0004
  local replies = {}
  local real = z.node.reply
  z.node.reply = function(m, status, payload)
    replies[#replies + 1] = { status = status, payload = payload }
    return real(m, status, payload)
  end
  local function ask(payload)
    z.node.roles.zentrale.on_message(s.node.factory.make("abfrage", "hauptstelle", payload), "ok")
    return replies[#replies]
  end
  return h, z, netz, ask
end

local function add(z, v, fields)
  z.tap(v, "act:neu")
  z.type(v, "knoten", fields.knoten)
  if fields.typ then z.type(v, "typ", fields.typ) end
  if fields.a then z.type(v, "a", fields.a) end
  z.tap(v, "act:f_weiter")
  if fields.b then z.type(v, "b", fields.b) end
  z.tap(v, "act:f_speichern")
end

return {
  { "Seite Knoten: Knoten, Anschluesse, Fahrwege eintragen; Fehlertexte; Vorschlag bleibt unbestaetigt, Bestaetigen gibt frei", function()
    local h, z, netz = network()
    local v = H.open_page(z, "knoten")
    t.ok(z.has(v, "Noch kein Knoten"), z.text(v))
    add(z, v, { knoten = "Hauptknoten" })
    t.eq(#netz.junctions(), 1, v.hint .. z.text(v))
    add(z, v, { knoten = "Hauptknoten", typ = "anschluss", a = "West", b = "West / Gleis 1; West / Gleis 2" })
    add(z, v, { knoten = "Hauptknoten", typ = "anschluss", a = "Ost", b = "A0003; Ost / Gleis 2" })
    t.eq(#netz.junction("K0001").connections, 2, v.hint)
    -- Fehler
    add(z, v, { knoten = "Hauptknoten", typ = "anschluss", a = "Nord", b = "Nirgends / Gleis 1" })
    t.contains(v.hint, "gibt es nicht")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    add(z, v, { knoten = "Gibt es nicht", typ = "fahrweg", a = "West / Gleis 1", b = "Ost / Gleis 1" })
    t.contains(v.hint, "erst mit Was = knoten anlegen")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- Fahrweg von Hand
    add(z, v, { knoten = "hauptknoten", typ = "fahrweg", a = "West / Gleis 1", b = "Ost / Gleis 1" })
    t.eq(#netz.junction("K0001").routes, 1, v.hint)
    t.eq(netz.junction("K0001").routes[1].confirmed, false)
    -- Vorschlag (zwei Anschluesse -> durchgehend) markiert den ersten Eintrag des Knotens
    z.tap(v, "sel:knoten:1")
    z.tap(v, "act:vorschlag")
    t.contains(v.hint, "vorgeschlagen")
    t.ok(#netz.junction("K0001").routes > 1)
    t.ok(netz.junction("K0001").unconfirmed > 0)
    t.eq(#netz.junction_part("K0001", "fahrwege").routes, 0, "unbestaetigt: nichts fuer Nodes")
    z.tap(v, "act:bestaetigen")
    t.contains(v.hint, "bestaetigt")
    t.eq(netz.junction("K0001").unconfirmed, 0)
    t.ok(#netz.junction_part("K0001", "fahrwege").routes > 1)
    -- Eintraege lassen sich nicht aendern, nur loeschen
    z.tap(v, "sel:knoten:2")
    z.tap(v, "act:bearbeiten")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.contains(v.hint, "loeschen und neu anlegen")
    z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    -- Loeschen eines Anschlusses (zweimal tippen)
    z.tap(v, "act:loeschen"); t.contains(v.hint, "Nochmal")
    z.tap(v, "act:loeschen")
    t.eq(#netz.junction("K0001").connections, 1)
  end },
  { "Knoten umbenennen ueber 'Aendern' und ganzen Knoten loeschen", function()
    local h, z, netz = network()
    local v = H.open_page(z, "knoten")
    add(z, v, { knoten = "Alt" })
    z.tap(v, "act:bearbeiten")
    z.type(v, "knoten", "Neu")
    z.tap(v, "act:f_weiter"); z.tap(v, "act:f_speichern")
    t.eq(netz.junction("K0001").name, "Neu", v.hint)
    z.tap(v, "act:loeschen"); z.tap(v, "act:loeschen")
    t.eq(#netz.junctions(), 0)
  end },
  { "Funkabfragen: Liste der Knoten und Teile; unbestaetigtes fehlt; Unsinn wird abgelehnt", function()
    local h, z, netz, ask = network()
    local k = netz.add_junction({ name = "Hauptknoten" })
    netz.add_connection(k, "West", { "A0001", "A0002" }); netz.add_connection(k, "Ost", { "A0003", "A0004" })
    netz.propose_routes(k, "durchgehend")
    local list = ask({ kind = "knoten_liste" })
    t.eq(list.status, "ok"); t.eq(#list.payload.junctions, 1)
    t.eq(list.payload.junctions[1].name, "Hauptknoten"); t.eq(list.payload.junctions[1].open, 4)
    local part = ask({ kind = "knoten_teil", junction = k, part = "anschluesse" })
    t.eq(part.status, "ok"); t.eq(part.payload.part.connections[1].name, "Ost"); t.eq(part.payload.part.connections[1].tracks[1].name, "Gleis 1")
    t.eq(#ask({ kind = "knoten_teil", junction = k, part = "fahrwege" }).payload.part.routes, 0)
    netz.confirm_junction(k)
    t.eq(#ask({ kind = "knoten_teil", junction = k, part = "fahrwege" }).payload.part.routes, 4)
    t.eq(ask({ kind = "knoten_teil", junction = "K9999", part = "fahrwege" }).status, "abgelehnt")
    t.eq(ask({ kind = "knoten_teil", junction = 7, part = "fahrwege" }).status, "abgelehnt")
    t.eq(ask({ kind = "knoten_teil", junction = k, part = "teil" }).status, "abgelehnt")
    t.eq(ask({ kind = "knoten_teil" }).status, "abgelehnt")
  end },
}
