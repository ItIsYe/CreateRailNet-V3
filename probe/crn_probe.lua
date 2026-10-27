--[[
Purpose: Messprogramm fuer das echte Modpack (Pruefungen A01 bis A05 des Konzepts 1.1). Es LIEST nur: Umgebung, alle Geraete mit Typ und Methoden, Zustand von Bahnhoefen, Signalen und Beobachtern, den Fahrplan eines haltenden Zuges, auf Wunsch Ereignisse. Es schaltet nichts.
Usage: crn_probe                    schreibt den Bericht nach crn_probe.txt und zeigt eine Zusammenfassung
       crn_probe --events 60        zusaetzlich 60 Sekunden lang Create-Ereignisse mitschreiben (Zuege fahren lassen)
       crn_probe --reach NAME       zusaetzlich canTrainReach / distanceTo fuer die Zielstation NAME (nur Lesen)
       crn_probe --out datei.txt    anderer Dateiname
Notes: ruft nur Methoden einer festen Leseliste auf (keine set*, cycle*, assemble, disassemble, kein Redstone-Ausgang, kein rednet). Ein am Computer angeschlossenes Create-Signal steht schon durch den Anschluss unter Computer-Kontrolle; das Lesen aendert daran nichts weiter.
  Den Bericht schickst du so: `pastebin put crn_probe.txt` (gibt einen Code) oder die Datei mit `edit crn_probe.txt` anschauen und abfotografieren.
]]

local args = { ... }
local opts = { out = "crn_probe.txt", events = 0 }
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--events" then opts.events = tonumber(args[i + 1]) or 0; i = i + 2
    elseif a == "--reach" then opts.reach = args[i + 1]; i = i + 2
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --events N, --reach NAME, --out DATEI)", 0) end
  end
end

