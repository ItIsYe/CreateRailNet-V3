--[[
Purpose: Freigabeausgang (Redstone) setzen und zuruecklesen: an einer Computerseite oder an einem Redstone Relay. Das Zuruecklesen bestaetigt nur den Sollzustand des Ausgangs, nicht dass ein Zug abfaehrt (Konzept 24.3).
API: out.new(env, spec) -> o; spec = { side = "back" } oder { relay = "redstone_relay_0", side = "front" }; o.set(on) -> { requested, confirmed }; o.get() -> bool oder nil
Notes: env = { redstone, peripheral }. Ein pauschales Setzen aller Ausgaenge auf false waere ungeeignet (Konzept 14.2); jeder Ausgang gehoert genau einem Haltepunkt.
]]

local M = {}

function M.new(env, spec)
  local o = {}

  local function read()
    if spec.relay then
      local ok, v = pcall(env.peripheral.call, spec.relay, "getOutput", spec.side)
      if ok then return v end
      return nil
    end
    local ok, v = pcall(env.redstone.getOutput, spec.side)
    if ok then return v end
    return nil
  end

  function o.get() return read() end

  function o.set(on)
    local ok, err
    if spec.relay then
      ok, err = pcall(env.peripheral.call, spec.relay, "setOutput", spec.side, on)
    else
      ok, err = pcall(env.redstone.setOutput, spec.side, on)
    end
    if not ok then return { requested = on, confirmed = false, error = tostring(err) } end
    return { requested = on, confirmed = (read() == on) }
  end

  return o
end

return M
