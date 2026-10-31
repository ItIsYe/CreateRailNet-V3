--[[
Purpose: Der Build: Konfiguration passt zu src/, dist/ ist aktuell, das Dateiverzeichnis stimmt mit den Dateien ueberein, das Groessenbudget je Rolle wird eingehalten.
]]

local t = dofile("tests/lib/t.lua")
local build = dofile("tools/build.lua")
local config = dofile("build/roles.lua")
local budget = dofile("build/budget.lua")

local function read(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

return {
  { "Plan baut ohne Fehler", function()
    local files, err = build.plan()
    t.ok(files, err)
    t.ok(files["manifest.lua"])
  end },
  { "dist ist aktuell", function()
    local files = build.plan()
    for path, text in pairs(files) do t.eq(read("dist/" .. path), text, "dist/" .. path) end
  end },
  { "installer_beta.lua ist aktuell und unterscheidet sich nur im Kanal", function()
    local beta, err = build.beta_installer()
    t.ok(beta, err)
    t.eq(read("installer_beta.lua"), beta, "installer_beta.lua veraltet: lua tools/build.lua")
    local main_text = read("installer.lua")
    local function lines_of(text) local out = {} for line in (text .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end return out end
    local a, b = lines_of(main_text), lines_of(beta)
    t.eq(#a, #b)
    local diffs = {}
    for i = 1, #a do if a[i] ~= b[i] then diffs[#diffs + 1] = i end end
    t.eq(#diffs, 1, "genau eine Zeile weicht ab")
    t.contains(a[diffs[1]], 'local CHANNEL = "main"')
    t.contains(b[diffs[1]], 'local CHANNEL = "beta"')
  end },
  { "jede Datei unter src liegt in genau einem Modul", function()
    local listed = {}
    for _, paths in pairs(config.modules) do
      for _, path in ipairs(paths) do
        t.ok(not listed[path], "doppelt: " .. path)
        listed[path] = true
      end
    end
    local pipe = io.popen("find src -type f -name '*.lua'")
    local count = 0
    for line in pipe:lines() do
      count = count + 1
      t.ok(listed[line:gsub("^src/", "")] == true, "nicht in build/roles.lua: " .. line)
    end
    pipe:close()
    t.eq(count > 0, true)
  end },
  { "alle sieben Rollen nach Konzept Kapitel 4 sind da", function()
    for _, role in ipairs({ "zentrale", "passagierbahnhof", "gueterbahnhof", "depot", "signal", "knoten", "anmeldung" }) do
      t.ok(config.roles[role], "Rolle fehlt: " .. role)
    end
  end },
  { "Verzeichnis stimmt mit den Dateien ueberein", function()
    local manifest = dofile("dist/manifest.lua")
    local adler = require("core.adler")
    for path, entry in pairs(manifest.files) do
      local text = read("dist/" .. path)
      t.ok(text, "fehlt: " .. path)
      t.eq(#text, entry.size, "Groesse " .. path)
      t.eq(adler.hex(text), entry.sum, "Summe " .. path)
    end
    for role, paths in pairs(manifest.roles) do
      for _, path in ipairs(paths) do t.ok(manifest.files[path], role .. " nennt unbekannte Datei " .. path) end
    end
  end },
  { "Budget je Rolle wird eingehalten und mit 500 Byte je Datei gerechnet", function()
    local manifest = dofile("dist/manifest.lua")
    for role, paths in pairs(manifest.roles) do
      local used = 0
      for _, path in ipairs(paths) do used = used + math.max(manifest.files[path].size, budget.min_file) end
      t.ok(used <= budget.program_max, role .. " ist zu gross: " .. used)
    end
    t.eq(budget.program_max + budget.data_max + budget.free_min, budget.capacity)
  end },
  { "ein zu grosses Modul bricht den Build ab", function()
    -- Rolle mit kuenstlich kleinem Budget pruefen, ohne Dateien zu aendern
    local saved = budget.program_max
    local build2 = loadfile("tools/build.lua")
    local old_dofile = dofile
    _G.dofile = function(path)
      local value = old_dofile(path)
      if path == "build/budget.lua" then value.program_max = 100 end
      return value
    end
    local ok, module = pcall(build2)
    _G.dofile = old_dofile
    t.ok(ok, tostring(module))
    local files, err = module.plan()
    t.eq(files, nil)
    t.contains(err, "ueberschreitet das Programmbudget")
    t.eq(budget.program_max, saved)
  end },
}
