--[[
Purpose: Messprogramm Stufe 3 fuer das echte Modpack: misst, ob sich die Abfahrt eines Zuges allein ueber die Train Station freigeben laesst (ohne Redstone): ob setSchedule mit geaendertem Inhalt geschrieben und gelesen wird, ob ein Zug nach dem Ende eines Fahrplans haelt, ob create:powered angenommen wird und haelt, und (nur mit --ziel) wie lange es von setSchedule bis zur Abfahrt dauert. Stellt den urspruenglichen Fahrplan danach wieder her.
Usage: crn_probe3                     Zug an einem Bahnhof (Computer mit Kabelmodem am Bahnhof genuegt): Proben A bis C, Zug bleibt am Bahnhof
       crn_probe3 --ziel NAME         zusaetzlich Probe D: der Zug FAEHRT zum Bahnhof NAME und zurueck (Rundlauf, wird vorher bestaetigt)
       crn_probe3 --station GERAET    bestimmtes Geraet (zum Beispiel Create_Station_1); Standard: der erste Bahnhof mit Zug
       crn_probe3 --no-write          nur lesen, nichts wird veraendert
       crn_probe3 --ja                Rueckfragen gelten als mit j beantwortet (fuer den automatischen Ablauf, crn_alles)
       crn_probe3 --wait N            so lange (Sekunden) auf einen Zug warten (Standard 150); bei Probe D so lange auf die Rueckkehr (Standard 240)
       crn_probe3 --out datei.txt     anderer Dateiname (Standard crn_probe3.txt)
Notes: Voraussetzung: ein Zug mit Fahrplan steht am Bahnhof (er wird nach jeder Probe auf seinen Fahrplan zurueckgestellt, auch bei Fehlern). Schreibt nur Fahrplaene ueber setSchedule: A geaenderter Inhalt (eine Sekunde Wartezeit mehr), B Haltefahrplan (ein Eintrag am eigenen Bahnhof, eine Sekunde, nicht zyklisch), C create:powered ohne Strom, D Abfahrt per Fahrplan (nur mit --ziel). Kein Redstone, kein rednet, kein Signal, kein Zusammenbauen. Probe D bewegt den Zug wirklich; nur starten, wenn der Weg zum Ziel frei ist.
  Senden: pastebin put crn_probe3.txt   (oder den Bericht hier einfuegen)
]]

local args = { ... }
local opts = { out = "crn_probe3.txt", write = true, wait = nil, station = nil, goal = nil, yes = false }
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--no-write" then opts.write = false; i = i + 1
    elseif a == "--ja" then opts.yes = true; i = i + 1
    elseif a == "--wait" then opts.wait = tonumber(args[i + 1]); i = i + 2
    elseif a == "--out" then opts.out = args[i + 1] or opts.out; i = i + 2
    elseif a == "--station" then opts.station = args[i + 1]; i = i + 2
    elseif a == "--ziel" then opts.goal = args[i + 1]; i = i + 2
    else error("Unbekannte Option: " .. tostring(a) .. " (erlaubt: --ziel NAME, --station GERAET, --no-write, --ja, --wait N, --out DATEI)", 0) end
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

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepcopy(x) end
  return out
end

-- gleicher Inhalt, unabhaengig von der Reihenfolge der Schluessel
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function plain(err) return (tostring(err):gsub("^.-:%d+: ", "")) end

