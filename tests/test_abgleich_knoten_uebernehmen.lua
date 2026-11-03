--[[
Purpose: Aenderungen eines Knotens im Netzverzeichnis auf der Knoten-Node uebernehmen (Konzept 15): nur bei gleichen Gleisen, Anschluessen und Rollen, nur bei freiem Knoten, erst nach zweimaligem Tippen, ganz oder gar nicht; Aenderungen waehrend des Holens und unlesbare Teile werden nicht uebernommen.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function build(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "Kreuzung", ends = { "Nord", "Sued" }, count = 4 })
  local k = assert(netz.add_junction({ name = "Hauptknoten" }))
  assert(netz.add_connection(k, "West", { "A0001", "A0002" })); assert(netz.add_connection(k, "Ost", { "A0003", "A0004" }))
  assert(netz.add_route(k, "A0001", "A0003", true)); assert(netz.add_route(k, "A0004", "A0002", true))
  local function dir(id) if opts.nodir then return nil end return { id = id, junction = k } end
  local spec = {
    id = "tee", roles = { "knoten" }, central = "hauptstelle",
    junction = { connections = { West = true, Ost = true }, moves = { { from = "Ost", to = "West" }, { from = "West", to = "Ost" } }, conflicts = {} },
    tracks = {
      { name = "West Gleis 1", signals = { "Sig_W" }, observers = { "Obs_W1" }, junction = { connection = "West", role = "ein" }, dir = dir("A0001") },
      { name = "Ost Gleis 3", observers = { "Obs_O3" }, junction = { connection = "Ost", role = "aus" }, dir = dir("A0003") },
      { name = "Ost Gleis 4", signals = { "Sig_O" }, observers = { "Obs_O4" }, junction = { connection = "Ost", role = "ein" }, dir = dir("A0004") },
      { name = "West Gleis 2", observers = { "Obs_W2" }, junction = { connection = "West", role = "aus" }, dir = dir("A0002") },
    },
    directory_junction = { id = k, rev = netz.junction(k).rev },
  }
  local s = h.add_node(spec)
  h.step(40)
  return h, z, netz, k, s, s.node.roles.knoten
end

local function sync_now(h, role)
  assert(role.sync_request())
  h.step(8)
end

local function track_of(s, dir_id)
  for tid, tr in pairs(s.node.config.tracks) do if tr.dir and tr.dir.id == dir_id then return tid end end
end

return {
  { "Verträgliche Aenderung (neuer Konflikt): erkannt, erst nach zweimaligem Tippen uebernommen, gespeichert und wirksam", function()
    local h, z, netz, k, s, role = build()
    local rev_before = s.node.config.node.junction_rev
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    t.eq(role.sync.state, "abweichend")
    t.ok(role.sync.plan, "Plan: " .. tostring(role.sync.note))
    t.contains(role.sync.note, "Uebernehmen moeglich")
    t.contains(role.sync.note, "Konflikte 0 -> 1")
    t.eq(#s.node.config.junction.conflicts, 0, "nichts still uebernommen")
    t.eq(role.areas.entries_conflict("West", "Ost"), false)
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.ok(s.has(v, "Uebernehmen"), s.text(v))
    s.tap(v, "act:uebernehmen")
    t.contains(v.hint, "Nochmal druecken")
    t.eq(#s.node.config.junction.conflicts, 0, "der erste Druck aendert nichts")
    s.node.render()
    t.ok(s.has(v, "Wirklich?"), s.text(v))
    s.tap(v, "act:uebernehmen")
    t.contains(v.hint, "uebernommen")
    t.eq(#s.node.config.junction.conflicts, 1)
    t.eq(s.node.config.node.junction_rev, netz.junction(k).rev)
    t.ok(s.node.config.node.junction_rev ~= rev_before)
    t.eq(role.sync.state, "gleich")
    t.eq(role.sync.plan, nil)
    -- gespeichert
    local saved = s.node.store.load("/crn_data/config.lua")
    t.eq(#saved.junction.conflicts, 1, "in der Datei")
    t.eq(saved.node.junction_rev, netz.junction(k).rev)
    -- wirksam: die neue Konfliktregel gilt in der laufenden Rolle
    t.eq(role.areas.entries_conflict("West", "Ost"), true)
    local a = role.areas.announce("West", "ZugA", track_of(s, "A0001"))
    local b = role.areas.announce("Ost", "ZugB", track_of(s, "A0004"))
    t.ok(a and b)
    local grants = role.areas.next_grants()
    t.eq(#grants, 1, "nur eine der beiden Einfahrten wird freigegeben")
    -- noch einmal uebernehmen geht nicht
    local ok, why = role.sync_apply()
    t.eq(ok, nil); t.contains(why, "Nichts zu uebernehmen")
  end },
  { "Umbenanntes Gleis zusammen mit einer Aenderung: Name wird uebernommen, auch fuer Meldungen", function()
    local h, z, netz, k, s, role = build()
    assert(netz.set_track("A0001", { name = "Einfahrt" }))
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    t.ok(role.sync.plan, tostring(role.sync.note))
    t.contains(role.sync.note, "1 Gleisname")
    t.eq(role.sync_apply(), true)
    local tid = track_of(s, "A0001")
    t.eq(s.node.config.tracks[tid].name, "West Einfahrt")
    t.eq(s.node.store.load("/crn_data/config.lua").tracks[tid].name, "West Einfahrt")
    -- die Einfahrt traegt den neuen Namen auch in Meldungen: das Signal faellt aus, die Sperre scheitert
    s.world.devices.Sig_W = nil
    local obs = s.node.config.tracks[tid].observers[1]
    role.observe(obs, "ZugA", "passing")
    role.observe(obs, "ZugA", "passed")
    local found
    for _, m in ipairs(s.node.messages) do if m.text:find("Einfahrt West Einfahrt", 1, true) then found = m end end
    t.ok(found, "Meldung mit neuem Namen")
  end },
  { "Gleise gaendert (Fahrweg entfernt): nicht uebernehmbar, kein Knopf, nichts geaendert", function()
    local h, z, netz, k, s, role = build()
    local rev_before = s.node.config.node.junction_rev
    assert(netz.remove_route(k, "F0002"))
    sync_now(h, role)
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.plan, nil)
    t.contains(role.sync.note, "nicht uebernehmbar")
    t.contains(role.sync.note, "Einrichtung neu durchlaufen")
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.ok(not s.has(v, "Uebernehmen"), s.text(v))
    local ok, why = role.sync_apply()
    t.eq(ok, nil); t.contains(why, "Nichts zu uebernehmen")
    t.eq(#s.node.config.junction.moves, 2)
    t.eq(s.node.config.node.junction_rev, rev_before, "Stand unveraendert")
  end },
  { "Anderer Anschluss oder andere Rolle eines Gleises: nicht uebernehmbar", function()
    local h, z, netz, k, s, role = build()
    -- Gleis A0002 (Ausfahrt West) wird Ausfahrt Ost, A0003 dafuer Ausfahrt West: gleiche Gleise, aber andere Anschluesse
    assert(netz.remove_route(k, "F0001")); assert(netz.remove_route(k, "F0002"))
    assert(netz.remove_connection(k, "West")); assert(netz.remove_connection(k, "Ost"))
    assert(netz.add_connection(k, "West", { "A0001", "A0003" })); assert(netz.add_connection(k, "Ost", { "A0002", "A0004" }))
    assert(netz.add_route(k, "A0001", "A0002", true)); assert(netz.add_route(k, "A0004", "A0003", true))
    sync_now(h, role)
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.plan, nil)
    t.contains(role.sync.note, "Anschluesse oder Gleisrollen")
    t.eq(s.node.config.junction.connections.West, true)
    for _, tr in pairs(s.node.config.tracks) do
      if tr.dir and tr.dir.id == "A0002" then t.eq(tr.junction.connection, "West", "lokal unveraendert") end
    end
  end },
  { "Gleiche Gleise und Anschluesse, aber Ein- und Ausfahrt vertauscht: nicht uebernehmbar", function()
    local h, z, netz, k, s, role = build()
    -- West hatte A0001 als Einfahrt und A0002 als Ausfahrt; jetzt umgekehrt (Ost ebenso)
    assert(netz.remove_route(k, "F0001")); assert(netz.remove_route(k, "F0002"))
    assert(netz.add_route(k, "A0002", "A0004", true)); assert(netz.add_route(k, "A0003", "A0001", true))
    sync_now(h, role)
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.plan, nil)
    t.contains(role.sync.note, "Anschluesse oder Gleisrollen")
    for _, tr in pairs(s.node.config.tracks) do
      if tr.dir and tr.dir.id == "A0001" then t.eq(tr.junction.role, "ein", "lokal unveraendert") end
    end
  end },
  { "Die Bestaetigung gilt nur fuer die angezeigte Fassung: eine neue Abfrage macht sie ungueltig", function()
    local h, z, netz, k, s, role = build()
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    local v = H.open_page(s, "knoten")
    s.node.render()
    s.tap(v, "act:uebernehmen")                       -- scharf gemacht
    t.contains(v.hint, "Nochmal druecken")
    t.eq(#s.node.config.junction.conflicts, 0)
    -- bevor bestaetigt wird, fragt der Abgleich erneut (hier: Knopf Abgleich)
    s.tap(v, "act:abgleich")
    h.step(8)
    s.node.render()
    s.tap(v, "act:uebernehmen")
    t.eq(#s.node.config.junction.conflicts, 0, "der Druck nach der neuen Abfrage ist wieder der erste")
    t.contains(v.hint, "Nochmal druecken")
    s.tap(v, "act:uebernehmen")
    t.eq(#s.node.config.junction.conflicts, 1)
  end },
  { "Nicht frei: bei vorgemerkter Nutzung wird nichts uebernommen; nach dem Aufloesen geht es", function()
    local h, z, netz, k, s, role = build()
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    t.ok(role.sync.plan)
    local use = role.areas.announce("West", "ZugA", track_of(s, "A0001"))
    local ok, why = role.sync_apply()
    t.eq(ok, nil); t.contains(why, "frei")
    t.eq(#s.node.config.junction.conflicts, 0)
    t.eq(role.sync.state, "abweichend")
    t.ok(role.sync.plan, "Plan bleibt")
    t.ok(role.areas.clear(use.id, "Test"))
    t.eq(role.sync_apply(), true)
    t.eq(#s.node.config.junction.conflicts, 1)
  end },
  { "Speichern schlaegt fehl: alles bleibt wie vorher", function()
    local h, z, netz, k, s, role = build()
    assert(netz.set_track("A0001", { name = "Einfahrt" }))
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    t.ok(role.sync.plan)
    local cfg = s.node.config
    local before = { junction = cfg.junction, rev = cfg.node.junction_rev, revision = cfg.revision, name = cfg.tracks[track_of(s, "A0001")].name, areas = role.areas }
    local real = s.node.save_config
    s.node.save_config = function() return nil, "Speicher voll" end
    local ok, why = role.sync_apply()
    s.node.save_config = real
    t.eq(ok, nil); t.contains(why, "Speichern fehlgeschlagen")
    t.ok(cfg.junction == before.junction, "Verbindungen unveraendert")
    t.eq(#cfg.junction.conflicts, 0)
    t.eq(cfg.node.junction_rev, before.rev)
    t.eq(cfg.revision, before.revision)
    t.eq(cfg.tracks[track_of(s, "A0001")].name, before.name)
    t.ok(role.areas == before.areas, "laufende Regeln unveraendert")
    t.eq(role.areas.entries_conflict("West", "Ost"), false)
    t.eq(role.sync.state, "abweichend"); t.ok(role.sync.plan, "Plan bleibt")
    t.eq(role.sync_apply(), true, "danach geht es")
  end },
  { "Die Leitstelle aendert den Knoten waehrend des Holens: nicht uebernehmbar, spaetere Wiederholung klappt", function()
    local h, z, netz, k, s, role = build()
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    local real = z.node.reply
    local calls = 0
    z.node.reply = function(m, status, payload)
      if m.payload and m.payload.kind == "knoten_teil" and m.payload.part == "anschluesse" then
        calls = calls + 1
        if calls == 2 and payload.part then payload.part.rev = payload.part.rev + 3 end
      end
      return real(m, status, payload)
    end
    sync_now(h, role)
    t.eq(calls, 2, "Anschluesse zweimal gefragt: vorher und nachher")
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.plan, nil)
    t.contains(role.sync.note, "aendert den Knoten gerade")
    t.ok(role.sync_apply() == nil)
    z.node.reply = real
    h.step(80)
    t.ok(role.sync.plan, "nach der Wiederholung: " .. tostring(role.sync.note))
  end },
  { "Unlesbare oder fehlerhafte Teile der Fassung: nichts wird angeboten", function()
    local cases = {
      { "fahrwege", function(p) p.part.routes = { { id = "x", from = "A0001", to = "A0003" } } end },
      { "fahrwege", function(p) p.part.routes = "kaputt" end },
      { "konflikte", function(p) p.part.conflicts = { { a = "F0001", b = 7 } } end },
      { "konflikte", function(p) p.part = { id = "K9999", conflicts = {} } end },
    }
    for _, case in ipairs(cases) do
      local h, z, netz, k, s, role = build()
      assert(netz.add_conflict(k, "F0001", "F0002", true))
      local real = z.node.reply
      z.node.reply = function(m, status, payload)
        if m.payload and m.payload.kind == "knoten_teil" and m.payload.part == case[1] then case[2](payload) end
        return real(m, status, payload)
      end
      sync_now(h, role)
      t.eq(role.sync.plan, nil, case[1])
      t.ok(role.sync.state == "unlesbar" or role.sync.state == "frage", case[1] .. " -> " .. tostring(role.sync.state))
      local ok = role.sync_apply()
      t.eq(ok, nil)
      t.eq(#s.node.config.junction.conflicts, 0)
    end
  end },
  { "Formpruefung der drei Teile (unbeglaubigte Antworten): nur Werte in der erlaubten Form kommen durch", function()
    local h, z, netz, k, s, role = build()
    local node = s.node
    local function conns() return { id = "K0001", name = "Hauptknoten", rev = 3, connections = { { name = "West", tracks = { { id = "A0001", name = "Gleis 1", area = "Kreuzung" } } } } } end
    local good = node.parse_junction_connections(conns(), "K0001")
    t.ok(good, "gueltig")
    t.eq(good.rev, 3); t.eq(good.connections[1].tracks[1].id, "A0001")
    local bad_cases = {
      function(p) p.id = "K0002" end,                                  -- falscher Knoten
      function(p) p.name = "Haupt<knoten" end,                          -- Zeichen
      function(p) p.rev = "3" end,                                      -- Stand keine Zahl
      function(p) p.connections = "x" end,
      function(p) p.connections[1].name = "We;st" end,                  -- Anschlussname
      function(p) p.connections[1].tracks[1].id = "G1" end,             -- Gleiskennung
      function(p) p.connections[1].tracks[1].name = "Gl\"eis" end,
      function(p) p.connections[1].tracks[1].area = 5 end,
      function(p) p.connections[1].tracks = { "A0001" } end,
    }
    for i, mutate in ipairs(bad_cases) do
      local p = conns()
      mutate(p)
      t.eq(node.parse_junction_connections(p, "K0001"), nil, "Anschluesse Fall " .. i)
    end
    t.eq(node.parse_junction_connections(nil, "K0001"), nil)
    local routes = node.parse_junction_routes({ id = "K0001", routes = { { id = "F0001", from = "A0001", to = "A0003" } } }, "K0001")
    t.ok(routes and routes[1].id == "F0001")
    t.eq(node.parse_junction_routes({ id = "K0009", routes = {} }, "K0001"), nil, "falscher Knoten (Fahrwege)")
    t.eq(node.parse_junction_routes({ id = "K0001", routes = { { id = "F1", from = "A0001", to = "A0003" } } }, "K0001"), nil)
    t.eq(node.parse_junction_routes({ id = "K0001", routes = { { id = "F0001", from = "x", to = "A0003" } } }, "K0001"), nil)
    t.eq(node.parse_junction_routes({ id = "K0001", routes = { { id = "F0001", from = "A0001" } } }, "K0001"), nil)
    local conflicts = node.parse_junction_conflicts({ id = "K0001", conflicts = { { a = "F0001", b = "F0002" } } }, "K0001")
    t.ok(conflicts and conflicts[1].b == "F0002")
    t.eq(node.parse_junction_conflicts({ id = "K0009", conflicts = {} }, "K0001"), nil, "falscher Knoten (Konflikte)")
    t.eq(node.parse_junction_conflicts({ id = "K0001", conflicts = { { a = "F0001", b = 7 } } }, "K0001"), nil)
    t.eq(node.parse_junction_conflicts({ id = "K0001", conflicts = { { a = "x", b = "F0002" } } }, "K0001"), nil)
  end },
  { "Gleise ohne Zuordnung zum Verzeichnis: nur Meldung, kein Uebernehmen", function()
    local h, z, netz, k, s, role = build({ nodir = true })
    assert(netz.add_conflict(k, "F0001", "F0002", true))
    sync_now(h, role)
    t.eq(role.sync.state, "abweichend")
    t.eq(role.sync.plan, nil)
    t.contains(role.sync.note, "keine Zuordnung")
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.ok(not s.has(v, "Uebernehmen"), s.text(v))
  end },
}
