--[[
Purpose: UI core resilience tests for draw/touch failures.
Public API: returns table of tests.
]]

local ui_core = require("src.master.ui.ui_core")

return {
  test_draw_failure_isolated = function()
    local messages = {}
    local monitor = {
      clear = function() end,
      setCursorPos = function() end,
      write = function(_, text)
        table.insert(messages, text)
      end
    }
    local logger = {
      error = function() end
    }
    local panel = {
      draw = function()
        error("boom")
      end
    }
    local ui = ui_core.new(monitor, { bad = panel }, { logger = logger })
    ui.set_panel("bad")
    ui.draw()
    assert(messages[1] == "UI unavailable", "expected fallback message")
  end,

  test_touch_failure_isolated = function()
    local logger_calls = 0
    local logger = {
      error = function()
        logger_calls = logger_calls + 1
      end
    }
    local panel = {
      touch = function()
        error("touch boom")
      end
    }
    local ui = ui_core.new({}, { bad = panel }, { logger = logger })
    ui.set_panel("bad")
    ui.handle_touch(1, 1)
    assert(logger_calls == 1, "expected touch error log")
  end
}
