--[[
Purpose: Redstone fallback adapter tests.
Public API: returns table of tests.
]]

local hardware_config = require("src.adapter.hardware_config")
local redstone = require("src.adapter.redstone")
local create_signals = require("src.adapter.create_signals")
local create_sensors = require("src.adapter.create_sensors")
local create_switches = require("src.adapter.create_switches")

local function fake_peripherals()
  return {
    wrap = function() return nil, "no peripheral" end,
    methods = function() return {} end
  }
end

local function fake_redstone()
  local calls = {}
  local inputs = {}
  return {
    calls = calls,
    inputs = inputs,
    adapter = redstone.new({
      setOutput = function(side, value) calls[side] = value end,
      getInput = function(side) return inputs[side] end
    })
  }
end

return {
  test_signal_redstone_green_sets_output = function()
    local rs = fake_redstone()
    local hw = hardware_config.new({ nodes = { { id = "SIG-1", role = "signal", adapter = "redstone", side = "right" } } })
    local adapter = create_signals.new(fake_peripherals(), { hardware = hw, redstone = rs.adapter })
    local ok = adapter.setAspect("SIG-1", "GREEN")
    assert(ok)
    assert(rs.calls.right == true)
  end,

  test_signal_redstone_red_clears_output = function()
    local rs = fake_redstone()
    local hw = hardware_config.new({ nodes = { { id = "SIG-1", role = "signal", adapter = "redstone", side = "right" } } })
    local adapter = create_signals.new(fake_peripherals(), { hardware = hw, redstone = rs.adapter })
    local ok = adapter.setAspect("SIG-1", "RED")
    assert(ok)
    assert(rs.calls.right == false)
  end,

  test_sensor_redstone_reads_input = function()
    local rs = fake_redstone()
    rs.inputs.left = true
    local hw = hardware_config.new({ nodes = { { id = "SEN-1", role = "sensor", adapter = "redstone", side = "left" } } })
    local adapter = create_sensors.new(fake_peripherals(), { hardware = hw, redstone = rs.adapter })
    local ok, occupied = adapter.readOccupied("SEN-1")
    assert(ok)
    assert(occupied == true)
  end,

  test_switch_redstone_active_position = function()
    local rs = fake_redstone()
    local hw = hardware_config.new({ nodes = { { id = "SW-1", role = "switch", adapter = "redstone", side = "back", active_position = "DIVERGING" } } })
    local adapter = create_switches.new(fake_peripherals(), { hardware = hw, redstone = rs.adapter })
    local ok = adapter.setPosition("SW-1", "DIVERGING")
    assert(ok)
    assert(rs.calls.back == true)
  end
}
