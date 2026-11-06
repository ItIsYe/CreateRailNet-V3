--[[
Purpose: Alle offenen Messungen in einem Lauf: laedt crn_probe4 (Signal gegen Beobachter) und crn_probe3 (Abfahrt ueber die Train Station) bei Bedarf selbst, fuehrt alles aus, was an diesem Computer moeglich ist, schreibt einen gemeinsamen Bericht (crn_alles.txt) und laedt ihn mit pastebin hoch. Es gibt nur eine Rueckfrage am Anfang.
Usage: crn_alles                    alles Anwendbare nacheinander; vorher einmal j bestaetigen
       crn_alles --hilfe            diese Anleitung (es wird nichts gestartet)
       crn_alles --ja               ohne die Rueckfrage (alles gilt als bestaetigt)
       crn_alles --zeit N           Beobachtungszeit je Signal-Lauf in Sekunden (Standard 150)
       crn_alles --ziel NAME        Zielbahnhof fuer den Rundlauf des Zuges (Probe D); ohne Angabe der erste andere Bahnhof im Fahrplan des Zuges
       crn_alles --ohne-sperre      kein Signal rot sperren (nur beobachten)
       crn_alles --ohne-fahrt       am Bahnhof nur die Proben A bis C, kein Rundlauf des Zuges
       crn_alles --nur signal       nur den Signalteil (oder --nur abfahrt)
       crn_alles --lokal            crn_probe3/crn_probe4 nicht neu laden, vorhandene Dateien benutzen
       crn_alles --nicht-hochladen  den Bericht nicht mit pastebin hochladen
       crn_alles --out datei.txt    anderer Dateiname (Standard crn_alles.txt)
Notes: Welche Teile laufen, ergibt sich aus den Geraeten am Netz des Computers: Signale (und Beobachter) -> S1 beobachten und S2 das am staerksten befahrene Signal rot sperren (nur wenn in S1 ein Zug gesehen wurde; Zug soll davor warten, am Ende wird immer zurueckgestellt); Bahnhof -> B Fahrplan-Proben von crn_probe3 (Fahrplan wird zurueckgestellt, der Zug faehrt bei Probe D nach Bestaetigung zum Zielbahnhof und zurueck). Fehlt etwas, wird der Teil mit Grund uebersprungen. Voraussetzung wie bei den Einzelprogrammen: Computer mit Kabelmodem an den Geraeten, Zuege fahren; http muss erlaubt sein (Download und pastebin).
]]

local args = { ... }
local unpack = table.unpack or unpack
local opts = { out = "crn_alles.txt", yes = false, wait = 150, goal = nil, hold = true, trip = true, only = nil, upload = true, refresh = true }

do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--ja" then opts.yes = true; i = i + 1
    elseif a == "--hilfe" or a == "-h" then opts.help = true; i = i + 1
    elseif a == "--zeit" then opts.wait = tonumber(args[i + 1]) or opts.wait; i = i + 2
    elseif a == "--ziel" then opts.goal = args[i + 1]; i = i + 2
    elseif a == "--ohne-sperre" then opts.hold = false; i = i + 1
    elseif a == "--ohne-fahrt" then opts.trip = false; i = i + 1
    elseif a == "--nur" then opts.only = args[i + 1]; i = i + 2
    elseif a == "--lokal" then opts.refresh = false; i = i + 1
    elseif a == "--nicht-hochladen" then opts.upload = false; i = i + 1
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --hilfe, --ja, --zeit N, --ziel NAME, --ohne-sperre, --ohne-fahrt, --nur signal|abfahrt, --lokal, --nicht-hochladen, --out DATEI)", 0) end
  end
  if opts.only and opts.only ~= "signal" and opts.only ~= "abfahrt" then
    error("--nur versteht signal oder abfahrt, nicht " .. tostring(opts.only), 0)
  end
end

