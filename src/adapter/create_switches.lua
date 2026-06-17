--[[
Purpose: Switch adapter for Create track switches with redstone control.
Public API: new(peripherals, opts), setPosition(switch_id, position).

IMPORTANT: Vanilla Create track switches DO NOT expose a CC:Tweaked peripheral.
In Create, switches are controlled by redstone signals. Configure switch nodes
with adapter="redstone" in hardware_config to use redstone side outputs.

The peripheral path (setPosition method call) is provided for potential
third-party mod compatibility (e.g. Immersive Railroading, custom addons)
that may expose a setPosition peripheral method. It will NOT work with
vanilla Create track switches — use redstone adapter instead.
]]

local method_helper = require("src.adapter.methods")
local redstone = require("src.adapter.redstone")

local create_switches = {}

function create_switches.new(peripherals, opts)
  local options = opts or {}
  local hardware = options.hardware
  local rs = options.redstone or redstone.new()
  local self = {}

  local function adapter_for(id)
    return hardware and hardware.adapter(id) or "peripheral"
  end

  local function target_for(id)
    return hardware and hardware.target(id) or id
  end

  local function side_for(id)
    return hardware and hardware.side(id) or nil
  end

  function self.setPosition(switch_id, position)
    -- NOTE: Vanilla Create track switches use redstone control, not CC peripheral.
    -- If adapter_for returns "peripheral", this call will likely fail unless
    -- a third-party mod provides a setPosition method on the switch peripheral.
    if adapter_for(switch_id) == "redstone" then
      local invert = hardware and hardware.value(switch_id, "invert") or false
      local active_position = hardware and hardware.value(switch_id, "active_position") or "DIVERGING"
      local active = position == active_position
      if invert then active = not active end
      return rs.set_output(side_for(switch_id), active)
    end

    local ok, err = method_helper.call(peripherals, target_for(switch_id), "setPosition", position)
    if not ok then
      return false, "switch " .. tostring(err)
    end
    return true
  end

  return self
end

return create_switches
