--[[
Purpose: Plays a recorded dispatcher trace against a fresh dispatcher and checks that nothing unsafe happens.
Public API: run(cfg, trace, opts) -> result { steps, mismatches = { {step, op, recorded, replayed} }, violations = { {step, text} } }
  opts: strict (the safety invariants of legal runs; default is the chaos set that real runs with garbage input need),
        compare (compare results with the recording, default true)
Notes: the clock is the recorded one, so debounce and plausibility checks of the sensor guard behave as they did in the game.
]]

local trace_recorder = require("src.domain.trace_recorder")
local world_mod = require("tests.harness.dispatcher_world")

local trace_replay = {}

local function arg_list(op, args)
  local list = {}
  for i, name in ipairs(trace_recorder.OPS[op] or {}) do list[i] = args and args[name] end
  return list
end

local function call(d, op, args)
  local a = arg_list(op, args)
  if op == "request_route" then return d.request_route(a[1], a[2], { priority = a[3] }) end
  if op == "reserve_route" then return d.reserve_route(a[1], a[2]) end
  if op == "process_queue" then return d.process_queue(a[1]) end
  if op == "on_sensor_event_by_sensor" then return d.on_sensor_event_by_sensor(a[1], a[2], a[3]) end
  if op == "on_sensor_event" then return d.on_sensor_event(a[1], a[2], a[3], a[4]) end
  if op == "timeout_node" then return d.timeout_node(a[1]) end
  if op == "release_route" then return d.release_route(a[1], a[2]) end
  if op == "clear_fault" then return d.clear_fault(a[1]) end
  if op == "restore" then return d.restore(a[1]) end
  error("unknown op in trace: " .. tostring(op))
end

function trace_replay.run(cfg, trace, opts)
  local o = opts or {}
  local world = world_mod.from_config(cfg, { strict = o.strict })
  local result = { steps = 0, mismatches = {}, violations = {} }
  local ok, err = pcall(function()
    if trace.start then world.d.restore(trace.start) end
    for index, entry in ipairs(trace.entries) do
      world.clock = entry.t or world.clock
      local r1, r2 = call(world.d, entry.op, entry.a)
      result.steps = index
      if o.compare ~= false and entry.r then
        -- false is a legitimate result: no `x and r1 or nil` here
        local got1 = r1
        if type(got1) == "table" or type(got1) == "function" then got1 = nil end
        if entry.r[1] ~= got1 and entry.r[1] ~= "error" then
          result.mismatches[#result.mismatches + 1] = { step = index, op = entry.op, recorded = tostring(entry.r[1]), replayed = tostring(got1) }
        end
      end
      local broken = world_mod.violation(world, { chaos = not o.strict })
      if broken then result.violations[#result.violations + 1] = { step = index, text = broken } end
    end
  end)
  world_mod.close(world)
  if not ok then result.error = tostring(err) end
  return result
end

return trace_replay
