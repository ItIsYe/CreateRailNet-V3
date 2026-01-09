--[[
Purpose: Mock peripherals with deterministic sensor states.
Public API: new(), set_sensor(id, occupied), wrap(id).
]]

local mock_peripherals = {}

function mock_peripherals.new()
  local self = { sensors = {}, signals = {}, switches = {} }

  function self.set_sensor(id, occupied)
    self.sensors[id] = occupied
  end

  function self.wrap(id)
    if self.sensors[id] ~= nil then
      return {
        isOccupied = function()
          return self.sensors[id]
        end
      }
    end
    if self.signals[id] ~= nil then
      return {
        setAspect = function(aspect)
          self.signals[id] = aspect
        end
      }
    end
    if self.switches[id] ~= nil then
      return {
        setPosition = function(position)
          self.switches[id] = position
        end
      }
    end
    return {}
  end

  return self
end

return mock_peripherals
