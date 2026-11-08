--[[
Purpose: Das Messprogramm probe/crn_alles.lua gegen eine nachgebildete Anlage (Bahnhof mit Zug) mit virtueller Uhr, nachgebautem shell.run (mit der Zerlegung in Anfuehrungszeichen wie in CC), http.get, Dateien und pastebin: nur eine Rueckfrage am Anfang, crn_probe3 wird geladen und gestartet, der Fahrplan wird zurueckgestellt, fehlender Bahnhof und fehlende Datei fuehren zu begruendetem Ueberspringen oder FEHLER, ein Bericht entsteht und wird hochgeladen.
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

-- opts: no_station, second_station, no_train_at_start, own_only, no_http, pastebin_fail, files (vorhandene Dateien)
local function world(opts)
  opts = opts or {}
  local w = { now = 0, timers = {}, queue = {}, next_timer = 0, files = {}, output = {}, writes = {}, runs = {}, pastebin = {}, downloads = {}, reads = 0 }
  for k, v in pairs(opts.files or {}) do w.files[k] = v end
  local function at(time, ...) w.queue[#w.queue + 1] = { at = time, ev = { ... } } end

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
  w.station = { name = "Hof A", present = not opts.no_train_at_start, train = "Zug 7", schedule = deepcopy(ORIGINAL), device = "Create_Station_1" }
  if opts.own_only then w.station.schedule.entries = { w.station.schedule.entries[1] } end
  local station2 = { name = "Hof B", present = false, device = "Create_Station_2" }

  local devices = {}
  if not opts.no_station then devices.Create_Station_1 = { type = "Create_Station", methods = station_methods(w.station) } end
  if opts.second_station then devices.Create_Station_2 = { type = "Create_Station", methods = station_methods(station2) } end
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
  return { ["crn_probe3.lua"] = read_source("probe/crn_probe3.lua") }
end

return {
  { "Alles in einem Lauf: Fahrplan-Proben samt Rundlauf; keine Rueckfrage mit --ja, Fahrplan zurueckgestellt, ein Bericht, ein Upload", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.eq(w.reads, 0, "mit --ja keine Rueckfrage, auch nicht im Einzelprogramm")
    t.contains(out, "[ok] Abfahrt ueber die Station")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL), "Fahrplan wiederhergestellt")
    local runs = table.concat(w.runs, "\n")
    t.contains(runs, "crn_probe3 --ja --out crn_alles_abfahrt.txt --station Create_Station_1 --ziel auto")
    t.eq(#w.downloads, 1, "crn_probe3 neu geladen")
    t.contains(w.downloads[1], "https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/beta/probe/crn_probe3.lua")
    local report = w.files["crn_alles.txt"]
    t.ok(report and #report > 1000, "Bericht geschrieben")
    t.contains(report, "== Kurzfassung")
    t.contains(report, "D Rundlauf beendet: JA")
    t.contains(report, "== Vollstaendiger Bericht")
    t.eq(#w.pastebin, 1)
    t.eq(w.pastebin[1], "put crn_alles.txt")
    t.contains(out, "Uploaded as https://pastebin.com/TEST")
  end },
  { "Ohne --ja gibt es genau eine Rueckfrage, danach laeuft alles ohne weitere", function()
    local w = world({ second_station = true })
    local ok, err = run(w, {}, "j")
    t.ok(ok, tostring(err))
    t.eq(w.reads, 1, "nur die eine Rueckfrage des Hauptprogramms")
    t.ok(#w.runs >= 2, "Messung und Upload gelaufen")
  end },
  { "Antwort n: nichts wird geladen, gestartet, geschrieben oder hochgeladen", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, {}, "n")
    t.ok(ok, tostring(err))
    t.contains(out, "abgebrochen: nichts wurde veraendert")
    t.eq(#w.runs, 0)
    t.eq(#w.downloads, 0)
    t.eq(#w.writes, 0)
    t.eq(#w.pastebin, 0)
  end },
  { "Ein Bahnhof am Netz: Rundlauf zu einem Bahnhof aus dem Fahrplan des Zuges", function()
    local w = world({})
    local ok, err, out = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "[ok] Abfahrt ueber die Station")
    t.contains(out, "Rundlauf zu einem Bahnhof aus dem Fahrplan des Zuges")
    t.contains(table.concat(w.runs, "\n"), "--ziel auto")
    t.contains(w.files["crn_alles.txt"], "D Rundlauf beendet: JA")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },
  { "Steht beim Planen noch kein Zug am Bahnhof, wird der angeschlossene Bahnhof nicht selbst zum Ziel (Fehler im ersten Spiellauf)", function()
    local w = world({ no_train_at_start = true })
    local ok, err = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    local runs = table.concat(w.runs, "\n")
    t.contains(runs, "--ziel auto")
    t.ok(not runs:find("--ziel Hof A", 1, true), "nie der eigene Bahnhof als Ziel")
  end },
  { "Fahrplan des Zuges nennt nur den eigenen Bahnhof: Probe D entfaellt, im Bericht steht der Grund", function()
    local w = world({ own_only = true })
    local ok, err = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.contains(w.files["crn_alles.txt"], "im Fahrplan des Zuges steht kein anderer Bahnhof")
    t.contains(w.files["crn_alles.txt"], "D Abfahrt per Fahrplan: nicht gemessen: kein Zielbahnhof")
  end },
  { "Ohne Bahnhof: Hinweis, keine Rueckfrage, nichts gestartet", function()
    local w = world({ no_station = true })
    local ok, err, out = run(w, {})
    t.ok(ok, tostring(err))
    t.contains(out, "Nichts zu tun")
    t.eq(w.reads, 0)
    t.eq(#w.runs, 0)
  end },
  { "--ohne-fahrt: nur die Proben A bis C, auch wenn ein zweiter Bahnhof da ist", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--ja", "--ohne-fahrt" })
    t.ok(ok, tostring(err))
    t.ok(not table.concat(w.runs, "\n"):find("--ziel", 1, true))
    t.contains(out, "ohne Rundlauf")
  end },
  { "Explizites Ziel mit Leerzeichen kommt als ein Argument an (Anfuehrungszeichen fuer shell.run)", function()
    local w = world({})
    local ok, err, out = run(w, { "--ja", "--ziel", "Hof B" })
    t.ok(ok, tostring(err))
    t.contains(out, "[ok] Abfahrt ueber die Station")
    t.contains(table.concat(w.runs, "\n"), "--ziel Hof B")
    t.contains(w.files["crn_alles.txt"], "D Rundlauf beendet: JA")
  end },
  { "Download scheitert, vorhandene Datei wird benutzt", function()
    local w = world({ no_http = true, second_station = true, files = sources() })
    local ok, err, out = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "es wird die vorhandene Datei crn_probe3.lua benutzt")
    t.contains(out, "[ok] Abfahrt ueber die Station")
  end },
  { "Download scheitert und keine Datei da: FEHLER, das Programm laeuft zu Ende und schreibt den Bericht", function()
    local w = world({ no_http = true })
    local ok, err, out = run(w, { "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "[FEHLER] Abfahrt ueber die Station: crn_probe3.lua nicht verfuegbar")
    t.ok(w.files["crn_alles.txt"], "Bericht trotzdem geschrieben")
  end },
  { "--lokal: kein Download, vorhandene Datei", function()
    local w = world({ files = sources() })
    local ok, err = run(w, { "--ja", "--lokal" })
    t.ok(ok, tostring(err))
    t.eq(#w.downloads, 0)
  end },
  { "--nicht-hochladen: kein pastebin; Upload-Fehler wird gemeldet statt abzustuerzen", function()
    local w = world({})
    local ok, err, out = run(w, { "--ja", "--nicht-hochladen" })
    t.ok(ok, tostring(err))
    t.eq(#w.pastebin, 0)
    t.contains(out, "Senden: pastebin put crn_alles.txt")
    local w2 = world({ pastebin_fail = true })
    local ok2, err2, out2 = run(w2, { "--ja" })
    t.ok(ok2, tostring(err2))
    t.contains(out2, "Hochladen fehlgeschlagen")
  end },
  { "Ziel ist der eigene Bahnhof: kein Rundlauf, Hinweis auf die Regel", function()
    local w = world({})
    local ok, err, out = run(w, { "--ja", "--ziel", "Hof A" })
    t.ok(ok, tostring(err))
    t.contains(out, "Ziel Hof A ist der eigene Bahnhof")
    t.ok(not table.concat(w.runs, "\n"):find("--ziel", 1, true), "kein --ziel weitergegeben")
    t.contains(out, ", ohne Rundlauf")
  end },
  { "--hilfe: nur die Anleitung, nichts wird gefragt, geladen, gestartet oder geschrieben", function()
    local w = world({ second_station = true })
    local ok, err, out = run(w, { "--hilfe" })
    t.ok(ok, tostring(err))
    t.contains(out, "crn_alles --ja")
    t.eq(w.reads, 0)
    t.eq(#w.runs, 0)
    t.eq(#w.downloads, 0)
    t.ok(w.files["crn_alles.txt"] == nil, "keine Datei geschrieben")
  end },
  { "Unbekannte Optionen (auch die entfernten Signal-Optionen): klarer Fehler", function()
    local w = world()
    local ok, err = run(w, { "--quatsch" })
    t.ok(not ok)
    t.contains(tostring(err), "Unbekannte Option")
    local w2 = world()
    local ok2, err2 = run(w2, { "--nur", "signal" })
    t.ok(not ok2)
    t.contains(tostring(err2), "Unbekannte Option")
  end },
}
