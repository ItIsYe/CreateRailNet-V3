--[[
Purpose: Messprogramm Stufe 2 fuer das echte Modpack: misst die Zeit (Spielzeit gegen Echtzeit), die Kosten von Geraeteaufrufen (wichtig fuer 300+ Signale) und prueft die Schreibwege von Signal und Bahnhof so, dass der Ausgangszustand danach wieder hergestellt ist.
Usage: crn_probe2                  alles automatisch, Bericht in crn_probe2.txt
       crn_probe2 --no-write       nur Zeit- und Lesemessungen, nichts wird veraendert
       crn_probe2 --wait 180       so lange (Sekunden) auf einen Zug am Bahnhof warten (Standard 150)
       crn_probe2 --out datei.txt  anderer Dateiname
Notes: Schreibt nur zwei Dinge. 1) Signal: setForcedRed(true), kurz warten, Zustand lesen, dann zurueck auf den vorherigen Wert (wird auch bei Fehlern versucht). 2) Bahnhof: setSchedule mit dem eben gelesenen, UNVERAENDERTEN Fahrplan eines haltenden Zuges. Dabei kann Create den Zug auf den ersten Fahrplaneintrag zuruecksetzen. Beides entfaellt mit --no-write. Kein Redstone, kein rednet, kein Zusammenbauen.
  Senden: pastebin put crn_probe2.txt
]]

local args = { ... }
local opts = { out = "crn_probe2.txt", write = true, wait = 150 }
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--no-write" then opts.write = false; i = i + 1
    elseif a == "--wait" then opts.wait = tonumber(args[i + 1]) or opts.wait; i = i + 2
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --no-write, --wait N, --out DATEI)", 0) end
  end
end

