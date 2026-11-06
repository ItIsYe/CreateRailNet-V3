--[[
Purpose: Textgroesse eines Monitors von Hand umschalten (1,0 und 0,5): Taste auf der Geraete-Seite fuer den gewaehlten Monitor, der Wert wird in der Konfiguration gespeichert (devices[id].text_scale) und beim Start angewendet; ein Monitor ohne gespeicherten Wert bleibt, wie er ist. Dazu der Fake-Monitor mit Bloecken (Raster nach docs/MESSWERTE.md Q02).
]]

local t = dofile("tests/lib/t.lua")
local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local storelib = require("core.store")
local model = require("setup.model")

-- Computer mit einem Monitor aus bw x bh Bloecken (Textgroesse 1,0 beim Einbau); saved: bereits gespeicherte Textgroesse oder nil
local function setup(bw, bh, saved, plain)
  local w = create.world()
  w.add_modem("left", true)
  local screen = plain and screenlib.new(71, 33) or screenlib.new(1, 1, { blocks = { bw, bh } })
  -- Fake-Bildschirm mit Raster fuer Bloecke: Groesse bei 1,0 ist 'screen.getSize()' nach dem ersten Setzen
  if not plain then screen.setTextScale(1) end
  local sw, sh = screen.getSize()
  w.add_monitor("monitor_0", sw, sh)
  local d = drv.new({ world = w, monitors = { monitor_0 = screen } })
  d.restart()
  local cfg = model.new("Westbahnhof", { "passagierbahnhof" }, { name = "Testnetz", central_id = "hauptstelle" })
  local id = model.add_device(cfg, "monitor", "monitor_0")
  if saved then cfg.devices[id].text_scale = saved end
  cfg.status = "aktiv"
  storelib.new(d.fs).save("/crn_data/config.lua", cfg)
  d.restart()
  return d, screen, id
end

local function saved_scale(d, id)
  return storelib.new(d.fs).load("/crn_data/config.lua").devices[id].text_scale
end

-- Eintrag in der Liste der Geraete-Seite waehlen (auch im grossen Layout, wo ein Eintrag drei Zeilen hat)
local function select_device(d, v, name)
  d.node.render()
  local rows = v.target.rows()
  for _, a in ipairs(v.touch.areas) do
    if a.id:find("^sel:geraete:") then
      for y = a.y, a.y + (a.h or 1) - 1 do
        if rows[y] and rows[y]:find(name, 1, true) then
          v.handle(v.name and { "monitor_touch", v.name, a.x, a.y } or { "mouse_click", 1, a.x, a.y })
          d.node.render()
          return
        end
      end
    end
  end
  error("kein Eintrag " .. name .. "\n" .. v.target.text(), 2)
end

