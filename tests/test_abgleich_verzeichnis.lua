--[[
Purpose: Abgleich einer aktiven Signal-Node mit dem Netzverzeichnis (Konzept 15): Abweichungen bei Name und Richtung werden angezeigt und nur auf Wunsch uebernommen; fehlende oder unlesbare Antworten aendern nichts.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local storelib = require("core.store")

local function build(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 2 })     -- A0001 Ostbahnhof, A0002 Westbahnhof
  local spec = {
    id = "strecke", roles = { "signal" }, central = "hauptstelle",
    tracks = {
      { name = "Gleis 1", signals = { "Sig_1" }, signal_info = { use = "strecke", effect = "Ostbahnhof", place = "Ostbahnhof" }, dir = { id = "A0001", area = "B0001", direction = "Ostbahnhof", rev = 1 } },
      { name = "Gleis 2", signals = { "Sig_2" }, signal_info = { use = "strecke", effect = "Westbahnhof", place = "Westbahnhof" }, dir = { id = "A0002", area = "B0001", direction = "Westbahnhof", rev = 1 } },
    },
  }
  if opts.claimed ~= false then spec.area, spec.area_ends = "B0001", { "Westbahnhof", "Ostbahnhof" } end
  local s = h.add_node(spec)
  local role = s.node.roles.signal
  return h, z, netz, s, role
end

local function has_note(s, text)
  for _, m in ipairs(s.node.messages) do if m.text:find(text, 1, true) then return m end end
end

local function config_on_disk(s)
  return storelib.new(s.fs).load("/crn_data/config.lua")
end

local function track_by_name(config, name)
  for tid, tr in pairs(config.tracks) do if tr.name == name then return tr, tid end end
end

return {
  { "Alles gleich: Der Abgleich meldet es, die Seite zeigt es, es wird nichts veraendert", function()
    local h, z, netz, s, role = build()
    h.step(40)
    t.eq(role.sync.state, "gleich")
    t.eq(#role.sync.diffs, 0)
    local v = H.open_page(s, "signale")
    t.contains(s.text(v), "stimmen")
  end },
  { "Zentral geaendert: Abweichung wird angezeigt und gemeldet, lokal bleibt alles, bis uebernommen wird", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { name = "Hauptgleis", direction = "Westbahnhof" }))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich")
    h.step(4)
    t.eq(role.sync.state, "abweichend", tostring(role.sync.note))
    t.eq(#role.sync.diffs, 2)
    s.node.render()
    t.contains(s.text(v), "Abweichung")
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.ok(tr, "lokal unveraendert")
    t.eq(tr.dir.direction, "Ostbahnhof")
    local note = has_note(s, "Abweichung zum Netzverzeichnis")
    t.ok(note, "Meldung ueber die Abweichung")
    t.eq(note.level, "warnung")
    -- eine unveraenderte Abweichung wird nicht bei jedem Abgleich neu gemeldet
    local count = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Abweichung zum Netzverzeichnis", 1, true) then count = count + 1 end end
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "abweichend")
    local after = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Abweichung zum Netzverzeichnis", 1, true) then after = after + 1 end end
    t.eq(after, count)
  end },
  { "Uebernehmen: Name, Richtung und Stand, Wirkrichtung der Signale folgt, Datei gespeichert, Leitstelle erfaehrt es", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { name = "Hauptgleis", direction = "Westbahnhof" }))
    local rev = s.node.config.revision or 0
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "uebernommen")
    local tr, tid = track_by_name(s.node.config, "Hauptgleis")
    t.ok(tr, "umbenannt")
    t.eq(tr.dir.direction, "Westbahnhof"); t.eq(tr.dir.rev, netz.track("A0001").rev)
    local did = tr.signals[1]
    t.eq(s.node.config.devices[did].signal.effect, "Westbahnhof"); t.eq(s.node.config.devices[did].signal.place, "Westbahnhof")
    t.eq(s.node.config.revision, rev + 1)
    local disk = config_on_disk(s)
    local dtr = track_by_name(disk, "Hauptgleis")
    t.ok(dtr, "gespeichert"); t.eq(dtr.dir.direction, "Westbahnhof")
    t.eq(role.sync.state, "gleich")
    t.eq(#role.sync.diffs, 0)
    -- die Signalanzeige und die Leitstelle kennen den neuen Namen und die neue Wirkrichtung
    h.step(15)
    local found
    for _, row in ipairs(z.node.roles.zentrale.signal_overview()) do if row.signal.track_name == "Hauptgleis" then found = row end end
    t.ok(found, "Signal unter dem neuen Gleisnamen")
    t.eq(found.effect, "Westbahnhof")
    -- ein weiterer Abgleich findet nichts mehr
    s.tap(v, "act:abgleich"); h.step(4)
    t.eq(role.sync.state, "gleich")
  end },
  { "Richtung wird 'beide': eine gueltige Wirkrichtung bleibt, eine nicht mehr gueltige wird offen", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { direction = "beide" }))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    s.tap(v, "act:abgleich")
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.eq(tr.dir.direction, "beide")
    t.eq(s.node.config.devices[tr.signals[1]].signal.effect, "Ostbahnhof", "Ostbahnhof ist weiter ein Anschluss des Bereichs")
  end },
  { "Richtung wird 'beide' und die Wirkrichtung gilt nicht mehr: sie wird offen, ist sichtbar gemeldet, die Schaltpruefung bleibt gueltig", function()
    local h, z, netz, s, role = build()
    -- Sig_1 meldet eine Wirkrichtung, die kein Anschluss des Bereichs ist (zum Beispiel nach einer Umbenennung)
    local tr0, tid0 = track_by_name(s.node.config, "Gleis 1")
    s.node.config.devices[tr0.signals[1]].signal = { use = "strecke", effect = "Altbahnhof", place = "Altbahnhof" }
    role.signals[1].effect, role.signals[1].place = "Altbahnhof", "Altbahnhof"
    s.node.config.pruefung = { devices = { [tr0.signals[1]] = { sig = "signal:Sig_1", lesen = { ok = true }, sperre = { ok = true } } } }
    h.step(40)
    assert(netz.set_track("A0001", { direction = "beide" }))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "Wirkrichtung festlegen")
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.eq(s.node.config.devices[tr.signals[1]].signal.effect, nil, "Wirkrichtung ist offen")
    t.eq(role.signals[1].effect, nil)
    t.ok(has_note(s, "ohne Wirkrichtung"), "als Meldung sichtbar")
    t.ok(s.node.config.pruefung.devices[tr.signals[1]], "die Schaltpruefung bleibt gueltig (Richtung ist weder Geraet noch Zuordnung)")
    t.eq(s.node.config.pruefung.devices[tr.signals[1]].sperre.ok, true)
  end },
  { "Uebernahme ohne offene Wirkrichtung meldet nichts Zusaetzliches", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { name = "Einfahrt" }))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "uebernommen")
    t.ok(not v.hint:find("Wirkrichtung", 1, true), v.hint)
    t.ok(not has_note(s, "ohne Wirkrichtung"))
  end },
  { "Leitstelle antwortet nicht: 'keine Antwort', keine Meldung ueber Abweichungen, lokal unveraendert", function()
    local h, z, netz, s, role = build()
    z.node.handle = function() end
    h.step(60)
    t.eq(role.sync.state, "keine Antwort")
    t.contains(role.sync.note, "bleibt unveraendert")
    t.eq(#role.sync.diffs, 0)
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.eq(tr.dir.direction, "Ostbahnhof")
    t.ok(not has_note(s, "Abweichung zum Netzverzeichnis"), "ein Ausfall ist keine Abweichung")
    local v = H.open_page(s, "signale")
    s.node.render()
    t.contains(s.text(v), "Netzverzeichnis")
  end },
  { "Unlesbare Antwort wird nicht uebernommen", function()
    local h, z, netz, s, role = build()
    local real = z.node.reply
    z.node.reply = function(m, status, payload)
      if m.payload and m.payload.kind == "verzeichnis_gleise" then
        return real(m, "ok", { area = { id = "B0001", tracks = { { id = "A0001", name = "Boese/Zeichen\n", direction = "Ostbahnhof" } } } })
      end
      return real(m, status, payload)
    end
    h.step(40)
    t.eq(role.sync.state, "unlesbar")
    t.eq(#role.sync.diffs, 0)
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.ok(tr, "Name unveraendert")
  end },
  { "Abgelehnte Antwort (Bereich gibt es nicht mehr) wird angezeigt, nichts geaendert", function()
    local h, z, netz, s, role = build()
    s.node.config.node.area = "B0099"
    h.step(40)
    t.eq(role.sync.state, "abgelehnt")
    t.contains(role.sync.note, "Bereich")
  end },
  { "Gleis im Verzeichnis geloescht: wird gezeigt, aber nicht angewendet", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.remove_track("A0002"))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.diffs[1].kind, "fehlt")
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "Nichts zu uebernehmen")
    t.ok(track_by_name(s.node.config, "Gleis 2"), "das Gleis bleibt lokal")
  end },
  { "Speichern schlaegt fehl: nichts bleibt halb uebernommen", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { name = "Hauptgleis", direction = "Westbahnhof" }))
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich"); h.step(4)
    local rev = s.node.config.revision or 0
    s.node.save_config = function() return nil, "Platte voll" end
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "Speichern fehlgeschlagen")
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.ok(tr, "alter Name")
    t.eq(tr.dir.direction, "Ostbahnhof")
    t.eq(s.node.config.devices[tr.signals[1]].signal.effect, "Ostbahnhof")
    t.eq(s.node.config.revision or 0, rev)
  end },
  { "Node ohne Verzeichnis-Einrichtung (von Hand): kein Abgleich, kein Knopf", function()
    local h, z, netz, s, role = build({ claimed = false })
    h.step(700)
    t.eq(role.sync.state, "offen")
    local v = H.open_page(s, "signale")
    t.ok(not s.has(v, "Abgleich"), s.text(v))
    local ok, why = role.sync_request()
    t.eq(ok, nil); t.contains(why, "nicht ueber das Netzverzeichnis")
  end },
  { "Eine Antwort, die zu keiner eigenen Frage gehoert, wird ignoriert", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(role.sync_request())
    local fake = s.node.factory.make("bestaetigung", "strecke", {
      kind = "antwort", status = "ok", antwort_auf = "verzeichnis_gleise",
      area = { id = "B0001", tracks = { { id = "A0001", name = "Eingeschleust", direction = "Westbahnhof" }, { id = "A0002", name = "Gleis 2", direction = "Westbahnhof" } } },
    }, { correlationId = "fremd:1:1" })
    role.on_message(fake, "ok")
    t.eq(role.sync.state, "frage", "die Frage ist weiter offen")
    t.eq(#role.sync.diffs, 0)
    h.step(4)
    t.eq(role.sync.state, "gleich", "die echte Antwort wird danach normal verarbeitet")
  end },
  { "Nur der Stand geaendert (gleicher Inhalt): kein Unterschied, der Stand wird nachgezogen", function()
    local h, z, netz, s, role = build()
    h.step(40)
    assert(netz.set_track("A0001", { name = "Gleis 1" }))
    assert(netz.track("A0001").rev > 1)
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "gleich")
    local tr = track_by_name(s.node.config, "Gleis 1")
    t.eq(tr.dir.rev, netz.track("A0001").rev)
  end },
  { "Der Abgleich wiederholt sich (alle zehn Minuten) und findet spaetere Aenderungen", function()
    local h, z, netz, s, role = build()
    h.step(40)
    t.eq(role.sync.state, "gleich")
    assert(netz.set_track("A0002", { name = "Nachtgleis" }))
    h.step(700)
    t.eq(role.sync.state, "abweichend")
  end },
}
