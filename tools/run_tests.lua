--[[
Purpose: Testlaeufer: laedt jede Datei tests/test_*.lua (gibt eine Liste { name, funktion } zurueck), fuehrt alle Tests aus und meldet Fehlschlaege. Laeuft unter Lua 5.1, 5.4 und LuaJIT; Exitcode 1 bei einem Fehlschlag oder einem Fehler beim Laden.
Usage: lua tools/run_tests.lua [Teil des Dateinamens]
]]

package.path = "./src/?.lua;./?.lua;" .. package.path
_G.__CRN_TEST = true

local filter = ({ ... })[1]

local files = {}
local pipe = io.popen("ls tests/test_*.lua 2>/dev/null")
if pipe then
  for line in pipe:lines() do files[#files + 1] = line end
  pipe:close()
end
table.sort(files)

local passed, failed = 0, 0
for _, file in ipairs(files) do
  if not filter or file:find(filter, 1, true) then
    local chunk, err = loadfile(file)
    local list
    if chunk then
      local ok, result = pcall(chunk)
      if ok then list = result else err = result end
    end
    if type(list) ~= "table" then
      failed = failed + 1
      print("FEHLER beim Laden von " .. file .. ": " .. tostring(err))
    else
      for _, test in ipairs(list) do
        local ok, problem = pcall(test[2])
        if ok then
          passed = passed + 1
        else
          failed = failed + 1
          print("FEHLSCHLAG " .. file .. " :: " .. test[1] .. "\n  " .. tostring(problem))
        end
      end
    end
  end
end

print(string.format("%d/%d bestanden (%d fehlgeschlagen)", passed, passed + failed, failed))
os.exit(failed > 0 and 1 or 0)
