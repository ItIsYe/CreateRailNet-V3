--[[
Purpose: Einrichtung einer Knoten-Node ueber das Netzverzeichnis (Konzept 7, 12.1): Knoten waehlen, Uebersetzung pruefen, Kennung anfordern, Geraete den Einfahrten (Signal, Beobachter) und Ausfahrten (Beobachter) zuordnen, pruefen und aktivieren. Unbestaetigtes wird nicht uebernommen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

local function setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Kreuzung", ends = { "Nord", "Sued" }, count = 4 })
  local k = assert(netz.add_junction({ name = "Hauptknoten" }))
  assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
  assert(netz.add_route(k, "A0001", "A0003", true)); assert(netz.add_route(k, "A0004", "A0002", true))
  assert(netz.add_conflict(k, "F0001", "F0002", true))
  if opts.unconfirmed then assert(netz.add_route(k, "A0002", "A0004")) end
  local d = h.add_blank({ id = "neu" })
  for i = 1, 2 do d.world.add_signal("Create_Signal_" .. i) end
  for i = 1, 4 do d.world.add_observer("Create_TrainObserver_" .. i) end
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v, netz, k
end

local function screen(d) return d.node.setup.session().screen end

local function to_choice(h, d, v)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", "Knotenpunkt"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

local function to_review(h, d, v)
  to_choice(h, d, v)
  d.tap(v, "sel:knoten_wahl:1")
  h.step(5); d.node.render()
  d.tap(v, "act:weiter")
end

local function to_devices(h, d, v)
  to_review(h, d, v)
  d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

return {
  { "Knoten-Node: waehlen, uebernehmen, Geraete zuordnen, pruefen, aktivieren", function()
    local h, z, d, v, netz = setup()
    to_choice(h, d, v)
    t.eq(screen(d), "2.knoten", d.text(v))
    t.contains(d.text(v), "Hauptknoten")
    d.tap(v, "sel:knoten_wahl:1")
    h.step(5); d.node.render()
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.k.pruefen", d.text(v))
    t.contains(d.text(v), "2 Anschluesse: Ost, West")
    t.contains(d.text(v), "2 Verbindungen")
    t.contains(d.text(v), "1 Konflikte")
    t.contains(d.text(v), "2 Einfahrten")
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "3.geraete", d.text(v))
    t.eq(netz.node("N0001").role, "knoten"); t.eq(netz.node("N0001").junction, "K0001"); t.eq(#netz.node("N0001").tracks, 4)
    -- Geraete waehlen
    d.tap_row(v, "geraete", "Create_Signal_1"); d.tap_row(v, "geraete", "Create_Signal_2")
    for i = 1, 4 do d.tap_row(v, "geraete", "Create_TrainObserver_" .. i) end
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.contains(d.text(v), "West Gleis 1"); t.contains(d.text(v), "Ost Gleis 4")
    -- jedes Gleis: Einfahrten Signal + Beobachter, Ausfahrten Beobachter
    local wiz = d.node.setup.session().wiz
    local order = wiz.tracks()
    local signal_no, observer_no = 0, 0
    for i, tid in ipairs(order) do
      d.tap(v, "sel:gleise:" .. i); d.tap(v, "act:bearbeiten")
      local track = wiz.config.tracks[tid]
      if track.junction.role == "ein" then
        t.eq(screen(d), "4.g.signale", track.name .. " " .. d.text(v))
        signal_no = signal_no + 1
        d.tap_row(v, "signale", "Create_Signal_" .. signal_no); d.tap(v, "act:weiter")
      end
      t.eq(screen(d), "4.g.beobachter", d.text(v))
      observer_no = observer_no + 1
      d.tap_row(v, "beobachter", "Create_TrainObserver_" .. observer_no); d.tap(v, "act:weiter")
      t.eq(screen(d), "4.gleise", d.text(v))
    end
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.test", d.text(v))
    d.tap(v, "act:alle_pruefen")
    d.tap(v, "act:alle_starten")
    t.contains(v.hint, "0 Fehler")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "6.fertig", d.text(v))
    d.tap(v, "act:speichern")
    local config = d.node.config
    t.eq(config.status, "aktiv", d.text(v))
    t.eq(config.node.id, "N0001"); t.eq(config.node.label, "N0001 | KNO | K0001"); t.eq(config.node.junction, "K0001")
    t.eq(#config.junction.moves, 2); t.eq(#config.junction.conflicts, 1)
    t.eq(d.label, "N0001 | KNO | K0001")
    t.ok(d.node.roles.knoten, "die Knotenrolle laeuft")
    h.step(30)
    t.eq(netz.node("N0001").state, "aktiv")
  end },
  { "Unbestaetigte Fahrwege: der Knoten wird markiert und nicht uebernommen", function()
    local h, z, d, v, netz, k = setup({ unconfirmed = true })
    to_choice(h, d, v)
    t.contains(d.text(v), "UNBEST")
    d.tap(v, "sel:knoten_wahl:1")
    h.step(5); d.node.render()
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.knoten")
    t.contains(v.hint, "unbestaetigte")
    -- in der Leitstelle bestaetigen, neu laden: jetzt geht es
    assert(netz.remove_route(k, "F0003"))
    d.tap(v, "act:knoten_laden"); h.step(5); d.node.render()
    d.tap(v, "sel:knoten_wahl:1"); h.step(5); d.node.render()
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.k.pruefen", d.text(v))
  end },
  { "Ohne Auswahl geht es nicht weiter; leeres Netz zeigt einen Hinweis", function()
    local h, z, d, v, netz, k = setup()
    assert(netz.remove_junction(k))
    to_choice(h, d, v)
    t.contains(d.text(v), "noch keinen Knoten")
    d.tap(v, "act:weiter")
    t.contains(v.hint, "Bitte einen Knoten waehlen")
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
  end },
  { "Ein Gleis, das Ein- und Ausfahrt zugleich ist, wird erklaert und nicht uebernommen", function()
    local h, z, d, v, netz, k = setup()
    assert(netz.add_route(k, "A0003", "A0001", true))          -- A0001 wird auch Ziel, A0003 auch Start
    to_choice(h, d, v)
    d.tap(v, "sel:knoten_wahl:1")
    h.step(5); d.node.render()
    d.tap(v, "act:weiter")
    t.contains(v.hint, "Ein- und Ausfahrt")
    t.eq(screen(d), "2.knoten")
  end },
  { "Nach einem Neustart beginnt die Einrichtung des Knotens von vorn (kein Entwurf); die Kennung N0001 bleibt, die Gleise kommen wieder aus dem Verzeichnis", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap_row(v, "geraete", "Create_Signal_1")
    t.ok(not d.fs.exists("/crn_data/config.lua"), "nichts als Entwurf gespeichert")
    d.restart(); h.step(1)
    local v2 = d.view(); v2.set_page("einrichtung")
    t.eq(d.node.config, nil)
    to_devices(h, d, v2)
    t.eq(screen(d), "3.geraete", d.text(v2))
    t.ok(not d.has(v2, "[x] Create_Signal_1"), "die Auswahl beginnt leer: " .. d.text(v2))
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001")
    t.eq(d.node.setup.session().wiz.config.node.junction, "K0001")
    t.eq(#netz.nodes(), 1, "keine zweite Kennung")
  end },
  { "Keine Gleise lokal anlegen: im Verzeichnis-Weg gibt es nur 'Zuordnen'", function()
    local h, z, d, v, netz = setup()
    to_devices(h, d, v)
    d.tap_row(v, "geraete", "Create_Signal_1")
    d.tap_row(v, "geraete", "Create_TrainObserver_1")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "4.gleise", d.text(v))
    t.ok(not d.has(v, "Kopieren") and not d.has(v, "Entfernen"), d.text(v))
    t.ok(d.has(v, "Zuordnen"), d.text(v))
  end },
  { "Leitstelle antwortet nicht beim Laden des Knotens: Meldung statt Absturz", function()
    local h, z, d, v, netz = setup()
    to_choice(h, d, v)
    z.node.handle = function() end
    d.tap(v, "sel:knoten_wahl:1")
    h.step(12); d.node.render()
    t.contains(d.text(v), "antwortet nicht")
    d.tap(v, "act:weiter")
    t.contains(v.hint, "geladen")
  end },
  { "Unsinnige Antworten der Leitstelle werden abgewiesen (Knotenliste, Anschluesse, Fahrwege, Konflikte)", function()
    local function try(bad)
      local h, z, d, v, netz = setup()
      local real = z.node.reply
      z.node.reply = function(m, status, payload)
        if m.payload and bad(m.payload.kind, m.payload.part, payload) then return real(m, "ok", bad(m.payload.kind, m.payload.part, payload)) end
        return real(m, status, payload)
      end
      to_choice(h, d, v)
      pcall(d.tap, v, "sel:knoten_wahl:1")
      h.step(8); d.node.render()
      return d, v
    end
    local d, v = try(function(kind) if kind == "knoten_liste" then return { junctions = { { id = "X", name = "Gut", connections = 2, open = 0 } } } end end)
    t.contains(d.text(v), "Unerwartete Antwort"); t.eq(screen(d), "2.knoten")
    d, v = try(function(kind, part) if kind == "knoten_teil" and part == "anschluesse" then return { part = { id = "K0001", name = "Boese\n", rev = 1, connections = {} } } end end)
    t.contains(d.text(v), "Unerwartete Antwort")
    d, v = try(function(kind, part) if kind == "knoten_teil" and part == "fahrwege" then return { part = { id = "K0001", routes = { { id = "F0001", from = 5, to = "A0001" } } } } end end)
    t.contains(d.text(v), "Unerwartete Antwort")
    d, v = try(function(kind, part) if kind == "knoten_teil" and part == "konflikte" then return { part = { id = "K0001", conflicts = "nein" } } end end)
    t.contains(d.text(v), "Unerwartete Antwort")
    d, v = try(function(kind, part) if kind == "knoten_teil" and part == "konflikte" then return { part = { id = "K0001", conflicts = { { a = "F0001", b = 7 } } } } end end)
    t.contains(d.text(v), "Unerwartete Antwort")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.knoten", "mit unvollstaendigen Daten geht es nicht weiter")
  end },
}
