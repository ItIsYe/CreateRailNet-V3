--[[
Purpose: Prueft alle .lua Dateien: Syntax (mit dem Interpreter, der das Programm startet; CI nimmt auch Lua 5.1, die Sprache von CC:Tweaked), eine Kopfzeile "Purpose:" in den ersten 12 Zeilen und keine Funktionen, die es in Lua 5.1 oder in CC nicht gibt.
Usage: lua tools/check.lua
]]

-- die verbotenen Namen stehen zerlegt hier, damit diese Datei sich nicht selbst meldet
local FORBIDDEN = {
  { "goto" .. " ", "goto gibt es in Lua 5.1 nicht" },
  { "table" .. ".unpack", "table.unpack fehlt in Lua 5.1: lokal 'unpack = table.unpack or unpack' verwenden", "table" .. ".unpack or unpack" },
  { "table" .. ".pack", "table.pack fehlt in Lua 5.1" },
  { "table" .. ".move", "table.move fehlt in Lua 5.1" },
  { "utf" .. "8.", "utf8 fehlt in Lua 5.1" },
  { "bit" .. "32", "bit32 fehlt in CC:Tweaked" },
  { "math" .. ".type", "math.type fehlt in Lua 5.1" },
  { "string" .. ".pack", "string.pack fehlt in Lua 5.1" },
  { "<" .. "const>", "Attribute <const> gibt es in Lua 5.1 nicht" },
  { "<" .. "close>", "Attribute <close> gibt es in Lua 5.1 nicht" },
}

local M = {}

function M.scan_text(name, text, opts)
  opts = opts or {}
  local problems = {}
  local head = {}
  local n = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n <= 12 then head[#head + 1] = line end
    local code = line:gsub("^%s*%-%-.*$", "")
    if not opts.skip_tokens then
      for _, rule in ipairs(FORBIDDEN) do
        if code:find(rule[1], 1, true) and not (rule[3] and code:find(rule[3], 1, true)) then
          problems[#problems + 1] = name .. ":" .. n .. ": " .. rule[2]
        end
      end
    end
  end
  if not table.concat(head, "\n"):find("Purpose:", 1, true) then
    problems[#problems + 1] = name .. ": Kopfzeile 'Purpose:' fehlt in den ersten 12 Zeilen"
  end
  local chunk, err = (loadstring or load)(text, "=" .. name)
  if not chunk then problems[#problems + 1] = name .. ": Syntaxfehler: " .. tostring(err) end
  return problems
end

function M.main()
  local files = {}
  local pipe = io.popen("find . -name '*.lua' -not -path './.git/*' -not -path './dist/*' | sort")
  for line in pipe:lines() do files[#files + 1] = line:gsub("^%./", "") end
  pipe:close()
  local all = {}
  for _, path in ipairs(files) do
    local fh = io.open(path, "rb")
    local text = fh:read("*a")
    fh:close()
    -- tools/check.lua nennt die verbotenen Namen in seinen Meldungen
    for _, p in ipairs(M.scan_text(path, text, { skip_tokens = path == "tools/check.lua" })) do all[#all + 1] = p end
  end
  for _, p in ipairs(all) do print(p) end
  print(string.format("%d Dateien geprueft, %d Probleme", #files, #all))
  return #all == 0 and 0 or 1
end

if rawget(_G, "__CRN_TEST") then return M end
os.exit(M.main())
