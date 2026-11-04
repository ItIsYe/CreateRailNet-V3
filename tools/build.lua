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

-- Vergleicht den Bytecode (ohne Zeilenangaben) zweier Texte: true gleich, false verschieden, nil nicht vergleichbar.
-- LuaJIT schreibt Tabellenvorlagen nicht immer in gleicher Reihenfolge; deshalb mehrere Versuche, verschieden gilt erst wenn alle abweichen.
function M.same_bytecode(a, b)
  if _VERSION == "Lua 5.1" and not rawget(_G, "jit") then return nil end
  local loader = loadstring or load
  for _ = 1, 10 do
    local f1, f2 = loader(a, "=a"), loader(b, "=b")
    if not f1 or not f2 then return nil end
    local ok1, d1 = pcall(string.dump, f1, true)
    local ok2, d2 = pcall(string.dump, f2, true)
    if not (ok1 and ok2) then return nil end
    if d1 == d2 then return true end
  end
  return false
end

-- Kommentare, Einrueckung, Leerzeichen am Zeilenende und ueberfluessige Leerzeichen zwischen Zeichen entfernen. Die Zeilenzahl bleibt (Fehlermeldungen zeigen
-- dieselbe Zeilennummer wie in src/); Zeichenketten und lange Zeichenketten werden unveraendert kopiert. Ein Leerzeichen bleibt nur, wo ohne es zwei Zeichen
-- zu einem anderen Wort oder Zeichen verschmelzen wuerden (zwei Namen oder Zahlen, "- -" gegen Kommentar, "[ [" gegen lange Zeichenkette, ". ." und Zahl ".."
-- gegen verunglueckte Zahlen). Der Aufruf prueft selbst, dass der Bytecode (ohne Zeilenangaben) gleich bleibt.
function M.minify(text, name)
  local out, line, len, i = {}, {}, #text, 1
  local at_start = true
  local pending = false          -- zwischen zwei Teilen stand ein Leerzeichen
  local function flush(newline)
    local piece = table.concat(line):gsub("%s+$", "")
    out[#out + 1] = piece
    if newline then out[#out + 1] = "\n" end
    line = {}
    pending = false
  end
  local function put(piece)
    if pending then
      local last = line[#line]
      local a, b = last and last:sub(-1) or "", piece:sub(1, 1)
      if a ~= "" then
        local keep = (a:match("[%w_]") and b:match("[%w_]"))
          or (a == "-" and b == "-") or (a == "[" and (b == "[" or b == "=")) or (a == "." and b == ".") or (a:match("%d") and b == ".")
          or (a == "=" and b == "=") or (a == "~" and b == "=") or (a == "<" and b == "=") or (a == ">" and b == "=")
        if keep then line[#line + 1] = " " end
      end
      pending = false
    end
    line[#line + 1] = piece
  end
  while i <= len do
    local c = text:sub(i, i)
    if c == "\n" then
      flush(true); at_start = true; i = i + 1
    elseif at_start and (c == " " or c == "\t") then
      i = i + 1
    elseif c == " " or c == "\t" then
      pending = true
      i = i + 1
    else
      at_start = false
      local level = text:match("^%-%-%[(=*)%[", i)
      if c == "-" and text:sub(i + 1, i + 1) == "-" then
        if level then
          local close = "]" .. level .. "]"
          local stop = text:find(close, i, true)
          if not stop then error((name or "?") .. ": Kommentar nicht geschlossen") end
          local body = text:sub(i, stop + #close - 1)
          local _, newlines = body:gsub("\n", "")
          pending = true
          for _ = 1, newlines do flush(true) end
          i = stop + #close
        else
          local stop = text:find("\n", i, true) or (len + 1)
          i = stop
        end
      elseif c == '"' or c == "'" then
        local j = i + 1
        while j <= len do
          local d = text:sub(j, j)
          if d == "\\" then j = j + 2
          elseif d == c then break
          else j = j + 1 end
        end
        if j > len then error((name or "?") .. ": Zeichenkette nicht geschlossen") end
        put(text:sub(i, j))
        i = j + 1
      elseif c == "[" and text:match("^%[=*%[", i) then
        local eq = text:match("^%[(=*)%[", i)
        local close = "]" .. eq .. "]"
        local stop = text:find(close, i, true)
        if not stop then error((name or "?") .. ": lange Zeichenkette nicht geschlossen") end
        put(text:sub(i, stop + #close - 1))
        i = stop + #close
      else
        put(c)
        i = i + 1
      end
    end
  end
  flush(false)
  local result = table.concat(out)
  -- Gegenprobe: gleicher Bytecode ohne Zeilenangaben (wo die Lua-Version das kann)
  local loader = loadstring or load
  if not loader(text, "=a") or not loader(result, "=b") then error((name or "?") .. ": verkleinerter Text ist kein gueltiges Lua") end
  if M.same_bytecode(text, result) == false then
    error((name or "?") .. ": verkleinerter Text uebersetzt anders als das Original")
  end
  return result
end

-- liefert die erwarteten Dateien von dist/ als { [pfad] = text } und den Fehlertext, falls die Konfiguration nicht stimmt
function M.plan()
  local files = {}
  local info = {}
  local roles = {}
  for _, module in ipairs(sorted_keys(config.modules)) do
    for _, path in ipairs(config.modules[module]) do
      local text = read_file("src/" .. path)
      if not text then return nil, "Datei fehlt: src/" .. path .. " (Modul " .. module .. ")" end
      text = M.minify(text, path)
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
