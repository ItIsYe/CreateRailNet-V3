--[[
Purpose: Das Messprogramm probe/crn_probe3.lua gegen einen nachgebildeten Bahnhof mit virtueller Uhr: es laeuft ohne Fehler durch, schreibt nur Fahrplaene, stellt den urspruenglichen Fahrplan nach jeder Probe wieder her (auch wenn Schreiben fehlschlaegt oder ein Zug fehlt) und fasst die Ergebnisse zusammen. Die Probe selbst laeuft nur im Spiel; hier wird nur geprueft, dass sie dort nicht an eigenen Fehlern scheitert.
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

-- Nachbildung: ein Bahnhof "Create_Station_1" mit Zug "Zug 1"; Verhalten je nach Fahrplan wie von der Probe erwartet (Halt, Abfahrt, Rueckkehr)
local function world(opts)
  opts = opts or {}
  local w = { now = 0, timers = {}, queue = {}, next_timer = 0, calls = {}, files = {}, output = {} }
  local st = { present = opts.no_train ~= true, train = "Zug 1", schedule = deepcopy(ORIGINAL), name = "Hof A" }
  w.station = st

  local function event_at(at, ...) w.queue[#w.queue + 1] = { at = at, ev = { ... } } end

  local methods = {
    getStationName = function() return st.name end,
    isTrainPresent = function() return st.present end,
    getTrainName = function() if not st.present then error("there is no train present") end return st.train end,
    hasSchedule = function() if not st.present then error("there is no train present") end return st.schedule ~= nil end,
    getSchedule = function() if not st.present or not st.schedule then error("there is no train present") end return deepcopy(st.schedule) end,
    canTrainReach = function(target) if target == "Nirgendwo" then return false, "no-target" end return true, nil end,
    distanceTo = function() return 120, nil end,
    setSchedule = function(s)
      if opts.fail_write then error("Fahrplan abgelehnt") end
      w.calls[#w.calls + 1] = ser.encode(s)
      st.schedule = deepcopy(s)
      -- Reise: drei Eintraege, der Zug faehrt los und kommt zurueck
      if #s.entries == 3 and not opts.no_departure then
        event_at(w.now + 2.5, "train_departure", "Create_Station_1", "Zug 1")
        event_at(w.now + 30, "train_arrival", "Create_Station_1", "Zug 1")
      end
    end,
  }

  w.peripheral = {
    getNames = function() return { "Create_Station_1" } end,
    getType = function() return "Create_Station" end,
    call = function(_, method, ...)
      if not methods[method] then error("Method not found: " .. method) end
      return methods[method](...)
    end,
  }

  w.os = {
    clock = function() return w.now end,
    epoch = function() return 0 end,
    startTimer = function(seconds)
      w.next_timer = w.next_timer + 1
      w.timers[#w.timers + 1] = { id = w.next_timer, at = w.now + seconds }
      return w.next_timer
    end,
    -- naechstes Ereignis oder naechster Zeitgeber, die Uhr springt dorthin
    pullEvent = function()
      local best, kind, index
      for i, e in ipairs(w.queue) do if not best or e.at < best then best, kind, index = e.at, "event", i end end
      for i, e in ipairs(w.timers) do if not best or e.at < best then best, kind, index = e.at, "timer", i end end
      if not best then error("Terminated", 0) end
      if best > w.now then w.now = best end
      if kind == "event" then
        local e = table.remove(w.queue, index)
        return unpack(e.ev)
      end
      local e = table.remove(w.timers, index)
      return "timer", e.id
    end,
  }

  w.fs = { open = function(path)
    local buffer = {}
    return { write = function(text) buffer[#buffer + 1] = text end, close = function() w.files[path] = table.concat(buffer) end }
  end }
  w.textutils = { serializeJSON = function(v) return ser.encode(v) end }
  return w
end

local function run(w, args, answer)
  local file = io.open("probe/crn_probe3.lua", "rb")
  local source = file:read("*a")
  file:close()
  local env = setmetatable({
    peripheral = w.peripheral, os = w.os, fs = w.fs, textutils = w.textutils, _HOST = "Test",
    print = function(text) w.output[#w.output + 1] = tostring(text) end,
    read = function() w.reads = (w.reads or 0) + 1; return answer or "j" end,
  }, { __index = _G })
  local chunk
  if setfenv then
    chunk = assert(loadstring(source, "=probe"))
    setfenv(chunk, env)
  else
    chunk = assert(load(source, "=probe", "t", env))
  end
  local ok, err = pcall(chunk, unpack(args or {}))
  return ok, err, table.concat(w.output, "\n")
end

return {
  { "Probe ohne Ziel: A bis C laufen, der Fahrplan ist danach wieder der urspruengliche, die Kurzfassung nennt die Ergebnisse", function()
    local w = world()
    local ok, err, out = run(w, {})
    t.ok(ok, tostring(err))
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL), "urspruenglicher Fahrplan wiederhergestellt")
    t.contains(out, "Probe A: setSchedule mit geaendertem Inhalt")
    t.contains(out, "Probe B: Haltefahrplan")
    t.contains(out, "Probe C: create:powered ohne Strom")
    t.contains(out, "A geaenderter Inhalt wird geschrieben und gelesen: JA")
    t.contains(out, "B Zug haelt nach dem Ende eines nicht zyklischen Fahrplans: JA")
    t.contains(out, "C create:powered wird angenommen: JA")
    t.contains(out, "C Zug haelt ohne Strom: JA")
    t.contains(out, "Probe D: Abfahrt per Fahrplan")
    t.contains(out, "mit --ziel BAHNHOFSNAME starten")
    t.contains(out, "IDENTISCH mit vorher")
    t.ok(not out:find("WEICHT AB", 1, true))
    t.ok(w.files["crn_probe3.txt"] and #w.files["crn_probe3.txt"] > 500, "Bericht geschrieben")
    -- jeder Schreibzugriff: drei Proben und die Rueckstellungen (A, B, C je eine) und die am Ende
    t.ok(#w.calls >= 7, "setSchedule-Aufrufe: " .. #w.calls)
  end },

  { "Probe mit Ziel: Rundlauf mit Bestaetigung, Zeit bis zur Abfahrt wird gemessen, danach Rueckstellung", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "Hof B" })
    t.ok(ok, tostring(err))
    t.contains(out, "ACHTUNG: der Zug Zug 1 faehrt jetzt von Hof A nach Hof B")
    t.contains(out, "D Zug faehrt nach setSchedule los, obwohl er schon am Bahnhof steht: JA")
    t.contains(out, "D Zeit von setSchedule bis train_departure: 2.5 s")
    t.contains(out, "D Rundlauf beendet: JA")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
    -- der Rundlauf hat drei Eintraege: Start, Ziel, Rueckkehr
    local trip
    for _, call in ipairs(w.calls) do if call:find("Hof B", 1, true) and call:find("Hof A", 1, true) and select(2, call:gsub("create:destination", "")) == 3 then trip = call end end
    t.ok(trip, "Rundlauffahrplan wurde gesetzt")
  end },

  { "Probe mit Ziel ohne Bestaetigung: der Zug faehrt nicht, die Probe D entfaellt", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "Hof B" }, "")
    t.ok(ok, tostring(err))
    t.contains(out, "D Abfahrt per Fahrplan: nicht gemessen (abgebrochen)")
    for _, call in ipairs(w.calls) do t.ok(select(2, call:gsub("create:destination", "")) ~= 3, "kein Rundlauf gesetzt") end
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },

  { "--ja: Probe D laeuft ohne Rueckfrage (read wird nie gerufen), auch wenn die Antwort sonst Nein waere", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "Hof B", "--ja" }, "n")
    t.ok(ok, tostring(err))
    t.eq(w.reads or 0, 0, "keine Rueckfrage")
    t.contains(out, "(--ja: ohne Rueckfrage)")
    t.contains(out, "D Rundlauf beendet: JA")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },

  { "Ziel ist der eigene Bahnhof: Probe D entfaellt (Create schickt einen Zug nicht direkt wieder dorthin, M20), kein Rundlauf", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "Hof A", "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "Ziel ist der eigene Bahnhof")
    t.contains(out, "D Abfahrt per Fahrplan: nicht gemessen: Ziel ist der eigene Bahnhof")
    for _, call in ipairs(w.calls) do t.ok(select(2, call:gsub("create:destination", "")) ~= 3, "kein Rundlauf gesetzt") end
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },

  { "--ziel auto: das Ziel ist der erste andere Bahnhof im Fahrplan des Zuges, Probe D laeuft", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "auto", "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "Ziel (aus dem Fahrplan des Zuges): Hof B")
    t.contains(out, "D Rundlauf beendet: JA")
    t.eq(ser.encode(w.station.schedule), ser.encode(ORIGINAL))
  end },

  { "--ziel auto ohne anderen Bahnhof im Fahrplan: Probe D entfaellt mit Hinweis statt zu raten", function()
    local w = world()
    -- Fahrplan nur mit dem eigenen Bahnhof
    w.station.schedule = deepcopy(ORIGINAL)
    w.station.schedule.entries = { w.station.schedule.entries[1] }
    local only_own = deepcopy(w.station.schedule)
    local ok, err, out = run(w, { "--ziel", "auto", "--ja" })
    t.ok(ok, tostring(err))
    t.contains(out, "im Fahrplan des Zuges steht kein anderer Bahnhof")
    t.contains(out, "D Abfahrt per Fahrplan: nicht gemessen: kein Zielbahnhof")
    for _, call in ipairs(w.calls) do t.ok(select(2, call:gsub("create:destination", "")) ~= 3, "kein Rundlauf gesetzt") end
    t.eq(ser.encode(w.station.schedule), ser.encode(only_own))
  end },

  { "Probe mit unerreichbarem Ziel: keine Fahrt, Hinweis", function()
    local w = world()
    local ok, err, out = run(w, { "--ziel", "Nirgendwo" })
    t.ok(ok, tostring(err))
    t.contains(out, "Ziel nicht erreichbar")
    t.contains(out, "D Abfahrt per Fahrplan: nicht gemessen: Ziel nicht erreichbar")
  end },

  { "--no-write: es wird nichts geschrieben", function()
    local w = world()
    local ok, err, out = run(w, { "--no-write" })
    t.ok(ok, tostring(err))
    t.eq(#w.calls, 0)
    t.contains(out, "Schreibproben uebersprungen")
    t.contains(out, "getSchedule: ")
  end },

  { "Schreiben schlaegt fehl: Fehler stehen im Bericht, die Probe bricht nicht ab", function()
    local w = world({ fail_write = true })
    local ok, err, out = run(w, {})
    t.ok(ok, tostring(err))
    t.contains(out, "FEHLER: Fahrplan abgelehnt")
    t.contains(out, "A geaenderter Inhalt wird geschrieben und gelesen: NEIN")
    t.contains(out, "C create:powered wird angenommen: NEIN")
  end },

  { "Kein Zug am Bahnhof: wartet, meldet es und aendert nichts", function()
    local w = world({ no_train = true })
    local ok, err, out = run(w, { "--wait", "20" })
    t.ok(ok, tostring(err))
    t.contains(out, "Kein Bahnhof mit Zug")
    t.eq(#w.calls, 0)
  end },

  { "Zug faehrt in Probe D nicht ab: die Probe sagt NEIN statt zu haengen", function()
    local w = world({ no_departure = true })
    local ok, err, out = run(w, { "--ziel", "Hof B", "--wait", "30" })
    t.ok(ok, tostring(err))
    t.contains(out, "D Zug faehrt nach setSchedule los, obwohl er schon am Bahnhof steht: NEIN")
  end },

  { "Unbekannte Option wird abgelehnt", function()
    local w = world()
    local ok, err = run(w, { "--quatsch" })
    t.eq(ok, false)
    t.contains(tostring(err), "Unbekannte Option")
  end },
}
