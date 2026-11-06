--[[
Purpose: Das Gesamt-Messprogramm probe/crn_alles.lua gegen eine nachgebildete Anlage (Bahnhof mit Zug, Signal mit Zugverkehr, Beobachter) mit virtueller Uhr, nachgebautem shell.run (mit der Zerlegung in Anfuehrungszeichen wie in CC), http.get, Dateien und pastebin: nur eine Rueckfrage am Anfang, die Teile S1, S2 und B laufen nacheinander, die Signalsperre und der Fahrplan werden zurueckgestellt, fehlende Geraete und fehlende Zuege fuehren zu begruendetem Ueberspringen, ein gemeinsamer Bericht entsteht und wird hochgeladen.
]]

local t = dofile("tests/lib/t.lua")
local ser = require("core.ser")
local unpack = table.unpack or unpack

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepcopy(x) end
  return out
end

local ORIGINAL = {
  cyclic = true,
  entries = {
    { instruction = { id = "create:destination", data = { text = "Hof A" } }, conditions = { { { id = "create:delay", data = { value = 5, time_unit = 1 } }, { id = "create:powered", data = {} } } } },
    { instruction = { id = "create:destination", data = { text = "Hof B" } }, conditions = { { { id = "create:delay", data = { value = 5, time_unit = 1 } } } } },
  },
}

local function read_source(path)
  local file = assert(io.open(path, "rb"))
  local source = file:read("*a")
  file:close()
  return source
end

