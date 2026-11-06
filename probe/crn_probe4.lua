--[[
Purpose: Messprogramm Stufe 4 fuer das echte Modpack: misst, was ein Create-Signal bei einer Zugdurchfahrt selbst meldet, und stellt es dem Beobachter gegenueber. Frage dahinter: Koennte ein Knoten die Raeumung auch ohne Beobachter nachweisen (Zugname in listBlockingTrainNames, Wechsel von getState)? Bisher gemessen ist nur der Ruhezustand (docs/MESSWERTE.md M03, M08), nie ein Signal mit Zug.
Usage: crn_probe4                          alle Signale und Beobachter am Netz beobachten (Standard 180 s), dazu einen oder mehrere Zuege durchfahren lassen
       crn_probe4 --signal NAME[,NAME]     nur diese Signale (zum Beispiel Create_Signal_0)
       crn_probe4 --beobachter NAME[,NAME] nur diese Beobachter
       crn_probe4 --sperre                 zusaetzlich: das erste Signal rot sperren (setForcedRed), damit ein Zug davor warten muss; wird vorher mit j bestaetigt und am Ende immer zurueckgestellt
       crn_probe4 --wait N                 Dauer der Beobachtung in Sekunden (Standard 180)
       crn_probe4 --poll S                 Abfrageabstand in Sekunden (Standard 0.2)
       crn_probe4 --out datei.txt          anderer Dateiname (Standard crn_probe4.txt)
Notes: Aufbau wie am Knoten: der Computer haengt ueber Kabelmodem am Einfahrtssignal und an den Beobachtern (Einfahrt und Ausfahrt). Der Lauf liest nur (getState, isForcedRed, listBlockingTrainNames, isTrainPassing, getPassingTrainName) und hoert alle Ereignisse train_*; geschrieben wird nur mit --sperre (setForcedRed). Empfohlen: erst ein Lauf ohne --sperre mit zwei durchfahrenden Zuegen, dann einer mit --sperre, bei dem ein Zug vor dem roten Signal warten muss.
  Senden: pastebin put crn_probe4.txt   (oder den Bericht hier einfuegen)
]]

local args = { ... }
local opts = { out = "crn_probe4.txt", wait = 180, poll = 0.2, signals = nil, observers = nil, hold = false }

local function split(text)
  local out = {}
  for part in tostring(text):gmatch("[^,]+") do out[#out + 1] = part end
  return out
end

do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--sperre" then opts.hold = true; i = i + 1
    elseif a == "--wait" then opts.wait = tonumber(args[i + 1]) or opts.wait; i = i + 2
    elseif a == "--poll" then opts.poll = math.max(0.05, tonumber(args[i + 1]) or opts.poll); i = i + 2
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    elseif a == "--signal" then opts.signals = split(args[i + 1] or ""); i = i + 2
    elseif a == "--beobachter" then opts.observers = split(args[i + 1] or ""); i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --signal NAMEN, --beobachter NAMEN, --sperre, --wait N, --poll S, --out DATEI)", 0) end
  end
end

