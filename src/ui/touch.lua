--[[
Purpose: Beruehrbare Rechtecke. Jede sichtbare Aktion hat ein Rechteck (Konzept 28.2); eine gesperrte Aktion nennt ihren Grund und sendet nichts. Die Liste wird bei jedem Zeichnen neu aufgebaut, damit sich Klickbereiche mit dem Layout aendern.
API: touch.new() -> t; t.reset(); t.add(id, x, y, w, h, opts); t.hit(x, y) -> Bereich oder nil; Bereich = { id, x, y, w, h, enabled, reason }
Notes: Spaeter hinzugefuegte Bereiche liegen oben (gewinnen bei Ueberlappung). Hover, Wischen und lange Beruehrung gibt es nicht.
]]

local M = {}

function M.new()
  local t = { areas = {} }
  function t.reset() t.areas = {} end
  function t.add(id, x, y, w, h, opts)
    opts = opts or {}
    t.areas[#t.areas + 1] = { id = id, x = x, y = y, w = w, h = h, enabled = opts.enabled ~= false, reason = opts.reason }
  end
  function t.hit(x, y)
    for i = #t.areas, 1, -1 do
      local a = t.areas[i]
      if x >= a.x and x < a.x + a.w and y >= a.y and y < a.y + a.h then return a end
    end
    return nil
  end
  return t
end

return M