local lines = {}
local function add(text) lines[#lines + 1] = tostring(text) end
local function section(title) add(""); add("== " .. title) end

local function pack(...) return { n = select("#", ...), ... } end

local function show_value(v)
  local kind = type(v)
  if kind == "string" then return string.format("%q", v) end
  if kind == "table" then
    if textutils and textutils.serialize then
      local ok, text = pcall(textutils.serialize, v, { compact = true })
      if not ok then ok, text = pcall(textutils.serialize, v) end
      if ok then return text end
    end
    return "{table}"
  end
  return tostring(v)
end

-- ruft fn auf und liefert (true, text der Rueckgaben) oder (false, Fehlertext); nichts wirft
local function try(fn, ...)
  local r = pack(pcall(fn, ...))
  if not r[1] then return false, tostring(r[2]), nil end
  local parts = {}
  for i = 2, r.n do parts[#parts + 1] = show_value(r[i]) end
  local first = r[2]
  return true, (#parts == 0) and "(keine Rueckgabe)" or table.concat(parts, ", "), first
end

local function sorted(list)
  local copy = {}
  for _, v in ipairs(list) do copy[#copy + 1] = v end
  table.sort(copy)
  return copy
end

-- die Leseliste: nur diese Methoden werden je Typ aufgerufen
local READ = {
  Create_Station = { "getStationName", "isTrainPresent", "isTrainImminent", "isTrainEnroute", "getTrainName", "hasSchedule", "isInAssemblyMode" },
  Create_Signal = { "getState", "isForcedRed", "getSignalType", "listBlockingTrainNames" },
  Create_TrainObserver = { "isTrainPassing", "getPassingTrainName" },
  Create_DisplayLink = { "getSize", "getCursorPos", "isColor", "isColour" },
  monitor = { "getSize", "isColor", "isColour", "getTextScale" },
  modem = { "isWireless" },
}

-- was das Konzept 1.1 an Methoden erwartet (Kapitel 19, 20, 22)
local EXPECTED = {
  Create_Station = { "getStationName", "setStationName", "isTrainPresent", "isTrainImminent", "isTrainEnroute", "getTrainName", "setTrainName",
    "hasSchedule", "getSchedule", "setSchedule", "canTrainReach", "distanceTo", "isInAssemblyMode", "setAssemblyMode", "assemble", "disassemble" },
  Create_Signal = { "getState", "isForcedRed", "setForcedRed", "getSignalType", "cycleSignalType", "listBlockingTrainNames" },
  Create_TrainObserver = { "isTrainPassing", "getPassingTrainName" },
  Create_DisplayLink = { "setCursorPos", "getCursorPos", "getSize", "isColor", "isColour", "write", "writeBytes", "clearLine", "clear", "update" },
}

local function has(list, name)
  for _, v in ipairs(list) do if v == name then return true end end
  return false
end

local started = os.epoch and os.epoch("utc") or 0

-- 1. Umgebung -------------------------------------------------------------------------------------------------------------
section("Umgebung")
add("Programm: crn_probe (Messprogramm, nur lesend)")
add("_HOST: " .. tostring(_HOST))
add("os.version: " .. select(2, try(os.version)))
add("Computer-ID: " .. select(2, try(os.getComputerID)) .. "  Beschriftung: " .. select(2, try(os.getComputerLabel)))
if term and term.getSize then add("term.getSize: " .. select(2, try(term.getSize))) end
if term and term.isColor then add("term.isColor: " .. select(2, try(term.isColor))) end
if fs then
  add("fs.getFreeSpace('/'): " .. select(2, try(fs.getFreeSpace, "/")))
  if fs.getCapacity then add("fs.getCapacity('/'): " .. select(2, try(fs.getCapacity, "/"))) end
end
add("http: " .. (http and "vorhanden" or "NICHT verfuegbar"))
if http and http.checkURL then add("http.checkURL(raw.githubusercontent.com): " .. select(2, try(http.checkURL, "https://raw.githubusercontent.com/"))) end

-- 2. Geraete ----------------------------------------------------------------------------------------------------------------
section("Geraete (peripheral.getNames)")
local names = sorted(peripheral and peripheral.getNames and peripheral.getNames() or {})
local by_type = {}
local devices = {}
for _, name in ipairs(names) do
  local t = pack(pcall(peripheral.getType, name))
  local types = {}
  for i = 2, t.n do if t[i] ~= nil then types[#types + 1] = tostring(t[i]) end end
  local ok_m, methods = pcall(peripheral.getMethods, name)
  if not ok_m or type(methods) ~= "table" then methods = {} end
  methods = sorted(methods)
  local primary = types[1] or "unbekannt"
  devices[#devices + 1] = { name = name, types = types, primary = primary, methods = methods }
  by_type[primary] = (by_type[primary] or 0) + 1
  add("")
  add(name .. "   Typ: " .. table.concat(types, ", "))
  add("  Methoden (" .. #methods .. "): " .. table.concat(methods, ", "))
end
if #devices == 0 then add("(keine Geraete angeschlossen)") end

-- 3. Zustand der bekannten Typen ----------------------------------------------------------------------------------------------
local function wrap(name)
  local ok, obj = pcall(peripheral.wrap, name)
  if ok and obj then return obj end
  return nil
end

local function read_all(device, kind)
  local obj = wrap(device.name)
  if not obj then add("  wrap fehlgeschlagen"); return end
  for _, method in ipairs(READ[kind]) do
    if has(device.methods, method) and type(obj[method]) == "function" then
      local ok, text = try(obj[method])
      add("  " .. method .. "(): " .. (ok and text or ("FEHLER: " .. text)))
    elseif not has(device.methods, method) then
      add("  " .. method .. "(): Methode gibt es hier nicht")
    end
  end
  return obj
end

section("Create-Bahnhoefe (A02, A04)")
local stations = 0
for _, device in ipairs(devices) do
  if device.primary == "Create_Station" then
    stations = stations + 1
    add("")
    add(device.name)
    local obj = read_all(device, "Create_Station")
    if obj then
      local present = pcall(obj.isTrainPresent) and select(2, pcall(obj.isTrainPresent)) == true
      if present and has(device.methods, "getSchedule") then
        local ok, text = try(obj.getSchedule)
        add("  getSchedule(): " .. (ok and text or ("FEHLER: " .. text)))
        if textutils and textutils.serializeJSON then
          local okj, json = pcall(textutils.serializeJSON, select(2, pcall(obj.getSchedule)))
          if okj then add("  getSchedule() als JSON: " .. json) end
        end
      else
        add("  (kein Zug anwesend: getSchedule wird nicht aufgerufen; zum Messen einen Zug mit Fahrplan an diese Station stellen und das Programm erneut starten)")
      end
      if opts.reach then
        for _, method in ipairs({ "canTrainReach", "distanceTo" }) do
          if has(device.methods, method) then
            local ok, text = try(obj[method], opts.reach)
            add("  " .. method .. "(" .. string.format("%q", opts.reach) .. "): " .. (ok and text or ("FEHLER: " .. text)))
          end
        end
      end
    end
  end
end
if stations == 0 then add("(kein Create_Station angeschlossen)") end

section("Create-Signale (A09)")
local signals = 0
for _, device in ipairs(devices) do
  if device.primary == "Create_Signal" then
    signals = signals + 1
    add("")
    add(device.name)
    read_all(device, "Create_Signal")
  end
end
if signals == 0 then add("(kein Create_Signal angeschlossen)") end

section("Create-Beobachter (A03)")
local observers = 0
for _, device in ipairs(devices) do
  if device.primary == "Create_TrainObserver" then
    observers = observers + 1
    add("")
    add(device.name)
    read_all(device, "Create_TrainObserver")
  end
end
if observers == 0 then add("(kein Create_TrainObserver angeschlossen)") end

section("Anzeigen und Modems")
for _, device in ipairs(devices) do
  local kind = (device.primary == "monitor" and "monitor") or (device.primary == "modem" and "modem") or (device.primary == "Create_DisplayLink" and "Create_DisplayLink") or nil
  if kind then
    add("")
    add(device.name .. "  (" .. device.primary .. ")")
    read_all(device, kind)
  end
end

-- 4. Vergleich mit dem Konzept (A01) --------------------------------------------------------------------------------------------
section("Vergleich mit den Methoden des Konzepts 1.1 (A01)")
for kind, expected in pairs(EXPECTED) do
  local seen = {}
  local count = 0
  for _, device in ipairs(devices) do
    if device.primary == kind then
      count = count + 1
      for _, m in ipairs(device.methods) do seen[m] = true end
    end
  end
  if count == 0 then
    add(kind .. ": nicht angeschlossen, nicht pruefbar")
  else
    local missing, extra = {}, {}
    for _, m in ipairs(expected) do if not seen[m] then missing[#missing + 1] = m end end
    for m in pairs(seen) do if not has(expected, m) then extra[#extra + 1] = m end end
    table.sort(extra)
    add(kind .. " (" .. count .. " Geraet(e)): fehlt gegenueber dem Konzept: " .. (#missing == 0 and "nichts" or table.concat(missing, ", ")))
    if #extra > 0 then add("  zusaetzlich vorhanden: " .. table.concat(extra, ", ")) end
  end
end

-- 5. Ereignisse (A03) ---------------------------------------------------------------------------------------------------------
if opts.events > 0 then
  section("Ereignisse (" .. opts.events .. " Sekunden)")
  local watched = {}
  for _, e in ipairs({ "train_imminent", "train_arrival", "train_departure", "train_passing", "train_passed", "train_signal_state_change",
    "speed_change", "stress_change", "overstressed", "peripheral", "peripheral_detach", "monitor_touch", "monitor_resize" }) do watched[e] = true end
  print("Ereignisse werden " .. opts.events .. " Sekunden mitgeschrieben. Jetzt Zuege fahren lassen ...")
  local timer = os.startTimer(opts.events)
  local t0 = os.clock()
  local count = 0
  while true do
    local ev = pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then break end
    if watched[ev[1]] then
      count = count + 1
      local parts = {}
      for i = 2, ev.n do parts[#parts + 1] = show_value(ev[i]) end
      add(string.format("+%.1fs  %s  %s", os.clock() - t0, ev[1], table.concat(parts, "  ")))
    end
  end
  add("(" .. count .. " Ereignisse)")
end

section("Ende")
add("Dauer ungefaehr: " .. tostring(((os.epoch and os.epoch("utc") or 0) - started) / 1000) .. " s")

-- Bericht schreiben -----------------------------------------------------------------------------------------------------------
local body = table.concat(lines, "\n") .. "\n"
local ok_w, err_w = pcall(function()
  local fh = fs.open(opts.out, "w")
  if not fh then error("kann " .. opts.out .. " nicht schreiben", 0) end
  fh.write(body)
  fh.close()
end)

print("crn_probe fertig (nur gelesen, nichts geschaltet).")
print("Geraete: " .. #devices .. "   Bahnhoefe: " .. stations .. "   Signale: " .. signals .. "   Beobachter: " .. observers)
for kind, n in pairs(by_type) do print("  " .. kind .. ": " .. n) end
if ok_w then
  print("Bericht: " .. opts.out .. " (" .. #body .. " Byte)")
  print("Senden: pastebin put " .. opts.out .. "   oder   edit " .. opts.out)
else
  print("FEHLER beim Schreiben: " .. tostring(err_w))
end
