--[[
Purpose: Create hardware adapter tests using fake peripherals only.
Public API: returns table of tests.
]]

local create_signals = require("src.adapter.create_signals")
local create_sensors = require("src.adapter.create_sensors")

local function fake_peripherals(device)
  return {
    wrap = function() return device end,
    methods = function()
      local out = {}
      for name, value in pairs(device or {}) do
        if type(value) == "function" then table.insert(out, name) end
      end
      return out
    end
  }
end

return {
  test_create_signal_red_uses_forced_red = function()
    local forced = nil
    local adapter = create_signals.new(fake_peripherals({
      setForcedRed = function(value) forced = value end
    }))
    local ok = adapter.setAspect("Create_Signal_0", "RED")
    assert(ok)
    assert(forced == true)
  end,

  test_create_signal_green_clears_forced_red = function()
    local forced = nil
    local adapter = create_signals.new(fake_peripherals({
      setForcedRed = function(value) forced = value end
    }))
    local ok = adapter.setAspect("Create_Signal_0", "GREEN")
    assert(ok)
    assert(forced == false)
  end,

  test_create_signal_state_reads_get_state = function()
    local adapter = create_signals.new(fake_peripherals({
      getState = function() return "GREEN" end
    }))
    local ok, state = adapter.getState("Create_Signal_0")
    assert(ok)
    assert(state == "GREEN")
  end,

  test_create_train_observer_reads_presence = function()
    local adapter = create_sensors.new(fake_peripherals({
      isTrainPassing = function() return true end
    }))
    local ok, occupied = adapter.readOccupied("Create_TrainObserver_0")
    assert(ok)
    assert(occupied == true)
  end,

  test_create_train_observer_reads_name = function()
    local adapter = create_sensors.new(fake_peripherals({
      getPassingTrainName = function() return "Train A" end
    }))
    local ok, name = adapter.readTrainName("Create_TrainObserver_0")
    assert(ok)
    assert(name == "Train A")
  end
}
