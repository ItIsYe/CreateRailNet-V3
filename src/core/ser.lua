--[[
Purpose: Gleichbleibende Text-Darstellung von Lua-Tabellen (Zahlen, Texte, Wahrheitswerte, verschachtelte Tabellen) fuer Dateien und Nachrichten. Ein Wert ergibt immer denselben einzeiligen Text (sortierte Schluessel); Lesen laeuft ohne Zugriff auf Funktionen.
API: ser.encode(value) -> text oder wirft; ser.decode(text) -> wert oder nil, fehler
Notes: Kein Zeilenumbruch im Ergebnis (Journal und Nachrichten brauchen eine Zeile). Zyklen, Funktionen und nicht endliche Zahlen sind Fehler.
]]

local M = {}

local function quote(text)
  return '"' .. text:gsub('[%c"\\\128-\255]', function(c) return string.format("\\%03d", c:byte()) end) .. '"'
end

local function number_text(n)
  if n ~= n or n == math.huge or n == -math.huge then error("ser: Zahl nicht darstellbar", 0) end
  if n == math.floor(n) and n >= -2 ^ 53 and n <= 2 ^ 53 then return string.format("%d", n) end
  return string.format("%.14g", n)
end

local function sort_key(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  return a < b
end

local function encode(value, seen, out)
  local kind = type(value)
  if kind == "string" then
    out[#out + 1] = quote(value)
  elseif kind == "number" then
    out[#out + 1] = number_text(value)
  elseif kind == "boolean" then
    out[#out + 1] = value and "true" or "false"
  elseif kind == "table" then
    if seen[value] then error("ser: Zyklus", 0) end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do
      local tk = type(k)
      if tk ~= "string" and tk ~= "number" then error("ser: Schluessel vom Typ " .. tk, 0) end
      keys[#keys + 1] = k
    end
    table.sort(keys, sort_key)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      out[#out + 1] = "[" .. (type(k) == "number" and number_text(k) or quote(k)) .. "]="
      encode(value[k], seen, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
    seen[value] = nil
  else
    error("ser: Typ " .. kind .. " nicht darstellbar", 0)
  end
end

function M.encode(value)
  local out = {}
  encode(value, {}, out)
  return table.concat(out)
end

function M.decode(text)
  if type(text) ~= "string" then return nil, "kein Text" end
  local source = "return " .. text
  local chunk, err
  if setfenv then
    chunk, err = loadstring(source, "=ser")
    if chunk then setfenv(chunk, {}) end
  else
    chunk, err = load(source, "=ser", "t", {})
  end
  if not chunk then return nil, tostring(err) end
  local ok, value = pcall(chunk)
  if not ok then return nil, tostring(value) end
  return value
end

return M
