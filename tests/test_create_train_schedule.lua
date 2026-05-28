--[[
Purpose: Create train schedule adapter tests.
Public API: returns table of tests.
]]

local create_train_schedule = require("src.adapter.create_train_schedule")

local function fake_peripherals(methods)
  return {
    wrap = function()
      return methods
    end,
    methods = function()
      local out = {}
      for name in pairs(methods or {}) do table.insert(out, name) end
      return out
    end
  }
end

return {
  test_build_schedule_from_stops = function()
    local schedule = create_train_schedule.build_schedule({
      { from = "A", to = "B", route_id = "R1", dwell_seconds = 10 }
    })
    assert(#schedule.stops == 1)
    assert(schedule.stops[1].to == "B")
    assert(schedule.stops[1].route_id == "R1")
  end,

  test_apply_uses_set_schedule = function()
    local applied = nil
    local adapter = create_train_schedule.new(fake_peripherals({
      setSchedule = function(schedule) applied = schedule end
    }))
    local ok = adapter.apply("TRAIN-1", { stops = { { to = "B" } } })
    assert(ok)
    assert(applied.stops[1].to == "B")
  end,

  test_apply_stops_builds_schedule = function()
    local applied = nil
    local adapter = create_train_schedule.new(fake_peripherals({
      setTrainSchedule = function(schedule) applied = schedule end
    }))
    local ok = adapter.apply_stops("TRAIN-1", { { to = "C" } })
    assert(ok)
    assert(applied.stops[1].to == "C")
  end,

  test_apply_fails_without_method = function()
    local adapter = create_train_schedule.new(fake_peripherals({}))
    local ok, err = adapter.apply("TRAIN-1", { stops = {} })
    assert(not ok)
    assert(err)
  end
}
