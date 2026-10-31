--[[
Purpose: Baut dist/ aus src/: kopiert die Dateien aller Rollen und schreibt dist/manifest.lua (Version, Stand, Groesse und Pruefsumme jeder Datei, Dateiliste je Rolle). Prueft das Groessenbudget je Rolle. Erzeugt ausserdem installer_beta.lua aus installer.lua (nur der Kanal ist ein anderer).
Usage: lua tools/build.lua          schreibt dist/
       lua tools/build.lua --check  prueft, ob dist/ zu src/ passt (CI), schreibt nichts
]]

package.path = "./src/?.lua;" .. package.path

local adler = require("core.adler")
local version = require("core.version")
local config = dofile("build/roles.lua")
local budget = dofile("build/budget.lua")

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

local function write_file(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local M = {}

-- liefert die erwarteten Dateien von dist/ als { [pfad] = text } und den Fehlertext, falls die Konfiguration nicht stimmt
function M.plan()
  local files = {}
  local info = {}
  local roles = {}
  for _, module in ipairs(sorted_keys(config.modules)) do
    for _, path in ipairs(config.modules[module]) do
      local text = read_file("src/" .. path)
      if not text then return nil, "Datei fehlt: src/" .. path .. " (Modul " .. module .. ")" end
      if files[path] then return nil, "Datei in mehreren Modulen: " .. path end
      files[path] = text
      info[path] = { size = #text, sum = adler.hex(text) }
    end
  end
  for _, role in ipairs(sorted_keys(config.roles)) do
    local list = {}
    local seen = {}
    for _, module in ipairs(config.roles[role]) do
      if not config.modules[module] then return nil, "Unbekanntes Modul " .. module .. " in Rolle " .. role end
      for _, path in ipairs(config.modules[module]) do
        if not seen[path] then
          seen[path] = true
          list[#list + 1] = path
        end
      end
    end
    table.sort(list)
    roles[role] = list
    local used = 0
    for _, path in ipairs(list) do used = used + math.max(info[path].size, budget.min_file) end
    if used > budget.program_max then
      return nil, "Rolle " .. role .. " ueberschreitet das Programmbudget: " .. used .. " > " .. budget.program_max
    end
  end
  local lines = { "return {", string.format("  version = %q,", version.number) }
  local id_parts = {}
  lines[#lines + 1] = "  files = {"
  for _, path in ipairs(sorted_keys(info)) do
    lines[#lines + 1] = string.format("    [%q] = { size = %d, sum = %q },", path, info[path].size, info[path].sum)
    id_parts[#id_parts + 1] = path .. ":" .. info[path].size .. ":" .. info[path].sum
  end
  lines[#lines + 1] = "  },"
  lines[#lines + 1] = "  roles = {"
  for _, role in ipairs(sorted_keys(roles)) do
    local quoted = {}
    for i, path in ipairs(roles[role]) do quoted[i] = string.format("%q", path) end
    lines[#lines + 1] = string.format("    %s = { %s },", role, table.concat(quoted, ", "))
    id_parts[#id_parts + 1] = role .. "=" .. table.concat(roles[role], ",")
  end
  lines[#lines + 1] = "  },"
  table.insert(lines, 2, string.format("  id = %q,", adler.hex(version.number .. "\n" .. table.concat(id_parts, "\n"))))
  lines[#lines + 1] = "}"
  files["manifest.lua"] = table.concat(lines, "\n") .. "\n"
  return files
end

-- installer_beta.lua: derselbe Installer, aber der Kanal ist beta; wer ihn von beta laedt, installiert beta
local CHANNEL_LINE = 'local CHANNEL = "main"'
function M.beta_installer()
  local text = read_file("installer.lua")
  if not text then return nil, "installer.lua fehlt" end
  local a, b = text:find(CHANNEL_LINE, 1, true)
  if not a then return nil, "installer.lua: Zeile " .. CHANNEL_LINE .. " nicht gefunden" end
  return text:sub(1, a - 1) .. 'local CHANNEL = "beta"' .. text:sub(b + 1)
end

local function list_dist()
  local found = {}
  local pipe = io.popen('find dist -type f 2>/dev/null')
  if not pipe then return found end
  for line in pipe:lines() do found[#found + 1] = line:gsub("^dist/", "") end
  pipe:close()
  return found
end

function M.main(args)
  local files, err = M.plan()
  if not files then
    io.stderr:write("Build fehlgeschlagen: " .. err .. "\n")
    return 1
  end
  local beta, berr = M.beta_installer()
  if not beta then
    io.stderr:write("Build fehlgeschlagen: " .. berr .. "\n")
    return 1
  end
  if args[1] == "--check" then
    local problems = {}
    if read_file("installer_beta.lua") ~= beta then problems[#problems + 1] = "veraltet oder fehlt: installer_beta.lua" end
    for _, path in ipairs(sorted_keys(files)) do
      if read_file("dist/" .. path) ~= files[path] then problems[#problems + 1] = "veraltet oder fehlt: dist/" .. path end
    end
    for _, path in ipairs(list_dist()) do
      if files[path] == nil then problems[#problems + 1] = "ueberzaehlig: dist/" .. path end
    end
    if #problems > 0 then
      io.stderr:write(table.concat(problems, "\n") .. "\nBitte 'lua tools/build.lua' ausfuehren.\n")
      return 1
    end
    print("dist ist aktuell")
    return 0
  end
  write_file("installer_beta.lua", beta)
  os.execute("rm -rf dist && mkdir -p dist")
  for _, path in ipairs(sorted_keys(files)) do
    local dir = path:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p dist/" .. dir) end
    write_file("dist/" .. path, files[path])
  end
  print("dist geschrieben: " .. #sorted_keys(files) .. " Dateien")
  return 0
end

if rawget(_G, "__CRN_TEST") then return M end
os.exit(M.main({ ... }))
