--[[
Purpose: Testnetz mit mehreren Nodes (jede mit eigenem Computer, Dateisystem und Fake-Welt) an einem Funkbus plus Schienensimulation. Der Takt laeuft in ganzen Sekunden Betriebszeit; Create-Ereignisse und Funknachrichten werden den Nodes zugestellt.
API: H.new(opts) -> h; h.add_node(spec) -> node-Eintrag; h.sim(stations, travel); h.step(n); h.until_true(fn, max) -> Sekunden oder nil; h.restart(node_id)
Notes: spec = { id, roles, tracks = { { name, station_name, release_side } }, central, registration (Gleisname), world_setup(w) }. Die Konfiguration wird wie vom Assistenten erzeugt und aktiv gespeichert.
]]

local drv = dofile("tests/lib/ui_driver.lua")
local create = dofile("tests/fakes/create.lua")
local busLib = dofile("tests/fakes/bus.lua")
local simlib = dofile("tests/fakes/sim.lua")
local model = require("setup.model")
local storelib = require("core.store")

local H = {}

-- Seite im Terminal oeffnen, notfalls durch Blaettern der Reiter
function H.open_page(d, id)
  local v = d.view()
  for _ = 1, 12 do
    if pcall(d.tap, v, "nav:" .. id) then return v end
    d.tap(v, "navscroll:next")
  end
  d.tap(v, "nav:" .. id)
  return v
end

function H.new(opts)
  opts = opts or {}
  local h = { nodes = {}, order = {}, bus = busLib.new(opts.bus), t = 0 }

  function h.add_node(spec)
    local w = create.world()
    w.add_modem("left", true)
    w.add_modem("right", false, true)
    local device_names = {}
    for i, track in ipairs(spec.tracks or {}) do
      if track.station_name then
        local dev = "Create_Station_" .. i
        w.add_station(dev, { station_name = track.station_name, known = track.known })
        device_names[track.name] = dev
      end
      for _, name in ipairs(track.signals or {}) do if not w.devices[name] then w.add_signal(name) end end
      for _, name in ipairs(track.observers or {}) do if not w.devices[name] then w.add_observer(name) end end
    end
    if spec.world_setup then spec.world_setup(w) end
    local cid = #h.order + 1
    local d = drv.new({ world = w, bus = h.bus, cid = cid })
    local config = model.new(spec.id, spec.roles, { name = "Testnetz", central_id = spec.central })
    config.node.id = spec.id
    local device_ids = {}
    for _, track in ipairs(spec.tracks or {}) do
      local tid = model.add_track(config, track.name)
      if track.station_name then
        device_ids[track.name] = model.add_device(config, "station", device_names[track.name])
        model.assign(config, tid, "station", device_ids[track.name])
      end
      for _, name in ipairs(track.signals or {}) do model.assign(config, tid, "signals", model.add_device(config, "signal", name)) end
      for _, name in ipairs(track.observers or {}) do model.assign(config, tid, "observers", model.add_device(config, "observer", name)) end
      if track.junction then config.tracks[tid].junction = track.junction end
      if track.release_side then config.tracks[tid].release = { side = track.release_side } end
      if track.length then config.tracks[tid].length = track.length end
      track.tid = tid
    end
    if spec.junction then config.junction = spec.junction end
    if spec.registration then config.registration_station = device_ids[spec.registration] end
    config.status = "aktiv"
    d.fs.makeDir("/crn_data")
    storelib.new(d.fs).save("/crn_data/config.lua", config)
    d.boot_t = 0
    d.cid = cid
    d.id = spec.id
    d.spec = spec
    d.world = w
    h.nodes[spec.id] = d
    h.order[#h.order + 1] = d
    d.restart()
    return d
  end

  function h.sim(stations, travel)
    local list = {}
    for _, st in ipairs(stations) do
      local d = h.nodes[st.node]
      list[#list + 1] = { name = st.name, world = d.world, device = st.device or "Create_Station_1", side = st.side or "back" }
    end
    h.simulation = simlib.new({ stations = list, travel = travel })
    return h.simulation
  end

  local function pump_node(d)
    local node = d.node
    local rounds = 0
    local progress = true
    while progress and rounds < 50 do
      progress = false
      rounds = rounds + 1
      while true do
        local ev = d.world.pull()
        if not ev then break end
        node.handle(ev)
        progress = true
      end
      while true do
        local ev = h.bus.pop(d.cid)
        if not ev then break end
        node.handle(ev)
        progress = true
      end
    end
  end

  local function pump_all()
    for round = 1, 6 do
      for _, d in ipairs(h.order) do pump_node(d) end
    end
  end

  function h.step(n)
    for _ = 1, n or 1 do
      h.t = h.t + 1
      for _, d in ipairs(h.order) do d.raw.v = h.t - d.boot_t end
      if h.simulation then h.simulation.step(1) end
      pump_all()      -- Ereignisse liegen in der Warteschlange vor dem Takt (wie in CC)
      for _, d in ipairs(h.order) do d.node.handle({ "timer", 1 }) end
      pump_all()
    end
  end

  function h.until_true(fn, max)
    for i = 1, max or 300 do
      if fn() then return i end
      h.step(1)
    end
    if fn() then return max end
    return nil
  end

  -- Neustart eines Nodes: der Computer startet neu, die Betriebsuhr beginnt mit os.clock bei 0
  function h.restart(id)
    local d = h.nodes[id]
    d.node.shutdown()
    d.restart()
    d.boot_t = h.t
    d.raw.v = 0
    d.node.handle({ "timer", 1 })
  end

  return h
end

return H
