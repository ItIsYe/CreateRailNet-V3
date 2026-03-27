--[[
Purpose: Peripheral wrapper safety and monitor scale normalization tests.
Public API: returns table of tests.
]]

local peripherals = require("src.adapter.peripherals")

return {
  test_safe_call_missing_method = function()
    local p = peripherals.new({})
    local ok, err = p.call({}, "missing")
    assert(not ok, "expected missing method to fail")
    assert(type(err) == "string" and err:find("missing method"), "expected missing method error")
  end,

  test_normalize_scale = function()
    local p = peripherals.new({})
    assert(p.normalize_scale("bad") == 1)
    assert(p.normalize_scale(0.1) == 0.5)
    assert(p.normalize_scale(5.9) == 5)
    assert(p.normalize_scale(1.24) == 1)
    assert(p.normalize_scale(1.26) == 1.5)
  end,

  test_set_monitor_scale_skips_unchanged = function()
    local p = peripherals.new({})
    local calls = 0
    local monitor = {
      setTextScale = function(_, value)
        calls = calls + 1
        return value
      end
    }

    local ok1 = p.set_monitor_scale(monitor, 1)
    local ok2 = p.set_monitor_scale(monitor, 1)
    assert(ok1, "first set should succeed")
    assert(ok2, "second set should succeed")
    assert(calls == 1, "expected unchanged scale to skip call")
  end
}
