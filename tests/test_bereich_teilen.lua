--[[
Purpose: Bereich aufteilen (Konzept 10.3): Gleise wechseln mit unveraenderter Kennung in einen neuen Bereich, Richtungen ziehen mit, Nodes mit allen Gleisen gehen mit, eine Node mit Gleisen auf beiden Seiten verhindert es; die aktive Signal-Node erfaehrt es im Abgleich und uebernimmt Bereich und Label.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local netzlib = require("domain.netz")

local function netz_with_area()
  local netz = netzlib.new({})
  assert(netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 }))   -- A0001/A0002 Ost, A0003/A0004 West
  return netz
end

return {
  { "Aufteilen: Kennungen und Stand bleiben, Richtungen werden auf die neuen Anschluesse abgebildet, beide Bereiche sind danach normal bearbeitbar", function()
    local netz = netz_with_area()
    local rev = netz.area("B0001").rev
    local new_area = assert(netz.split_area("B0001", { name = "Ost-Mitte", ends = { "Mitte", "Ost" }, tracks = { "A0002", "A0003" } }))
    t.eq(new_area, "B0002")
    local old, new = netz.area("B0001"), netz.area("B0002")
    t.eq(#old.tracks, 2); t.eq(old.tracks[1].id, "A0001"); t.eq(old.tracks[2].id, "A0004")
    t.eq(#new.tracks, 2); t.eq(new.tracks[1].id, "A0002"); t.eq(new.tracks[2].id, "A0003")
    t.eq(new.tracks[1].direction, "Ost", "Anschluss 2 des alten Bereichs ist Anschluss 2 des neuen")
    t.eq(new.tracks[2].direction, "Mitte", "Anschluss 1 des alten ist Anschluss 1 des neuen")
    t.eq(old.tracks[1].direction, "Ostbahnhof")
    t.ok(old.rev > rev)
    t.eq(new.tracks[1].name, "Gleis 2", "Gleisnamen bleiben")
    assert(netz.set_end("B0002", 1, { kind = "bereich", ref = "B0001" }))
    assert(netz.add_track("B0002", "Zusatz", "Ost"))
    assert(netz.set_track("A0002", { name = "Umbenannt" }))
  end },
  { "Aufteilen: Fehler aendern nichts (leere Liste, fremdes oder doppeltes Gleis, alle Gleise, Name, Anschluesse, Stand)", function()
    local netz = netz_with_area()
    assert(netz.add_area({ name = "Nord-Sued", ends = { "Nord", "Sued" }, count = 1 }))              -- A0005
    local ser = require("core.ser")
    local before = ser.encode({ netz.areas(), netz.area("B0001"), netz.revision() })
    local function bad(spec, expect, why)
      local r, err = netz.split_area("B0001", spec)
      t.eq(r, nil, why); t.contains(err, expect)
      t.eq(ser.encode({ netz.areas(), netz.area("B0001"), netz.revision() }), before, "unveraendert: " .. why)
    end
    bad({ name = "X", ends = { "A", "B" }, tracks = {} }, "fehlen", "leer")
    bad({ name = "X", ends = { "A", "B" }, tracks = { "A0099" } }, "gehoert nicht", "unbekannt")
    bad({ name = "X", ends = { "A", "B" }, tracks = { "A0005" } }, "gehoert nicht", "Gleis eines anderen Bereichs")
    bad({ name = "X", ends = { "A", "B" }, tracks = { "A0001", "A0001" } }, "doppelt", "doppelt")
    bad({ name = "X", ends = { "A", "B" }, tracks = { "A0001", "A0002", "A0003", "A0004" } }, "mindestens ein Gleis behalten", "alle")
    bad({ name = "West-Ost", ends = { "A", "B" }, tracks = { "A0001" } }, "gibt es schon", "Name belegt")
    bad({ name = "X", ends = { "A", "A" }, tracks = { "A0001" } }, "verschiedene Namen", "gleiche Anschluesse")
    bad({ name = "X", ends = { "A", "B" }, tracks = { "A0001" }, if_rev = 99 }, "inzwischen geaendert", "veralteter Stand")
    local r, err = netz.split_area("B0099", { name = "X", ends = { "A", "B" }, tracks = { "A0001" } })
    t.eq(r, nil); t.contains(err, "gibt es nicht")
  end },
  { "Nodes: wer alle Gleise abgibt, geht mit (neues Label); wer auf beiden Seiten betreut, verhindert das Aufteilen", function()
    local netz = netz_with_area()
    local both = assert(netz.claim_node({ claim = "teilen-claim-1", role = "signal", area = "B0001", tracks = { "A0001", "A0002" } }))
    local r, err = netz.split_area("B0001", { name = "Ost-Mitte", ends = { "Mitte", "Ost" }, tracks = { "A0002" } })
    t.eq(r, nil); t.contains(err, both.id); t.contains(err, "beiden Seiten")
    local ok = assert(netz.split_area("B0001", { name = "Ost-Mitte", ends = { "Mitte", "Ost" }, tracks = { "A0001", "A0002" } }))
    t.eq(ok, "B0002")
    local node = netz.node(both.id)
    t.eq(node.area, "B0002"); t.eq(node.label, both.id .. " | SIG | B0002")
    -- eine Node im verbleibenden Teil bleibt
    local netz2 = netz_with_area()
    local keep = assert(netz2.claim_node({ claim = "teilen-claim-2", role = "depot", area = "B0001", tracks = { "A0003", "A0004" } }))
    assert(netz2.split_area("B0001", { name = "Rest", ends = { "A", "B" }, tracks = { "A0001", "A0002" } }))
    t.eq(netz2.node(keep.id).area, "B0001"); t.eq(netz2.node(keep.id).label, keep.label)
    -- verworfene Anforderungen halten nichts auf
    local netz3 = netz_with_area()
    local gone = assert(netz3.claim_node({ claim = "teilen-claim-3", role = "signal", area = "B0001", tracks = { "A0001", "A0002" } }))
    assert(netz3.discard_node(gone.id))
    assert(netz3.split_area("B0001", { name = "Teil", ends = { "A", "B" }, tracks = { "A0002" } }))
  end },
  { "Seite Assistent 'teilen': Bereich, Gleise nach Name oder Nummer, Fehlertexte", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    h.step(2)
    local netz = z.node.roles.zentrale.netz
    netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 })
    local v = H.open_page(z, "assistent")
    local function fill(name, ends, gleise)
      z.tap(v, "act:neu")
      z.type(v, "vorlage", "teilen"); z.type(v, "name", name); z.type(v, "anschluesse", ends)
      z.tap(v, "act:f_weiter"); z.type(v, "gleise", gleise)
      z.tap(v, "act:f_speichern")
    end
    fill("Ost-Mitte", "Mitte; Ost", "Falsch")
    t.contains(v.hint, "Gleise: Bereich: Gleis 3"); z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    fill("Ost-Mitte", "Mitte; Ost", "Unbekannt: Gleis 3")
    t.contains(v.hint, "gibt es nicht"); z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    fill("Ost-Mitte", "Mitte; Ost", "West-Ost: Gleis 9")
    t.contains(v.hint, "Gleis '"); z.tap(v, "act:f_zurueck"); z.tap(v, "act:f_zurueck")
    fill("Ost-Mitte", "Mitte; Ost", "west-ost: Gleis 3; 4")
    t.eq(#netz.areas(), 2, v.hint)
    t.eq(netz.area("B0002").tracks[1].id, "A0003"); t.eq(#netz.area("B0001").tracks, 2)
  end },
  { "Abgleich: die aktive Signal-Node erfaehrt, dass sie jetzt zu einem anderen Bereich gehoert, und uebernimmt Bereich und Label", function()
    local h = H.new()
    local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
    local netz = z.node.roles.zentrale.netz
    netz.add_area({ name = "West-Ost", ends = { "Westbahnhof", "Ostbahnhof" }, count = 4 })
    local claim = "abgleich-claim-1"
    local entry = assert(netz.claim_node({ claim = claim, role = "signal", area = "B0001", tracks = { "A0003", "A0004" } }))
    local s = h.add_node({
      id = entry.id, roles = { "signal" }, central = "hauptstelle", area = "B0001", area_ends = { "Westbahnhof", "Ostbahnhof" }, claim = claim, label = entry.label,
      tracks = {
        { name = "Gleis 3", signals = { "Sig_3" }, signal_info = { use = "strecke", effect = "Westbahnhof", place = "Westbahnhof" }, dir = { id = "A0003", area = "B0001", direction = "Westbahnhof", rev = 1 } },
        { name = "Gleis 4", signals = { "Sig_4" }, signal_info = { use = "strecke", effect = "Westbahnhof", place = "Westbahnhof" }, dir = { id = "A0004", area = "B0001", direction = "Westbahnhof", rev = 1 } },
      },
    })
    local role = s.node.roles.signal
    h.step(40)
    t.eq(role.sync.state, "gleich")
    assert(netz.split_area("B0001", { name = "Mitte-West", ends = { "Westbahnhof", "Mitte" }, tracks = { "A0003", "A0004" } }))
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "abweichend", tostring(role.sync.note))
    t.eq(role.sync.diffs[1].kind, "bereich")
    t.contains(role.describe_difference(role.sync.diffs[1]), "Mitte-West")
    t.eq(s.node.config.node.area, "B0001", "noch nichts geaendert")
    local v = H.open_page(s, "signale")
    s.tap(v, "act:abgleich")
    t.contains(v.hint, "uebernommen")
    t.eq(s.node.config.node.area, "B0002"); t.eq(s.node.config.node.area_ends[2], "Mitte")
    t.eq(s.node.config.node.label, entry.id .. " | SIG | B0002"); t.eq(s.label, entry.id .. " | SIG | B0002")
    for _, tr in pairs(s.node.config.tracks) do t.eq(tr.dir.area, "B0002") end
    assert(role.sync_request()); h.step(4)
    t.eq(role.sync.state, "gleich", tostring(role.sync.note))
  end },
}
