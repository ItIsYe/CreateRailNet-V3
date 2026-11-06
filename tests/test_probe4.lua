--[[
Purpose: Das Messprogramm probe/crn_probe4.lua gegen ein nachgebildetes Signal und einen Beobachter mit virtueller Uhr: es laeuft ohne Fehler durch, liest ohne --sperre nur, haelt eine Sperre nur nach Bestaetigung und stellt sie am Ende zurueck, und die Kurzfassung nennt Zugname im Signal, Zustandswechsel und den Abstand zum train_passed am Beobachter.
]]

local t = dofile("tests/lib/t.lua")
local unpack = table.unpack or unpack

-- Ablauf: Zug 1 faehrt durch. 5,0 s Signal rot und Zug im Block, 5,1 s Beobachter meldet passing, 8,0 s passed, 9,0 s Block geraeumt und Signal gruen
local function world(opts)
  opts = opts or {}
  local w = { now = 0, timers = {}, queue = {}, next_timer = 0, files = {}, output = {}, writes = {} }
  local forced = false
  local function at(time, ...) w.queue[#w.queue + 1] = { at = time, ev = { ... } } end
  if not opts.no_train then
    at(5.0, "train_signal_state_change", "Create_Signal_0", "RED")
    at(5.1, "train_passing", "Create_TrainObserver_0", "Zug 1")
    at(8.0, "train_passed", "Create_TrainObserver_0", "Zug 1")
    at(9.0, "train_signal_state_change", "Create_Signal_0", "GREEN")
  end
  local function occupied() return not opts.no_train and not opts.no_names and w.now >= 5.0 and w.now < 9.0 end
  local signal = {
    getState = function() if forced or (not opts.no_train and w.now >= 5.0 and w.now < 9.0) then return "RED" end return "GREEN" end,
    isForcedRed = function() return forced end,
    setForcedRed = function(v) w.writes[#w.writes + 1] = tostring(v); forced = v end,
    getSignalType = function() return "ENTRY_SIGNAL" end,
    listBlockingTrainNames = function() if occupied() then return { "Zug 1" } end return {} end,
  }
  local observer = {
    isTrainPassing = function() return not opts.no_train and w.now >= 5.1 and w.now < 8.0 end,
    getPassingTrainName = function()
      if opts.no_train or w.now < 5.1 or w.now >= 8.0 then error("there is no train passing") end
      return "Zug 1"
    end,
  }
  local devices = {
    Create_Signal_0 = { type = "Create_Signal", methods = signal },
    Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = observer },
  }
  w.peripheral = {
    getNames = function() return opts.empty and {} or { "Create_Signal_0", "Create_TrainObserver_0" } end,
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
  w.fs = { open = function(path)
    local buffer = {}
    return { write = function(text) buffer[#buffer + 1] = text end, close = function() w.files[path] = table.concat(buffer) end }
  end }
  return w
end

local function run(w, args, answer)
  local file = io.open("probe/crn_probe4.lua", "rb")
  local source = file:read("*a")
  file:close()
  local env = setmetatable({
    peripheral = w.peripheral, os = w.os, fs = w.fs, _HOST = "Test",
    print = function(text) w.output[#w.output + 1] = tostring(text) end,
    read = function() return answer or "j" end,
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
  { "Lauf ohne Sperre: Zugname im Signal, Zustandswechsel und Abstand zum Beobachter stehen in der Kurzfassung, nichts wird geschrieben", function()
    local w = world()
    local ok, err, out = run(w, { "--wait", "20" })
    t.ok(ok, tostring(err))
    t.eq(#w.writes, 0, "ohne --sperre kein setForcedRed")
    t.contains(out, "Signal Create_Signal_0 nennt Zug Zug 1: JA")
    t.contains(out, "GREEN (+0.0 s) -> RED")
    t.contains(out, "Beobachter Create_TrainObserver_0 Zug Zug 1: passing +5.1 s; passed +8.0 s")
    t.contains(out, "Abstand Signal Create_Signal_0 zu Beobachter Create_TrainObserver_0, Zug Zug 1: Name verschwindet im Signal 1.0 s NACH train_passed")
    t.ok(w.files["crn_probe4.txt"] and #w.files["crn_probe4.txt"] > 200, "Bericht geschrieben")
  end },
  { "Signal ohne Zugname: die Kurzfassung sagt NEIN", function()
    local w = world({ no_names = true })
    local ok, err, out = run(w, { "--wait", "20" })
    t.ok(ok, tostring(err))
    t.contains(out, "Zugname in listBlockingTrainNames: NEIN")
  end },
  { "Ohne Zug laufen die Abfragen trotzdem sauber durch (Fehler von getPassingTrainName sind normal)", function()
    local w = world({ no_train = true })
    local ok, err, out = run(w, { "--wait", "10" })
    t.ok(ok, tostring(err))
    t.contains(out, "keine Ereignisse train_passing/train_passed")
  end },
  { "--sperre: nach j wird gesperrt und am Ende zurueckgestellt, nach n nichts veraendert", function()
    local w = world()
    local ok, err, out = run(w, { "--wait", "20", "--sperre" }, "j")
    t.ok(ok, tostring(err))
    t.eq(table.concat(w.writes, ","), "true,false", "gesperrt, dann zurueckgestellt")
    t.eq(w.forced(), false)
    t.contains(out, "Rueckstellung Create_Signal_0: setForcedRed(false) ok")
    local w2 = world()
    local ok2, err2, out2 = run(w2, { "--wait", "20", "--sperre" }, "n")
    t.ok(ok2, tostring(err2))
    t.eq(#w2.writes, 0, "nach n keine Schreibung")
    t.contains(out2, "abgebrochen: keine Sperre")
  end },
  { "Auch bei einem Fehler waehrend der Beobachtung wird die Sperre zurueckgestellt", function()
    local w = world()
    local real_pull = w.os.pullEvent
    local calls = 0
    w.os.pullEvent = function()
      calls = calls + 1
      if calls > 20 then error("Terminated", 0) end
      return real_pull()
    end
    local ok, err, out = run(w, { "--wait", "60", "--sperre" }, "j")
    t.ok(ok, tostring(err))
    t.eq(w.forced(), false, "Sperre zurueckgestellt")
    t.contains(out, "Abbruch der Beobachtung")
  end },
  { "Keine Geraete: Hinweis statt Absturz", function()
    local w = world({ empty = true })
    local ok, err, out = run(w, {})
    t.ok(ok, tostring(err))
    t.contains(out, "Keine Signale und keine Beobachter")
  end },
  { "Unbekannte Option: klarer Fehler", function()
    local w = world()
    local ok, err = run(w, { "--quatsch" })
    t.ok(not ok)
    t.contains(tostring(err), "Unbekannte Option")
  end },
}
