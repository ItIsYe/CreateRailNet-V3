--[[
Purpose: Zeigt das Programmbudget je Rolle aus dist/manifest.lua (belegte Byte, jede Datei mindestens 500) und bricht mit Fehler ab, wenn eine Rolle das Budget ueberschreitet.
Usage: lua tools/budget.lua
]]

local budget = dofile("build/budget.lua")
local manifest = dofile("dist/manifest.lua")

local names = {}
for role in pairs(manifest.roles) do names[#names + 1] = role end
table.sort(names)

local failed = false
print(string.format("%-18s %8s %10s %10s", "Rolle", "Dateien", "belegt", "Budget"))
for _, role in ipairs(names) do
  local used = 0
  for _, path in ipairs(manifest.roles[role]) do
    used = used + math.max(manifest.files[path].size, budget.min_file)
  end
  local mark = used > budget.program_max and "  ZU GROSS" or ""
  if used > budget.program_max then failed = true end
  print(string.format("%-18s %8d %10d %10d%s", role, #manifest.roles[role], used, budget.program_max, mark))
end
os.exit(failed and 1 or 0)
