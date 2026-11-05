--[[
Purpose: Gefuehrte Einrichtung einer Signal-Node ueber die Oberflaeche (Konzept 12.1, 13): Netz waehlen, Bereich waehlen, Gleise uebernehmen (Kennung von der Leitstelle), Signale zuordnen, "Pruefen+Aktivieren" -> die Abschlusspruefung laeuft schrittweise und aktiviert nur bei vollstaendigem Erfolg. Dazu Abbruch, Fehler, Wiederaufnahme, Rueckfall auf die Handeinrichtung und kleiner wie grosser Bildschirm.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

-- Leitstelle mit einem Bereich "West-Ost" (4 Gleise) und ein Computer ohne Einrichtung mit n Signalen
local function setup(opts)
  opts = opts or {}
  local h = H.new(opts.bus and { bus = opts.bus } or nil)
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  if opts.area ~= false then
    netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = opts.tracks or 4 })
  end
  local d = h.add_blank({ id = "neu" })
  for i = 1, opts.signals or 4 do d.world.add_signal("Create_Signal_" .. i) end
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  return h, z, d, v, netz
end

local function screen(d) return d.node.setup.session().screen end

-- bis "Bereich waehlen" (Netz suchen, waehlen, Rolle Signal)
local function to_area(h, d, v)
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
end

local function through_tracks(h, d, v)
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter")            -- Gleise uebernehmen
  d.tap(v, "act:weiter")            -- Kennung anfordern
  h.step(3); d.node.render()
end

local function assign_all(h, d, v, count)
  for _ = 1, count do
    d.tap(v, "act:signal_waehlen")
    d.tap(v, "sel:signal:1")
  end
end

