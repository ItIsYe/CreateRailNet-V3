--[[
Purpose: Mehrere Signale hintereinander auf einem Gleis (Reihenfolge von Anschluss 1 nach Anschluss 2): Pflichtbestaetigung in der gefuehrten Einrichtung, Verschieben, Rueckfall der Bestaetigung bei Aenderungen, Anzeige der Lage in Node und Leitstelle.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local G = dofile("tests/lib/guided.lua")
local model = require("setup.model")

local function row_of(wiz, name)
  for _, r in ipairs(wiz.guided_rows()) do if r.name == name then return r end end
end

-- gefuehrte Einrichtung bis "Signale zuordnen" mit zwei Gleisen und fuenf angeschlossenen Signalen
local function ui()
  local h, z, d, v, netz = G.setup({ tracks = 2, signals = 6, pattern = "gegenlaeufig" })
  t.eq(G.screen(d), "4.zuordnung", d.text(v))
  return h, z, d, v, netz
end

local function assign(d, v, row, count)
  for _ = 1, count do
    d.tap(v, "sel:zuordnung:" .. row)
    d.tap(v, "act:signal_waehlen")
    d.tap(v, "sel:signal:1")
  end
end

local function devices(wiz, name)
  local out = {}
  for _, sg in ipairs(row_of(wiz, name).signals) do out[#out + 1] = sg.device end
  return table.concat(out, ",")
end

return {
  { "Modell: ab zwei Signalen an einem Verzeichnis-Gleis ist die Reihenfolge Pflicht; Aenderungen nehmen die Bestaetigung zurueck", function()
    local c = model.new("n", { "signal" }, { name = "Netz", central_id = "z" })
    c.node.area_ends = { "Westbahnhof", "Ostbahnhof" }
    local tid = model.add_track(c, "Gleis 1")
    c.tracks[tid].dir = { id = "A0001", direction = "Ostbahnhof" }
    c.tracks[tid].direction = "hin"
    local function problem()
      for _, p in ipairs(model.validate(c, {})) do if p.code == "signal_reihenfolge" then return p end end
    end
    local a = model.add_device(c, "signal", "Sig_A"); model.assign(c, tid, "signals", a)
    c.devices[a].signal = { use = "strecke", effect = "Ostbahnhof", place = "Ostbahnhof" }
    t.eq(problem(), nil, "ein Signal: keine Reihenfolge")
    local b = model.add_device(c, "signal", "Sig_B"); model.assign(c, tid, "signals", b)
    c.devices[b].signal = { use = "strecke", effect = "Ostbahnhof", place = "Ostbahnhof" }
    local p = problem()
    t.ok(p, "zwei Signale: Reihenfolge fehlt")
    t.contains(p.text, "Gleis 1"); t.contains(p.text, "2 Signale"); t.contains(p.text, "von Westbahnhof nach Ostbahnhof")
    c.tracks[tid].order_ok = true
    t.eq(problem(), nil, "bestaetigt")
    -- ein weiteres Signal nimmt die Bestaetigung zurueck
    local d = model.add_device(c, "signal", "Sig_C"); model.assign(c, tid, "signals", d)
    c.devices[d].signal = { use = "strecke", effect = "Ostbahnhof", place = "Ostbahnhof" }
    t.eq(c.tracks[tid].order_ok, nil)
    t.ok(problem())
    c.tracks[tid].order_ok = true
    -- ein Signal weniger ebenso
    model.remove_device(c, d)
    t.eq(c.tracks[tid].order_ok, nil)
    c.tracks[tid].order_ok = true
    -- ein fremdes Geraet entfernen aendert nichts
    local obs = model.add_device(c, "observer", "Obs_1")
    model.remove_device(c, obs)
    t.eq(c.tracks[tid].order_ok, true, "ein anderes Geraet beruehrt die Bestaetigung nicht")
    -- ein Gleis ohne Zuordnung zum Verzeichnis (bisheriger Ablauf) braucht keine Bestaetigung
    local old = model.add_track(c, "Altgleis")
    for _, name in ipairs({ "S1", "S2" }) do
      local id = model.add_device(c, "signal", name); model.assign(c, old, "signals", id)
    end
    for _, pr in ipairs(model.validate(c, {})) do
      t.ok(not (pr.code == "signal_reihenfolge" and pr.text:find("Altgleis", 1, true)), "kein Zwang im bisherigen Ablauf")
    end
  end },
  { "Oberflaeche: drei Signale auf einem Gleis - Weiter bleibt gesperrt, bis die Reihenfolge bestaetigt ist", function()
    local h, z, d, v = ui()
    assign(d, v, 1, 3)
    assign(d, v, 2, 1)
    local wiz = d.node.setup.session().wiz
    t.eq(devices(wiz, "Gleis 1"), "Create_Signal_1,Create_Signal_2,Create_Signal_3")
    d.node.render()
    t.contains(d.text(v), "Reihenfolge?")
    d.tap(v, "act:weiter")
    t.contains(d.text(v), "Reihenfolge der 3 Signale bestaetigen")
    t.eq(G.screen(d), "4.zuordnung")
    -- Details: Kopf nennt die Richtung, die Signale sind nummeriert
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:signal_details")
    t.eq(G.screen(d), "4.z.detail", d.text(v))
    t.contains(d.text(v), "Reihenfolge Westbahnhof -> Ostbahnhof (offen)")
    t.contains(d.text(v), "1. Create_Signal_1")
    t.contains(d.text(v), "3. Create_Signal_3")
    -- das dritte Signal nach oben schieben
    d.tap(v, "sel:detail:3")
    d.tap(v, "act:d_hoch")
    t.eq(devices(wiz, "Gleis 1"), "Create_Signal_1,Create_Signal_3,Create_Signal_2")
    d.node.render()
    t.contains(d.text(v), "2. Create_Signal_3")
    -- die Auswahl folgt dem verschobenen Signal: noch einmal Hoch macht es zum ersten
    d.tap(v, "act:d_hoch")
    t.eq(devices(wiz, "Gleis 1"), "Create_Signal_3,Create_Signal_1,Create_Signal_2")
    d.tap(v, "act:d_hoch")
    t.contains(v.hint, "schon das erste")
    t.eq(devices(wiz, "Gleis 1"), "Create_Signal_3,Create_Signal_1,Create_Signal_2")
    -- ganz nach unten
    d.tap(v, "act:d_runter"); d.tap(v, "act:d_runter")
    t.eq(devices(wiz, "Gleis 1"), "Create_Signal_1,Create_Signal_2,Create_Signal_3")
    d.tap(v, "act:d_runter")
    t.contains(v.hint, "schon das letzte")
    -- bestaetigen
    d.tap(v, "act:d_reihenfolge")
    t.contains(v.hint, "bestaetigt")
    d.node.render()
    t.contains(d.text(v), "Westbahnhof -> Ostbahnhof (ok)")
    t.eq(row_of(wiz, "Gleis 1").order_ok, true)
    -- Verschieben nimmt die Bestaetigung zurueck
    d.tap(v, "sel:detail:2"); d.tap(v, "act:d_hoch")
    t.eq(row_of(wiz, "Gleis 1").order_ok, false)
    d.tap(v, "act:d_runter")
    d.tap(v, "act:d_reihenfolge")
    d.tap(v, "act:zurueck")
    t.eq(G.screen(d), "4.zuordnung", d.text(v))
    d.tap(v, "act:weiter")
    t.eq(G.screen(d), "5.pruefen", d.text(v))
  end },
  { "Ein Signal weniger oder mehr am Gleis verlangt die Bestaetigung erneut; die Pruefliste vor dem Aktivieren nennt sie", function()
    local h, z, d, v = ui()
    assign(d, v, 1, 3)
    assign(d, v, 2, 1)
    local wiz = d.node.setup.session().wiz
    assert(wiz.guided_order_confirm(row_of(wiz, "Gleis 1").track))
    t.eq(#wiz.order_problems(), 0)
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:signal_loesen")
    t.eq(#row_of(wiz, "Gleis 1").signals, 2)
    t.eq(row_of(wiz, "Gleis 1").order_ok, false)
    local open = wiz.order_problems()
    t.eq(#open, 1); t.eq(open[1].name, "Gleis 1"); t.eq(open[1].count, 2)
    local found = false
    for _, w in ipairs(wiz.warnings()) do if w.code == "signal_reihenfolge" then found = true end end
    t.ok(found, "die Warnungen vor dem Aktivieren nennen die Reihenfolge")
    d.tap(v, "act:weiter")
    t.contains(d.text(v), "Reihenfolge der 2 Signale")
    -- bei einem einzigen Signal gibt es nichts zu bestaetigen
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:signal_loesen")
    t.eq(#wiz.order_problems(), 0)
    local ok, why = wiz.guided_order_confirm(row_of(wiz, "Gleis 1").track)
    t.eq(ok, false); t.contains(why, "keine Reihenfolge")
  end },
  { "Oberflaeche: die Auswahl springt zum Gleis mit offener Reihenfolge; Hoch/Runter gibt es nur bei mehreren Signalen; Bestaetigen nur einmal", function()
    local h, z, d, v = ui()
    assign(d, v, 1, 3)
    assign(d, v, 2, 1)           -- zuletzt Gleis 2 bearbeitet: Gleis 1 hat noch eine offene Reihenfolge
    d.node.render()
    t.contains(d.text(v), "> Gleis 1")
    -- Gleis 2 hat nur ein Signal: keine Reihenfolge-Tasten
    d.tap(v, "sel:zuordnung:2")
    d.tap(v, "act:signal_details")
    d.node.render()
    t.ok(not d.has(v, "Hoch"), d.text(v))
    t.ok(not d.has(v, "Runter"), d.text(v))
    t.ok(not d.has(v, "Reihenf."), d.text(v))
    d.tap(v, "act:zurueck")
    -- Gleis 1: bestaetigen, ein zweites Mal ist gesperrt
    d.tap(v, "sel:zuordnung:1")
    d.tap(v, "act:signal_details")
    d.tap(v, "act:d_reihenfolge")
    t.contains(v.hint, "bestaetigt")
    d.tap(v, "act:d_reihenfolge")
    t.contains(v.hint, "schon bestaetigt")
  end },
  { "Verschieben und Bestaetigen: unbekanntes Signal und unbekanntes Gleis werden abgelehnt", function()
    local h, z, d, v = ui()
    assign(d, v, 1, 2)
    local wiz = d.node.setup.session().wiz
    local ok, why = wiz.guided_signal_move("gibtsnicht", 1)
    t.eq(ok, false); t.contains(why, "zu keinem Gleis")
    ok, why = wiz.guided_order_confirm("gibtsnicht")
    t.eq(ok, false); t.contains(why, "gibt es nicht")
  end },
  { "Anzeige: Node und Leitstelle zeigen Lage und Nachbarn; Gleise mit einem Signal bekommen keine Nummer", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local tracks = {}
    for i = 1, 2 do
      local sigs = {}
      for j = 1, (i == 1) and 5 or 1 do sigs[j] = string.format("Sig_%d_%d", i, j) end
      tracks[i] = { name = "Gleis " .. i, signals = sigs, signal_info = { use = "strecke", effect = "Ostbahnhof", place = "mitte" },
        dir = { id = string.format("A%04d", i), area = "B0001", direction = "Ostbahnhof", rev = 1 } }
      tracks[i].order_ok = true
    end
    local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle", tracks = tracks, area = "B0001", area_ends = { "Westbahnhof", "Ostbahnhof" } })
    h.step(40)
    local role = s.node.roles.signal
    local first, middle, last
    for _, sg in ipairs(role.signals) do
      if sg.device == "Sig_1_1" then first = sg elseif sg.device == "Sig_1_3" then middle = sg elseif sg.device == "Sig_1_5" then last = sg end
    end
    t.eq(first.pos, 1); t.eq(first.count, 5); t.eq(first.prev, "Westbahnhof"); t.eq(first.next, "Sig_1_2")
    t.eq(middle.pos, 3); t.eq(middle.prev, "Sig_1_2"); t.eq(middle.next, "Sig_1_4")
    t.eq(last.pos, 5); t.eq(last.prev, "Sig_1_4"); t.eq(last.next, "Ostbahnhof")
    local single = role.signals[6]
    t.eq(single.count, 1)
    -- Seite der Node
    local v = H.open_page(s, "signale")
    s.node.render()
    local text = s.text(v)
    t.contains(text, "Signal 1/5")
    t.contains(text, "Sig_1_1 (1/5) zwischen Westbahnhof und Sig_1_2")
    t.ok(not text:find("Signal 1/1", 1, true), "ein einzelnes Signal bekommt keine Nummer")
    s.tap(v, "sel:signale:3")
    s.node.render()
    t.contains(s.text(v), "Sig_1_3 (3/5) zwischen Sig_1_2 und Sig_1_4")
    s.tap(v, "sel:signale:6")
    s.node.render()
    t.ok(not s.text(v):find("zwischen", 1, true), "ein einzelnes Signal hat keine Lagezeile: " .. s.text(v))
    -- Leitstelle
    local rows = z.node.roles.zentrale.signal_overview()
    t.eq(#rows, 6)
    local seen = {}
    for _, r in ipairs(rows) do seen[r.signal.id] = r end
    local found
    for _, r in ipairs(rows) do if r.pos == 3 then found = r end end
    t.eq(found.count, 5); t.eq(found.prev, "Sig_1_2"); t.eq(found.next, "Sig_1_4")
    local zv = H.open_page(z, "signale")
    z.node.render()
    t.contains(z.text(zv), "Gleis 1: 1/5 zwischen Westbahnhof und Sig_1_2")
    z.tap(zv, "sel:signale:3")
    z.node.render()
    t.contains(z.text(zv), "Gleis 1: 3/5 zwischen Sig_1_2 und Sig_1_4")
    z.tap(zv, "sel:signale:6")
    z.node.render()
    t.ok(not z.text(zv):find("zwischen", 1, true), "ein einzelnes Signal hat keine Lagezeile: " .. z.text(zv))
    -- die Reihenfolge der Zeilen folgt der Lage im Gleis
    local order = {}
    for _, r in ipairs(rows) do if r.count == 5 then order[#order + 1] = r.pos end end
    t.eq(table.concat(order, ","), "1,2,3,4,5")
  end },
  { "Ohne bekannte Anschlussnamen (aelterer Entwurf) nennt die Anzeige trotzdem die Nachbarsignale", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local s = h.add_node({ id = "strecke", roles = { "signal" }, central = "hauptstelle",
      tracks = { { name = "Gleis 1", signals = { "Sig_A", "Sig_B" } } } })
    h.step(30)
    local role = s.node.roles.signal
    t.eq(role.signals[1].prev, nil); t.eq(role.signals[1].next, "Sig_B")
    t.eq(role.signals[2].prev, "Sig_A"); t.eq(role.signals[2].next, nil)
    local v = H.open_page(s, "signale")
    s.node.render()
    t.contains(s.text(v), "Sig_A (1/2) zwischen ? und Sig_B")
  end },
}
