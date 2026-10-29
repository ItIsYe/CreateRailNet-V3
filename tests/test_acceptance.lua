--[[
Purpose: Die Abnahmematrix (docs/ABNAHME.md) ist vollstaendig: A01 bis A18 stehen drin, jeder genannte Testlauf existiert, jeder genannte Schritt steht im grossen Spieltest (docs/GROSSER_TEST.md).
]]

local t = dofile("tests/lib/t.lua")

local function read(path)
  local fh = assert(io.open(path, "r"))
  local text = fh:read("*a")
  fh:close()
  return text
end

return {
  { "alle Abnahmen A01 bis A18 haben Test und Spieltestschritt", function()
    local matrix = read("docs/ABNAHME.md")
    local test_doc = read("docs/GROSSER_TEST.md")
    for n = 1, 18 do
      local id = string.format("A%02d", n)
      local line = matrix:match("\n| " .. id .. " [^\n]*")
      t.ok(line, id .. " fehlt in der Matrix")
      -- Spieltestschritte: letzte Spalte
      local steps = line:match("| ([^|]*) |$")
      t.ok(steps and steps:match("%d+%.%d+"), id .. " nennt keinen Spieltestschritt")
      for step in steps:gmatch("%d+%.%d+") do
        t.ok(test_doc:find("| " .. step .. " |", 1, true), id .. ": Schritt " .. step .. " steht nicht im Spieltest")
      end
      for path in line:gmatch("tests/[%w_]+%.lua") do
        local fh = io.open(path, "r")
        t.ok(fh, id .. ": " .. path .. " existiert nicht")
        if fh then fh:close() end
      end
    end
  end },
}
