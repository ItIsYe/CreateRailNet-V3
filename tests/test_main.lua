--[[
Purpose: Das Startprogramm zeigt Version, Rolle und Platz und meldet eine fehlende Installation.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local main = dofile("src/app/main.lua")

return {
  { "ohne Installation", function()
    local fs = cc.fs()
    local env = cc.env(fs, nil)
    t.eq(main.info(env), false)
    t.contains(env.output(), "Kein Dateiverzeichnis")
  end },
  { "mit Installation", function()
    local fs = cc.fs()
    fs.makeDir("/crn")
    local fh = fs.open("/crn/manifest.lua", "w")
    fh.write('return { version = "0.1.0", id = "abcd1234", files = { ["a.lua"] = { size = 100, sum = "00000001" } }, roles = { signal = { "a.lua" } } }')
    fh.close()
    fh = fs.open("/crn/install.lua", "w")
    fh.write('return { role = "signal" }')
    fh.close()
    local env = cc.env(fs, nil)
    t.eq(main.info(env), true)
    local out = env.output()
    t.contains(out, "Version: 0.1.0  Stand: abcd1234")
    t.contains(out, "Rolle: signal")
    t.contains(out, "1 Dateien, 500 Byte")
    t.contains(out, "Frei auf dem Computer: ")
  end },
}
