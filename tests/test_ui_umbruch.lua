--[[
Purpose: Texte werden an die Breite des Bildschirms angepasst, nicht auf eine feste Zahl gekuerzt: die Kopfzeile richtet sich nach der Breite der Ansicht (Name und Kennung bleiben lesbar, zuerst entfaellt die Rolle), und in Listen des grossen Layouts werden lange Titel und Einzelheiten umgebrochen statt mit "~" abgeschnitten.
]]

local t = dofile("tests/lib/t.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local storelib = require("core.store")
local viewlib = require("ui.view")
local W = require("ui.widgets")

local function node_with_name(name, monitor_w, monitor_h)
  local w = create.world()
  w.add_modem("left", true)
  if monitor_w then w.add_monitor("monitor_0", monitor_w, monitor_h) end
  local monitors = monitor_w and { monitor_0 = screenlib.new(monitor_w, monitor_h) } or {}
  local d = drv.new({ world = w, monitors = monitors })
  d.restart()
  local model = require("setup.model")
  local cfg = model.new(name, { "bahnhof" }, { name = "Testnetz", central_id = "hauptstelle" })
  if monitor_w then model.add_device(cfg, "monitor", "monitor_0") end
  cfg.status = "aktiv"
  storelib.new(d.fs).save("/crn_data/config.lua", cfg)
  d.restart()
  return d
end

-- Kopfbereich: eine Zeile im kompakten, drei im grossen Layout
local function first_row(v)
  local rows = v.target.rows()
  return table.concat(rows, "\n", 1, v.layout.header.h)
end

local function list_view(w, h, items)
  local screen = screenlib.new(w, h)
  local v = viewlib.new({
    target = screen,
    ctx = { title = function() return "Test" end, status = function() return { text = "Bereit", kind = "ok" } end },
    pages = { {
      id = "liste", title = "Liste",
      render = function(view, rect)
        local state = view.page_state("liste")
        state.list = state.list or { index = 1 }
        W.list(view, "l", rect, items, state.list)
      end,
    } },
  })
  v.render()
  return v, screen
end

local function rows_text(screen) return table.concat(screen.rows(), "\n") end

local function count_rows(screen, needle)
  local n = 0
  for _, row in ipairs(screen.rows()) do if row:find(needle, 1, true) then n = n + 1 end end
  return n
end

return {
  { "Kopfzeile am PC-Terminal (51 Zeichen): lange Namen bleiben ganz, die Rolle entfaellt zuerst", function()
    local d = node_with_name("Personenbahnhof N0001 Nord", nil)
    local row = first_row(d.view())
    t.ok(row:find("Personenbahnhof N0001 Nord", 1, true), "Name und Kennung vollstaendig: " .. row)
    t.ok(not row:find("~", 1, true), "nichts gekuerzt: " .. row)
  end },
  { "Kopfzeile am Monitor (100 Zeichen): Name und Rolle stehen ganz da, wo der Platz reicht", function()
    local d = node_with_name("Personenbahnhof N0001 Nord", 100, 40)
    local row = first_row(d.view("monitor_0"))
    t.ok(row:find("Personenbahnhof N0001 Nord - bahnhof", 1, true), "Name und Rolle: " .. row)
    t.ok(not row:find("~", 1, true), "nichts gekuerzt")
  end },
  { "Kopfzeile: kurzer Name behaelt die Rolle auch am PC-Terminal", function()
    local d = node_with_name("Westbahnhof", nil)
    t.ok(first_row(d.view()):find("Westbahnhof - bahnhof", 1, true))
  end },
  { "Kopfzeile: ein Name, der auch allein nicht passt, wird als Letztes gekuerzt", function()
    local d = node_with_name("Ein sehr langer Name fuer einen Bahnhof am Rand der Welt", nil)
    local row = first_row(d.view())
    t.ok(row:find("~", 1, true), "gekuerzt: " .. row)
    t.ok(row:find("Ein sehr langer Name", 1, true))
  end },
  { "Liste im grossen Layout: lange Einzelheit wird auf zwei Zeilen umgebrochen", function()
    local detail = "wartet: Kein geeignetes Gleis fuer Weizenhof (Weizenhof: dem Auftrag A-1 zugewiesenes Gleis ist belegt, naechster Versuch folgt)"
    local _, screen = list_view(100, 40, { { text = "A-3 Rundreise Hof", detail = detail } })
    local all = rows_text(screen)
    t.ok(not all:find("~", 1, true), "nichts gekuerzt")
    t.ok(all:find("wartet: Kein geeignetes Gleis fuer Weizenhof", 1, true))
    t.ok(all:find("naechster Versuch folgt)", 1, true), "das Ende der Begruendung steht auch da")
  end },
  { "Liste im grossen Layout: langer Titel wird umgebrochen, Einzelheit bleibt sichtbar", function()
    local text = "Unerwarteter Zug Fremdzug auf Gleis gleis2 (depot). Er wird als Belegung beachtet, aber keinem Auftrag zugeordnet."
    local _, screen = list_view(100, 40, { { text = text, detail = "neu" } })
    local all = rows_text(screen)
    t.ok(not all:find("~", 1, true), "nichts gekuerzt")
    t.ok(all:find("keinem Auftrag zugeordnet.", 1, true))
    t.ok(all:find("neu", 1, true))
  end },
  { "Liste im grossen Layout: passt alles, bleibt das Aussehen (Einzelheit direkt unter dem Titel)", function()
    local _, screen = list_view(100, 40, { { text = "Signal 1", detail = "rot" } })
    local title_row, detail_row
    for y, row in ipairs(screen.rows()) do
      if row:find("> Signal 1", 1, true) then title_row = y end
      if row:find("rot", 1, true) and y > 4 then detail_row = y end
    end
    t.ok(title_row and detail_row and detail_row == title_row + 1, "Einzelheit direkt unter dem Titel")
  end },
  { "Liste im grossen Layout: ueberlanger Text wird erst nach dem Umbruch gekuerzt", function()
    local detail = string.rep("sehr lange Begruendung ", 20)
    local _, screen = list_view(100, 40, { { text = "Eintrag", detail = detail } })
    t.ok(rows_text(screen):find("~", 1, true), "nur der Rest hinter dem Umbruch ist gekuerzt")
    t.ok(count_rows(screen, "Begruendung") >= 2, "mehrere Zeilen der Begruendung sichtbar")
  end },
  { "Liste im kompakten Layout bleibt einzeilig (Umbruch nur im grossen)", function()
    local detail = string.rep("lang ", 30)
    local _, screen = list_view(51, 19, { { text = "Eintrag", detail = detail } })
    t.eq(count_rows(screen, "lang"), 1, "eine Zeile")
  end },
}