local lines = {}
local function add(text) lines[#lines + 1] = tostring(text); print(tostring(text)) end
local function section(title) add(""); add("== " .. title) end
local function pack(...) return { n = select("#", ...), ... } end
local function plain(err) return (tostring(err):gsub("^.-:%d+: ", "")) end

-- Namen einer Liste als sortierter Text ("" fuer leer)
local function names_text(list)
  if type(list) ~= "table" then return tostring(list) end
  local out = {}
  for _, v in ipairs(list) do out[#out + 1] = tostring(v) end
  table.sort(out)
  return table.concat(out, ",")
end

local function show(v)
  if type(v) == "table" and textutils and textutils.serializeJSON then
    local ok, text = pcall(textutils.serializeJSON, v)
    if ok then return text end
  end
  if type(v) == "table" then return "{" .. names_text(v) .. "}" end
  return tostring(v)
end

local function call(device, method, ...) return pcall(peripheral.call, device, method, ...) end

-- Geraete ---------------------------------------------------------------------------------------------------------------
local all = { signal = {}, observer = {} }
for _, name in ipairs(peripheral.getNames()) do
  local kind = peripheral.getType(name)
  if kind == "Create_Signal" then all.signal[#all.signal + 1] = name
  elseif kind == "Create_TrainObserver" then all.observer[#all.observer + 1] = name end
end
table.sort(all.signal); table.sort(all.observer)

local function pick(list, wanted, label)
  if not wanted then return list end
  local out = {}
  for _, w in ipairs(wanted) do
    local known = false
    for _, n in ipairs(list) do if n == w then known = true end end
    if known then out[#out + 1] = w else add("Unbekanntes Geraet (" .. label .. "): " .. w .. " - uebersprungen") end
  end
  return out
end

section("Umgebung")
add("_HOST: " .. tostring(_HOST))
add("Optionen: wait=" .. opts.wait .. " poll=" .. opts.poll .. " sperre=" .. tostring(opts.hold))
local signals = pick(all.signal, opts.signals, "Signal")
local observers = pick(all.observer, opts.observers, "Beobachter")
add("Signale: " .. #signals .. (#signals > 0 and ("  (" .. table.concat(signals, ", ") .. ")") or ""))
add("Beobachter: " .. #observers .. (#observers > 0 and ("  (" .. table.concat(observers, ", ") .. ")") or ""))

local summary = {}
local function result(key, text) summary[#summary + 1] = key .. ": " .. text end

local t0 = 0
local function now() return os.clock() - t0 end
local changes, events, last = {}, {}, {}

-- Wert merken; eine Aenderung kommt mit Zeit ins Protokoll
local function track(device, field, value)
  local key = device .. "|" .. field
  if last[key] ~= value then
    last[key] = value
    local rec = { t = now(), dev = device, field = field, value = value }
    changes[#changes + 1] = rec
    add(string.format("  [+%.2fs] %s %s = %s", rec.t, device, field, value == "" and "(leer)" or value))
  end
end

local function poll_all()
  for _, s in ipairs(signals) do
    local ok, state = call(s, "getState")
    track(s, "getState", ok and tostring(state) or ("FEHLER: " .. plain(state)))
    local ok_f, forced = call(s, "isForcedRed")
    track(s, "isForcedRed", ok_f and tostring(forced) or ("FEHLER: " .. plain(forced)))
    local ok_b, list = call(s, "listBlockingTrainNames")
    track(s, "blockiert", ok_b and names_text(list) or ("FEHLER: " .. plain(list)))
  end
  for _, o in ipairs(observers) do
    local ok, passing = call(o, "isTrainPassing")
    track(o, "isTrainPassing", ok and tostring(passing) or ("FEHLER: " .. plain(passing)))
    local ok_n, name = call(o, "getPassingTrainName")
    track(o, "Zug", ok_n and tostring(name or "") or "")      -- ohne Zug kann der Aufruf einen Fehler melden: das ist normal
  end
end

local function observe(seconds)
  local deadline = os.clock() + seconds
  local timer = os.startTimer(opts.poll)
  while os.clock() < deadline do
    local ev = pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then
      poll_all()
      timer = os.startTimer(opts.poll)
    elseif type(ev[1]) == "string" and ev[1]:find("^train_") then
      local parts = {}
      for i = 2, ev.n do parts[#parts + 1] = tostring(ev[i]) end
      local rec = { t = now(), name = ev[1], dev = tostring(ev[2]), train = ev[3] ~= nil and tostring(ev[3]) or nil, args = table.concat(parts, ", ") }
      events[#events + 1] = rec
      add(string.format("  [+%.2fs] Ereignis %s  %s", rec.t, rec.name, rec.args))
    end
  end
end

-- Ruhezustand -----------------------------------------------------------------------------------------------------------
section("Ruhezustand (vor der Beobachtung)")
for _, s in ipairs(signals) do
  local okm, methods = pcall(peripheral.getMethods, s)
  add(s .. " Methoden: " .. (okm and table.concat(methods, ", ") or ("FEHLER: " .. plain(methods))))
  local ok, state = call(s, "getState")
  add(s .. " getState: " .. (ok and tostring(state) or ("FEHLER: " .. plain(state))))
  local ok_f, forced = call(s, "isForcedRed")
  add(s .. " isForcedRed: " .. (ok_f and tostring(forced) or ("FEHLER: " .. plain(forced))))
  local ok_t, kind = call(s, "getSignalType")
  add(s .. " getSignalType: " .. (ok_t and tostring(kind) or ("FEHLER: " .. plain(kind))))
  local ok_b, list = call(s, "listBlockingTrainNames")
  add(s .. " listBlockingTrainNames: " .. (ok_b and show(list) or ("FEHLER: " .. plain(list))))
end
for _, o in ipairs(observers) do
  local okm, methods = pcall(peripheral.getMethods, o)
  add(o .. " Methoden: " .. (okm and table.concat(methods, ", ") or ("FEHLER: " .. plain(methods))))
  local ok, passing = call(o, "isTrainPassing")
  add(o .. " isTrainPassing: " .. (ok and tostring(passing) or ("FEHLER: " .. plain(passing))))
  local ok_n, name = call(o, "getPassingTrainName")
  add(o .. " getPassingTrainName: " .. (ok_n and tostring(name) or ("FEHLER (ohne Zug normal): " .. plain(name))))
end

-- Auswertung ------------------------------------------------------------------------------------------------------------
-- Zeitraeume, in denen ein Zugname in listBlockingTrainNames eines Signals stand
local function blocking_intervals(device)
  local open, out = {}, {}
  for _, c in ipairs(changes) do
    if c.dev == device and c.field == "blockiert" and not c.value:find("^FEHLER") then
      local present = {}
      for n in c.value:gmatch("[^,]+") do present[n] = true end
      for n in pairs(present) do if not open[n] then open[n] = c.t end end
      for n, from in pairs(open) do
        if not present[n] then
          out[n] = out[n] or {}
          out[n][#out[n] + 1] = { from = from, to = c.t }
          open[n] = nil
        end
      end
    end
  end
  for n, from in pairs(open) do
    out[n] = out[n] or {}
    out[n][#out[n] + 1] = { from = from, to = nil }
  end
  return out
end

-- Zeiten von train_passing / train_passed je Zugname an einem Beobachter
local function observer_times(device)
  local out = {}
  for _, e in ipairs(events) do
    if e.dev == device and (e.name == "train_passing" or e.name == "train_passed") then
      local key = e.train or "?"
      out[key] = out[key] or { passing = {}, passed = {} }
      local list = (e.name == "train_passing") and out[key].passing or out[key].passed
      list[#list + 1] = e.t
    end
  end
  return out
end

local function sorted_keys(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

local function analyse()
  for _, s in ipairs(signals) do
    local seq = {}
    for _, c in ipairs(changes) do
      if c.dev == s and c.field == "getState" then seq[#seq + 1] = string.format("%s (+%.1f s)", c.value, c.t) end
    end
    result("Signal " .. s .. " getState", #seq <= 1 and ("blieb " .. (seq[1] or "ohne Wert")) or table.concat(seq, " -> "))
    local forced_seq = {}
    for _, c in ipairs(changes) do
      if c.dev == s and c.field == "isForcedRed" then forced_seq[#forced_seq + 1] = string.format("%s (+%.1f s)", c.value, c.t) end
    end
    result("Signal " .. s .. " isForcedRed", table.concat(forced_seq, " -> "))
    local count = 0
    for _, e in ipairs(events) do if e.dev == s then count = count + 1 end end
    result("Signal " .. s .. " Ereignisse", count .. " (train_signal_state_change und weitere train_*)")
    local iv = blocking_intervals(s)
    local names = sorted_keys(iv)
    if #names == 0 then
      result("Signal " .. s .. " Zugname in listBlockingTrainNames", "NEIN (immer leer)")
    else
      for _, n in ipairs(names) do
        local parts = {}
        for _, w in ipairs(iv[n]) do
          parts[#parts + 1] = string.format("+%.1f s bis %s", w.from, w.to and string.format("+%.1f s", w.to) or "Ende der Messung")
        end
        result("Signal " .. s .. " nennt Zug " .. n, "JA, " .. table.concat(parts, "; "))
      end
    end
  end
  for _, o in ipairs(observers) do
    local times = observer_times(o)
    local keys = sorted_keys(times)
    if #keys == 0 then
      result("Beobachter " .. o, "keine Ereignisse train_passing/train_passed")
    end
    for _, n in ipairs(keys) do
      local rec = times[n]
      local function list(l)
        local out = {}
        for _, x in ipairs(l) do out[#out + 1] = string.format("+%.1f s", x) end
        return #out > 0 and table.concat(out, ", ") or "-"
      end
      result("Beobachter " .. o .. " Zug " .. n, "passing " .. list(rec.passing) .. "; passed " .. list(rec.passed))
    end
  end
  -- Gegenueberstellung: wann verschwindet der Name im Signal, wann kommt train_passed am Beobachter?
  for _, s in ipairs(signals) do
    local iv = blocking_intervals(s)
    for _, o in ipairs(observers) do
      local times = observer_times(o)
      for _, n in ipairs(sorted_keys(iv)) do
        local first = iv[n][1]
        local rec = times[n]
        if first and first.to and rec and rec.passed[1] then
          result("Abstand Signal " .. s .. " zu Beobachter " .. o .. ", Zug " .. n,
            string.format("Name verschwindet im Signal %.1f s %s train_passed (Abfrageabstand %.2f s)",
              math.abs(first.to - rec.passed[1]), first.to >= rec.passed[1] and "NACH" or "VOR", opts.poll))
        end
      end
    end
  end
end

-- Sperre (optional) -----------------------------------------------------------------------------------------------------
local held = {}
local function release_all()
  for _, h in ipairs(held) do
    local ok, err = call(h.dev, "setForcedRed", h.before)
    local ok_r, forced = call(h.dev, "isForcedRed")
    add(string.format("Rueckstellung %s: setForcedRed(%s) %s, isForcedRed danach %s", h.dev, tostring(h.before), ok and "ok" or ("FEHLER: " .. plain(err)), ok_r and tostring(forced) or "unbekannt"))
  end
  held = {}
end

local function take_hold()
  local s = signals[1]
  if not s then add("--sperre: kein Signal gewaehlt, uebersprungen"); return end
  local ok_f, before = call(s, "isForcedRed")
  if not ok_f then add("--sperre: isForcedRed nicht lesbar (" .. plain(before) .. "), uebersprungen"); return end
  if before == true then add("--sperre: " .. s .. " ist schon rot gesperrt, uebersprungen"); return end
  add("Das Signal " .. s .. " wird rot gesperrt (setForcedRed) und am Ende wieder freigegeben. Ein Zug davor bleibt stehen. Fortfahren? (j/n)")
  local answer = read()
  if answer ~= "j" then add("abgebrochen: keine Sperre"); return end
  local ok, err = call(s, "setForcedRed", true)
  add("setForcedRed(true) an " .. s .. ": " .. (ok and "ok" or ("FEHLER: " .. plain(err))))
  if ok then held[#held + 1] = { dev = s, before = before } end
end

-- Beobachtung -----------------------------------------------------------------------------------------------------------
if #signals == 0 and #observers == 0 then
  add("Keine Signale und keine Beobachter am Netz: nichts zu messen (Kabelmodem an Signal und Beobachter, Computer am Kabelnetz).")
else
  section("Beobachtung (" .. opts.wait .. " s): jetzt Zuege durchfahren lassen")
  local ok, err = pcall(function()
    if opts.hold then take_hold() end
    t0 = os.clock()
    poll_all()
    observe(opts.wait)
  end)
  if not ok then add("Abbruch der Beobachtung: " .. plain(err)) end
  section("Rueckstellung")
  release_all()
  if #held == 0 and not opts.hold then add("(es wurde nichts veraendert)") end
  analyse()
end

section("Ergebnis (Kurzfassung)")
if #summary == 0 then add("(keine Messwerte)") end
for _, line in ipairs(summary) do add(line) end
section("Lesehilfe")
add("Ein Knoten koennte die Raeumung ohne Beobachter nachweisen, wenn (1) der Zugname bei JEDER Durchfahrt in listBlockingTrainNames des Einfahrtssignals steht, (2) er beim Verlassen des Knotens verschwindet und (3) der Abstand zum train_passed am Ausfahrtsbeobachter klein und gleichbleibend ist. Fehlt eines davon, bleibt der Beobachter noetig.")

local body = table.concat(lines, "\n") .. "\n"
local ok_w, err_w = pcall(function()
  local fh = fs.open(opts.out, "w")
  if not fh then error("kann " .. opts.out .. " nicht schreiben", 0) end
  fh.write(body)
  fh.close()
end)
print("")
print(ok_w and ("Bericht: " .. opts.out .. " (" .. #body .. " Byte)  senden: pastebin put " .. opts.out) or ("FEHLER beim Schreiben: " .. tostring(err_w)))
