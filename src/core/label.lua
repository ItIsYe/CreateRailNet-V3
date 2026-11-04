--[[
Purpose: Anzeigenamen fuer Texte: ein Gleis heisst im Assistenten meist schon "Gleis 1"; in einem Satz darf das Wort nicht doppelt stehen ("Gleis Gleis 1").
API: label.track(name) -> Text mit genau einem Wort Gleis (oder Bahnsteig) davor
Notes: "Gleis 1" und "Bahnsteig 2" bleiben, "3" wird "Gleis 3", "Nord" wird "Gleis Nord".
]]

local M = {}

function M.track(name)
  name = tostring(name or "")
  local low = name:lower()
  if low:find("gleis", 1, true) or low:find("bahnsteig", 1, true) then return name end
  return "Gleis " .. name
end

return M
