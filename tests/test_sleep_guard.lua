--[[
Purpose: sleep_guard tests: normal wake-up and wake-up after a dropped timer event.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local sleep_guard = require("src.shared.sleep_guard")

return {
  test_returns_timer_when_own_timer_arrives = function()
    local now = 0
    local result = sleep_guard.sleep(2, {
      clock = function() return now end,
      start_timer = function() return 7 end,
      pull_event = function() now = now + 2; return "timer", 7 end
    })
    assert(result == "timer")
  end,

  test_other_timer_ids_are_ignored = function()
    local now = 0
    local calls = 0
    local result = sleep_guard.sleep(5, {
      clock = function() return now end,
      start_timer = function() return 7 end,
      pull_event = function()
        calls = calls + 1
        if calls == 1 then now = 1; return "timer", 99 end
        now = 5; return "timer", 7
      end
    })
    assert(result == "timer" and calls == 2)
  end,

  test_dropped_timer_ends_at_deadline_on_next_event = function()
    local now = 0
    local calls = 0
    local result = sleep_guard.sleep(2, {
      clock = function() return now end,
      start_timer = function() return 7 end,
      pull_event = function()
        calls = calls + 1
        now = now + 1
        return "modem_message"
      end
    })
    assert(result == "deadline")
    assert(calls == 2, "must stop on the first event at or after the deadline, got " .. calls)
  end
}
