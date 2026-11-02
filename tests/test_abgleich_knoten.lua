--[[
Purpose: Abgleich einer aktiven Knoten-Node mit dem Netzverzeichnis (Konzept 15): eine Aenderung des Knotens in der Leitstelle wird erkannt und gemeldet, aber nicht still uebernommen; Ausfall und unlesbare Antworten aendern nichts.
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
  local spec = {
    id = "tee", roles = { "knoten" }, central = "hauptstelle",
    junction = { connections = { West = true, Ost = true }, moves = { { from = "Ost", to = "West" }, { from = "West", to = "Ost" } }, conflicts = {} },
    tracks = {
      { name = "West Gleis 1", signals = { "Sig_W" }, observers = { "Obs_W1" }, junction = { connection = "West", role = "ein" } },
      { name = "Ost Gleis 3", observers = { "Obs_O3" }, junction = { connection = "Ost", role = "aus" } },
      { name = "Ost Gleis 4", signals = { "Sig_O" }, observers = { "Obs_O4" }, junction = { connection = "Ost", role = "ein" } },
      { name = "West Gleis 2", observers = { "Obs_W2" }, junction = { connection = "West", role = "aus" } },
    },
  }
  if opts.directory ~= false then spec.directory_junction = { id = k, rev = netz.junction(k).rev } end
  local s = h.add_node(spec)
  return h, z, netz, k, s, s.node.roles.knoten
end

local function has_note(s, text)
  for _, m in ipairs(s.node.messages) do if m.text:find(text, 1, true) then return m end end
end

return {
  { "Unveraendert: stimmt mit der Leitstelle ueberein", function()
    local h, z, netz, k, s, role = build()
    h.step(40)
    t.eq(role.sync.state, "gleich")
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.contains(s.text(v), "der Knoten stimmt mit der")
    t.contains(s.text(v), "Leitstelle ueberein")
  end },
  { "Der Knoten wurde in der Leitstelle geaendert: Abweichung gezeigt und einmal gemeldet, nichts wird still uebernommen", function()
    local h, z, netz, k, s, role = build()
    h.step(40)
    assert(netz.set_junction(k, { name = "Hauptknoten neu" }))
    local before = #s.node.config.junction.moves
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "abweichend")
    t.contains(role.sync.note, "in der Leitstelle geaendert")
    local note = has_note(s, "Abweichung zum Netzverzeichnis")
    t.ok(note, "gemeldet"); t.eq(note.level, "warnung")
    t.eq(#s.node.config.junction.moves, before, "lokal nichts geaendert")
    local count = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Abweichung zum Netzverzeichnis", 1, true) then count = count + 1 end end
    assert(role.sync_request()); h.step(4)
    local after = 0
    for _, m in ipairs(s.node.messages) do if m.text:find("Abweichung zum Netzverzeichnis", 1, true) then after = after + 1 end end
    t.eq(after, count, "dieselbe Abweichung wird nicht noch einmal gemeldet")
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.contains(s.text(v), "Einrichtung")
  end },
  { "Der Knoten ist aus dem Verzeichnis verschwunden: Meldung, Einrichtung bleibt", function()
    local h, z, netz, k, s, role = build()
    h.step(40)
    assert(netz.remove_junction(k))
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "abgelehnt")
    t.ok(has_note(s, "Netzverzeichnis"), "gemeldet")
    t.ok(s.node.roles.knoten, "die Rolle laeuft weiter")
  end },
  { "Leitstelle antwortet nicht: 'keine Antwort', keine Abweichungsmeldung", function()
    local h, z, netz, k, s, role = build()
    z.node.handle = function() end
    h.step(60)
    t.eq(role.sync.state, "keine Antwort")
    t.ok(not has_note(s, "Abweichung zum Netzverzeichnis"))
  end },
  { "Unlesbare oder fremde Antwort wird nicht gewertet", function()
    local h, z, netz, k, s, role = build()
    h.step(40)
    local real = z.node.reply
    z.node.reply = function(m, status, payload)
      if m.payload and m.payload.kind == "knoten_teil" then return real(m, "ok", { part = { id = "K0007", rev = 99 } }) end
      return real(m, status, payload)
    end
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "unlesbar")
    t.ok(not has_note(s, "Abweichung zum Netzverzeichnis"))
    -- eine Antwort ohne passende Frage wird ignoriert
    local fake = s.node.factory.make("bestaetigung", "tee", { kind = "antwort", status = "ok", antwort_auf = "knoten_teil", part = { id = k, rev = 55 } }, { correlationId = "fremd:1:1" })
    local state = role.sync.state
    role.on_message(fake, "ok")
    t.eq(role.sync.state, state)
  end },
  { "Node ohne Verzeichnis-Einrichtung fragt nie und zeigt keinen Knopf", function()
    local h, z, netz, k, s, role = build({ directory = false })
    h.step(700)
    t.eq(role.sync.state, "offen")
    local v = H.open_page(s, "knoten")
    s.node.render()
    t.ok(not s.has(v, "Abgleich"), s.text(v))
    local ok, why = role.sync_request()
    t.eq(ok, nil); t.contains(why, "nicht ueber das Netzverzeichnis")
  end },
  { "Knopf Abgleich fragt sofort; der Abgleich wiederholt sich alle zehn Minuten", function()
    local h, z, netz, k, s, role = build()
    h.step(40)
    local v = H.open_page(s, "knoten")
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "Frage die Leitstelle")
    h.step(4)
    t.eq(role.sync.state, "gleich")
    assert(netz.set_junction(k, { name = "Anders" }))
    h.step(700)
    t.eq(role.sync.state, "abweichend")
  end },
}