return {
  { "Fake-Monitor: Raster nach Bloecken und Textgroesse, ungueltige Werte werden abgelehnt", function()
    local s = screenlib.new(7, 5, { blocks = { 1, 1 } })
    s.setTextScale(1)
    local w, h = s.getSize()
    t.eq(w .. "x" .. h, "7x5")
    s.setTextScale(0.5)
    w, h = s.getSize()
    t.eq(w .. "x" .. h, "15x10")
    local big = screenlib.new(1, 1, { blocks = { 7, 5 } })
    big.setTextScale(1)
    t.eq(select(1, big.getSize()) .. "x" .. select(2, big.getSize()), "71x33")
    big.setTextScale(0.5)
    t.eq(select(1, big.getSize()) .. "x" .. select(2, big.getSize()), "143x67")
    t.eq(big.getTextScale(), 0.5)
    t.raises(function() big.setTextScale(0.3) end, "Expected number in range")
    t.raises(function() big.setTextScale(6) end, "Expected number in range")
    t.raises(function() big.setTextScale("1") end, "number expected")
  end },
  { "Taste auf der Geraete-Seite: gewaehlter Monitor wechselt von 1,0 auf 0,5 und zurueck, gespeichert in der Konfiguration", function()
    local d, screen, id = setup(5, 4)
    local tv, mv = d.view(), d.view("monitor_0")
    t.eq(select(1, screen.getSize()) .. "x" .. select(2, screen.getSize()), "50x26")
    t.eq(mv.layout.mode, "status", "5x4 Bloecke bei 1,0 sind zu klein fuer die Bedienung")
    d.tap(tv, "nav:geraete")
    select_device(d, tv, "monitor_0")
    t.ok(d.has(tv, "Textgroesse 0,5"), "die Taste nennt, was sie einstellt")
    d.tap(tv, "act:textgroesse")
    d.node.render()
    t.eq(screen.getTextScale(), 0.5)
    t.eq(select(1, screen.getSize()) .. "x" .. select(2, screen.getSize()), "100x52")
    t.eq(mv.layout.mode, "gross", "mit 0,5 reicht derselbe Monitor fuer das grosse Layout")
    t.eq(saved_scale(d, id), 0.5, "in der Konfiguration gespeichert")
    t.ok(d.has(tv, "monitor_0: Textgroesse 0,5, 100x52 Zeichen."), "Rueckmeldung im Hinweis, ganz lesbar: " .. d.text(tv))
    t.ok(d.has(tv, "Textgroesse 1,0"), "die Taste bietet jetzt den Rueckweg an")
    d.tap(tv, "act:textgroesse")
    d.node.render()
    t.eq(screen.getTextScale(), 1)
    t.eq(mv.layout.mode, "status")
    t.eq(saved_scale(d, id), 1)
  end },
  { "Nach einem Neustart gilt die gespeicherte Textgroesse wieder", function()
    local d, screen = setup(5, 4, 0.5)
    t.eq(screen.getTextScale(), 0.5, "beim Start angewendet")
    t.eq(d.view("monitor_0").layout.mode, "gross")
  end },
  { "Ein Monitor ohne gespeicherten Wert bleibt, wie er ist (von Hand gesetzte Textgroesse wird nicht ueberschrieben)", function()
    local d, screen = setup(5, 4)
    screen.setTextScale(0.5)
    d.restart()
    t.eq(screen.getTextScale(), 0.5)
    t.eq(d.view("monitor_0").layout.mode, "gross")
  end },
  { "Die Taste ist gesperrt und nennt den Grund, solange kein Monitor gewaehlt ist", function()
    local d, screen = setup(5, 4)
    local tv = d.view()
    d.tap(tv, "nav:geraete")
    select_device(d, tv, "left")
    d.tap(tv, "act:textgroesse")
    t.ok(d.has(tv, "Erst einen Monitor in der Liste waehlen."), "der Hinweis nennt den Grund: " .. d.text(tv))
    t.eq(screen.getTextScale(), 1, "nichts verstellt")
  end },
  { "Am Monitor selbst (kompaktes Layout) geht es auch", function()
    local d, screen, id = setup(7, 5)
    local mv = d.view("monitor_0")
    t.eq(mv.layout.mode, "kompakt", "7x5 Bloecke bei 1,0 sind 71x33")
    d.tap(mv, "nav:geraete")
    select_device(d, mv, "monitor_0")
    d.tap(mv, "act:textgroesse")
    d.node.render()
    t.eq(screen.getTextScale(), 0.5)
    t.eq(mv.layout.mode, "gross", "143x67")
    t.eq(saved_scale(d, id), 0.5)
  end },
  { "Ein Monitor, der setTextScale nicht kann, wird nicht angefasst, die Taste nennt den Grund", function()
    local d, screen, id = setup(7, 5, nil, true)
    local tv = d.view()
    d.tap(tv, "nav:geraete")
    select_device(d, tv, "monitor_0")
    d.tap(tv, "act:textgroesse")
    t.ok(d.has(tv, "Textgroesse geht an diesem Monitor nicht."), "Grund im Hinweis: " .. d.text(tv))
    t.eq(saved_scale(d, id), nil, "nichts gespeichert")
  end },
  { "Geraeteliste im grossen Layout zeigt Raster und Textgroesse des Monitors", function()
    local d = setup(7, 5, 0.5)
    local mv = d.view("monitor_0")
    d.tap(mv, "nav:geraete")
    t.ok(d.has(mv, "143x67 Zeichen, Textgroesse 0,5"), d.text(mv))
  end },
}
