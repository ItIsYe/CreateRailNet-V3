--[[
Purpose: Schienensimulation fuer Tests: Zuege fahren zwischen Bahnhoefen verschiedener Fake-Welten und arbeiten ihren Create-Fahrplan nach den Regeln aus Konzept 8.3 und 21: Bedingungen einer Gruppe nacheinander (delay in Sekunden, item_threshold strikt groesser, powered = Redstone-Ausgang an der Station), mehrere Gruppen als Alternativen, nicht zyklische Fahrplaene enden. Ein neuer Fahrplan beginnt am aktuellen Bahnhof, wenn dort der erste Eintrag liegt. Ereignisse (imminent, arrival, departure) gehen in die Warteschlange der jeweiligen Welt.
API: sim.new{ stations = { { name, world, device, side } }, travel = Sekunden } -> s; s.add_train(name, station, schedule, cargo); s.set_cargo(name, menge); s.step(sekunden); s.t; s.trains[name]
]]

local ser = require("core.ser")

local M = {}

function M.new(opts)
  local s = { t = 0, stations = {}, trains = {}, travel = opts.travel or 20, departures = {}, arrivals = {} }
  for _, st in ipairs(opts.stations) do s.stations[st.name] = st end

  local function powered(station)
    local st = s.stations[station]
    return st.world.sides[st.side] == true
  end

  local function entries(train)
    local st = s.stations[train.station]
    local dev = st and st.world.devices[st.device]
    local sched = dev and dev.state.train and dev.state.train.schedule
    return sched
  end

  -- Schluessel der Zuege ist der Name beim Anlegen (auch nach einem Umbenennen)
  function s.add_train(name, station, schedule, cargo)
    local st = s.stations[station]
    st.world.arrive(st.device, name, schedule)
    while st.world.pull() do end        -- Ereignisse der Anfangsaufstellung werden nicht zugestellt
    s.trains[name] = { name = name, status = "station", station = station, cargo = cargo or 0, since = s.t, last = schedule and ser.encode(schedule) or nil, progress = 1, gi = {}, cond_start = s.t }
  end

  function s.set_cargo(name, amount) s.trains[name].cargo = amount end

  local function reset_progress(train, index)
    train.progress, train.gi, train.cond_start = index or 1, {}, s.t
  end

  local function depart(train, dest)
    local st = s.stations[train.station]
    local dev = st.world.devices[st.device]
    local sched = dev.state.train and dev.state.train.schedule
    st.world.depart(st.device)
    train.schedule_copy = sched
    train.status, train.dest, train.arrive_at, train.imminent_sent = "travel", dest, s.t + s.travel, false
    train.station = nil
  end

  local function condition_ok(train, cond, group_idx)
    local id = cond.id
    if id == "create:delay" then
      local seconds = cond.data.value * ((cond.data.time_unit == 1) and 1 or 1)
      return s.t - train.gi[group_idx].start >= seconds
    elseif id == "create:powered" then
      return powered(train.station)
    elseif id == "create:item_threshold" then
      local threshold = tonumber(cond.data.threshold)
      return train.cargo > threshold
    end
    return false
  end

  local function evaluate(train, sched)
    local entry = sched.entries[train.progress]
    if not entry then return end
    local satisfied = false
    for g, group in ipairs(entry.conditions) do
      train.gi[g] = train.gi[g] or { i = 1, start = s.t }
      local gi = train.gi[g]
      while gi.i <= #group do
        if condition_ok(train, group[gi.i], g) then
          gi.i = gi.i + 1
          gi.start = s.t
        else
          break
        end
      end
      if gi.i > #group then satisfied = true end
    end
    if not satisfied then return end
    -- naechster Eintrag
    local nxt = train.progress + 1
    if nxt > #sched.entries then
      if sched.cyclic then nxt = 1 else train.status = "idle" return end
    end
    local dest = sched.entries[nxt].instruction.data.text
    train.progress = nxt
    train.gi = {}
    if dest == train.station then
      train.cond_start = s.t        -- schon am Ziel: weiter mit den Bedingungen dieses Eintrags
    else
      depart(train, dest)
    end
  end

  local function step_train(train)
    if train.status == "travel" then
      local st = s.stations[train.dest]
      if not train.imminent_sent and s.t >= train.arrive_at - 3 then
        st.world.devices[st.device].state.enroute = true
        st.world.queue[#st.world.queue + 1] = { "train_imminent", st.device, train.name }
        train.imminent_sent = true
      end
      if s.t >= train.arrive_at then
        st.world.arrive(st.device, train.name, train.schedule_copy)
        -- w.arrive sendet imminent noch einmal: die doppelte Meldung entfernen
        local q = st.world.queue
        for i = #q - 1, 1, -1 do
          if q[i][1] == "train_imminent" and q[i][3] == train.name and q[i + 1] and q[i + 1][1] == "train_arrival" then table.remove(q, i) break end
        end
        train.status, train.station, train.dest = "station", st.name, nil
        reset_progress(train, train.progress)
        train.last = ser.encode(train.schedule_copy)
      end
    elseif train.status == "station" then
      local st = s.stations[train.station]
      local dev = st.world.devices[st.device]
      if dev.state.train then train.name = dev.state.train.name end    -- der Name kann umbenannt worden sein
      local sched = dev.state.train and dev.state.train.schedule
      if not sched then return end
      local now_text = ser.encode(sched)
      if now_text ~= train.last then
        -- neuer Fahrplan: beginnt am aktuellen Bahnhof, wenn dort der erste Eintrag liegt (Konzept 8.2)
        train.last = now_text
        reset_progress(train, 1)
        if sched.entries[1].instruction.data.text ~= train.station then
          depart(train, sched.entries[1].instruction.data.text)
          return
        end
      end
      evaluate(train, sched)
    end
  end

  function s.step(seconds)
    for _ = 1, seconds do
      s.t = s.t + 1
      local names = {}
      for k in pairs(s.trains) do names[#names + 1] = k end
      table.sort(names)
      for _, name in ipairs(names) do step_train(s.trains[name]) end
    end
  end

  return s
end

return M
