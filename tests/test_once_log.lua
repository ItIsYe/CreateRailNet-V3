--[[
Purpose: once_log tests: first occurrence logged, repeats suppressed and counted, recovery announced, repeat after the interval.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local once_log = require("src.shared.once_log")

local function setup(repeat_ms)
  local env = { now = 0, lines = {} }
  local logger = {}
  for _, level in ipairs({ "info", "warn", "error" }) do
    logger[level] = function(text, data) env.lines[#env.lines + 1] = { level = level, text = text, data = data } end
  end
  env.once = once_log.new(logger, { now_ms = function() return env.now end, repeat_ms = repeat_ms or 1000 })
  return env
end

return {
  test_a_failing_loop_logs_once = function()
    local env = setup()
    for _ = 1, 50 do env.now = env.now + 10; env.once.warn("draw", "draw failed", { error = "boom" }) end
    assert(#env.lines == 1 and env.lines[1].level == "warn" and env.lines[1].data.error == "boom")
  end,

  test_it_logs_again_after_the_interval_and_reports_how_often_it_was_silent = function()
    local env = setup(1000)
    for _ = 1, 10 do env.once.warn("draw", "draw failed") end
    env.now = 1500
    env.once.warn("draw", "draw failed")
    assert(#env.lines == 2)
    assert(env.lines[2].data.repeated == 9, "suppressed calls are counted, got " .. tostring(env.lines[2].data.repeated))
  end,

  test_recovery_is_announced_once = function()
    local env = setup()
    env.once.error("peripheral", "monitor missing")
    assert(env.once.ok("peripheral", "monitor back") == true)
    assert(env.once.ok("peripheral", "monitor back") == false, "nothing to announce twice")
    assert(env.lines[#env.lines].level == "info" and env.lines[#env.lines].text:find("recovered"))
    env.once.error("peripheral", "monitor missing")
    assert(#env.lines == 3, "a new failure after the recovery is logged again")
  end,

  test_keys_are_independent_and_listed = function()
    local env = setup()
    assert(env.once.first("a") and env.once.first("b"))
    assert(env.once.first("a") == false)
    local keys = env.once.active()
    assert(#keys == 2 and keys[1] == "a" and keys[2] == "b")
  end
}