local lines = {}
local function add(text) lines[#lines + 1] = tostring(text); print(tostring(text)) end
local function section(title) add(""); add("== " .. title) end
local function pack(...) return { n = select("#", ...), ... } end

local function show(v)
  if type(v) == "table" and textutils and textutils.serializeJSON then
    local ok, text = pcall(textutils.serializeJSON, v)
    if ok then return text end
  end
  return tostring(v)
end

local function try(fn, ...)
  local r = pack(pcall(fn, ...))
  if not r[1] then return false, tostring(r[2]) end
  local parts = {}
  for i = 2, r.n do parts[#parts + 1] = show(r[i]) end
  return true, (#parts == 0) and "(keine Rueckgabe)" or table.concat(parts, ", "), r[2]
end

local function utc() return os.epoch and os.epoch("utc") / 1000 or 0 end
local function ingame()
  if not os.epoch then return nil end
  local ok, v = pcall(os.epoch, "ingame")
  if ok and type(v) == "number" then return v / 1000 end
  return nil
end

-- wartet seconds (Spielzeit) und schreibt die dabei eintreffenden Create-Ereignisse mit; stop(ev) beendet vorzeitig
local WATCH = { train_imminent = true, train_arrival = true, train_departure = true, train_passing = true, train_passed = true,
  train_signal_state_change = true }
local function wait_events(seconds, label, stop)
  local timer = os.startTimer(seconds)
  local t0 = os.clock()
  local last
  while true do
    local ev = pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then return last end
    if WATCH[ev[1]] then
      local parts = {}
      for i = 2, ev.n do parts[#parts + 1] = tostring(ev[i]) end
      add(string.format("  [%s +%.2fs] %s  %s", label, os.clock() - t0, ev[1], table.concat(parts, "  ")))
      last = ev
      if stop and stop(ev) then return ev end
    end
  end
end

local function wrap(name)
  local ok, obj = pcall(peripheral.wrap, name)
  if ok then return obj end
end

local signals, stations = {}, {}
for _, name in ipairs(peripheral.getNames()) do
  local t = peripheral.getType(name)
  if t == "Create_Signal" then signals[#signals + 1] = name end
  if t == "Create_Station" then stations[#stations + 1] = name end
end
table.sort(signals); table.sort(stations)

section("Umgebung")
add("_HOST: " .. tostring(_HOST))
add("Optionen: write=" .. tostring(opts.write) .. " wait=" .. opts.wait .. "s")
add("Signale: " .. #signals .. "  Bahnhoefe: " .. #stations)

-- 1. Zeit: Spielzeit gegen Echtzeit ------------------------------------------------------------------------------------
section("Zeit: Spielzeit gegen Echtzeit (10 s Spielzeit warten)")
do
  local c0, u0, g0 = os.clock(), utc(), ingame()
  local timer = os.startTimer(10)
  while true do
    local ev, id = os.pullEvent("timer")
    if id == timer then break end
  end
  local c1, u1, g1 = os.clock(), utc(), ingame()
  add(string.format("os.clock: %.2f s  os.epoch(utc): %.2f s  os.epoch(ingame): %s", c1 - c0, u1 - u0, g1 and string.format("%.2f s", g1 - g0) or "nicht verfuegbar"))
  if c1 - c0 > 0 then
    add(string.format("Echtzeit je Spielsekunde: %.2f  (1.00 = Server laeuft mit 20 Ticks/s; rechnerisch %.1f Ticks/s)", (u1 - u0) / (c1 - c0), 20 / math.max((u1 - u0) / (c1 - c0), 0.01)))
  end
end

-- 2. Kosten eines Geraeteaufrufs --------------------------------------------------------------------------------------------
section("Kosten von Geraeteaufrufen (Grundlage fuer 300+ Signale)")
local function bench(label, fn, n)
  local c0, u0 = os.clock(), utc()
  local okc = 0
  for _ = 1, n do if pcall(fn) then okc = okc + 1 end end
  local c1, u1 = os.clock(), utc()
  local dc, du = c1 - c0, u1 - u0
  add(string.format("%s: %d Aufrufe in %.2f s Spielzeit / %.2f s Echtzeit  -> %.1f ms je Aufruf (Spielzeit)  ok=%d", label, n, dc, du, dc / n * 1000, okc))
  return dc / n
end
local per_call
if signals[1] then
  local sig = wrap(signals[1])
  per_call = bench("Signal getState", function() return sig.getState() end, 40)
  bench("Signal isForcedRed", function() return sig.isForcedRed() end, 20)
end
if stations[1] then
  local st = wrap(stations[1])
  bench("Bahnhof isTrainPresent", function() return st.isTrainPresent() end, 40)
  bench("Bahnhof getStationName", function() return st.getStationName() end, 20)
end
do
  local n = 200
  local c0 = os.clock()
  for _ = 1, n do os.queueEvent("probe_nop"); os.pullEvent("probe_nop") end
  add(string.format("Vergleich ohne Geraet (queueEvent/pullEvent): %.1f ms je Runde", (os.clock() - c0) / n * 1000))
end
if per_call then
  add(string.format("Hochrechnung: eine Abfrage aller 300 Signale nacheinander braucht rund %.1f s Spielzeit; bei %d Signalen je Computer rund %.1f s je Computer.",
    300 * per_call, 12, 12 * per_call))
end

-- 3. Signal: Schreibweg ---------------------------------------------------------------------------------------------------
section("Signal: setForcedRed mit Rueckstellung")
if not opts.write then
  add("(uebersprungen: --no-write)")
elseif not signals[1] then
  add("(kein Create_Signal)")
else
  for _, name in ipairs(signals) do
    local sig = wrap(name)
    add("")
    add(name)
    local ok_f, forced = pcall(sig.isForcedRed)
    local ok_s, state0 = pcall(sig.getState)
    add("  vorher: isForcedRed=" .. tostring(ok_f and forced) .. "  getState=" .. tostring(ok_s and state0))
    local okb, blockers = pcall(sig.listBlockingTrainNames)
    add("  listBlockingTrainNames: " .. (okb and show(blockers) or ("FEHLER: " .. tostring(blockers))))
    if ok_f and forced == false then
      local ok, err = pcall(sig.setForcedRed, true)
      add("  setForcedRed(true): " .. (ok and "ok" or ("FEHLER: " .. tostring(err))))
      -- auch bei Strg+T oder Fehler wird zurueckgestellt, danach wird der Fehler weitergegeben
      local okw, werr = pcall(function()
        local ev = wait_events(3, "setForcedRed", function(e) return e[1] == "train_signal_state_change" and e[2] == name end)
        add("  Ereignis nach setForcedRed(true): " .. (ev and ev[1] .. " " .. tostring(ev[3]) or "keines innerhalb 3 s"))
        add("  nachher: isForcedRed=" .. tostring(select(2, pcall(sig.isForcedRed))) .. "  getState=" .. tostring(select(2, pcall(sig.getState))))
      end)
      local okr, errr = pcall(sig.setForcedRed, false)
      add("  setForcedRed(false) (Rueckstellung): " .. (okr and "ok" or ("FEHLER: " .. tostring(errr))))
      if not okw then error(werr, 0) end
      local ev2 = wait_events(3, "Freigabe", function(e) return e[1] == "train_signal_state_change" and e[2] == name end)
      add("  Ereignis nach Rueckstellung: " .. (ev2 and ev2[1] .. " " .. tostring(ev2[3]) or "keines innerhalb 3 s"))
      add("  zurueck: isForcedRed=" .. tostring(select(2, pcall(sig.isForcedRed))) .. "  getState=" .. tostring(select(2, pcall(sig.getState))))
    else
      add("  uebersprungen: Signal ist schon zwangsweise rot oder nicht lesbar")
    end
  end
end

-- 4. Bahnhof: Wegstrecken und Fahrplan-Rundlauf --------------------------------------------------------------------------------
section("Bahnhof: canTrainReach / distanceTo")
for _, name in ipairs(stations) do
  local st = wrap(name)
  local ok_n, own = pcall(st.getStationName)
  add(name .. "  (Name: " .. tostring(ok_n and own) .. ")")
  if ok_n and own then
    for _, method in ipairs({ "canTrainReach", "distanceTo" }) do
      local ok, text = try(st[method], own)
      add("  " .. method .. "(eigener Name): " .. (ok and text or ("FEHLER: " .. text)))
    end
  end
  local ok, text = try(st.canTrainReach, "Gibt Es Nicht 123")
  add("  canTrainReach(unbekannter Name): " .. (ok and text or ("FEHLER: " .. text)))
end

section("Bahnhof: setSchedule mit unveraendertem Fahrplan (Rundlauf)")
if not opts.write then
  add("(uebersprungen: --no-write)")
elseif not stations[1] then
  add("(kein Create_Station)")
else
  local name = stations[1]
  local st = wrap(name)
  add("Warte bis zu " .. opts.wait .. " s auf einen Zug an " .. name .. " ...")
  local arrived = wait_events(opts.wait, "warten", function(e) return e[1] == "train_arrival" and e[2] == name end)
  if not (arrived and arrived[1] == "train_arrival") then
    add("kein Zug angekommen: Rundlauf nicht gemessen (mit --wait laenger warten)")
  else
    local ok_p, present = pcall(st.isTrainPresent)
    if not (ok_p and present) then
      add("Zug ist schon wieder weg: Rundlauf nicht gemessen")
    else
      local ok_t, train = pcall(st.getTrainName)
      local ok_g, sched = pcall(st.getSchedule)
      if not ok_g then
        add("getSchedule FEHLER: " .. tostring(sched))
      else
        local before = show(sched)
        add("Zug: " .. tostring(ok_t and train))
        add("Fahrplan vorher:  " .. before)
        local ok_s, err_s = pcall(st.setSchedule, sched)
        add("setSchedule(gleicher Fahrplan): " .. (ok_s and "ok" or ("FEHLER: " .. tostring(err_s))))
        local ok_a, after_s = pcall(st.getSchedule)
        local after = ok_a and show(after_s) or ("FEHLER: " .. tostring(after_s))
        add("Fahrplan nachher: " .. after)
        add("Ergebnis: Fahrplan " .. (after == before and "UNVERAENDERT" or "VERAENDERT") .. " (Schluessel-Reihenfolge der Ausgabe kann abweichen)")
        add("Danach 40 s beobachten: faehrt der Zug normal weiter?")
        wait_events(40, "danach")
      end
    end
  end
end

section("Ende")
add("Wichtig fuer die Auswertung: Echtzeit je Spielsekunde, ms je Aufruf, Ereignis nach setForcedRed, Ergebnis des Fahrplan-Rundlaufs.")

local body = table.concat(lines, "\n") .. "\n"
local ok_w, err_w = pcall(function()
  local fh = fs.open(opts.out, "w")
  if not fh then error("kann " .. opts.out .. " nicht schreiben", 0) end
  fh.write(body)
  fh.close()
end)
print("")
print(ok_w and ("Bericht: " .. opts.out .. " (" .. #body .. " Byte)  senden: pastebin put " .. opts.out) or ("FEHLER beim Schreiben: " .. tostring(err_w)))