if opts.help then
  print("crn_alles - alle offenen Messungen in einem Lauf")
  print("  crn_alles --ja               ohne die Rueckfrage")
  print("  crn_alles --zeit N           Sekunden je Signalteil (Standard 150)")
  print("  crn_alles --ziel NAME        Zielbahnhof fuer den Rundlauf (nicht der eigene)")
  print("  crn_alles --ohne-sperre      kein Signal sperren")
  print("  crn_alles --ohne-fahrt       kein Rundlauf des Zuges")
  print("  crn_alles --nur signal       nur Signale (oder --nur abfahrt)")
  print("  crn_alles --lokal            nichts neu laden")
  print("  crn_alles --nicht-hochladen  kein pastebin")
  print("  crn_alles --out datei.txt    anderer Dateiname")
  print("Teile: S1 Signale beobachten, S2 Signal sperren, B Abfahrt (crn_probe3).")
  print("Am Ende: Bericht " .. opts.out .. " und Upload mit pastebin.")
  return
end

local BASE = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/probe/"
local FILES = { s1 = "crn_alles_s1.txt", s2 = "crn_alles_s2.txt", b = "crn_alles_b.txt" }

local lines = {}
local function add(text) lines[#lines + 1] = tostring(text); print(tostring(text)) end
local function section(title) add(""); add("== " .. title) end
local function plain(err) return (tostring(err):gsub("^.-:%d+: ", "")) end

local function read_file(path)
  if not fs.exists(path) then return nil end
  local fh = fs.open(path, "r")
  if not fh then return nil end
  local text = fh.readAll()
  fh.close()
  return text
end

local function write_file(path, text)
  local fh = fs.open(path, "w")
  if not fh then error("kann " .. path .. " nicht schreiben", 0) end
  fh.write(text)
  fh.close()
end

-- Namen mit Leerzeichen muessen fuer shell.run in Anfuehrungszeichen stehen (shell.run zerlegt den Text neu)
local function quoted(text)
  text = tostring(text)
  if text:find("%s") then return '"' .. text .. '"' end
  return text
end

-- Ergebnisse je Teil
local phases, order = {}, {}
local function set_phase(key, title, state, note)
  if not phases[key] then order[#order + 1] = key end
  phases[key] = { title = title, state = state, note = note }
  add(string.format("  [%s] %s%s", state, title, note and (": " .. note) or ""))
end

-- Programm beschaffen: neu laden, sonst die vorhandene Datei benutzen
local function ensure_program(name)
  local path = name .. ".lua"
  if not opts.refresh then
    if fs.exists(path) then return true end
    add("  " .. path .. " fehlt und --lokal verbietet den Download")
    return false
  end
  if http and http.get then
    local ok, res, err = pcall(http.get, BASE .. path)
    if ok and res then
      local body = res.readAll()
      res.close()
      if body and #body > 200 and body:find("Purpose:", 1, true) then
        write_file(path, body)
        add("  geladen: " .. path .. " (" .. #body .. " Byte)")
        return true
      end
      add("  Download von " .. path .. " war unbrauchbar")
    else
      add("  Download von " .. path .. " fehlgeschlagen: " .. tostring(ok and err or res))
    end
  else
    add("  http ist nicht verfuegbar")
  end
  if fs.exists(path) then
    add("  es wird die vorhandene Datei " .. path .. " benutzt")
    return true
  end
  return false
end

local function run_program(name, ...)
  local ok, result = pcall(shell.run, name, ...)
  if not ok then return false, plain(result) end
  if result == false then return false, "das Programm hat mit einem Fehler beendet" end
  return true
end

-- Geraete am Netz --------------------------------------------------------------------------------------------------------
local stations, signals, observers = {}, {}, {}
for _, name in ipairs(peripheral.getNames()) do
  local kind = peripheral.getType(name)
  if kind == "Create_Station" then stations[#stations + 1] = name
  elseif kind == "Create_Signal" then signals[#signals + 1] = name
  elseif kind == "Create_TrainObserver" then observers[#observers + 1] = name end
end
table.sort(stations); table.sort(signals); table.sort(observers)

local function call(device, method, ...) return pcall(peripheral.call, device, method, ...) end

-- Bahnhof mit Zug und Zielbahnhof fuer Probe D
local train_station
for _, st in ipairs(stations) do
  local ok, present = call(st, "isTrainPresent")
  if ok and present then train_station = st break end
end
local function station_name(device)
  local ok, name = call(device, "getStationName")
  return ok and type(name) == "string" and name ~= "" and name or nil
end
-- Ziel des Rundlaufs (Probe D): ausdruecklich angegeben, sonst "auto" = erster anderer Bahnhof im Fahrplan des Zuges (crn_probe3 liest ihn,
-- sobald der Zug am Bahnhof steht; der Zug fuhr dorthin schon, also ist er erreichbar)
local goal = opts.goal
local own = train_station and station_name(train_station)
local goal_note
if goal and own and goal == own then
  -- Create schickt einen Zug nicht direkt vom selben Bahnhof wieder dorthin (docs/MESSWERTE.md M20)
  goal_note = "Ziel " .. goal .. " ist der eigene Bahnhof: Create schickt einen Zug nicht direkt wieder dorthin, es gibt keinen Rundlauf (anderen Bahnhof als Ziel nehmen)."
  goal = nil
elseif not goal and opts.trip then
  goal = "auto"
end

local do_signal = #signals > 0 and opts.only ~= "abfahrt"
local do_depart = #stations > 0 and opts.only ~= "signal"

section("Umgebung")
add("_HOST: " .. tostring(_HOST))
local stamp
do
  local ok, text = pcall(function() return os.date("%Y-%m-%d %H:%M", os.epoch("utc") / 1000) end)
  stamp = ok and text or nil
end
if stamp then add("Zeit (UTC): " .. stamp) end
add("Optionen: zeit=" .. opts.wait .. " sperre=" .. tostring(opts.hold) .. " fahrt=" .. tostring(opts.trip) .. " nur=" .. tostring(opts.only) .. " ziel=" .. tostring(opts.goal))
add("Bahnhoefe: " .. #stations .. (#stations > 0 and ("  (" .. table.concat(stations, ", ") .. ")") or "") .. (train_station and ("  Zug steht an " .. train_station) or ""))
add("Signale: " .. #signals .. (#signals > 0 and ("  (" .. table.concat(signals, ", ") .. ")") or ""))
add("Beobachter: " .. #observers .. (#observers > 0 and ("  (" .. table.concat(observers, ", ") .. ")") or ""))
if goal_note then add(goal_note) end

-- Plan und eine Rueckfrage -------------------------------------------------------------------------------------------------
section("Plan")
local plan = {}
if do_signal then
  plan[#plan + 1] = "S1  Signale und Beobachter beobachten (" .. opts.wait .. " s, nur lesen); in der Zeit Zuege fahren lassen"
  if opts.hold then plan[#plan + 1] = "S2  das am staerksten befahrene Signal rot sperren (" .. opts.wait .. " s), ein Zug soll davor warten; wird danach freigegeben" end
end
if do_depart then
  plan[#plan + 1] = "B   Fahrplan-Proben am Bahnhof (Fahrplan wird geaendert und zurueckgestellt)" .. ((opts.trip and goal) and (goal == "auto" and ", Rundlauf des Zuges zu einem anderen Bahnhof aus seinem Fahrplan und zurueck" or (", Rundlauf des Zuges nach " .. goal .. " und zurueck")) or ", ohne Rundlauf")
end
if opts.upload and #plan > 0 then plan[#plan + 1] = "    Am Ende wird der Bericht " .. opts.out .. " mit pastebin hochgeladen" end
if #plan == 0 then
  add("Nichts zu tun: kein Signal und kein Bahnhof am Netz dieses Computers (Kabelmodem an die Geraete, Computer am Kabelnetz).")
else
  for _, line in ipairs(plan) do add(line) end
end

local confirmed = #plan > 0
if confirmed and not opts.yes then
  add("Alles ausfuehren? Weg und Zuege frei, Signalsperre und Zugfahrt sind in Ordnung. (j/n)")
  confirmed = (read() == "j")
  if not confirmed then add("abgebrochen: nichts wurde veraendert") end
end

-- Teile -------------------------------------------------------------------------------------------------------------------
local reports = {}
local busiest

-- das Signal mit den meisten Wechseln auf ROT in der Kurzfassung von S1
local function pick_busiest(text)
  local best, best_count
  for name, rest in text:gmatch("\nSignal (%S+) getState: ([^\n]*)") do
    local _, count = rest:gsub("RED %(", "")
    if count > 0 and (not best_count or count > best_count) then best, best_count = name, count end
  end
  return best, best_count
end

local function phase_signals()
  section("S1: Signale und Beobachter beobachten")
  if not ensure_program("crn_probe4") then
    set_phase("S1", "Signale beobachten", "FEHLER", "crn_probe4.lua nicht verfuegbar")
    set_phase("S2", "Signal sperren", "uebersprungen", "S1 nicht gelaufen")
    return
  end
  local ok, err = run_program("crn_probe4", "--wait", tostring(opts.wait), "--out", FILES.s1)
  reports.s1 = read_file(FILES.s1)
  if not ok or not reports.s1 then
    set_phase("S1", "Signale beobachten", "FEHLER", err or "kein Bericht")
    set_phase("S2", "Signal sperren", "uebersprungen", "S1 nicht gelaufen")
    return
  end
  set_phase("S1", "Signale beobachten", "ok", "Bericht " .. FILES.s1)
  local count
  busiest, count = pick_busiest("\n" .. reports.s1)

  section("S2: Signal rot sperren, Zug davor warten lassen")
  if not opts.hold then
    set_phase("S2", "Signal sperren", "uebersprungen", "--ohne-sperre")
    return
  end
  if not busiest then
    set_phase("S2", "Signal sperren", "uebersprungen", "in S1 wurde kein Zug an einem Signal gesehen; eine Sperre wuerde ins Leere laufen")
    return
  end
  add("Gesperrt wird " .. busiest .. " (" .. count .. " Wechsel auf ROT in S1); Zuege halten dort bis zu " .. opts.wait .. " s.")
  local ok_b, forced_before = call(busiest, "isForcedRed")
  local ok2, err2 = run_program("crn_probe4", "--sperre-an", busiest, "--ja", "--wait", tostring(opts.wait), "--out", FILES.s2)
  reports.s2 = read_file(FILES.s2)
  -- Sicherheitsnetz: das Einzelprogramm gibt die Sperre selbst zurueck; ist das Signal trotzdem noch gesperrt, wird es hier freigegeben
  local ok_a, forced_after = call(busiest, "isForcedRed")
  if ok_b and forced_before == false and ok_a and forced_after == true then
    call(busiest, "setForcedRed", false)
    local ok_c, forced_check = call(busiest, "isForcedRed")
    add("WARNUNG: " .. busiest .. " war nach S2 noch gesperrt; freigegeben, isForcedRed danach " .. (ok_c and tostring(forced_check) or "unbekannt") .. ". Bitte am Signal pruefen.")
  end
  if not ok2 or not reports.s2 then
    set_phase("S2", "Signal sperren", "FEHLER", err2 or "kein Bericht")
  else
    set_phase("S2", "Signal sperren", "ok", "Bericht " .. FILES.s2 .. ", " .. busiest)
  end
end

local function phase_depart()
  section("B: Abfahrt ueber die Train Station (crn_probe3)")
  if not ensure_program("crn_probe3") then
    set_phase("B", "Abfahrt ueber die Station", "FEHLER", "crn_probe3.lua nicht verfuegbar")
    return
  end
  local call_args = { "--ja", "--out", FILES.b }
  if train_station then call_args[#call_args + 1] = "--station"; call_args[#call_args + 1] = train_station end
  if opts.trip and goal then call_args[#call_args + 1] = "--ziel"; call_args[#call_args + 1] = quoted(goal) end
  if not train_station then add("Kein Zug an einem Bahnhof: crn_probe3 wartet bis zu 150 s auf eine Ankunft.") end
  local ok, err = run_program("crn_probe3", unpack(call_args))
  reports.b = read_file(FILES.b)
  if not ok or not reports.b then
    set_phase("B", "Abfahrt ueber die Station", "FEHLER", err or "kein Bericht")
  else
    local note = "Bericht " .. FILES.b .. ((opts.trip and goal) and (goal == "auto" and ", Rundlauf zu einem Bahnhof aus dem Fahrplan des Zuges" or (", mit Rundlauf nach " .. goal)) or ", ohne Rundlauf")
    set_phase("B", "Abfahrt ueber die Station", "ok", note)
  end
end

if confirmed then
  if do_signal then phase_signals() end
  if do_depart then phase_depart() end
end

-- Bericht ------------------------------------------------------------------------------------------------------------------
if confirmed then
  if not do_signal then
    set_phase("S1", "Signale beobachten", "uebersprungen", opts.only == "abfahrt" and "--nur abfahrt" or "kein Signal am Netz")
    set_phase("S2", "Signal sperren", "uebersprungen", opts.only == "abfahrt" and "--nur abfahrt" or "kein Signal am Netz")
  end
  if not do_depart then
    set_phase("B", "Abfahrt ueber die Station", "uebersprungen", opts.only == "signal" and "--nur signal" or "kein Bahnhof am Netz")
  end
end

local function extract_summary(text)
  local a = text:find("== Ergebnis (Kurzfassung)", 1, true)
  if not a then return nil end
  local b = text:find("\n== ", a + 3, true)
  return text:sub(a, b and (b - 1) or #text)
end

if confirmed then
  section("Ergebnis je Teil")
  for _, key in ipairs(order) do
    local p = phases[key]
    add(string.format("%s  %s: %s%s", key, p.title, p.state, p.note and (" (" .. p.note .. ")") or ""))
  end
  section("Kurzfassungen")
  for _, entry in ipairs({ { "S1", "s1" }, { "S2", "s2" }, { "B", "b" } }) do
    local text = reports[entry[2]]
    if text then
      add("--- " .. entry[1] .. " (" .. FILES[entry[2]] .. ") ---")
      add(extract_summary(text) or "(keine Kurzfassung im Bericht)")
    end
  end
  section("Vollstaendige Berichte")
  for _, entry in ipairs({ { "S1", "s1" }, { "S2", "s2" }, { "B", "b" } }) do
    local text = reports[entry[2]]
    if text then
      add("--- " .. entry[1] .. " (" .. FILES[entry[2]] .. ") ---")
      lines[#lines + 1] = text    -- ohne erneute Bildschirmausgabe
    end
  end
end

local body = table.concat(lines, "\n") .. "\n"
local ok_w, err_w = pcall(write_file, opts.out, body)
print("")
if not ok_w then
  print("FEHLER beim Schreiben: " .. tostring(err_w))
elseif confirmed then
  print("Bericht: " .. opts.out .. " (" .. #body .. " Byte)")
  if opts.upload then
    print("Lade hoch ...")
    local ok_u, res_u = run_program("pastebin", "put", opts.out)
    if not ok_u then print("Hochladen fehlgeschlagen (" .. tostring(res_u) .. "). Von Hand: pastebin put " .. opts.out .. "   (oder den Bericht hier einfuegen)") end
  else
    print("Senden: pastebin put " .. opts.out .. "   (oder den Bericht hier einfuegen)")
  end
end
