--[[
Purpose: Alle Messungen zur Abfahrt in einem Lauf: laedt crn_probe3 (Abfahrt ueber die Train Station) bei Bedarf selbst, fuehrt es am Bahnhof aus, schreibt einen Bericht (crn_alles.txt) und laedt ihn mit pastebin hoch. Es gibt nur eine Rueckfrage am Anfang.
Usage: crn_alles                    Fahrplan-Proben am Bahnhof; vorher einmal j bestaetigen
       crn_alles --hilfe            diese Anleitung (es wird nichts gestartet)
       crn_alles --ja               ohne die Rueckfrage (alles gilt als bestaetigt)
       crn_alles --ziel NAME        Zielbahnhof fuer den Rundlauf des Zuges (Probe D); ohne Angabe der erste andere Bahnhof im Fahrplan des Zuges
       crn_alles --ohne-fahrt       nur die Proben A bis C, kein Rundlauf des Zuges
       crn_alles --lokal            crn_probe3 nicht neu laden, vorhandene Datei benutzen
       crn_alles --nicht-hochladen  den Bericht nicht mit pastebin hochladen
       crn_alles --out datei.txt    anderer Dateiname (Standard crn_alles.txt)
Notes: Ein Computer mit Kabelmodem an einem Create_Station, an dem ein Zug steht. Der Fahrplan wird geaendert und zurueckgestellt, der Zug faehrt bei Probe D nach Bestaetigung zum Zielbahnhof und zurueck. Fehlt der Bahnhof, wird der Lauf mit Grund uebersprungen. http muss erlaubt sein (Download und pastebin).
]]

local args = { ... }
local unpack = table.unpack or unpack
local opts = { out = "crn_alles.txt", yes = false, goal = nil, trip = true, upload = true, refresh = true }

do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--ja" then opts.yes = true; i = i + 1
    elseif a == "--hilfe" or a == "-h" then opts.help = true; i = i + 1
    elseif a == "--ziel" then opts.goal = args[i + 1]; i = i + 2
    elseif a == "--ohne-fahrt" then opts.trip = false; i = i + 1
    elseif a == "--lokal" then opts.refresh = false; i = i + 1
    elseif a == "--nicht-hochladen" then opts.upload = false; i = i + 1
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --hilfe, --ja, --ziel NAME, --ohne-fahrt, --lokal, --nicht-hochladen, --out DATEI)", 0) end
  end
end

if opts.help then
  print("crn_alles - Messung der Abfahrt ueber die Train Station")
  print("  crn_alles --ja               ohne die Rueckfrage")
  print("  crn_alles --ziel NAME        Zielbahnhof fuer den Rundlauf (nicht der eigene)")
  print("  crn_alles --ohne-fahrt       nur Proben A bis C, kein Rundlauf des Zuges")
  print("  crn_alles --lokal            crn_probe3 nicht neu laden")
  print("  crn_alles --nicht-hochladen  kein pastebin")
  print("  crn_alles --out datei.txt    anderer Dateiname")
  print("Messung: Abfahrt ueber die Train Station (crn_probe3).")
  print("Am Ende: Bericht " .. opts.out .. " und Upload mit pastebin.")
  return
end

local BASE = "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/probe/"
local REPORT = "crn_alles_abfahrt.txt"

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
local stations = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "Create_Station" then stations[#stations + 1] = name end
end
table.sort(stations)

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

local do_depart = #stations > 0

section("Umgebung")
add("_HOST: " .. tostring(_HOST))
local stamp
do
  local ok, text = pcall(function() return os.date("%Y-%m-%d %H:%M", os.epoch("utc") / 1000) end)
  stamp = ok and text or nil
end
if stamp then add("Zeit (UTC): " .. stamp) end
add("Optionen: fahrt=" .. tostring(opts.trip) .. " ziel=" .. tostring(opts.goal))
add("Bahnhoefe: " .. #stations .. (#stations > 0 and ("  (" .. table.concat(stations, ", ") .. ")") or "") .. (train_station and ("  Zug steht an " .. train_station) or ""))
if goal_note then add(goal_note) end

-- Plan und eine Rueckfrage -------------------------------------------------------------------------------------------------
section("Plan")
local plan = {}
if do_depart then
  plan[#plan + 1] = "Fahrplan-Proben am Bahnhof (Fahrplan wird geaendert und zurueckgestellt)" .. ((opts.trip and goal) and (goal == "auto" and ", Rundlauf des Zuges zu einem anderen Bahnhof aus seinem Fahrplan und zurueck" or (", Rundlauf des Zuges nach " .. goal .. " und zurueck")) or ", ohne Rundlauf")
end
if opts.upload and #plan > 0 then plan[#plan + 1] = "Am Ende wird der Bericht " .. opts.out .. " mit pastebin hochgeladen" end
if #plan == 0 then
  add("Nichts zu tun: kein Bahnhof am Netz dieses Computers (Kabelmodem an den Bahnhof, Computer am Kabelnetz).")
else
  for _, line in ipairs(plan) do add(line) end
end

local confirmed = #plan > 0
if confirmed and not opts.yes then
  add("Ausfuehren? Weg und Zug sind frei, die Zugfahrt ist in Ordnung. (j/n)")
  confirmed = (read() == "j")
  if not confirmed then add("abgebrochen: nichts wurde veraendert") end
end

-- Teile -------------------------------------------------------------------------------------------------------------------
local report

local function phase_depart()
  section("Abfahrt ueber die Train Station (crn_probe3)")
  if not ensure_program("crn_probe3") then
    set_phase("Abfahrt", "Abfahrt ueber die Station", "FEHLER", "crn_probe3.lua nicht verfuegbar")
    return
  end
  local call_args = { "--ja", "--out", REPORT }
  if train_station then call_args[#call_args + 1] = "--station"; call_args[#call_args + 1] = train_station end
  if opts.trip and goal then call_args[#call_args + 1] = "--ziel"; call_args[#call_args + 1] = quoted(goal) end
  if not train_station then add("Kein Zug an einem Bahnhof: crn_probe3 wartet bis zu 150 s auf eine Ankunft.") end
  local ok, err = run_program("crn_probe3", unpack(call_args))
  report = read_file(REPORT)
  if not ok or not report then
    set_phase("Abfahrt", "Abfahrt ueber die Station", "FEHLER", err or "kein Bericht")
  else
    local note = "Bericht " .. REPORT .. ((opts.trip and goal) and (goal == "auto" and ", Rundlauf zu einem Bahnhof aus dem Fahrplan des Zuges" or (", mit Rundlauf nach " .. goal)) or ", ohne Rundlauf")
    set_phase("Abfahrt", "Abfahrt ueber die Station", "ok", note)
  end
end

if confirmed and do_depart then phase_depart() end

-- Bericht ------------------------------------------------------------------------------------------------------------------
local function extract_summary(text)
  local a = text:find("== Ergebnis (Kurzfassung)", 1, true)
  if not a then return nil end
  local b = text:find("\n== ", a + 3, true)
  return text:sub(a, b and (b - 1) or #text)
end

if confirmed then
  section("Ergebnis")
  for _, key in ipairs(order) do
    local p = phases[key]
    add(string.format("%s: %s%s", p.title, p.state, p.note and (" (" .. p.note .. ")") or ""))
  end
  if report then
    section("Kurzfassung")
    add(extract_summary(report) or "(keine Kurzfassung im Bericht)")
    section("Vollstaendiger Bericht")
    lines[#lines + 1] = report    -- ohne erneute Bildschirmausgabe
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
