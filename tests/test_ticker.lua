--[[
Purpose: Timer guard tests (src.shared.ticker): normal firing, lost timer recovery, stale timers, failing jobs.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local ticker = require("src.shared.ticker")

local function fake_env()
  local env = { now = 0, last_id = 0, started = {} }
  env.clock = function() return env.now end
  env.start_timer = function(seconds)
    env.last_id = env.last_id + 1
    env.started[#env.started + 1] = { id = env.last_id, seconds = seconds }
    return env.last_id
  end
  return env
end

local function new_ticker(env, extra)
  local opts = { clock = env.clock, start_timer = env.start_timer }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return ticker.new(opts)
end

return {
  test_timer_event_fires_owning_job_and_rearms = function()
    local env = fake_env()
    local t = new_ticker(env)
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    t.start()
    assert(#env.started == 1 and env.started[1].seconds == 1)
    env.now = 1
    assert(t.handle_event({ "timer", 1 }) == true)
    assert(fired == 1)
    assert(#env.started == 2, "job must be re-armed")
    assert(t.stats().jobs.a.recovered == 0)
  end,

  test_foreign_timer_and_other_events_are_not_consumed = function()
    local env = fake_env()
    local t = new_ticker(env)
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    t.start()
    assert(t.handle_event({ "timer", 999 }) == false)
    assert(t.handle_event({ "modem_message", "x" }) == false)
    assert(fired == 0)
  end,

  test_lost_timer_is_recovered_by_next_event_after_grace = function()
    local env = fake_env()
    local t = new_ticker(env, { grace = 1 })
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    t.start()
    -- the timer event (id 1) is dropped by a full event queue; the clock moves on, other events arrive
    env.now = 1.5
    t.handle_event({ "modem_message" })
    assert(fired == 0, "inside the grace window nothing is recovered yet")
    env.now = 2.1
    t.handle_event({ "modem_message" })
    assert(fired == 1, "overdue job must fire on the next event")
    local stats = t.stats()
    assert(stats.recovered == 1 and stats.jobs.a.recovered == 1)
    assert(stats.jobs.a.max_late >= 1.0)
    assert(#env.started == 2, "recovered job must be re-armed")
  end,

  test_stale_timer_after_recovery_does_not_fire_twice = function()
    local env = fake_env()
    local t = new_ticker(env, { grace = 0.5 })
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    t.start()
    env.now = 2
    t.handle_event({ "modem_message" })
    assert(fired == 1)
    -- the original timer event (id 1) shows up late, it belongs to the previous arming
    assert(t.handle_event({ "timer", 1 }) == false)
    assert(fired == 1)
  end,

  test_recovery_does_not_double_fire_a_job_that_just_ran = function()
    local env = fake_env()
    local t = new_ticker(env, { grace = 0.1 })
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    t.start()
    env.now = 5
    t.handle_event({ "timer", 1 })
    assert(fired == 1, "timer event fires once, poll must not fire it a second time")
  end,

  test_failing_job_is_rearmed_and_error_logged_once_per_message = function()
    local env = fake_env()
    local errors = {}
    local t = new_ticker(env, { on_error = function(name, err) errors[#errors + 1] = name .. ":" .. err end })
    t.every("bad", 1, function() error("boom", 0) end)
    t.start()
    for i = 1, 5 do
      env.now = i
      t.handle_event({ "timer", env.last_id })
    end
    assert(#errors == 1, "same error must not flood the log, got " .. #errors)
    assert(errors[1] == "bad:boom")
    local stats = t.stats()
    assert(stats.jobs.bad.errors == 5 and stats.jobs.bad.fired == 5)
    assert(#env.started == 6, "a failing job keeps its schedule")
  end,

  test_job_added_before_start_is_armed_by_start_and_after_start_immediately = function()
    local env = fake_env()
    local t = new_ticker(env)
    t.every("a", 1, function() end)
    assert(#env.started == 0)
    t.start()
    assert(#env.started == 1)
    t.every("b", 2, function() end)
    assert(#env.started == 2 and env.started[2].seconds == 2)
  end,

  test_nothing_runs_before_start = function()
    local env = fake_env()
    local t = new_ticker(env, { grace = 0 })
    local fired = 0
    t.every("a", 1, function() fired = fired + 1 end)
    env.now = 100
    assert(t.handle_event({ "modem_message" }) == false)
    assert(t.poll() == 0 and fired == 0)
  end,

  test_two_jobs_recover_independently = function()
    local env = fake_env()
    local t = new_ticker(env, { grace = 0.5 })
    local a, b = 0, 0
    t.every("a", 1, function() a = a + 1 end)
    t.every("b", 10, function() b = b + 1 end)
    t.start()
    env.now = 2
    t.handle_event({ "peripheral", "left" })
    assert(a == 1 and b == 0)
  end
}
