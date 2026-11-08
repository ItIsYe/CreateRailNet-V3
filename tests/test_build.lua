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
  { "Verkleinern: Kommentare und Einrueckung weg, Zeilenzahl und Verhalten bleiben", function()
    local source = table.concat({
      "--[[ Kopf",
      "ueber mehrere Zeilen ]]",
      "local t = {}",
      "  -- nur ein Hinweis",
      "  t.a = 'x -- kein Kommentar'  -- aber dies",
      "\tt.b = \"[[ auch kein ]] \\\" Anfang\" --[=[ Block ]=] .. 'y'",
      "  t.c = [[",
      "   Einrueckung bleibt -- und das hier auch",
      "  ]]",
      "  t.d = [==[ ]] ]==]",
      "  t.e = \"Zeile\\",
      "   Fortsetzung\"",
      "return t",
      "",
    }, "\n")
    local min = build.minify(source, "probe")
    local _, a = source:gsub("\n", "")
    local _, b = min:gsub("\n", "")
    t.eq(b, a, "gleiche Zeilenzahl")
    t.ok(#min < #source)
    local loader = loadstring or load
    local x, y = loader(source)(), loader(min)()
    for _, key in ipairs({ "a", "b", "c", "d", "e" }) do t.eq(y[key], x[key], "Wert " .. key) end
    t.contains(y.a, "-- kein Kommentar")
    t.contains(y.c, "   Einrueckung bleibt -- und das hier auch")
    t.contains(y.e, "   Fortsetzung")
    t.ok(not min:find("aber dies", 1, true) and not min:find("nur ein Hinweis", 1, true) and not min:find("Block", 1, true))
    t.ok(not min:find("\n  ", 1, true) or min:find("\n   Einrueckung", 1, true), "keine Einrueckung ausser in Zeichenketten")
  end },
  { "Verkleinern: Leerzeichen zwischen Zeichen entfallen, bleiben aber, wo sonst Woerter, Zahlen, Kommentarzeichen oder Zeichenketten verschmelzen", function()
    local min = build.minify("local a = 1 + 2 * (3 - 4)\nlocal s = 'x y' .. \"z  w\"\nreturn { a = a, s = s, f = function ( x ) return x ~= 5 and x >= 1 or not x end }\n", "probe")
    t.eq(min, "local a=1+2*(3-4)\nlocal s='x y'..\"z  w\"\nreturn{a=a,s=s,f=function(x)return x~=5 and x>=1 or not x end}\n")
    local loader = loadstring or load
    local function same(source, expected_min)
      local out = build.minify(source, "probe")
      if expected_min then t.eq(out, expected_min) end
      local x, y = loader(source)(), loader(out)()
      return x, y, out
    end
    -- Zahl vor ".." und Namen vor Zahl bleiben getrennt, Minus gegen Minus, eckige Klammern gegen lange Zeichenkette
    local x, y, min = same("local t = {}\nreturn 1 .. 2\n", "local t={}\nreturn 1 ..2\n"); t.eq(y, "12")
    x, y = same("local a, b = 5, 3\nreturn a - -b\n", "local a,b=5,3\nreturn a- -b\n"); t.eq(y, 8)
    x, y, min = same("local t = { [ [[k]] ] = 7 }\nreturn t.k\n"); t.eq(y, 7); t.contains(min, "[ [[k]]")
    x, y = same("local t = { x = 1 }\nreturn t[ 'x' ]\n", "local t={x=1}\nreturn t['x']\n"); t.eq(y, 1)
    x, y = same("local n = 2\nreturn n .. ' Stueck'\n", "local n=2\nreturn n..' Stueck'\n"); t.eq(y, "2 Stueck")
    x, y = same("local a = 3\nreturn a == 3 and a ~= 4 and a <= 3 and a >= 3 and not (a < 2)\n"); t.eq(y, true)
    x, y = same("local a = 4 --[[ x ]] local b = 5\nreturn a + b\n"); t.eq(y, 9)
    x, y = same("return 3 and 4\n", "return 3 and 4\n"); t.eq(y, 4)
    x, y = same("return (function(...) return select('#', ...) end)(1, 2, 3)\n"); t.eq(y, 3)
  end },
  { "Verkleinern: nicht geschlossene Zeichenketten und Kommentare sind Fehler, nichts wird still abgeschnitten", function()
    local ok, err = pcall(build.minify, "local x = 'offen\n", "a")
    t.eq(ok, false); t.contains(tostring(err), "nicht geschlossen")
    ok, err = pcall(build.minify, "--[[ offen\nlocal x = 1\n", "b")
    t.eq(ok, false); t.contains(tostring(err), "Kommentar nicht geschlossen")
    ok, err = pcall(build.minify, "local x = [[ offen\n", "c")
    t.eq(ok, false)
  end },
  { "Verkleinern: jede Quelldatei bleibt gleich uebersetzbar und wird kleiner", function()
    local files = build.plan()
    local loader = loadstring or load
    local total_src, total_min = 0, 0
    for path, text in pairs(files) do
      if path:match("%.lua$") and path ~= "manifest.lua" then
        local src = read("src/" .. path)
        t.ok(src, "Quelle " .. path)
        total_src, total_min = total_src + #src, total_min + #text
        local _, a = src:gsub("\n", "")
        local _, b = text:gsub("\n", "")
        t.eq(b, a, "Zeilenzahl " .. path)
        t.ok(loader(src, "=a") and loader(text, "=b"), "uebersetzbar " .. path)
        t.ok(build.same_bytecode(src, text) ~= false, "Bytecode " .. path)
      end
    end
    t.ok(total_min < total_src * 0.8, "mindestens ein Fuenftel kleiner: " .. total_min .. " von " .. total_src)
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
  { "alle fuenf Rollen (Create regelt die Strecke) sind da", function()
    for _, role in ipairs({ "zentrale", "passagierbahnhof", "gueterbahnhof", "depot", "anmeldung" }) do
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