-- Zerlegung wie shell.tokenise in CC: Leerzeichen trennen, Anfuehrungszeichen halten zusammen
local function tokenise(text)
  local out, i = {}, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == " " then i = i + 1
    elseif c == '"' then
      local j = text:find('"', i + 1, true) or (#text + 1)
      out[#out + 1] = text:sub(i + 1, j - 1)
      i = j + 1
    else
      local j = text:find(" ", i, true) or (#text + 1)
      out[#out + 1] = text:sub(i, j - 1)
      i = j
    end
  end
  return out
end

-- opts: no_station, no_signals, second_station, no_traffic, no_http, pastebin_fail, files (vorhandene Dateien)
local function world(opts)
  opts = opts or {}
  local w = { now = 0, timers = {}, queue = {}, next_timer = 0, files = {}, output = {}, writes = {}, runs = {}, pastebin = {}, downloads = {}, reads = 0 }
  for k, v in pairs(opts.files or {}) do w.files[k] = v end
  local forced = false
  local function at(time, ...) w.queue[#w.queue + 1] = { at = time, ev = { ... } } end

  -- Zugverkehr: alle 45 s faehrt ein Zug durch den Block hinter Create_Signal_0 (7 s rot) und am Beobachter vorbei
  if not opts.no_traffic and not opts.no_signals then
    for k = 0, 60 do
      local base = 20 + 45 * k
      at(base, "train_signal_state_change", "Create_Signal_0", "RED")
      at(base + 0.1, "train_passing", "Create_TrainObserver_0", "Zug 1")
      at(base + 3, "train_passed", "Create_TrainObserver_0", "Zug 1")
      at(base + 7, "train_signal_state_change", "Create_Signal_0", "GREEN")
    end
  end
  local function phase() return (w.now - 20) % 45 end
  local function occupied() return not opts.no_traffic and w.now >= 20 and phase() < 7 end

  local signal = {
    getState = function() return (forced or occupied()) and "RED" or "GREEN" end,
    isForcedRed = function() return forced end,
    setForcedRed = function(v) w.writes[#w.writes + 1] = tostring(v); forced = v and true or false end,
    getSignalType = function() return "ENTRY_SIGNAL" end,
    listBlockingTrainNames = function() if occupied() then return { "Zug 1" } end return {} end,
  }
  local observer = {
    isTrainPassing = function() return not opts.no_traffic and w.now >= 20 and phase() >= 0.1 and phase() < 3 end,
    getPassingTrainName = function()
      if opts.no_traffic or w.now < 20 or phase() < 0.1 or phase() >= 3 then error("there is no train passing") end
      return "Zug 1"
    end,
  }

  local function station_methods(st)
    local function event_at(time, ...) at(time, ...) end
    return {
      getStationName = function() return st.name end,
      isTrainPresent = function() return st.present end,
      getTrainName = function() if not st.present then error("there is no train present") end return st.train end,
      hasSchedule = function() if not st.present then error("there is no train present") end return st.schedule ~= nil end,
      getSchedule = function() if not st.present or not st.schedule then error("there is no train present") end return deepcopy(st.schedule) end,
      canTrainReach = function(target) if target == "Nirgendwo" then return false, "no-target" end return true, nil end,
      distanceTo = function() return 120, nil end,
      setSchedule = function(s)
        w.writes[#w.writes + 1] = "schedule"
        st.schedule = deepcopy(s)
        if #s.entries == 3 then
          event_at(w.now + 2.5, "train_departure", st.device, "Zug 7")
          event_at(w.now + 30, "train_arrival", st.device, "Zug 7")
        end
      end,
    }
  end
  w.station = { name = "Hof A", present = true, train = "Zug 7", schedule = deepcopy(ORIGINAL), device = "Create_Station_1" }
  local station2 = { name = "Hof B", present = false, device = "Create_Station_2" }

  local devices = {}
  if not opts.no_station then devices.Create_Station_1 = { type = "Create_Station", methods = station_methods(w.station) } end
  if opts.second_station then devices.Create_Station_2 = { type = "Create_Station", methods = station_methods(station2) } end
  if not opts.no_signals then
    devices.Create_Signal_0 = { type = "Create_Signal", methods = signal }
    devices.Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = observer }
  end
  w.peripheral = {
    getNames = function()
      local names = {}
      for name in pairs(devices) do names[#names + 1] = name end
      table.sort(names)
      return names
    end,
    getType = function(name) return devices[name] and devices[name].type end,
    getMethods = function(name)
      local out = {}
      for m in pairs(devices[name].methods) do out[#out + 1] = m end
      table.sort(out)
      return out
    end,
    call = function(name, method, ...)
      local d = devices[name]
      if not d or not d.methods[method] then error("Method not found: " .. tostring(method)) end
      return d.methods[method](...)
    end,
  }
  w.forced = function() return forced end

  w.os = {
    clock = function() return w.now end,
    startTimer = function(seconds)
      w.next_timer = w.next_timer + 1
      w.timers[#w.timers + 1] = { id = w.next_timer, at = w.now + seconds }
      return w.next_timer
    end,
    pullEvent = function()
      local best, kind, index
      for i, e in ipairs(w.queue) do if not best or e.at < best then best, kind, index = e.at, "event", i end end
      for i, e in ipairs(w.timers) do if not best or e.at < best then best, kind, index = e.at, "timer", i end end
      if not best then error("Terminated", 0) end
      if best > w.now then w.now = best end
      if kind == "event" then return unpack(table.remove(w.queue, index).ev) end
      local e = table.remove(w.timers, index)
      return "timer", e.id
    end,
  }

  w.fs = {
    exists = function(path) return w.files[path] ~= nil end,
    open = function(path, mode)
      if mode == "r" then
        if w.files[path] == nil then return nil end
        local text = w.files[path]
        return { readAll = function() return text end, close = function() end }
      end
      local buffer = {}
      return { write = function(text) buffer[#buffer + 1] = text end, close = function() w.files[path] = table.concat(buffer) end }
    end,
  }

  w.http = {
    get = function(url)
      w.downloads[#w.downloads + 1] = url
      if opts.no_http then return nil, "blocked" end
      local name = url:match("([^/]+)$")
      local text = read_source("probe/" .. name)
      return { readAll = function() return text end, close = function() end }
    end,
  }

  local env
  local function run_chunk(name, tokens)
    local source = w.files[name .. ".lua"]
    if not source then w.output[#w.output + 1] = "No such program"; return false end
    local chunk
    if setfenv then
      chunk = assert(loadstring(source, "=" .. name))
      setfenv(chunk, env)
    else
      chunk = assert(load(source, "=" .. name, "t", env))
    end
    local ok, err = pcall(chunk, unpack(tokens))
    if not ok then w.output[#w.output + 1] = tostring(err); return false end
    return true
  end

  w.shell = {
    run = function(program, ...)
      local parts = { program }
      for _, a in ipairs({ ... }) do parts[#parts + 1] = tostring(a) end
      local tokens = tokenise(table.concat(parts, " "))
      local name = table.remove(tokens, 1)
      w.runs[#w.runs + 1] = name .. " " .. table.concat(tokens, " ")
      if name == "pastebin" then
        w.pastebin[#w.pastebin + 1] = table.concat(tokens, " ")
        if opts.pastebin_fail then return false end
        w.output[#w.output + 1] = "Uploaded as https://pastebin.com/TEST"
        return true
      end
      return run_chunk(name, tokens)
    end,
  }

  env = setmetatable({
    peripheral = w.peripheral, os = w.os, fs = w.fs, http = (not opts.no_http_api) and w.http or nil, shell = w.shell, _HOST = "Test",
    print = function(text) w.output[#w.output + 1] = tostring(text) end,
    read = function() w.reads = w.reads + 1; return w.answer or "j" end,
  }, { __index = _G })
  w.env = env
  return w
end

local function run(w, args, answer)
  w.answer = answer
  w.files["crn_alles.lua"] = read_source("probe/crn_alles.lua")
  local ok, err = pcall(function()
    local chunk
    if setfenv then
      chunk = assert(loadstring(w.files["crn_alles.lua"], "=crn_alles"))
      setfenv(chunk, w.env)
    else
      chunk = assert(load(w.files["crn_alles.lua"], "=crn_alles", "t", w.env))
    end
    chunk(unpack(args or {}))
  end)
  return ok, err, table.concat(w.output, "\n")
end

local function sources()
  return { ["crn_probe3.lua"] = read_source("probe/crn_probe3.lua"), ["crn_probe4.lua"] = read_source("probe/crn_probe4.lua") }
end

return {
  { "Alles in einem Lauf: S1 beobachten, S2 das befahrene Signal sperren, B Fahrplan-Proben samt Rundlauf; keine Rueckfrage mit --ja, alles zurueckgestellt, ein Bericht, ein Upload", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "60" })
    t.ok(ok, tostring(err))
    t.eq(w.reads, 0, "mit --ja keine Rueckfrage, auch nicht in den Einzelprogrammen")
    t.contains(out, "[ok] Signale beobachten")
    t.contains(out, "[ok] Signal sperren")
    t.contains(out, "[ok] Abfahrt ueber die Station")
    -- Sperre: einmal gesetzt, einmal zurueckgestellt
    local sig_writes = {}
    for _, x in ipairs(w.writes) do if x == "true" or x == "false" then sig_writes[#sig_writes + 1] = x end end
    t.eq(table.concat(sig_writes, ","), "true,false", "Signal gesperrt und zurueckgestellt")
    t.eq(w.forced(), false)
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL), "Fahrplan wiederhergestellt")
    -- Aufrufe der Einzelprogramme
    local runs = table.concat(w.runs, "\n")
    t.contains(runs, "crn_probe4 --wait 60 --out crn_alles_s1.txt")
    t.contains(runs, "crn_probe4 --sperre --ja --signal Create_Signal_0 --wait 60 --out crn_alles_s2.txt")
    t.contains(runs, "crn_probe3 --ja --out crn_alles_b.txt --station Create_Station_1 --ziel Hof B")
    t.eq(#w.downloads, 2, "beide Programme neu geladen")
    t.contains(w.downloads[1], "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/probe/")
    -- Bericht
    local report = w.files["crn_alles.txt"]
    t.ok(report and #report > 1000, "Bericht geschrieben")
    t.contains(report, "== Kurzfassungen")
    t.contains(report, "--- S1 (crn_alles_s1.txt) ---")
    t.contains(report, "Signal Create_Signal_0 nennt Zug Zug 1: JA")
    t.contains(report, "--- B (crn_alles_b.txt) ---")
    t.contains(report, "D Rundlauf beendet: JA")
    t.contains(report, "== Vollstaendige Berichte")
    t.eq(#w.pastebin, 1)
    t.eq(w.pastebin[1], "put crn_alles.txt")
    t.contains(out, "Uploaded as https://pastebin.com/TEST")
  end },
  { "Ohne --ja gibt es genau eine Rueckfrage, danach laeuft alles ohne weitere", function()
    local w = world({ second_station = true })
    local ok, err = run(w, { "--zeit", "40" }, "j")
    t.ok(ok, tostring(err))
    t.eq(w.reads, 1, "nur die eine Rueckfrage des Hauptprogramms")
    t.ok(#w.runs >= 4, "alle Teile gelaufen")
  end },
  { "Antwort n: nichts wird geladen, gestartet, geschrieben oder hochgeladen", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--zeit", "40" }, "n")
    t.ok(ok, tostring(err))
    t.contains(out, "abgebrochen: nichts wurde veraendert")
    t.eq(#w.runs, 0)
    t.eq(#w.downloads, 0)
    t.eq(#w.writes, 0)
    t.eq(#w.pastebin, 0)
  end },
  { "Nur Signale am Netz: B entfaellt mit Grund, S1 und S2 laufen", function()
    local w = world({ no_station = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "60" })
    t.ok(ok, tostring(err))
    t.contains(out, "[ok] Signal sperren")
    t.contains(out, "[uebersprungen] Abfahrt ueber die Station: kein Bahnhof am Netz")
    t.ok(not table.concat(w.runs, "\n"):find("crn_probe3", 1, true))
  end },
  { "Nur ein Bahnhof am Netz: S1 und S2 entfallen mit Grund, B laeuft (ohne zweiten Bahnhof ohne Rundlauf)", function()
    local w = world({ no_signals = true })
    local ok, err, out = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "[uebersprungen] Signale beobachten: kein Signal am Netz")
    t.contains(out, "[ok] Abfahrt ueber die Station")
    t.contains(out, ", ohne Rundlauf")
    t.ok(not table.concat(w.runs, "\n"):find("--ziel", 1, true), "ohne zweiten Bahnhof kein Ziel")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },
  { "Ohne Geraete: Hinweis, keine Rueckfrage, nichts gestartet", function()
    local w = world({ no_station = true, no_signals = true })
    local ok, err, out = run(w, {})
    t.ok(ok, tostring(err))
    t.contains(out, "Nichts zu tun")
    t.eq(w.reads, 0)
    t.eq(#w.runs, 0)
  end },
  { "Kein Zug im Beobachtungszeitraum: das Signal wird nicht gesperrt", function()
    local w = world({ no_station = true, no_traffic = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "30" })
    t.ok(ok, tostring(err))
    t.contains(out, "[uebersprungen] Signal sperren: in S1 wurde kein Zug an einem Signal gesehen")
    t.eq(#w.writes, 0)
  end },
  { "--ohne-sperre: nur beobachten, nichts geschrieben", function()
    local w = world({ no_station = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "60", "--ohne-sperre" })
    t.ok(ok, tostring(err))
    t.contains(out, "[uebersprungen] Signal sperren: --ohne-sperre")
    t.eq(#w.writes, 0)
  end },
  { "--ohne-fahrt: am Bahnhof nur die Proben A bis C, auch wenn ein zweiter Bahnhof da ist", function()
    local w = world({ no_signals = true, second_station = true })
    local ok, err, out = run(w, { "--ja", "--ohne-fahrt" })
    t.ok(ok, tostring(err))
    t.ok(not table.concat(w.runs, "\n"):find("--ziel", 1, true))
    t.contains(out, "ohne Rundlauf")
  end },
  { "--nur signal und --nur abfahrt", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "40", "--nur", "signal" })
    t.ok(ok, tostring(err))
    t.contains(out, "[uebersprungen] Abfahrt ueber die Station: --nur signal")
    local w2 = world({ second_station = true })
    local ok2, err2, out2 = run(w2, { "--ja", "--nur", "abfahrt" })
    t.ok(ok2, tostring(err2))
    t.contains(out2, "[uebersprungen] Signale beobachten: --nur abfahrt")
    t.contains(out2, "[ok] Abfahrt ueber die Station")
  end },
  { "Explizites Ziel mit Leerzeichen kommt als ein Argument an (Anfuehrungszeichen fuer shell.run)", function()
    local w = world({ no_signals = true })
    local ok, err, out = run(w, { "--ja", "--ziel", "Hof B" })
    t.ok(ok, tostring(err))
    t.contains(out, "[ok] Abfahrt ueber die Station")
    t.contains(table.concat(w.runs, "\n"), "--ziel Hof B")
    t.contains(w.files["crn_alles.txt"], "D Rundlauf beendet: JA")
  end },
  { "Download scheitert, vorhandene Dateien werden benutzt", function()
    local w = world({ no_http = true, second_station = true, files = sources() })
    local ok, err, out = run(w, { "--ja", "--zeit", "40" })
    t.ok(ok, tostring(err))
    t.contains(out, "es wird die vorhandene Datei crn_probe4.lua benutzt")
    t.contains(out, "[ok] Signale beobachten")
    t.contains(out, "[ok] Abfahrt ueber die Station")
  end },
  { "Download scheitert und keine Datei da: die Teile melden FEHLER, das Programm laeuft zu Ende und schreibt den Bericht", function()
    local w = world({ no_http = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "40" })
    t.ok(ok, tostring(err))
    t.contains(out, "[FEHLER] Signale beobachten: crn_probe4.lua nicht verfuegbar")
    t.contains(out, "[FEHLER] Abfahrt ueber die Station: crn_probe3.lua nicht verfuegbar")
    t.ok(w.files["crn_alles.txt"], "Bericht trotzdem geschrieben")
  end },
  { "--lokal: kein Download, vorhandene Dateien", function()
    local w = world({ no_station = true, files = sources() })
    local ok, err = run(w, { "--ja", "--zeit", "40", "--lokal" })
    t.ok(ok, tostring(err))
    t.eq(#w.downloads, 0)
  end },
  { "--nicht-hochladen: kein pastebin; Upload-Fehler wird gemeldet statt abzustuerzen", function()
    local w = world({ no_station = true })
    local ok, err, out = run(w, { "--ja", "--zeit", "40", "--nicht-hochladen" })
    t.ok(ok, tostring(err))
    t.eq(#w.pastebin, 0)
    t.contains(out, "Senden: pastebin put crn_alles.txt")
    local w2 = world({ no_station = true, pastebin_fail = true })
    local ok2, err2, out2 = run(w2, { "--ja", "--zeit", "40" })
    t.ok(ok2, tostring(err2))
    t.contains(out2, "Hochladen fehlgeschlagen")
  end },
  { "Unbekannte Optionen: klarer Fehler", function()
    local w = world()
    local ok, err = run(w, { "--quatsch" })
    t.ok(not ok)
    t.contains(tostring(err), "Unbekannte Option")
    local w2 = world()
    local ok2, err2 = run(w2, { "--nur", "irgendwas" })
    t.ok(not ok2)
    t.contains(tostring(err2), "--nur versteht")
  end },
}
