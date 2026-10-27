--[[
Purpose: Sicheres Speichern einer Tabelle in eine Datei: erst in eine .tmp Datei schreiben, zuruecklesen und pruefen, dann die alte Fassung als .prev behalten und austauschen. Bei jedem Abbruch bleibt eine pruefbare Fassung uebrig; heal() stellt nach einem Neustart den Hauptzustand her.
API: store.new(fs) -> s; s.save(path, value) -> true | nil, fehler; s.load(path) -> wert, quelle ("main","tmp","prev") | nil, grund; s.heal(path) -> quelle oder nil
Notes: Dateikopf "-- crn <summe> <laenge>"; die Summe (Adler-32) deckt den Text dahinter. Ist der Platz knapp, wird .prev nicht behalten (Ergaenzung E9, Erfahrung: Zustandsdateien duerfen die Update-Reserve nicht aufbrauchen).
]]

local ser = require("core.ser")
local adler = require("core.adler")

local M = {}

local MARGIN = 5000

local function wrap(text)
  return "-- crn " .. adler.hex(text) .. " " .. #text .. "\n" .. text
end

local function unwrap(raw)
  if type(raw) ~= "string" then return nil, "leer" end
  local sum, len, body = raw:match("^%-%- crn (%x+) (%d+)\n(.*)$")
  if not sum then return nil, "Kopf fehlt" end
  if #body ~= tonumber(len) or adler.hex(body) ~= sum then return nil, "Summe falsch" end
  local value, err = ser.decode(body)
  if value == nil then return nil, err or "kein Wert" end
  return value
end

function M.new(fs)
  local s = {}

  local function read(path)
    if not fs.exists(path) or fs.isDir(path) then return nil, "fehlt" end
    local fh = fs.open(path, "rb")
    if not fh then return nil, "nicht lesbar" end
    local raw = fh.readAll()
    fh.close()
    return unwrap(raw)
  end

  local function write(path, text)
    local fh = fs.open(path, "wb")
    if not fh then return false end
    fh.write(text)
    fh.close()
    return true
  end

  local function ensure_dir(path)
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= ".." and not fs.exists(dir) then
      ensure_dir(dir)
      fs.makeDir(dir)
    end
  end

  function s.save(path, value)
    local ok, text = pcall(ser.encode, value)
    if not ok then return nil, "nicht darstellbar: " .. tostring(text) end
    local body = wrap(text)
    ensure_dir(path)
    local tmp, prev = path .. ".tmp", path .. ".prev"
    if fs.exists(tmp) then fs.delete(tmp) end
    local tight = fs.getFreeSpace("/") < 2 * math.max(#body, 500) + MARGIN
    if tight and fs.exists(prev) then fs.delete(prev) end
    local wrote, err = pcall(write, tmp, body)
    if not wrote or not read(tmp) then
      if fs.exists(tmp) then fs.delete(tmp) end
      return nil, "Schreiben fehlgeschlagen" .. (wrote and "" or (": " .. tostring(err)))
    end
    if fs.exists(path) then
      if tight then
        fs.delete(path)
      else
        if fs.exists(prev) then fs.delete(prev) end
        fs.move(path, prev)
      end
    end
    fs.move(tmp, path)
    return true
  end

  function s.load(path)
    local value, why = read(path)
    if value ~= nil then return value, "main" end
    local tmp_value = read(path .. ".tmp")
    if tmp_value ~= nil and not fs.exists(path) then return tmp_value, "tmp" end
    local prev_value = read(path .. ".prev")
    if prev_value ~= nil then return prev_value, "prev" end
    return nil, why
  end

  function s.heal(path)
    local value, source = s.load(path)
    if value == nil then
      if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
      return nil
    end
    if source == "main" then
      if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
      return "main"
    end
    if source == "tmp" then
      fs.move(path .. ".tmp", path)
      return "tmp"
    end
    -- nur .prev ist heil: Hauptdatei aus ihm neu schreiben
    if fs.exists(path) then fs.delete(path) end
    if fs.exists(path .. ".tmp") then fs.delete(path .. ".tmp") end
    local ok = s.save(path, value)
    if not ok then return nil end
    return "prev"
  end

  return s
end

return M
