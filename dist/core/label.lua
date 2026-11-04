





local M={}

function M.track(name)
name=tostring(name or"")
local low=name:lower()
if low:find("gleis",1,true)or low:find("bahnsteig",1,true)then return name end
return"Gleis "..name
end

return M
