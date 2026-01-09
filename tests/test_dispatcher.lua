--[[
Purpose: Dispatcher logic tests.
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function build_dispatcher()
  local cfg = {
    blocks = {
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = {"SEN-1"}, switches = { { id = "SW-1", position = "STRAIGHT" } } },
      { id = "B2", entry_signal = "SIG-3", exit_signal = "SIG-4", sensors = {"SEN-2"}, switches = {} }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = {"B1"}, priority = 1 },
      { id = "R2", from = "A", to = "B", blocks = {"B1", "B2"}, priority = 1 }
    }
  }
  local signals = {}
  local adapters = {
    signals = {
      setAspect = function(id, aspect) signals[id] = aspect end
    },
    switches = {
      setPosition = function() end
    }
  }
  return dispatcher.new(cfg, adapters), signals
end

return {
  test_reserve_ok = function()
    local disp = build_dispatcher()
    local ok = disp.reserve_route("T1", "R1")
    assert(ok, "expected reserve ok")
    assert(disp.get_block("B1").state == dispatcher.STATES.RESERVED)
  end,
  test_reserve_conflict = function()
    local disp = build_dispatcher()
    disp.reserve_route("T1", "R1")
    local ok = disp.reserve_route("T2", "R1")
    assert(not ok, "expected conflict")
  end,
  test_reserve_rollback = function()
    local disp = build_dispatcher()
    disp.get_block("B2").state = dispatcher.STATES.OCCUPIED
    local ok = disp.reserve_route("T1", "R2")
    assert(not ok, "expected failure")
    assert(disp.get_block("B1").state == dispatcher.STATES.FREE, "expected rollback")
  end,
  test_sensor_transitions = function()
    local disp = build_dispatcher()
    disp.reserve_route("T1", "R1")
    local ok_enter = disp.on_sensor_event("B1", "enter")
    assert(ok_enter)
    assert(disp.get_block("B1").state == dispatcher.STATES.OCCUPIED)
    local ok_leave = disp.on_sensor_event("B1", "leave")
    assert(ok_leave)
    assert(disp.get_block("B1").state == dispatcher.STATES.FREE)
  end,
  test_inconsistency_fault = function()
    local disp = build_dispatcher()
    local ok = disp.on_sensor_event("B1", "leave")
    assert(not ok)
    assert(disp.get_block("B1").state == dispatcher.STATES.FAULT)
  end,
  test_timeout_fault_and_red = function()
    local disp, signals = build_dispatcher()
    disp.timeout_node("SEN-1")
    assert(disp.get_block("B1").state == dispatcher.STATES.FAULT)
    assert(signals["SIG-1"] == "RED")
  end
}
