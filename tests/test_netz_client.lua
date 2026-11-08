--[[
Purpose: Node-Seite des Netzverzeichnisses (src/app/node.lua): ein Computer ohne Einrichtung holt Betriebsstellen (auch ueber mehrere Seiten) und seine Node-Kennung von der Leitstelle; unbeglaubigte, falsch geformte oder ausbleibende Antworten fuehren zu klaren Fehlern; das Computerlabel wird gesetzt.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function network(opts)
  opts = opts or {}
  local h = H.new(opts.bus and { bus = opts.bus } or nil)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local blank = h.add_blank({ id = "neu" })
  h.step(1)
  local netz = z.node.roles.zentrale.netz
  return h, z, blank, netz
end

-- laeuft, bis der Zustand nicht mehr "wait" ist
local function settle(h, blank, max)
  for _ = 1, max or 12 do
    local st = blank.node.directory_status()
    if st and st.kind ~= "wait" then return st end
    h.step(1)
  end
  return blank.node.directory_status()
end

return {
  { "Betriebsstellen holen: Name, Art; mehr als eine Seite wird zusammengesetzt", function()
    local h, z, blank, netz = network()
    for i = 1, 35 do netz.add_station({ name = "Bahnhof " .. i, kind = (i % 2 == 0) and "depot" or "personenbahnhof" }) end
    blank.node.directory_stations("hauptstelle")
    t.eq(blank.node.directory_status().kind, "wait")
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.stations, 35, "beide Seiten")
    t.eq(st.stations[1].id, "BF0001"); t.eq(st.stations[35].id, "BF0035")
    t.eq(st.stations[1].name, "Bahnhof 1"); t.eq(st.stations[2].kind, "depot")
  end },
  { "Kennung anfordern: Node-Kennung, Name und Label; dieselbe Anforderung liefert dieselbe Kennung", function()
    local h, z, blank, netz = network()
    local claim = blank.node.new_claim()
    t.ok(#claim >= 8 and #claim <= 64 and not claim:find("[^%w%-_]"), claim)
    blank.node.directory_claim("hauptstelle", claim, "passagierbahnhof", nil, { roles = { "passagierbahnhof" } })
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.node.id, "N0001"); t.eq(st.node.name, "Personenbahnhof N0001"); t.eq(st.node.label, "N0001 | PBF")
    blank.node.directory_claim("hauptstelle", claim, "passagierbahnhof", nil, { roles = { "passagierbahnhof" } })
    st = settle(h, blank)
    t.eq(st.node.id, "N0001", "kein zweiter Eintrag")
    t.eq(#netz.nodes(), 1)
    local other = blank.node.new_claim()
    t.ok(other ~= claim, "jede neue Anforderung hat eine eigene Kennung")
  end },
  { "Anmeldung: die Kennung gehoert zu einer Betriebsstelle", function()
    local h, z, blank, netz = network()
    local bf = netz.add_station({ name = "Hauptbahnhof", kind = "personenbahnhof" })
    blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "anmeldung", nil, { station = bf })
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.node.label, "N0001 | ANM | " .. bf)
  end },
  { "Leitstelle antwortet nicht: nach der Frist ein klarer Hinweis", function()
    local h, z, blank = network()
    blank.node.directory_stations("gibt-es-nicht")
    local st = settle(h, blank, 12)
    t.eq(st.kind, "halt"); t.contains(st.text, "antwortet nicht")
    -- eine spaete Antwort aendert danach nichts mehr
    t.eq(blank.node.dir_req, nil)
  end },
  { "Falsch geformte oder erfundene Antworten werden nicht uebernommen", function()
    local h, z, blank, netz = network()
    local zentrale = z.node.roles.zentrale
    local function answer_with(payload)
      zentrale.handle_directory = function(m) z.node.reply(m, "ok", payload) end
    end
    local function bad(call, payload, text)
      answer_with(payload)
      call()
      local st = settle(h, blank)
      t.eq(st.kind, "halt", text)
      t.contains(st.text, "Unerwartete Antwort", text)
    end
    local function stations() blank.node.directory_stations("hauptstelle") end
    local function claim() blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "depot", nil, { roles = { "depot" } }) end
    bad(stations, { stations = "viel" }, "Betriebsstellen keine Liste")
    bad(stations, { stations = { { id = "../x", name = "A", kind = "depot" } } }, "Kennung")
    bad(stations, { stations = { { id = "BF0001", name = "A;B", kind = "depot" } } }, "Name mit Sonderzeichen")
    bad(stations, { stations = { { id = "BF0001", name = "A", kind = "hafen" } } }, "unbekannte Art")
    bad(claim, { node = { id = "N0001", name = "x", label = "bad\nlabel" } }, "Label mit Zeilenumbruch")
    bad(claim, { node = { id = "root", name = "x", label = "N0001 | DEP" } }, "Kennung")
    bad(claim, { node = "N0001" }, "kein Eintrag")
  end },
  { "Eine abgelehnte Anforderung zeigt die Begruendung der Leitstelle", function()
    local h, z, blank, netz = network()
    blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "anmeldung", nil, { station = "BF0099" })
    local st = settle(h, blank)
    t.eq(st.kind, "halt"); t.contains(st.text, "Betriebsstelle")
  end },
  { "Ein schon eingerichteter Computer fragt ueber seinen eigenen Funk mit seiner Kennung, nicht ueber die vorlaeufige Verbindung", function()
    local h, z, blank, netz = network()
    netz.add_station({ name = "Hauptbahnhof", kind = "personenbahnhof" })
    local s = h.add_node({ id = "strecke", roles = { "passagierbahnhof" }, central = "hauptstelle", tracks = { { name = "Nord", station = "Station_N" } } })
    s.node.directory_stations("hauptstelle")
    local st = settle(h, s)
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.stations, 1)
    t.ok(not s.node.replace_net, "keine vorlaeufige Verbindung aufgebaut")
  end },
  { "Ueber einen Funkweg mit Verlust: nach erneutem Versuch kommt die Antwort", function()
    local h, z, blank, netz = network({ bus = { seed = 3, drop = 0.5 } })
    netz.add_station({ name = "Hauptbahnhof", kind = "personenbahnhof" })
    local st
    for attempt = 1, 8 do
      blank.node.directory_stations("hauptstelle")
      st = settle(h, blank, 9)
      if st.kind == "ok" then break end
    end
    t.eq(st.kind, "ok", "irgendwann klappt es; bis dahin steht ein Hinweis, kein Absturz")
  end },
  { "Computerlabel: wird ueber die Umgebung gesetzt, ein Fehler dort bleibt folgenlos", function()
    local h, z, blank = network()
    t.eq(blank.node.set_label("N0001 | PBF"), true)
    t.eq(blank.label, "N0001 | PBF")
    local real = blank.env.set_label
    blank.env.set_label = function() error("kein Label moeglich") end
    t.eq(blank.node.set_label("N0002"), false)
    blank.env.set_label = real
    t.eq(blank.node.set_label(nil), false)
  end },
}
