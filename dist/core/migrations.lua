





local M = {}



M.STEPS = {}


function M.validate(steps)
local count = 0
for key in pairs(steps) do
if type(key) ~= "number" then return "Schluessel " .. tostring(key) .. " ist keine Nummer" end
count = count + 1
end
for i = 1, count do
local step = steps[i]
if step == nil then return "Schritt " .. i .. " fehlt (Luecke in der Nummerierung)" end
local run = type(step) == "function" and step or (type(step) == "table" and step.run)
if type(run) ~= "function" then return "Schritt " .. i .. " hat keine Funktion" end
end
return nil
end

M.FORMAT = 1 + #M.STEPS

return M