return {
  { "Gefuehrter Ablauf: Bereich, Gleise, vier Signale, pruefen und aktivieren; die Node ist die von der Leitstelle vergebene", function()
    local h, z, d, v, netz = setup()
    to_area(h, d, v)
    t.eq(screen(d), "2.bereich", d.text(v))
    t.ok(d.has(v, "West-Ost"), d.text(v))
    t.ok(d.has(v, "( ) West-Ost"), d.text(v))
    d.tap(v, "sel:bereich:1")
    h.step(3); d.node.render()
    d.tap(v, "act:weiter")
    t.eq(screen(d), "2.gleise", d.text(v))
    t.ok(d.has(v, "[x] Gleis 1"), d.text(v)); t.ok(d.has(v, "Richtung Ostbahnhof"), d.text(v))
    d.tap(v, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "4.zuordnung", d.text(v))
    t.ok(d.has(v, "Gleis 1"), d.text(v))
    t.ok(d.has(v, "Signal fehlt"), d.text(v))
    t.eq(netz.node("N0001").state, "reserviert", "die Leitstelle hat die Kennung vergeben")
    -- Zuordnung: Signal waehlen, erstes freies antippen; die Auswahl springt zum naechsten offenen Gleis
    assign_all(h, d, v, 4)
    t.ok(d.has(v, "Create_Signal_1"), d.text(v)); t.ok(d.has(v, "Create_Signal_4"), d.text(v))
    t.ok(not d.has(v, "Signal fehlt"), d.text(v))
    d.tap(v, "act:weiter")
    t.eq(screen(d), "5.pruefen", d.text(v))
    t.ok(d.has(v, "N0001"), d.text(v)); t.ok(d.has(v, "Rotsperre"), d.text(v)); t.ok(d.has(v, "vorbereitet ist"), "der ganze Text ist lesbar:\n" .. d.text(v))
    d.tap(v, "act:pruefen")
    h.step(1)
    t.eq(d.node.status().text, "Bereit", "nach der Pruefung ist die Node aktiv")
    local config = storelib.new(d.fs).load("/crn_data/config.lua")
    t.eq(config.status, "aktiv"); t.eq(config.node.id, "N0001"); t.eq(config.node.label, "N0001 | SIG | B0001")
    t.eq(d.label, "N0001 | SIG | B0001", "das Computerlabel ist gesetzt")
    for i = 1, 4 do t.eq(d.world.devices["Create_Signal_" .. i].state.forced, false, "keine Testsperre bleibt") end
    -- im Betrieb meldet sie sich bei der Leitstelle unter der vergebenen Kennung
    h.step(15)
    t.eq(netz.node("N0001").state, "aktiv")
    local overview = z.node.roles.zentrale.signal_overview()
    t.eq(#overview, 4)
    t.eq(overview[1].node, "N0001"); t.eq(overview[1].signal.track_name, "Gleis 1")
  end },
  { "Zuordnung: Gleise ohne Signal sperren Weiter mit Begruendung; Loesen; ein Signal nur einmal", function()
    local h, z, d, v = setup({ tracks = 2, signals = 3 })
    to_area(h, d, v)
    through_tracks(h, d, v)
    t.eq(screen(d), "4.zuordnung", d.text(v))
    t.eq(d.area(v, "act:weiter").enabled, false)
    d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1")
    t.eq(d.area(v, "act:weiter").enabled, false, "Gleis 2 hat noch kein Signal")
    d.tap(v, "act:signal_waehlen")
    t.ok(not d.has(v, "Create_Signal_1  "), "ein zugeordnetes Signal wird nicht mehr angeboten:\n" .. d.text(v))
    d.tap(v, "sel:signal:1")
    t.eq(d.area(v, "act:weiter").enabled, true)
    -- Loesen: das Signal des gewaehlten Gleises wird wieder frei
    d.tap(v, "act:signal_loesen")
    t.eq(d.area(v, "act:weiter").enabled, false)
    local wiz = d.node.setup.session().wiz
    t.eq(#wiz.guided_free_signals(), 2)
  end },
  { "Weniger Gleise uebernehmen: nur diese brauchen ein Signal", function()
    local h, z, d, v, netz = setup({ signals = 2 })
    to_area(h, d, v)
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter")
    d.tap(v, "sel:gleise_auswahl:2"); d.tap(v, "sel:gleise_auswahl:3"); d.tap(v, "sel:gleise_auswahl:4")
    t.ok(d.has(v, "[x] Gleis 1"), d.text(v)); t.ok(d.has(v, "[ ] Gleis 2"), d.text(v))
    d.tap(v, "act:weiter"); h.step(3); d.node.render()
    t.eq(screen(d), "4.zuordnung", d.text(v))
    local wiz = d.node.setup.session().wiz
    t.eq(#wiz.guided_rows(), 1)
    t.eq(#netz.node("N0001").tracks, 1)
    d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1")
    d.tap(v, "act:weiter"); d.tap(v, "act:pruefen"); h.step(1)
    t.eq(d.node.status().text, "Bereit")
  end },
  { "Ohne Bereich im Netz: klarer Hinweis, 'Neu laden' und 'Von Hand' (alter Weg) bleiben moeglich", function()
    local h, z, d, v, netz = setup({ area = false })
    to_area(h, d, v)
    t.eq(screen(d), "2.bereich", d.text(v))
    t.ok(d.has(v, "noch keinen Bereich"), d.text(v))
    t.eq(d.area(v, "act:weiter").enabled, false)
    netz.add_area({ name = "Neu", ends = { "A", "B" }, count = 2 })
    d.tap(v, "act:neu_laden"); h.step(3); d.node.render()
    t.ok(d.has(v, "Neu"), d.text(v))
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
    d.tap(v, "act:zurueck")
  end },
  { "'Von Hand' fuehrt auf den alten Weg: Name, dann Geraete wie bisher", function()
    local h, z, d, v = setup()
    to_area(h, d, v)
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name", d.text(v))
    d.type(v, "name", "Strecke Nord")
    d.tap(v, "act:weiter")
    t.eq(screen(d), "3.geraete", d.text(v))
  end },
  { "Die Antwort der Leitstelle wird sofort verarbeitet, nicht erst im naechsten Takt", function()
    local h, z, d, v = setup()
    to_area(h, d, v)
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter")
    d.node.setup.tick = function() end                  -- ohne Takt: nur die Antwort selbst darf weiterschalten
    d.tap(v, "act:weiter")
    h.step(2)
    t.eq(screen(d), "4.zuordnung")
  end },
  { "Stehengebliebene Testsperre (Marke in eigener Datei): beim Start aufgehoben und gemeldet, auch ohne gespeicherte Einrichtung", function()
    local h, z, d, v = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    assign_all(h, d, v, 2)
    t.eq(d.node.config, nil, "es gibt keinen Entwurf")
    -- Absturz mitten in der Testsperre: Marke steht, das Signal ist gesperrt
    storelib.new(d.fs).save("/crn_data/pruefmarke.lua", { device = "signal1", name = "Create_Signal_1", t = 3 })
    d.world.devices["Create_Signal_1"].state.forced = true
    d.restart()
    t.eq(d.world.devices["Create_Signal_1"].state.forced, false, "Testsperre aufgehoben")
    local found = false
    for _, m in ipairs(d.node.messages) do if m.text:find("Testsperre", 1, true) and m.text:find("aufgehoben", 1, true) then found = true end end
    t.ok(found, "Meldung ueber die aufgehobene Testsperre")
    t.ok(not d.fs.exists("/crn_data/pruefmarke.lua"), "Marke erledigt")
    t.eq(d.node.config, nil)
  end },
  { "Leitstelle antwortet nicht: Hinweis statt Haengen, 'Von Hand' geht trotzdem", function()
    local h, z, d, v = setup()
    z.node.roles.zentrale.handle_directory = function() end          -- schweigt
    to_area(h, d, v)
    h.step(10); d.node.render()
    t.ok(d.has(v, "antwortet nicht"), d.text(v))
    d.tap(v, "act:von_hand")
    t.eq(screen(d), "2.name")
  end },
  { "Abgelehnte Anforderung: Begruendung wird gezeigt, Weiter bleibt moeglich (wiederholbar)", function()
    local h, z, d, v, netz = setup()
    to_area(h, d, v)
    d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v, "act:weiter")
    local real = z.node.roles.zentrale.handle_directory
    z.node.roles.zentrale.handle_directory = function(m)
      if m.payload.kind == "node_anfordern" then return z.node.reply(m, "abgelehnt", { grund = "Das Verzeichnis ist gesperrt." }) end
      return real(m)
    end
    d.tap(v, "act:weiter"); h.step(3); d.node.render()
    t.eq(screen(d), "2.gleise", d.text(v))
    t.contains(v.hint, "Das Verzeichnis ist gesperrt")
    t.eq(d.area(v, "act:weiter").enabled, true, "nach der Ablehnung darf man es erneut versuchen")
    z.node.roles.zentrale.handle_directory = real
    d.tap(v, "act:weiter"); h.step(3); d.node.render()
    t.eq(screen(d), "4.zuordnung", d.text(v))
  end },
  { "Fehlgeschlagene Pruefung: nichts wird aktiviert, das Ergebnis zeigt das Signal, nach der Behebung geht es weiter", function()
    local h, z, d, v = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    assign_all(h, d, v, 2)
    d.world.devices["Create_Signal_2"].state.ignore_hold = true
    d.tap(v, "act:weiter"); d.tap(v, "act:pruefen"); h.step(1); d.node.render()
    t.ok(d.node.status().text ~= "Bereit", "nicht aktiviert")
    t.eq(screen(d), "5.pruefen")
    t.ok(d.has(v, "nicht alles bestanden"), d.text(v))
    t.ok(d.has(v, "Sperre nicht bestaetigt"), d.text(v))
    t.eq(d.area(v, "act:pruefen").enabled, true)
    d.world.devices["Create_Signal_2"].state.ignore_hold = nil
    d.tap(v, "act:pruefen"); h.step(1)
    t.eq(d.node.status().text, "Bereit")
  end },
  { "Pruefung abbrechen (Stoppen): keine weiteren Tests, keine Sperre bleibt, nichts wird gespeichert", function()
    local h, z, d, v = setup({ tracks = 4, signals = 4 })
    to_area(h, d, v); through_tracks(h, d, v)
    assign_all(h, d, v, 4)
    d.tap(v, "act:weiter")
    d.tap(v, "act:pruefen")
    t.eq(d.node.setup.session().checking, true)
    t.ok(d.area(v, "act:pruefung_stopp"), d.text(v))
    t.eq(d.area(v, "act:zurueck"), nil, "waehrend der Pruefung keine Navigation")
    d.tap(v, "act:pruefung_stopp")
    t.eq(d.node.setup.session().checking, false)
    h.step(2)
    t.ok(d.node.status().text ~= "Bereit")
    for i = 1, 4 do t.eq(d.world.devices["Create_Signal_" .. i].state.forced, false) end
    d.tap(v, "act:pruefen"); h.step(1)
    t.eq(d.node.status().text, "Bereit", "danach laesst sie sich neu starten")
  end },
  { "Waehrend der Testsperre steht die Marke in ihrer Datei (nicht in einer gespeicherten Einrichtung) und ist danach weg", function()
    local h, z, d, v = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    assign_all(h, d, v, 2)
    local seen = {}
    for i = 1, 2 do
      local dev = d.world.devices["Create_Signal_" .. i]
      local real = dev.methods.setForcedRed
      dev.methods.setForcedRed = function(on)
        if on == true then
          local mark = storelib.new(d.fs).load("/crn_data/pruefmarke.lua")
          seen[#seen + 1] = mark and mark.name or false
          t.ok(not d.fs.exists("/crn_data/config.lua"), "keine Einrichtung als Entwurf gespeichert")
        end
        return real(on)
      end
    end
    d.tap(v, "act:weiter"); d.tap(v, "act:pruefen"); h.step(1)
    t.eq(seen[1], "Create_Signal_1"); t.eq(seen[2], "Create_Signal_2")
    t.ok(not d.fs.exists("/crn_data/pruefmarke.lua"), "Marke nach der Pruefung weg")
    t.eq(d.node.status().text, "Bereit")
  end },
  { "Neustart nach abgebrochener Einrichtung: sie beginnt von vorn, die Node behaelt dieselbe Kennung, keine zweite im Verzeichnis", function()
    local h, z, d, v, netz = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    d.tap(v, "act:signal_waehlen"); d.tap(v, "sel:signal:1")
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001")
    d.restart()
    t.eq(d.node.config, nil, "nichts als Entwurf gespeichert")
    local v2 = d.view(); v2.set_page("einrichtung")
    to_area(h, d, v2); through_tracks(h, d, v2)
    t.eq(screen(d), "4.zuordnung", d.text(v2))
    t.ok(not d.has(v2, "Create_Signal_1  Signal"), "die Zuordnung beginnt leer")
    t.eq(d.node.setup.session().wiz.config.node.id, "N0001", "dieselbe Kennung")
    assign_all(h, d, v2, 2)
    d.tap(v2, "act:weiter"); d.tap(v2, "act:pruefen"); h.step(1)
    t.eq(d.node.status().text, "Bereit")
    t.eq(#netz.nodes(), 1, "keine zweite Kennung")
  end },
  { "Hat die Leitstelle die Anforderung dieses Computers verworfen, gibt es eine neue Kennung statt einer Sackgasse", function()
    local h, z, d, v, netz = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    t.eq(netz.node("N0001").state, "reserviert")
    netz.discard_node("N0001")
    d.restart()
    local v2 = d.view(); v2.set_page("einrichtung")
    to_area(h, d, v2)
    d.tap(v2, "sel:bereich:1"); h.step(3); d.node.render()
    d.tap(v2, "act:weiter"); d.tap(v2, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "2.gleise", d.text(v2))
    t.contains(v2.hint, "verworfen")
    t.contains(v2.hint, "neue")
    d.tap(v2, "act:weiter")
    h.step(3); d.node.render()
    t.eq(screen(d), "4.zuordnung", d.text(v2))
    t.eq(d.node.setup.session().wiz.config.node.id, "N0002", "eine neue Anforderung")
  end },
  { "Ein neu angeschlossenes Signal wird in der Auswahl als (neu) markiert", function()
    local h, z, d, v = setup({ tracks = 2, signals = 2 })
    to_area(h, d, v); through_tracks(h, d, v)
    d.world.add_signal("Create_Signal_7")
    d.tap(v, "act:signal_waehlen")
    t.ok(d.has(v, "Create_Signal_7  (neu)"), d.text(v))
    t.ok(not d.has(v, "Create_Signal_1  (neu)"), d.text(v))
  end },
  { "Alle Aktionen sind auf kleinem und grossem Bildschirm sichtbar", function()
    for _, size in ipairs({ { 51, 19 }, { 100, 40 } }) do
      local h = H.new()
      local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
      z.node.roles.zentrale.netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 })
      local d = h.add_blank({ id = "neu", width = size[1], height = size[2] })
      for i = 1, 4 do d.world.add_signal("Create_Signal_" .. i) end
      h.step(1)
      local v = d.view(); v.set_page("einrichtung")
      to_area(h, d, v)
      d.tap(v, "sel:bereich:1"); h.step(3); d.node.render()
      d.tap(v, "act:weiter"); d.tap(v, "act:weiter"); h.step(3); d.node.render()
      assign_all(h, d, v, 4)
      d.tap(v, "act:weiter")
      d.node.render(); d.check_actions(v)
      d.tap(v, "act:pruefen")
    end
  end },
}
