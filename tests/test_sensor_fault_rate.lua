--[[
Purpose: A station or depot sensor that stays broken is reported once (and every 30 s), the platform or track returns to its
  previous state when the sensor answers again.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local station_node = require("src.nodes.station_node")
local depot_node = require("src.nodes.depot_node")

local function build(factory, role, list_key, item, id)
  local env = { now = 0, last_id = 0, sent = {}, sensor_ok = true, occupied = false, virtual = 0 }
  local modem = {
    open = function() return true end,
    send = function(_, _, _, m) env.sent[#env.sent + 1] = m; return true end,
    broadcast = function(_, _, m) env.sent[#env.sent + 1] = m; return true end
  }
  local peripherals = {
    methods = function() if env.sensor_ok then return { "isTrainPassing" } end; return {} end,
    wrap = function(name) if name == "monitor" then return nil end; return { isTrainPassing = function() return env.occupied end } end,
    invalidate = function() end
  }
  local node_cfg = { id = id, role = role }
  node_cfg[list_key] = { item }
  env.node = factory.new_runtime({
    id = id, role = role, config = { channel = 1, master_id = "M", nodes = { node_cfg } },
    logger = { info = function() end, warn = function() end, error = function() end, debug = function() end },
    peripherals = peripherals, modem = modem,
    clock = function() return env.now end, start_timer = function() env.last_id = env.last_id + 1; return env.last_id end, tick_grace = 0
  })
  env.real_clock = os.clock
  os.clock = function() return env.virtual end
  env.step = function(seconds)
    env.now = env.now + seconds
    env.virtual = env.virtual + seconds
    env.node.handle_event({ "peripheral", "tick" })
  end
  env.close = function() os.clock = env.real_clock end
  env.count = function(payload_type)
    local n = 0
    for _, m in ipairs(env.sent) do if m.payload and m.payload.type == payload_type then n = n + 1 end end
    return n
  end
  return env
end

local function scenario(factory, role, list_key, item, id, fault_type, status_type)
  local env = build(factory, role, list_key, item, id)
  local ok, err = pcall(function()
    env.node.start()
    env.step(0.5)
    env.sensor_ok = false
    for _ = 1, 40 do env.step(0.5) end
    assert(env.count(fault_type) == 1, "a broken sensor is reported once, not " .. env.count(fault_type) .. " times in 20 seconds")
    for _ = 1, 70 do env.step(0.5) end
    assert(env.count(fault_type) == 2 or env.count(fault_type) == 3, "and again after 30 s, got " .. env.count(fault_type))
    local before = env.count(status_type)
    env.sensor_ok = true
    env.step(0.5)
    assert(env.count(status_type) > before, "the recovery is announced with a status event")
  end)
  env.close()
  if not ok then error(err, 0) end
end

return {
  test_station_sensor_fault_is_reported_once_and_recovers = function()
    scenario(station_node, "station", "platforms", { id = "P1", sensor_id = "SEN-P1" }, "ST-A", "station_fault", "platform_status")
  end,

  test_depot_sensor_fault_is_reported_once_and_recovers = function()
    scenario(depot_node, "depot", "tracks", { id = "D1", sensor_id = "SEN-D1" }, "DEP-1", "depot_fault", "depot_track_status")
  end,

  test_station_platform_returns_to_its_previous_state_after_a_sensor_fault = function()
    local env = build(station_node, "station", "platforms", { id = "P1", sensor_id = "SEN-P1" }, "ST-A")
    local ok, err = pcall(function()
      env.node.start()
      env.occupied = true
      env.step(0.5)
      local function platform_state() return env.node.station_state.platforms.P1.state end
      assert(platform_state() == "DWELLING", tostring(platform_state()))
      env.sensor_ok = false
      env.step(0.5)
      assert(platform_state() == "FAULT")
      env.sensor_ok = true
      env.step(0.5)
      assert(platform_state() == "DWELLING", "the platform must not stay in FAULT, got " .. tostring(platform_state()))
    end)
    env.close()
    if not ok then error(err, 0) end
  end
}
