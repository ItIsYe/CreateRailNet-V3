--[[
Purpose: Hilfen fuer Tests der Bedienoberflaeche: einen Node mit Fake-Welt, Terminal, Monitor und Funk aufbauen, Flaechen per Kennung oder Zeilentext antippen, in Felder tippen, den Bildschirm als Text lesen.
API: driver.new(opts) -> d; d.tap(view, id); d.tap_row(view, listid, text); d.type(view, fieldid, text); d.key(view, name); d.screen_has(screen, text); d.restart() -> neuer Node auf demselben Dateisystem
]]

local cc = dofile("tests/fakes/cc.lua")
local create = dofile("tests/fakes/create.lua")
local screenlib = dofile("tests/fakes/screen.lua")
local busLib = dofile("tests/fakes/bus.lua")

local M = {}

local KEYS = { tab = 258, enter = 257, backspace = 259, up = 265, down = 264, escape = 256, pageDown = 267, pageUp = 266 }

function M.new(opts)
  opts = opts or {}
  local d = {}
  d.world = opts.world or create.world()
  d.fs = opts.fs or cc.fs()
  d.bus = opts.bus or busLib.new()
  d.raw = { v = 0 }
  d.screen = opts.screen or screenlib.new(opts.width or 51, opts.height or 19)
  d.monitors = opts.monitors or {}
  d.queue = {}

  function d.restart()
    d.raw.v = 0
    local env = {
      fs = d.fs, peripheral = d.world.peripheral, redstone = d.world.redstone, rednet = d.bus.attach(opts.cid or 1),
      raw_clock = function() return d.raw.v end, term = d.screen, host = d.env_host or "CC test",
      wrap = function(name) return d.monitors[name] end,
      start_timer = function() return 1 end,
      pull_event = function()
        local ev = table.remove(d.queue, 1)
        if not ev then error("Terminated", 0) end
        return ev
      end,
    }
    d.env = env
    d.node = require("app.node").new(env)
    d.node.render()
    return d.node
  end

  function d.view(name)
    for _, v in ipairs(d.node.views) do
      if (v.name or "terminal") == (name or "terminal") then return v end
    end
  end

  function d.area(v, id)
    for _, a in ipairs(v.touch.areas) do if a.id == id then return a end end
  end

  local function click(v, x, y)
    if v.name then return v.handle({ "monitor_touch", v.name, x, y }) end
    return v.handle({ "mouse_click", 1, x, y })
  end

  function d.ids(v)
    local out = {}
    for _, a in ipairs(v.touch.areas) do out[#out + 1] = a.id end
    return table.concat(out, " ")
  end

  -- Jede Aktion der aktuellen Seite muss sichtbar und beruehrbar sein (nichts darf am Rand abgeschnitten werden)
  function d.check_actions(v)
    local page = v.current_page()
    if not page.actions or v.layout.mode == "status" then return end
    for _, a in ipairs(page.actions(v)) do
      if not d.area(v, "act:" .. a.id) then
        error("Aktion '" .. a.id .. "' ist nicht sichtbar (Seite " .. page.id .. ", " .. v.layout.mode .. ")\n" .. v.target.text(), 3)
      end
    end
  end

  function d.tap(v, id)
    d.node.render()
    d.check_actions(v)
    local a = d.area(v, id)
    if not a then error("keine Flaeche '" .. id .. "'; vorhanden: " .. d.ids(v) .. "\nBildschirm:\n" .. v.target.text(), 2) end
    click(v, a.x, a.y)
    d.node.render()
    return a
  end

  function d.tap_row(v, list_id, text)
    d.node.render()
    d.check_actions(v)
    local rows = v.target.rows()
    for _, a in ipairs(v.touch.areas) do
      if a.id:find("^sel:" .. list_id .. ":") and rows[a.y] and rows[a.y]:find(text, 1, true) then
        click(v, a.x, a.y)
        d.node.render()
        return a
      end
    end
    error("keine Zeile '" .. text .. "' in Liste " .. list_id .. "\nBildschirm:\n" .. v.target.text(), 2)
  end

  function d.type(v, field_id, text)
    d.tap(v, "field:" .. field_id)
    for ch in text:gmatch(".") do v.handle({ "char", ch }) end
    v.handle({ "key", KEYS.enter })
    d.node.render()
  end

  function d.key(v, name)
    v.handle({ "key", KEYS[name] })
    d.node.render()
  end

  function d.has(v, text)
    for _, row in ipairs(v.target.rows()) do if row:find(text, 1, true) then return true end end
    return false
  end

  function d.text(v) return v.target.text() end

  return d
end

return M
