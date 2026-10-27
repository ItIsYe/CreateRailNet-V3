--[[
Purpose: Zugriff auf ein Create-Signal (Create_Signal): lesen und die zusaetzliche Rotsperre setzen oder aufheben. Ob die eigene Sperre steht, gilt nur nach dem Zuruecklesen von isForcedRed (das Ereignis train_signal_state_change ist nicht unterscheidbar, Messwert M08). Aufheben heisst nur Sperre aufheben, nie "gruen" (Konzept 20.1).
API: signal.new(env, name) -> g; g.read() -> { available, state, forced, signal_type, blocking, errors }; g.hold() -> { requested, confirmed, forced }; g.release() -> dasselbe
Notes: env = { peripheral }. Ein Computeranschluss veraendert das Verhalten des Signalblocks; lesende Anzeigen sollen die Daten des verantwortlichen Nodes nutzen, nicht selbst anschliessen (Konzept 3.2).
]]

local M = {}

function M.new(env, name)
  local g = {}

  local function call(method, ...)
    return pcall(env.peripheral.call, name, method, ...)
  end

  local function plain(text)
    return tostring(text):gsub("^.-:%d+: ", "")
  end

  function g.read()
    local state = { name = name, errors = {} }
    local ok, value = call("getState")
    if not ok then
      state.available = false
      state.errors[#state.errors + 1] = plain(value)
      return state
    end
    state.available = true
    state.state = value
    local ok_f, forced = call("isForcedRed")
    if ok_f then state.forced = forced == true else state.errors[#state.errors + 1] = plain(forced) end
    local ok_t, kind = call("getSignalType")
    if ok_t then state.signal_type = kind end
    local ok_b, list = call("listBlockingTrainNames")
    if ok_b and type(list) == "table" then state.blocking = list end
    return state
  end

  local function set(enabled)
    local ok, err = call("setForcedRed", enabled)
    if not ok then return { requested = enabled, confirmed = false, error = plain(err) } end
    local ok_r, forced = call("isForcedRed")
    if not ok_r then return { requested = enabled, confirmed = false, error = plain(forced) } end
    return { requested = enabled, confirmed = (forced == enabled), forced = forced }
  end

  function g.hold() return set(true) end
  function g.release() return set(false) end

  return g
end

return M
