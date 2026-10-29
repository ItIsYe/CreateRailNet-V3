--[[
Purpose: Aufteilung der Flaeche je nach gemeldeter Groesse (Konzept 28.2, 29.4): ab 100x40 das grosse Layout mit fester Seitennavigation, ab 51x19 die kompakte Ansicht, darunter nur eine Statusansicht mit Hinweis auf den Bediencomputer. Das grosse Layout wird nie heruntergerechnet.
API: layout.compute(w, h) -> { mode = "gross" | "kompakt" | "status", header, nav, work, hint, actions } (Rechtecke { x, y, w, h })
Notes: Bei groesserer Flaeche waechst nur der Arbeitsbereich. Primaere Aktionsflaechen sind im grossen Layout drei Zeilen hoch, im kompakten zwei.
]]

local M = {}

local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

function M.compute(w, h)
  if w >= 100 and h >= 40 then
    return {
      mode = "gross", w = w, h = h,
      header = rect(1, 1, w, 3),
      nav = rect(1, 4, 20, h - 3),
      work = rect(22, 5, w - 22, h - 12),
      hint = rect(22, h - 6, w - 22, 2),
      actions = rect(22, h - 4, w - 22, 4),
      nav_row_h = 3, action_row_h = 3,
    }
  end
  if w >= 51 and h >= 19 then
    return {
      mode = "kompakt", w = w, h = h,
      header = rect(1, 1, w, 1),
      nav = rect(1, 2, w, 1),
      work = rect(1, 4, w, h - 7),
      hint = rect(1, h - 2, w, 1),
      actions = rect(1, h - 1, w, 2),
      nav_row_h = 1, action_row_h = 2,
    }
  end
  return { mode = "status", w = w, h = h, work = rect(1, 1, w, h) }
end

return M
