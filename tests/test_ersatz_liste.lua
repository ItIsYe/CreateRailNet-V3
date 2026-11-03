--[[
Purpose: Ersatzcomputer waehlt die zu ersetzende Node aus einer Liste der Nodes mit Sicherung (Konzept 11.4): Zustand (aktiv, ausgefallen, stillgelegt), Seiten, unbeglaubigte Antworten, Abbruch.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local w = h.add_node({
    id = "weizenhof", roles = { "gueterbahnhof", "anmeldung" }, central = "hauptstelle", registration = "Gleis 1",
    tracks = { { name = "Gleis 1", station_name = "Weizenhof", release_side = "back", known = { Zentrallager = 100, Weizenhof = 0 } } },
  })
  local l = h.add_node({
    id = "lager", roles = { "gueterbahnhof" }, central = "hauptstelle",
    tracks = { { name = "Gleis 1", station_name = "Zentrallager", release_side = "back", known = { Weizenhof = 100, Zentrallager = 0 } } },
  })
  h.sim({ { node = "weizenhof", name = "Weizenhof" }, { node = "lager", name = "Zentrallager" } }, 12)
  h.step(60)
  return h, z, w, l
end

local blank_count = 0
local function open_replace(h, z)
  blank_count = blank_count + 1
  local fresh = h.add_blank({ id = "neu" .. blank_count, stations = {} })
  local v = H.open_page(fresh, "einrichtung")
  fresh.tap(v, "act:ersatz")
  fresh.type(v, "r_central", "hauptstelle")
  return fresh, v
end

local function load_list(h, fresh, v)
  fresh.tap(v, "act:r_liste")
  h.step(4)
  fresh.node.render()
end

return {
  { "Liste zeigt die Nodes mit Sicherung samt Zustand; die Auswahl ersetzt das Tippen der Kennung", function()
    local h, z, w, l = build()
    local fresh, v = open_replace(h, z)
    load_list(h, fresh, v)
    t.ok(fresh.has(v, "weizenhof"), fresh.text(v))
    t.ok(fresh.has(v, "lager"), fresh.text(v))
    t.ok(fresh.has(v, "NOCH AKTIV"), "beide laufen noch: " .. fresh.text(v))
    local list = fresh.node.setup.session().replace_list
    t.eq(#list, 2, "nur Weizenhof und Lager haben eine Sicherung")
    for _, b in ipairs(list) do t.ok(b.id ~= "hauptstelle", "die Leitstelle selbst ist keine Auswahl") end
    -- Auswahl setzt die Kennung; der alte Computer laeuft noch, also lehnt die Leitstelle ab
    fresh.tap(v, "sel:r_wahl:2")
    fresh.node.render()
    t.ok(fresh.has(v, "(o)"), fresh.text(v))
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "noch aktiv"), fresh.text(v))
  end },
  { "Liste: ausgefallene und stillgelegte Node sind uebernehmbar, die Auswahl fuehrt zur Uebernahme", function()
    local h, z, w, l = build()
    local zentrale = z.node.roles.zentrale
    -- Lager faellt aus, Weizenhof wird stillgelegt
    l.node.handle = function() end
    h.step(75)
    t.eq(zentrale.retire("weizenhof"), true)
    local fresh, v = open_replace(h, z)
    load_list(h, fresh, v)
    t.ok(fresh.has(v, "ausgefallen"), fresh.text(v))
    t.ok(fresh.has(v, "stillgelegt"), fresh.text(v))
    t.ok(not fresh.has(v, "NOCH AKTIV"), fresh.text(v))
    fresh.tap(v, "sel:r_wahl:1")                      -- sortiert: lager vor weizenhof
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "empfangen"), fresh.text(v))
    fresh.tap(v, "act:r_uebernehmen")
    t.eq(fresh.node.setup.session().wiz.config.node.id, "lager", "die gewaehlte Node wird uebernommen")
  end },
  { "Liste braucht die Kennung der Leitstelle; Eingeben schaltet zurueck; Abbrechen verwirft die Liste", function()
    local h, z, w, l = build()
    local fresh = h.add_blank({ id = "neu", stations = {} })
    local v = H.open_page(fresh, "einrichtung")
    fresh.tap(v, "act:ersatz")
    fresh.tap(v, "act:r_liste")
    t.ok(fresh.has(v, "Kennung der Leitstelle"), fresh.text(v))
    t.eq(fresh.node.setup.session().replace_want, nil, "ohne Leitstelle wird nicht gefragt")
    fresh.type(v, "r_central", "hauptstelle")
    load_list(h, fresh, v)
    t.ok(fresh.node.setup.session().replace_list ~= nil)
    fresh.tap(v, "act:r_liste")                       -- "Eingeben"
    fresh.node.render()
    t.eq(fresh.node.setup.session().replace_list, nil)
    t.ok(fresh.has(v, "zu ersetzenden Node"), fresh.text(v))
    load_list(h, fresh, v)
    fresh.tap(v, "act:r_abbruch")
    t.eq(fresh.node.setup.session().replace, nil)
    t.eq(fresh.node.setup.session().replace_list, nil)
    t.eq(fresh.node.setup.session().replace_want, nil)
  end },
  { "Liste: mehrere Seiten werden vollstaendig geholt (nur Nodes mit Sicherung)", function()
    local h, z, w, l = build()
    local zentrale = z.node.roles.zentrale
    local fs = z.node.env.fs
    if not fs.exists("/crn_data/nodesich") then fs.makeDir("/crn_data/nodesich") end
    for i = 1, 14 do
      local id = string.format("alt%02d", i)
      zentrale.info().nodes[id] = { name = "Alt " .. i, last_seen = 0, roles = {}, tracks = {} }
      z.node.store.save("/crn_data/nodesich/" .. id .. ".lua", { revision = 1, config = {} })
    end
    zentrale.info().nodes.ohnesicherung = { name = "Ohne", last_seen = 0, roles = {}, tracks = {} }
    local fresh, v = open_replace(h, z)
    load_list(h, fresh, v)
    local list = fresh.node.setup.session().replace_list
    t.ok(list ~= nil, fresh.text(v))
    t.eq(#list, 16, "14 alte plus Weizenhof und Lager")
    local seen = {}
    for _, b in ipairs(list) do
      t.ok(not seen[b.id], "doppelt: " .. b.id)
      seen[b.id] = true
      t.ok(b.id ~= "ohnesicherung", "ohne Sicherung gehoert nicht in die Liste")
    end
    t.eq(list[1].id, "alt01")
    t.eq(list[16].id, "weizenhof")
  end },
  { "Liste: unbeglaubigte Antworten in falscher Form werden abgelehnt", function()
    local h, z, w, l = build()
    local zentrale = z.node.roles.zentrale
    local cases = {
      { { id = "x y", state = "aktiv" } },               -- Leerzeichen in der Kennung
      { { id = "alt01", state = "frei" } },              -- unbekannter Zustand
      { { id = string.rep("a", 31), state = "aktiv" } }, -- zu lang
      { { state = "aktiv" } },                           -- ohne Kennung
      { "text" },                                        -- kein Eintrag
    }
    -- ein Ersatzcomputer fragt nacheinander (gleiche vorlaeufige Kennung wie im Betrieb: eine Anfrage nach der anderen)
    local fresh, v = open_replace(h, z)
    for _, bad in ipairs(cases) do
      zentrale.handle_replace_list = function(m) z.node.reply(m, "ok", { backups = bad }) end
      load_list(h, fresh, v)
      t.eq(fresh.node.setup.session().replace_list, nil, "kein Ergebnis fuer eine falsche Antwort")
      t.ok(fresh.has(v, "Unerwartete Antwort"), fresh.text(v))
    end
    -- nach einer fehlgeschlagenen Liste zeigt "Holen" wieder den eigenen Zustand (nicht den alten Listenfehler)
    fresh.tap(v, "act:r_liste")                       -- erneut Liste -> bleibt Fehler
    fresh.type(v, "r_node", "gibtsnicht")
    fresh.tap(v, "act:r_holen")
    h.step(4)
    fresh.node.render()
    t.ok(fresh.has(v, "keine Sicherung"), fresh.text(v))
    t.ok(not fresh.has(v, "Unerwartete Antwort"), fresh.text(v))
    -- ein ungueltiger Name wird nur geleert, die Auswahl bleibt moeglich
    zentrale.handle_replace_list = function(m) z.node.reply(m, "ok", { backups = { { id = "alt01", name = "Na\"me<", state = "stillgelegt" } } }) end
    load_list(h, fresh, v)
    local list = fresh.node.setup.session().replace_list
    t.ok(list ~= nil and list[1].id == "alt01" and list[1].name == "", "Name geleert")
  end },
}
