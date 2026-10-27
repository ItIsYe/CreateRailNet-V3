--[[
Purpose: Betriebsjournal "Absicht vor Aktion, Ergebnis danach" (Konzept 13.4). Eine Zeile je Absicht (I) und je Ergebnis (D); eine Absicht ohne Ergebnis bleibt nach einem Absturz als offener Vorgang erhalten und muss abgeglichen werden. Groesse ist begrenzt: beim Ueberschreiten bleiben offene Vorgaenge und die letzten abgeschlossenen.
API: journal.new{fs, path, now, max_bytes, keep} -> j; j.begin(kind, payload) -> id; j.finish(id, result); j.pending() -> Liste; j.recent(n) -> Liste; j.size()
Notes: Eine halb geschriebene letzte Zeile wird beim Lesen ignoriert. Das Verdichten schreibt eine .tmp Datei mit Endmarke "E" und tauscht dann aus (die Marke bleibt als ignorierte Zeile stehen); open() uebernimmt eine fertige .tmp, wenn die Hauptdatei fehlt.
]]

local ser = require("core.ser")

local M = {}

local function clean_kind(kind)
  kind = tostring(kind)
  if not kind:match("^[%w_%.%-]+$") then error("journal: ungueltige Art '" .. kind .. "'", 0) end
  return kind
end

local function parse_line(line)
  local tag, id, time, rest = line:match("^([ID])\t(%d+)\t([%d%.%-e%+]+)\t(.*)$")
  if not tag then return nil end
  if tag == "I" then
    local kind, payload = rest:match("^([%w_%.%-]+)\t(.*)$")
    if not kind then return nil end
    local value = ser.decode(payload)
    if value == nil then return nil end
    return { tag = "I", id = tonumber(id), time = tonumber(time), kind = kind, payload = value }
  end
  local value = ser.decode(rest)
  if value == nil then return nil end
  return { tag = "D", id = tonumber(id), time = tonumber(time), result = value }
end

local function read_lines(fs, path)
  if not fs.exists(path) then return nil end
  local fh = fs.open(path, "rb")
  if not fh then return nil end
  local raw = fh.readAll()
  fh.close()
  local lines = {}
  for line in (raw .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then lines[#lines + 1] = line end
  end
  -- eine unvollstaendig geschriebene letzte Zeile endet nicht mit Zeilenumbruch
  if raw ~= "" and raw:sub(-1) ~= "\n" then lines[#lines] = nil end
  return lines
end

function M.new(opts)
  local fs, path = opts.fs, opts.path
  local max_bytes = opts.max_bytes or 30000
  local keep = opts.keep or 100
  local now = opts.now or function() return 0 end
  local j = {}
  local tmp = path .. ".tmp"

  local entries = {}     -- id -> { id, time, kind, payload, done, result, done_time }
  local order = {}       -- ids in Reihenfolge der Absichten
  local next_id = 1

  local function ensure_dir()
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= ".." and not fs.exists(dir) then fs.makeDir(dir) end
  end

  local function load()
    -- fertig geschriebene .tmp uebernehmen, wenn die Hauptdatei fehlt
    if fs.exists(tmp) then
      local lines = read_lines(fs, tmp)
      local last = lines and lines[#lines]
      local count = last and last:match("^E\t(%d+)$")
      if not fs.exists(path) and count and tonumber(count) == #lines - 1 then
        fs.move(tmp, path)
      else
        fs.delete(tmp)
      end
    end
    local lines = read_lines(fs, path) or {}
    for _, line in ipairs(lines) do
      local item = parse_line(line)
      if item and item.tag == "I" then
        entries[item.id] = { id = item.id, time = item.time, kind = item.kind, payload = item.payload }
        order[#order + 1] = item.id
        if item.id >= next_id then next_id = item.id + 1 end
      elseif item and item.tag == "D" and entries[item.id] and not entries[item.id].done then
        entries[item.id].done = true
        entries[item.id].result = item.result
        entries[item.id].done_time = item.time
      end
    end
  end

  -- physische Zeilen eines Eintrags: Absicht und, falls abgeschlossen, Ergebnis
  local function lines_for(entry)
    local out = { string.format("I\t%d\t%s\t%s\t%s", entry.id, ser.encode(entry.time), entry.kind, ser.encode(entry.payload)) }
    if entry.done then out[#out + 1] = string.format("D\t%d\t%s\t%s", entry.id, ser.encode(entry.done_time or entry.time), ser.encode(entry.result)) end
    return out
  end

  local function append(text)
    ensure_dir()
    local fh = fs.open(path, "a")
    if not fh then error("journal: Datei nicht beschreibbar", 0) end
    fh.write(text .. "\n")
    fh.close()
  end

  local function size()
    if not fs.exists(path) then return 0 end
    return fs.getSize(path)
  end

  local function compact()
    local finished, kept = {}, {}
    for _, id in ipairs(order) do
      local e = entries[id]
      if e then
        if e.done then finished[#finished + 1] = id else kept[id] = true end
      end
    end
    for i = math.max(1, #finished - keep + 1), #finished do kept[finished[i]] = true end
    local new_order, lines = {}, {}
    for _, id in ipairs(order) do
      if kept[id] then
        new_order[#new_order + 1] = id
        for _, line in ipairs(lines_for(entries[id])) do lines[#lines + 1] = line end
      else
        entries[id] = nil
      end
    end
    lines[#lines + 1] = "E\t" .. #lines
    order = new_order
    if fs.exists(tmp) then fs.delete(tmp) end
    local fh = fs.open(tmp, "wb")
    fh.write(table.concat(lines, "\n") .. "\n")
    fh.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
  end

  function j.begin(kind, payload)
    kind = clean_kind(kind)
    local entry = { id = next_id, time = now(), kind = kind, payload = payload or {} }
    append(string.format("I\t%d\t%s\t%s\t%s", entry.id, ser.encode(entry.time), kind, ser.encode(entry.payload)))
    next_id = next_id + 1
    entries[entry.id] = entry
    order[#order + 1] = entry.id
    if size() > max_bytes then compact() end
    return entry.id
  end

  function j.finish(id, result)
    local entry = entries[id]
    if not entry then error("journal: unbekannter Vorgang " .. tostring(id), 0) end
    if entry.done then return false end
    local time = now()
    append(string.format("D\t%d\t%s\t%s", id, ser.encode(time), ser.encode(result == nil and {} or result)))
    entry.done = true
    entry.result = result == nil and {} or result
    entry.done_time = time
    if size() > max_bytes then compact() end
    return true
  end

  function j.pending()
    local out = {}
    for _, id in ipairs(order) do
      local e = entries[id]
      if e and not e.done then out[#out + 1] = { id = e.id, time = e.time, kind = e.kind, payload = e.payload } end
    end
    return out
  end

  function j.recent(n)
    local out = {}
    for i = math.max(1, #order - n + 1), #order do
      local e = entries[order[i]]
      if e then out[#out + 1] = e end
    end
    return out
  end

  j.size = size

  load()
  return j
end

return M
