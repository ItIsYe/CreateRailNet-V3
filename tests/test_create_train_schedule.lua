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
  test_build_schedule_from_stops_uses_create_format = function()
    local schedule = create_train_schedule.build_schedule({
      { from = "A", to = "B", route_id = "R1", dwell_seconds = 10 }
    })
    assert(schedule.cyclic == false)
    assert(#schedule.entries == 1)
    assert(schedule.entries[1].instruction.id == "create:destination")
    assert(schedule.entries[1].instruction.data.text == "B")
    assert(schedule.entries[1].conditions[1][1].id == "create:delay")
    assert(schedule.entries[1].conditions[1][1].data.value == 10)
    assert(schedule.entries[1].conditions[1][1].data.time_unit == 1)
  end,

  test_build_schedule_supports_cyclic = function()
    local schedule = create_train_schedule.build_schedule({ { station_name = "Station A" } }, { cyclic = true })
    assert(schedule.cyclic == true)
    assert(schedule.entries[1].instruction.data.text == "Station A")
  end,

  test_build_schedule_fails_without_destination = function()
    local schedule, err = create_train_schedule.build_schedule({ { dwell_seconds = 1 } })
    assert(schedule == nil)
    assert(err == "missing destination/station name")
  end,

  test_apply_uses_create_station_set_schedule = function()
    local applied = nil
    local adapter = create_train_schedule.new(fake_peripherals({
      isTrainPresent = function() return true end,
      setSchedule = function(schedule) applied = schedule end
    }), { station = "Create_Station_0" })
    local ok = adapter.apply("TRAIN-1", { cyclic = false, entries = { { instruction = { id = "create:destination", data = { text = "B" } }, conditions = { { { id = "create:delay", data = { value = 1, time_unit = 1 } } } } } } })
    assert(ok)
    assert(applied.entries[1].instruction.data.text == "B")
  end,

  test_apply_stops_builds_and_applies_schedule = function()
    local applied = nil
    local adapter = create_train_schedule.new(fake_peripherals({
      isTrainPresent = function() return true end,
      setSchedule = function(schedule) applied = schedule end
    }))
    local ok = adapter.apply_stops("Create_Station_0", { { to = "C" } })
    assert(ok)
    assert(applied.entries[1].instruction.data.text == "C")
  end,

  test_apply_fails_when_no_train_present = function()
    local adapter = create_train_schedule.new(fake_peripherals({
      isTrainPresent = function() return false end,
      setSchedule = function() error("should not be called") end
    }))
    local ok, err = adapter.apply("Create_Station_0", { cyclic = false, entries = {} })
    assert(not ok)
    assert(err == "no train present at station")
  end,

  test_apply_fails_without_set_schedule = function()
    local adapter = create_train_schedule.new(fake_peripherals({ isTrainPresent = function() return true end }))
    local ok, err = adapter.apply("Create_Station_0", { cyclic = false, entries = {} })
    assert(not ok)
    assert(err == "station missing setSchedule")
  end,

  test_apply_rejects_old_internal_format = function()
    local adapter = create_train_schedule.new(fake_peripherals({}))
    local ok, err = adapter.apply("Create_Station_0", { stops = {} })
    assert(not ok)
    assert(err == "schedule must be official Create format with entries")
  end
}