-- Ereignisse dieses Bahnhofs, mit Zeit seit Beginn der Beobachtung
local WATCH = { train_imminent = true, train_arrival = true, train_departure = true }
local function wait_events(seconds, label, device, stop)
  local timer = os.startTimer(seconds)
  local t0 = os.clock()
  local seen = {}
  while true do
    local ev = pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then return seen end
    if WATCH[ev[1]] and (ev[2] == device or ev[2] == nil) then
      local rec = { name = ev[1], at = os.clock() - t0 }
      seen[#seen + 1] = rec
      add(string.format("  [%s +%.2fs] %s  %s", label, rec.at, ev[1], tostring(ev[3] or "")))
      if stop and stop(rec) then return seen end
    end
  end
end

local function found(events, name)
  for _, e in ipairs(events or {}) do if e.name == name then return e end end
end

local function delay_group(seconds) return { { id = "create:delay", data = { value = seconds, time_unit = 1 } } } end
local function destination(text, groups) return { instruction = { id = "create:destination", data = { text = text } }, conditions = groups } end

-- Geraete -------------------------------------------------------------------------------------------------------------
local stations = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "Create_Station" then stations[#stations + 1] = name end
end
table.sort(stations)

section("Umgebung")
add("_HOST: " .. tostring(_HOST))
add("Optionen: write=" .. tostring(opts.write) .. " ziel=" .. tostring(opts.goal) .. " station=" .. tostring(opts.station))
add("Bahnhoefe am Netz: " .. #stations .. (#stations > 0 and ("  (" .. table.concat(stations, ", ") .. ")") or ""))

local summary = {}
local function result(key, text) summary[#summary + 1] = key .. ": " .. text end

local device
if opts.station then
  device = opts.station
else
  for _, name in ipairs(stations) do
    local ok, present = pcall(peripheral.call, name, "isTrainPresent")
    if ok and present then device = name break end
  end
end

local function call(method, ...) return pcall(peripheral.call, device, method, ...) end

if not device and #stations > 0 then
  local wait = opts.wait or 150
  add("Kein Zug an einem Bahnhof. Warte bis zu " .. wait .. " s auf eine Ankunft ...")
  local timer = os.startTimer(wait)
  while true do
    local ev = pack(os.pullEvent())
    if ev[1] == "timer" and ev[2] == timer then break end
    if ev[1] == "train_arrival" then device = ev[2] break end
  end
end

if not device then
  add("Kein Bahnhof mit Zug: nichts zu messen. Zug an einen Bahnhof stellen (Kabelmodem am Bahnhof, Computer am Kabelnetz) und neu starten.")
else
  section("Lesen am Bahnhof " .. device)
  local ok_n, name = call("getStationName")
  add("getStationName: " .. (ok_n and tostring(name) or ("FEHLER: " .. plain(name))))
  local ok_p, present = call("isTrainPresent")
  add("isTrainPresent: " .. tostring(ok_p and present))
  local ok_t, train = call("getTrainName")
  add("getTrainName: " .. (ok_t and tostring(train) or ("FEHLER: " .. plain(train))))
  local ok_h, has = call("hasSchedule")
  add("hasSchedule: " .. (ok_h and tostring(has) or ("FEHLER: " .. plain(has))))
  local ok_g, original = call("getSchedule")
  add("getSchedule: " .. (ok_g and show(original) or ("FEHLER: " .. plain(original))))
  local ok_c, reach, why = call("canTrainReach", name)
  add("canTrainReach(eigener Name): " .. (ok_c and (tostring(reach) .. ", " .. tostring(why)) or ("FEHLER: " .. plain(reach))))
  if opts.goal then
    local ok_r, r2, w2 = call("canTrainReach", opts.goal)
    add("canTrainReach(" .. opts.goal .. "): " .. (ok_r and (tostring(r2) .. ", " .. tostring(w2)) or ("FEHLER: " .. plain(r2))))
    local ok_d, dist = call("distanceTo", opts.goal)
    add("distanceTo(" .. opts.goal .. "): " .. (ok_d and tostring(dist) or ("FEHLER: " .. plain(dist))))
  end

  local ready = ok_n and ok_p and present and ok_g and type(original) == "table" and type(original.entries) == "table" and #original.entries > 0
  if not opts.write then
    add("(Schreibproben uebersprungen: --no-write)")
  elseif not ready then
    add("Schreibproben nicht moeglich: ein Zug mit lesbarem Fahrplan muss am Bahnhof stehen (er wird zurueckgestellt).")
  else
    -- Rueckstellung: immer versuchen, auch bei Fehlern und nach Strg+T
    local function restore(label)
      local ok, err = call("setSchedule", deepcopy(original))
      local ok_a, after = call("getSchedule")
      local good = ok and ok_a and same(after, original)
      add("  Rueckstellung (" .. label .. "): " .. (ok and "setSchedule ok" or ("FEHLER: " .. plain(err))) .. "; gelesen: " .. (good and "IDENTISCH mit vorher" or "WEICHT AB"))
      if not good then add("  Urspruenglicher Fahrplan zur Handrueckstellung: " .. show(original)) end
      return good
    end

    local function run(title, fn)
      section(title)
      local ok, err = pcall(fn)
      if not ok then add("  ABBRUCH: " .. tostring(err)) end
      restore("nach " .. title:match("^%S+ %S+"):gsub(":$", ""))
    end

    -- A: geaenderter Inhalt ---------------------------------------------------------------------------------------------------
    run("Probe A: setSchedule mit geaendertem Inhalt", function()
      local changed = deepcopy(original)
      local group = changed.entries[1] and changed.entries[1].conditions and changed.entries[1].conditions[1]
      if group then group[#group + 1] = delay_group(1)[1] else changed.entries[1].conditions = { delay_group(1) } end
      local ok, err = call("setSchedule", changed)
      add("setSchedule(Fahrplan + 1 s Wartezeit): " .. (ok and "ok" or ("FEHLER: " .. plain(err))))
      local ok_a, after = call("getSchedule")
      local good = ok and ok_a and same(after, changed)
      add("gelesen: " .. (ok_a and (good and "ENTSPRICHT dem Geschriebenen" or ("WEICHT AB: " .. show(after))) or ("FEHLER: " .. plain(after))))
      result("A geaenderter Inhalt wird geschrieben und gelesen", good and "JA" or "NEIN")
      wait_events(6, "A", device)
    end)

    -- B: Haltefahrplan --------------------------------------------------------------------------------------------------------
    run("Probe B: Haltefahrplan (ein Eintrag am eigenen Bahnhof, 1 s, nicht zyklisch)", function()
      local hold = { cyclic = false, entries = { destination(name, { delay_group(1) }) } }
      local ok, err = call("setSchedule", hold)
      add("setSchedule(Haltefahrplan): " .. (ok and "ok" or ("FEHLER: " .. plain(err))))
      local events = wait_events(20, "B", device)
      local ok_p2, present2 = call("isTrainPresent")
      local ok_h2, has2 = call("hasSchedule")
      local ok_g2, sched2 = call("getSchedule")
      add("nach 20 s: isTrainPresent=" .. tostring(ok_p2 and present2) .. "  hasSchedule=" .. tostring(ok_h2 and has2) .. "  getSchedule=" .. (ok_g2 and show(sched2) or ("FEHLER: " .. plain(sched2))))
      local departed = found(events, "train_departure")
      result("B Zug haelt nach dem Ende eines nicht zyklischen Fahrplans", (ok and ok_p2 and present2 and not departed) and "JA" or "NEIN")
      result("B hasSchedule danach", tostring(ok_h2 and has2))
    end)

    -- C: create:powered -------------------------------------------------------------------------------------------------------
    run("Probe C: create:powered ohne Strom", function()
      local held = { cyclic = false, entries = { destination(name, { { { id = "create:powered", data = {} } } }) } }
      local ok, err = call("setSchedule", held)
      add("setSchedule(create:powered): " .. (ok and "ok" or ("FEHLER: " .. plain(err))))
      local events = wait_events(15, "C", device)
      local ok_p2, present2 = call("isTrainPresent")
      add("nach 15 s: isTrainPresent=" .. tostring(ok_p2 and present2))
      result("C create:powered wird angenommen", ok and "JA" or ("NEIN (" .. plain(err) .. ")"))
      result("C Zug haelt ohne Strom", (ok and ok_p2 and present2 and not found(events, "train_departure")) and "JA" or "NEIN")
    end)

    -- D: Abfahrt per Fahrplan -------------------------------------------------------------------------------------------------
    if not opts.goal then
      section("Probe D: Abfahrt per Fahrplan")
      add("(nicht gelaufen: mit --ziel BAHNHOFSNAME starten; der Zug faehrt dann dorthin und zurueck)")
    else
      run("Probe D: Abfahrt per Fahrplan (Rundlauf zu " .. opts.goal .. ")", function()
        local ok_r, reachable, rwhy = call("canTrainReach", opts.goal)
        if not (ok_r and reachable == true) then
          add("Ziel nicht erreichbar (" .. tostring(ok_r and rwhy or reachable) .. "): Probe D entfaellt.")
          result("D Abfahrt per Fahrplan", "nicht gemessen: Ziel nicht erreichbar")
          return
        end
        add("ACHTUNG: der Zug " .. tostring(train) .. " faehrt jetzt von " .. tostring(name) .. " nach " .. opts.goal .. " und zurueck.")
        add("Weg frei? Weiter mit j, Abbruch mit Enter.")
        local answer = "j"
        if opts.yes then add("(--ja: ohne Rueckfrage)") else answer = read() end
        if answer ~= "j" then
          add("abgebrochen")
          result("D Abfahrt per Fahrplan", "nicht gemessen (abgebrochen)")
          return
        end
        local trip = { cyclic = false, entries = { destination(name, { delay_group(1) }), destination(opts.goal, { delay_group(1) }), destination(name, { delay_group(1) }) } }
        local t0 = os.clock()
        local ok, err = call("setSchedule", trip)
        add("setSchedule(Rundlauf): " .. (ok and "ok" or ("FEHLER: " .. plain(err))))
        if ok then
          local wait = opts.wait or 240
          local events = wait_events(wait, "D", device, function(e) return e.name == "train_arrival" and e.at > 5 end)
          local departure = found(events, "train_departure")
          local back = found(events, "train_arrival")
          add("Abfahrt nach setSchedule: " .. (departure and string.format("%.1f s", departure.at) or "KEINE innerhalb von " .. wait .. " s"))
          add("Rueckkehr: " .. (back and string.format("nach %.1f s", back.at) or "nicht innerhalb von " .. wait .. " s"))
          result("D Zug faehrt nach setSchedule los, obwohl er schon am Bahnhof steht", departure and "JA" or "NEIN")
          result("D Zeit von setSchedule bis train_departure", departure and string.format("%.1f s", departure.at) or "keine Abfahrt")
          result("D Rundlauf beendet", back and "JA" or "NEIN")
          if back then
            local ok_p2, present2 = call("isTrainPresent")
            add("zurueck am Bahnhof: isTrainPresent=" .. tostring(ok_p2 and present2))
          end
        end
      end)
    end

    section("Rueckstellung am Ende")
    local ok_p3, present3 = call("isTrainPresent")
    if ok_p3 and present3 then
      restore("Ende")
    else
      add("Der Zug steht nicht am Bahnhof; sein Fahrplan wurde nicht zurueckgestellt. Urspruenglicher Fahrplan: " .. show(original))
    end
  end
end

section("Ergebnis (Kurzfassung)")
if #summary == 0 then add("(keine Schreibproben gelaufen)") end
for _, line in ipairs(summary) do add(line) end

local body = table.concat(lines, "\n") .. "\n"
local ok_w, err_w = pcall(function()
  local fh = fs.open(opts.out, "w")
  if not fh then error("kann " .. opts.out .. " nicht schreiben", 0) end
  fh.write(body)
  fh.close()
end)
print("")
print(ok_w and ("Bericht: " .. opts.out .. " (" .. #body .. " Byte)  senden: pastebin put " .. opts.out) or ("FEHLER beim Schreiben: " .. tostring(err_w)))
