--[[
Purpose: Dispatcher recovery snapshot/restore tests.
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function cfg()
  return {
    blocks = {
      { id = "B1", entry_signal = "SIG-A", exit_signal = "SIG-B", sensors = { "SEN-1" }, switches = {} },
      { id = "B2", entry_signal = "SIG-B", exit_signal = "SIG-C", sensors = { "SEN-2" }, switches = { { id = "SW-1", position = "STRAIGHT" } } }
    },
    routes = {
      { id = "R1", from = "ST-A", to = "ST-B", blocks = { "B1" }, priority = 10 },
      { id = "R1R", from = "ST-B", to = "ST-A", blocks = { "B1" }, priority = 10 },
      { id = "R2", from = "ST-B", to = "ST-C", blocks = { "B2" }, priority = 5 }
    }
  }
end

local function adapters()
  return {
    signals = { setAspect = function() return true end },
    switches = { setPosition = function() return true end }
  }
end

return {
  test_snapshot_keeps_reserved_block = function()
    local d = dispatcher.new(cfg(), adapters())
    local ok = d.reserve_route("TRAIN-1", "R1")
    assert(ok)
    local snap = d.snapshot()
    assert(snap.blocks.B1.state == "RESERVED")
    assert(snap.blocks.B1.reserved_by == "TRAIN-1")
    assert(snap.trains["TRAIN-1"].route == "R1")
  end,

  test_restore_preserves_reserved_block = function()
    local d1 = dispatcher.new(cfg(), adapters())
    assert(d1.reserve_route("TRAIN-1", "R1"))
    local snap = d1.snapshot()
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(snap))
    local overview = d2.get_overview()
    assert(overview.B1.state == "RESERVED")
    assert(overview.B1.reserved_by == "TRAIN-1")
    assert(d2.get_trains()["TRAIN-1"].state == "RESERVED")
  end,

  test_restore_preserves_running_block = function()
    local d1 = dispatcher.new(cfg(), adapters())
    assert(d1.reserve_route("TRAIN-1", "R1"))
    assert(d1.on_sensor_event("B1", "enter"))
    local snap = d1.snapshot()
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(snap))
    local overview = d2.get_overview()
    assert(overview.B1.state == "OCCUPIED")
    assert(overview.B1.reserved_by == "TRAIN-1")
    assert(d2.get_trains()["TRAIN-1"].state == "RUNNING")
    assert(d2.get_trains()["TRAIN-1"].current_block == "B1")
  end,

  test_restore_preserves_queue = function()
    local d1 = dispatcher.new(cfg(), adapters())
    assert(d1.reserve_route("TRAIN-1", "R1"))
    local ok2 = d1.request_route("TRAIN-2", "R1")
    assert(not ok2)
    local snap = d1.snapshot()
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(snap))
    local queue = d2.get_queue()
    assert(#queue == 1)
    assert(queue[1].train_id == "TRAIN-2")
    assert(queue[1].route_id == "R1")
  end,

  test_restore_preserves_conflict_groups = function()
    local d1 = dispatcher.new(cfg(), adapters())
    assert(d1.reserve_route("TRAIN-1", "R1"))
    local snap = d1.snapshot()
    assert(snap.active_conflicts["dir:ST-A<->ST-B"])
    local d2 = dispatcher.new(cfg(), adapters())
    assert(d2.restore(snap))
    assert(d2.get_conflicts()["dir:ST-A<->ST-B"])
    local ok, err = d2.reserve_route("TRAIN-2", "R1R")
    assert(not ok)
    assert(string.find(err, "conflict") or string.find(err, "block not free"), err)
  end
}
