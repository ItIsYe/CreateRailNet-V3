--[[
Purpose: Texte mit Gleisnamen und Titelzeile: ein Gleis heisst im Assistenten schon "Gleis 1", der Satz darf das Wort nicht noch einmal davorsetzen ("Gleis Gleis 1"); lange Fragen auf den Listenseiten werden umgebrochen statt abgeschnitten; ein Node ohne Namen zeigt "neue Node" statt eines leeren Titels.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")
local model = require("setup.model")
local label = require("core.label")
local storelib = require("core.store")

-- Bahnhof ueber das Netzverzeichnis einrichten bis zum Gleis-Bildschirm (Name und Create-Bahnhof, wie in test_einrichtung_bahnhof)
local function station_flow()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local d = h.add_blank({ id = "neu", stations = { "Hof A", "Hof B" } })
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap_row(v, "rollen", "Passagierbahnhof"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter"); h.step(3); d.node.render()
  d.tap_row(v, "geraete", "Create_Station_1"); d.tap(v, "act:weiter")
  d.tap(v, "act:neues_gleis")
  return h, d, v
end

return {
  { "label.track: das Wort steht genau einmal", function()
    t.eq(label.track("Gleis 1"), "Gleis 1")
    t.eq(label.track("gleis 2"), "gleis 2")
    t.eq(label.track("Bahnsteig 3"), "Bahnsteig 3")
    t.eq(label.track("Westbahnhof Gleis 2"), "Westbahnhof Gleis 2")
    t.eq(label.track("3"), "Gleis 3")
    t.eq(label.track("Nord"), "Gleis Nord")
    t.eq(label.track(nil), "Gleis ")
  end },

  { "Einrichtung Bahnhof: Fragen nennen das Gleis einmal und sind nicht abgeschnitten", function()
    local h, d, v = station_flow()
    local text = d.text(v)
    -- ein Bildschirm fuer Name und Create-Bahnhof: der Name steht im Feld, die Frage nennt das Gleis nicht noch einmal
    t.contains(text, "Gleisname")
    t.contains(text, "Welcher Create-Bahnhof gehoert zum Gleis?")
    t.contains(text, "Create_Station_1")
    t.not_contains(text, "Gleis Gleis")
    t.not_contains(text, "Richtung")
    -- nach dem Bahnhof gibt es keine Frage nach einem Ausgang mehr
    d.tap_row(v, "bahnhof", "Create_Station_1"); d.tap(v, "act:weiter")
    t.not_contains(d.text(v), "Welcher Ausgang")
  end },

  { "Pruefmeldungen und Texte der Einrichtung: kein doppeltes Gleis", function()
    local c = model.new("Hof", { "passagierbahnhof" }, { name = "Netz" })
    local tid = model.add_track(c, "Gleis 1")
    local texts = {}
    for _, p in ipairs(model.validate(c, {})) do texts[#texts + 1] = p.text end
    local joined = table.concat(texts, "\n")
    t.contains(joined, "Gleis 1 hat keinen Bahnhof.")
    t.not_contains(joined, "Gleis Gleis")
    local c2 = model.new("Hof", { "passagierbahnhof" }, { name = "Netz" })
    model.add_track(c2, "Nord")
    local joined2 = {}
    for _, p in ipairs(model.validate(c2, {})) do joined2[#joined2 + 1] = p.text end
    t.contains(table.concat(joined2, "\n"), "Gleis Nord hat keinen Bahnhof.")
  end },

  { "Quelltext: kein Satz setzt das Wort Gleis vor einen Gleisnamen (label.track benutzen)", function()
    local bad = {}
    local pipe = io.popen("ls src/*/*.lua")
    for path in pipe:lines() do
      local fh = io.open(path, "rb"); local source = fh:read("*a"); fh:close()
      if path == "src/core/label.lua" then source = "" end
      local number = 0
      for line in (source .. "\n"):gmatch("(.-)\n") do
        number = number + 1
        if line:find('Gleis " %.%. [%w_%.%[%]%(%)]*[nN]ame') and not line:find("label.track", 1, true) and not line:find('name = "Gleis "', 1, true)
          and not line:find('same(t.name', 1, true) and not line:find("add_track(", 1, true) then
          bad[#bad + 1] = path .. ":" .. number
        end
      end
    end
    pipe:close()
    t.eq(#bad, 0, "label.track fehlt: " .. table.concat(bad, ", "))
  end },

  { "Titelzeile: Node ohne Namen zeigt ihre Kennung, ein langer Name bleibt ganz (die Rolle entfaellt zuerst)", function()
    local h = H.new()
    local s = h.add_node({ id = "strecke", roles = { "passagierbahnhof" }, tracks = { { name = "Gleis 1", station_name = "Westbahnhof" } } })
    local store = storelib.new(s.fs)
    local config = store.load("/crn_data/config.lua")
    config.node.name = ""
    config.status = "aktiv"
    store.save("/crn_data/config.lua", config)
    s.restart()
    local v = s.view()
    local first = s.text(v):match("^[^\n]*")
    t.contains(first, config.node.id .. " - passagierbahnhof")
    t.not_contains(first, "  - ")
    t.not_contains(first, "neue Node")
    config.node.name = "Personenbahnhof Hauptbahnhof N0001"
    store.save("/crn_data/config.lua", config)
    s.restart()
    first = s.text(s.view()):match("^[^\n]*")
    t.contains(first, "Personenbahnhof Hauptbahnhof N0001")
    t.not_contains(first, "~")
  end },
}
