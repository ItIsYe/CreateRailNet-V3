--[[
Unit tests for eventbus: subscribe, publish, next, error handling, on_error callback.
]]
dofile("tests/harness/cc_bootstrap.lua")
local eventbus = require("src.shared.eventbus")

return {
  test_subscribe_and_receive = function()
    local bus = eventbus.new()
    local received = nil
    bus.subscribe("arrival", function(p) received = p.train_id end)
    bus.publish("arrival", { train_id="TRAIN-1" })
    local ok = bus.next()
    assert(ok)
    assert(received == "TRAIN-1")
  end,

  test_multiple_subscribers = function()
    local bus = eventbus.new()
    local count = 0
    bus.subscribe("tick", function() count = count + 1 end)
    bus.subscribe("tick", function() count = count + 1 end)
    bus.publish("tick", {})
    bus.next()
    assert(count == 2)
  end,

  test_no_subscribers_no_crash = function()
    local bus = eventbus.new()
    bus.publish("unhandled_event", { x=1 })
    local ok = bus.next()
    assert(ok)
  end,

  test_next_returns_false_on_empty = function()
    local bus = eventbus.new()
    local ok = bus.next()
    assert(ok == false)
  end,

  test_events_processed_in_order = function()
    local bus = eventbus.new()
    local order = {}
    bus.subscribe("ev", function(p) table.insert(order, p.n) end)
    bus.publish("ev", { n=1 })
    bus.publish("ev", { n=2 })
    bus.publish("ev", { n=3 })
    bus.next(); bus.next(); bus.next()
    assert(order[1]==1 and order[2]==2 and order[3]==3)
  end,

  test_subscriber_error_does_not_lose_event = function()
    local bus = eventbus.new()
    local errors = {}
    bus.on_error = function(ev, err) table.insert(errors, err) end
    local good_called = false
    bus.subscribe("ev", function() error("subscriber boom") end)
    bus.subscribe("ev", function() good_called = true end)
    bus.publish("ev", {})
    local ok, all_ok = bus.next()
    assert(ok == true)
    assert(all_ok == false)
    assert(good_called)               -- second subscriber still ran
    assert(#errors == 1)              -- error was reported
    assert(bus.next() == false)       -- event was removed (not stuck in queue)
  end,

  test_queue_size_after_processing = function()
    local bus = eventbus.new()
    bus.subscribe("x", function() end)
    bus.publish("x", {}); bus.publish("x", {}); bus.publish("x", {})
    assert(#bus.queue == 3)
    bus.next()
    assert(#bus.queue == 2)
    bus.next(); bus.next()
    assert(#bus.queue == 0)
  end,

  test_different_event_types_routed_correctly = function()
    local bus = eventbus.new()
    local a_count, b_count = 0, 0
    bus.subscribe("type_a", function() a_count = a_count + 1 end)
    bus.subscribe("type_b", function() b_count = b_count + 1 end)
    bus.publish("type_a", {}); bus.publish("type_b", {}); bus.publish("type_a", {})
    bus.next(); bus.next(); bus.next()
    assert(a_count == 2 and b_count == 1)
  end,

  test_publish_nil_payload_ok = function()
    local bus = eventbus.new()
    local received = "untouched"
    bus.subscribe("ev", function(p) received = p end)
    bus.publish("ev", nil)
    bus.next()
    assert(received == nil)
  end,
}
