--[[
Purpose: Trace recorder and replay: bounded ring, top-level calls only, dump/load round trip, identical replay of random walks.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local trace_recorder = require("src.domain.trace_recorder")
local trace_replay = require("tests.harness.trace_replay")
local world_mod = require("tests.harness.dispatcher_world")
local memfs = require("tests.harness.memfs")

local function cfg()
  return {
    sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "SE1", exit_signal = "SX1", sensors = { "SEN-1" }, switches = {} },
      { id = "B2", entry_signal = "SE2", exit_signal = "SX2", sensors = { "SEN-2" }, switches = {} }
    },
    routes = { { id = "R-12", from = "A", to = "B", blocks = { "B1", "B2" } }, { id = "R-1", from = "C", to = "D", blocks = { "B1" } } }
  }
end

local function fresh_dispatcher()
  local dispatcher = require("src.master.dispatcher")
  return dispatcher.new(cfg(), { signals = { setAspect = function() return true end }, switches = { setPosition = function() return true end } })
end

return {
  test_calls_are_recorded_with_arguments_and_results_and_still_work = function()
    local clock = 0
    local recorder = trace_recorder.new({ now_ms = function() clock = clock + 100; return clock end })
    local d = recorder.attach(fresh_dispatcher())
    local ok, status = d.request_route("T1", "R-1")
    assert(ok == true and status == "reserved")
    local ok2, status2 = d.request_route("T2", "R-1")
    assert(ok2 == false and status2 == "queued")
    local entries = recorder.entries()
    assert(#entries == 2, "internal reserve_route calls are not recorded, got " .. #entries)
    assert(entries[1].op == "request_route" and entries[1].a.train_id == "T1" and entries[1].a.route_id == "R-1")
    assert(entries[1].r[1] == true and entries[1].r[2] == "reserved" and entries[2].r[1] == false)
    assert(entries[2].t > entries[1].t)
  end,

  test_a_dispatcher_error_passes_through_and_is_recorded = function()
    local recorder = trace_recorder.new()
    local d = fresh_dispatcher()
    d.timeout_node = function() error("boom", 0) end
    recorder.attach(d)
    local ok, err = pcall(d.timeout_node, "SEN-1")
    assert(ok == false and err == "boom")
    assert(recorder.entries()[1].r[1] == "error")
  end,

  test_the_ring_keeps_only_the_newest_entries = function()
    local recorder = trace_recorder.new({ capacity = 5 })
    local d = recorder.attach(fresh_dispatcher())
    for i = 1, 20 do d.process_queue() end
    assert(recorder.size() == 5)
  end,

  test_dump_and_load_round_trip_through_safe_write = function()
    local fsys = memfs.new()
    local recorder = trace_recorder.new()
    local d = recorder.attach(fresh_dispatcher())
    d.request_route("T1", "R-12")
    d.on_sensor_event_by_sensor("SEN-1", "enter")
    assert(recorder.dump("traces/t1.json", { fs = fsys }))
    local trace = assert(trace_recorder.load("traces/t1.json", { fs = fsys }))
    assert(trace.version == 1 and #trace.entries == 2 and trace.entries[2].a.sensor_id == "SEN-1")
    assert(trace.start and trace.start.blocks)
    local missing, err = trace_recorder.load("traces/nope.json", { fs = fsys })
    assert(missing == nil and err == "missing")
    fsys.set("traces/bad.json", "{\"hello\":1}")
    assert(trace_recorder.load("traces/bad.json", { fs = fsys }) == nil)
    fsys.set("traces/broken.json", "{not json")
    assert(trace_recorder.load("traces/broken.json", { fs = fsys }) == nil)
  end,

  test_replay_of_a_simple_run_reproduces_every_result_without_violations = function()
    local clock = 0
    local recorder = trace_recorder.new({ now_ms = function() clock = clock + 1000; return clock end })
    local d = recorder.attach(fresh_dispatcher())
    d.request_route("T1", "R-12")
    d.request_route("T2", "R-1")
    d.on_sensor_event_by_sensor("SEN-1", "enter")
    d.on_sensor_event_by_sensor("SEN-1", "leave")
    d.on_sensor_event_by_sensor("SEN-2", "enter")
    d.on_sensor_event_by_sensor("SEN-2", "leave")
    d.timeout_node("SEN-1")
    local result = trace_replay.run(cfg(), recorder.to_table(), { strict = false })
    assert(result.steps == 7 and #result.mismatches == 0 and #result.violations == 0 and not result.error, result.error or "")
  end,

  test_a_doctored_trace_is_reported_as_a_mismatch = function()
    local clock = 0
    local recorder = trace_recorder.new({ now_ms = function() clock = clock + 1000; return clock end })
    local d = recorder.attach(fresh_dispatcher())
    d.request_route("T1", "R-1")
    local trace = recorder.to_table()
    trace.entries[1].r[1] = false
    local result = trace_replay.run(cfg(), trace)
    assert(#result.mismatches == 1 and result.mismatches[1].step == 1)
  end,

  -- the real test: whatever a random run does, recording it and replaying it gives the same results
  test_replaying_recorded_random_walks_gives_identical_results = function()
    for seed = 301, 312 do
      local world = world_mod.new(seed, { chaos = true })
      local ok, err = pcall(function()
        local recorder = trace_recorder.new({ capacity = 100000, now_ms = function() return world.clock end })
        recorder.attach(world.d)
        for _ = 1, 150 do world_mod.step_chaos(world) end
        local result = trace_replay.run(world.cfg, recorder.to_table(), {})
        assert(not result.error, "seed " .. seed .. ": " .. tostring(result.error))
        assert(#result.mismatches == 0, string.format("seed %d: step %d %s recorded %s replayed %s", seed, result.mismatches[1] and result.mismatches[1].step or 0, result.mismatches[1] and result.mismatches[1].op or "", result.mismatches[1] and result.mismatches[1].recorded or "", result.mismatches[1] and result.mismatches[1].replayed or ""))
        assert(#result.violations == 0, "seed " .. seed .. ": " .. tostring(result.violations[1] and result.violations[1].text))
      end)
      world_mod.close(world)
      if not ok then error(err, 0) end
    end
  end,

  test_dump_slots_rotate = function()
    local fsys = memfs.new()
    local recorder = trace_recorder.new()
    recorder.attach(fresh_dispatcher()).process_queue()
    local paths = {}
    for i = 1, 7 do paths[i] = assert(recorder.dump_slot("traces/fault_", 3, { fs = fsys })) end
    assert(paths[1] == "traces/fault_1.json" and paths[3] == "traces/fault_3.json" and paths[4] == "traces/fault_1.json" and paths[7] == "traces/fault_1.json")
    local count = 0
    for path in pairs(fsys.files) do if path:find("^traces/fault_%d%.json$") then count = count + 1 end end
    assert(count == 3)
  end,

  test_manual_action_dumps_a_trace_and_is_audited = function()
    local manual_control = require("src.master.manual_control")
    local recorder = trace_recorder.new()
    local d = recorder.attach(fresh_dispatcher())
    d.request_route("T1", "R-1")
    local audits = {}
    local context = { dispatcher = d, network = { send = function() end }, audit_log = { record = function(kind, data) audits[#audits + 1] = kind end } }
    local mc = manual_control.new(context)
    assert(mc.handle({ action = "trace_dump" }, "PANEL-1") == false, "no recorder yet")
    -- dump into the in-memory fs through the recorder's own option: the action uses the default fs, so only the wiring is checked here
    context.trace = { dump_slot = function(prefix, slots) return prefix .. "1.json" end }
    local ok, path = mc.handle({ action = "trace_dump" }, "PANEL-1")
    assert(ok == true and path == "traces/trace_1.json")
    assert(audits[#audits] == "trace_dumped")
  end
}
