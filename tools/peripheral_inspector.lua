--[[
Purpose: Inspect available peripherals and methods in CC:Tweaked.
Public API: none (script).
]]
if not peripheral then print("peripheral API unavailable (run inside CC:Tweaked)"); return end
local out={}
for _,name in ipairs(peripheral.getNames()) do
  local t = peripheral.getType and peripheral.getType(name) or "unknown"
  local methods = peripheral.getMethods(name) or {}
  local line = string.format("%s [%s] => %s", name, tostring(t), table.concat(methods, ","))
  print(line); table.insert(out,line)
end
local fh=io.open("peripheral_report.txt","w")
if fh then fh:write(table.concat(out,"\n")); fh:close(); print("wrote peripheral_report.txt") end
