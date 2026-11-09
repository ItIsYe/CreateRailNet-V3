--[[
Purpose: Node-Seite des Netzverzeichnisses (src/app/node.lua): ein Computer ohne Einrichtung holt die Bahnhoefe des Netzes (auch ueber mehrere Seiten) und seine Node-Kennung von der Leitstelle; unbeglaubigte, falsch geformte oder ausbleibende Antworten fuehren zu klaren Fehlern; das Computerlabel wird gesetzt.
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

-- Bahnhoefe, die die Leitstelle kennt (Bahnhoefe mit Gleisen)
local function add_stations(z, count)
  for i = 1, count do z.node.roles.zentrale.stations.set("Bahnhof " .. i, { "Gleis " .. i }) end
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
  { "Bahnhoefe holen: Namen, mehr als eine Seite wird zusammengesetzt", function()
    local h, z, blank, netz = network()
    add_stations(z, 35)
    blank.node.directory_stations("hauptstelle")
    t.eq(blank.node.directory_status().kind, "wait")
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.stations, 35, "beide Seiten")
    t.eq(st.stations[1].name, "Bahnhof 1"); t.eq(st.stations[2].name, "Bahnhof 10"); t.eq(st.stations[35].name, "Bahnhof 9")
    t.contains(st.text, "35")
  end },
  { "Kennung anfordern: Node-Kennung, Name und Label; dieselbe Anforderung liefert dieselbe Kennung", function()
    local h, z, blank, netz = network()
    local claim = blank.node.new_claim()
    t.ok(#claim >= 8 and #claim <= 64 and not claim:find("[^%w%-_]"), claim)
    blank.node.directory_claim("hauptstelle", claim, "bahnhof", nil, { roles = { "bahnhof" } })
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.node.id, "N0001"); t.eq(st.node.name, "Bahnhof N0001"); t.eq(st.node.label, "N0001 | BHF")
    blank.node.directory_claim("hauptstelle", claim, "bahnhof", nil, { roles = { "bahnhof" } })
    st = settle(h, blank)
    t.eq(st.node.id, "N0001", "kein zweiter Eintrag")
    t.eq(#netz.nodes(), 1)
    local other = blank.node.new_claim()
    t.ok(other ~= claim, "jede neue Anforderung hat eine eigene Kennung")
  end },
  { "Anmeldung: die Kennung nennt den Bahnhof (Name und Label der Node)", function()
    local h, z, blank, netz = network()
    add_stations(z, 1)
    blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "anmeldung", nil, { station = "Bahnhof 1" })
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.node.name, "Anmeldung Bahnhof 1 N0001"); t.eq(st.node.label, "N0001 | ANM")
    t.eq(netz.node("N0001").station, "Bahnhof 1")
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
    local function claim() blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "depot", nil, { roles = { "bahnhof" } }) end
    bad(stations, { stations = "viel" }, "Betriebsstellen keine Liste")
    bad(stations, { stations = { "Hauptbahnhof" } }, "Eintrag ist kein Bahnhof")
    bad(stations, { stations = { { name = "Haupt\nbahnhof" } } }, "Name mit Zeilenumbruch")
    bad(stations, { stations = { { name = "" } } }, "leerer Name")
    bad(stations, { stations = { { name = 5 } } }, "Name keine Zeichenkette")
    bad(stations, { stations = { { name = string.rep("x", 41) } } }, "Name zu lang")
    bad(claim, { node = { id = "N0001", name = "x", label = "bad\nlabel" } }, "Label mit Zeilenumbruch")
    bad(claim, { node = { id = "root", name = "x", label = "N0001 | DEP" } }, "Kennung")
    bad(claim, { node = "N0001" }, "kein Eintrag")
  end },
  { "Eine abgelehnte Anforderung zeigt die Begruendung der Leitstelle", function()
    local h, z, blank, netz = network()
    blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "anmeldung", nil, { station = "Gibtsnicht" })
    local st = settle(h, blank)
    t.eq(st.kind, "halt"); t.contains(st.text, "kennt die Leitstelle nicht")
  end },
  { "Ein schon eingerichteter Computer fragt ueber seinen eigenen Funk mit seiner Kennung, nicht ueber die vorlaeufige Verbindung", function()
    local h, z, blank, netz = network()
    add_stations(z, 1)
    local s = h.add_node({ id = "strecke", roles = { "bahnhof" }, central = "hauptstelle", tracks = { { name = "Nord", station = "Station_N" } } })
    s.node.directory_stations("hauptstelle")
    local st = settle(h, s)
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.stations, 1)
    t.ok(not s.node.replace_net, "keine vorlaeufige Verbindung aufgebaut")
  end },
  { "Ueber einen Funkweg mit Verlust: nach erneutem Versuch kommt die Antwort", function()
    local h, z, blank, netz = network({ bus = { seed = 3, drop = 0.5 } })
    add_stations(z, 1)
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
    t.eq(blank.node.set_label("N0001 | BHF"), true)
    t.eq(blank.label, "N0001 | BHF")
    local real = blank.env.set_label
    blank.env.set_label = function() error("kein Label moeglich") end
    t.eq(blank.node.set_label("N0002"), false)
    blank.env.set_label = real
    t.eq(blank.node.set_label(nil), false)
  end },
}
