--[[
Purpose: Node-Seite des Netzverzeichnisses (src/app/node.lua): ein Computer ohne Einrichtung holt Bereiche (auch ueber mehrere Seiten), die Gleise eines Bereichs und seine Node-Kennung von der Leitstelle; unbeglaubigte, falsch geformte oder ausbleibende Antworten fuehren zu klaren Fehlern; das Computerlabel wird gesetzt.
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
  { "Bereiche holen: Name, Anschluesse, Gleiszahl; mehr als eine Seite wird zusammengesetzt", function()
    local h, z, blank, netz = network()
    for i = 1, 35 do netz.add_area({ name = "Bereich " .. i, ends = { "West", "Ost" }, count = 3 }) end
    blank.node.directory_areas("hauptstelle")
    t.eq(blank.node.directory_status().kind, "wait")
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(#st.areas, 35, "beide Seiten")
    t.eq(st.areas[1].id, "B0001"); t.eq(st.areas[35].id, "B0035")
    t.eq(st.areas[1].tracks, 3); t.eq(st.areas[1].ends[2], "Ost")
  end },
  { "Gleise eines Bereichs holen", function()
    local h, z, blank, netz = network()
    local a = netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 })
    blank.node.directory_tracks("hauptstelle", a)
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.area.name, "West-Ost"); t.eq(#st.area.tracks, 4)
    t.eq(st.area.tracks[1].id, "A0001"); t.eq(st.area.tracks[1].direction, "Ostbahnhof"); t.eq(st.area.tracks[4].direction, "Westbahnhof")
    blank.node.directory_tracks("hauptstelle", "B9999")
    st = settle(h, blank)
    t.eq(st.kind, "halt"); t.contains(st.text, "Abgelehnt")
  end },
  { "Kennung anfordern: Node-Kennung, Name und Label; dieselbe Anforderung liefert dieselbe Kennung", function()
    local h, z, blank, netz = network()
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 2 })
    local claim = blank.node.new_claim()
    t.ok(#claim >= 8 and #claim <= 64 and not claim:find("[^%w%-_]"), claim)
    blank.node.directory_claim("hauptstelle", claim, "signal", a, { "A0001", "A0002" })
    local st = settle(h, blank)
    t.eq(st.kind, "ok", st.text)
    t.eq(st.node.id, "N0001"); t.eq(st.node.name, "Signal West-Ost N0001"); t.eq(st.node.label, "N0001 | SIG | B0001")
    blank.node.directory_claim("hauptstelle", claim, "signal", a, { "A0001" })
    st = settle(h, blank)
    t.eq(st.node.id, "N0001", "kein zweiter Eintrag")
    t.eq(#netz.nodes(), 1)
    local other = blank.node.new_claim()
    t.ok(other ~= claim, "jede neue Anforderung hat eine eigene Kennung")
  end },
  { "Leitstelle antwortet nicht: nach der Frist ein klarer Hinweis", function()
    local h, z, blank = network()
    blank.node.directory_areas("gibt-es-nicht")
    local st = settle(h, blank, 12)
    t.eq(st.kind, "halt"); t.contains(st.text, "antwortet nicht")
    -- eine spaete Antwort aendert danach nichts mehr
    t.eq(blank.node.dir_req, nil)
  end },
  { "Falsch geformte oder erfundene Antworten werden nicht uebernommen", function()
    local h, z, blank, netz = network()
    local zentrale = z.node.roles.zentrale
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 1 })
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
    local function areas() blank.node.directory_areas("hauptstelle") end
    local function tracks() blank.node.directory_tracks("hauptstelle", a) end
    local function claim() blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "signal", a, { "A0001" }) end
    bad(areas, { areas = "viel" }, "Bereiche keine Liste")
    bad(areas, { areas = { { id = "../x", name = "A", ends = { "W", "O" }, tracks = 1 } } }, "Kennung")
    bad(areas, { areas = { { id = "B0001", name = "A;B", ends = { "W", "O" }, tracks = 1 } } }, "Name mit Sonderzeichen")
    bad(areas, { areas = { { id = "B0001", name = "A", ends = { "W" }, tracks = 1 } } }, "Anschluss fehlt")
    bad(areas, { areas = { { id = "B0001", name = "A", ends = { "W", "O" }, tracks = 99 } } }, "zu viele Gleise")
    bad(tracks, { area = { id = "B0001", name = "A", ends = { "W", "O" }, tracks = { { id = "A0001", name = "G", direction = "Nord" } } } }, "Richtung ohne Bezug")
    bad(tracks, { area = { id = "B0001", name = "A", ends = { "W", "O" }, tracks = { { id = "gleis1", name = "G", direction = "beide" } } } }, "Gleiskennung")
    bad(claim, { node = { id = "N0001", name = "x", label = "bad\nlabel" } }, "Label mit Zeilenumbruch")
    bad(claim, { node = { id = "root", name = "x", label = "N0001 | SIG | B0001" } }, "Kennung")
    bad(claim, { node = "N0001" }, "kein Eintrag")
  end },
  { "Eine abgelehnte Anforderung zeigt die Begruendung der Leitstelle", function()
    local h, z, blank, netz = network()
    local a = netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 1 })
    blank.node.directory_claim("hauptstelle", blank.node.new_claim(), "signal", a, { "A0099" })
    local st = settle(h, blank)
    t.eq(st.kind, "halt"); t.contains(st.text, "gehoert nicht")
  end },
  { "Ein schon eingerichteter Computer fragt nicht ueber die vorlaeufige Verbindung", function()
    local h, z, blank, netz = network()
    local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = { { name = "Nord", signals = { "Sig_N" } } } })
    s.node.directory_areas("hauptstelle")
    t.eq(s.node.directory_status().kind, "halt"); t.contains(s.node.directory_status().text, "schon eingerichtet")
  end },
  { "Ueber einen Funkweg mit Verlust: nach erneutem Versuch kommt die Antwort", function()
    local h, z, blank, netz = network({ bus = { seed = 3, drop = 0.5 } })
    netz.add_area({ name = "West-Ost", ends = { "West", "Ost" }, count = 2 })
    local st
    for attempt = 1, 8 do
      blank.node.directory_areas("hauptstelle")
      st = settle(h, blank, 9)
      if st.kind == "ok" then break end
    end
    t.eq(st.kind, "ok", "irgendwann klappt es; bis dahin steht ein Hinweis, kein Absturz")
  end },
  { "Computerlabel: wird ueber die Umgebung gesetzt, ein Fehler dort bleibt folgenlos", function()
    local h, z, blank = network()
    t.eq(blank.node.set_label("N0001 | SIG | B0001"), true)
    t.eq(blank.label, "N0001 | SIG | B0001")
    local real = blank.env.set_label
    blank.env.set_label = function() error("kein Label moeglich") end
    t.eq(blank.node.set_label("N0002"), false)
    blank.env.set_label = real
    t.eq(blank.node.set_label(nil), false)
  end },
}
