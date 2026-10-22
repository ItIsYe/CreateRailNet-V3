--[[
Purpose: The six priority classes of the orders, FIFO inside a class, a documented anti-starvation, manual is no priority (Gesamtkonzept Kap. 8.3; test D-09).
Public API: returns table of tests.
]]

local priority = require("src.fleet.priority")

local clock = { t = 0 }
local function new(opts)
  clock.t = 0
  opts = opts or {}
  opts.now = function() return clock.t end
  return priority.new(opts)
end

local KINDS = { "REPLACEMENT_PASSENGER", "SCHEDULED_PASSENGER", "REPLACEMENT_FREIGHT", "SCHEDULED_FREIGHT", "EXTRA_PASSENGER", "EXTRA_FREIGHT" }

local function order(id, kind, extra)
  local o = { id = id, kind = kind }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

return {
  test_the_six_classes_come_out_in_the_order_of_the_concept = function()
    local q = new()
    for i = #KINDS, 1, -1 do assert(q.push(order("O" .. i, KINDS[i]))) end
    for i = 1, #KINDS do
      local o = q.next()
      assert(o.id == "O" .. i, "expected O" .. i .. " got " .. tostring(o and o.id))
      q.remove(o.id)
    end
    assert(q.next() == nil and q.size() == 0)
  end,

  test_inside_a_class_the_first_come_is_the_first_served = function()
    local q = new()
    for _, id in ipairs({ "A", "B", "C" }) do q.push(order(id, "SCHEDULED_PASSENGER")); clock.t = clock.t + 1 end
    assert(q.next().id == "A")
    q.remove("A")
    assert(q.next().id == "B")
  end,

  test_manual_is_not_a_higher_priority = function()
    local q = new()
    q.push(order("AUTO", "SCHEDULED_PASSENGER"))
    q.push(order("MANUAL", "EXTRA_FREIGHT", { manual = true }))
    assert(q.next().id == "AUTO")
    q.remove("AUTO")
    assert(q.next().id == "MANUAL")
    local o = q.get("MANUAL")
    assert(o.rank == 6, "rank stays that of the class")
  end,

  test_an_unknown_kind_or_a_duplicate_id_is_refused = function()
    local q = new()
    local ok, err = q.push(order("X", "VIP"))
    assert(not ok and err:find("kind", 1, true), tostring(err))
    assert(q.push(order("A", "SCHEDULED_FREIGHT")))
    local ok2, err2 = q.push(order("A", "SCHEDULED_FREIGHT"))
    assert(not ok2 and err2:find("already", 1, true), "an order exists once")
    assert(not q.push({ kind = "SCHEDULED_FREIGHT" }) and not q.push(nil))
  end,

  test_what_cannot_start_yet_is_skipped_and_waits_in_a_safe_state = function()
    local q = new()
    q.push(order("BIG", "REPLACEMENT_PASSENGER", { need = "D9" }))
    q.push(order("SMALL", "EXTRA_FREIGHT", { need = "D1" }))
    local blocked = { D9 = true }
    local picked = q.next(function(o) return not blocked[o.need] end)
    assert(picked.id == "SMALL", "the free resource goes on; priority does not lift a hardware limit")
    assert(q.get("BIG") ~= nil, "the blocked order is still there")
    blocked.D9 = nil
    assert(q.next(function(o) return not blocked[o.need] end).id == "BIG")
  end,

  test_a_long_waiting_order_rises_but_only_a_little_and_never_above_the_replacement_classes = function()
    local q = new({ aging_s = 100, max_promotion = 2 })
    q.push(order("OLD-EXTRA", "EXTRA_FREIGHT"))          -- rank 6
    clock.t = 1000
    q.push(order("NEW-SCHED-FREIGHT", "SCHEDULED_FREIGHT")) -- rank 4
    assert(q.get("OLD-EXTRA").effective == 4, "after ten steps still only two ranks up: " .. q.get("OLD-EXTRA").effective)
    assert(q.next().id == "NEW-SCHED-FREIGHT", "equal effective rank: the better class first (the aged order has only caught up)")
    q.remove("NEW-SCHED-FREIGHT")
    assert(q.next().id == "OLD-EXTRA")
    q.push(order("REPL", "REPLACEMENT_PASSENGER"))
    assert(q.next().id == "REPL")
  end,

  test_aging_never_lifts_an_order_above_the_first_class_and_a_tie_goes_to_the_better_class = function()
    local q = new({ aging_s = 100, max_promotion = 2 })
    q.push(order("OLD-SCHED", "SCHEDULED_PASSENGER"))     -- rank 2
    clock.t = 500
    q.push(order("NEW-REPL", "REPLACEMENT_PASSENGER"))    -- rank 1
    assert(q.get("OLD-SCHED").effective == 1, "two steps up from 2 stop at 1, not at 0: " .. q.get("OLD-SCHED").effective)
    assert(q.next().id == "NEW-REPL", "equal effective rank: the replacement class first, although the other one is older")
  end,

  test_without_waiting_nothing_is_promoted_and_a_zero_promotion_switches_it_off = function()
    local q = new({ aging_s = 100, max_promotion = 0 })
    q.push(order("E", "EXTRA_FREIGHT"))
    clock.t = 99999
    assert(q.get("E").effective == 6)
    local q2 = new({ aging_s = 100 })
    q2.push(order("E", "EXTRA_FREIGHT"))
    clock.t = 50
    assert(q2.get("E").effective == 6)
    clock.t = 150
    assert(q2.get("E").effective == 5)
  end,

  test_snapshot_and_restore_keep_the_order_of_arrival = function()
    local q = new()
    q.push(order("A", "SCHEDULED_PASSENGER")); q.push(order("B", "SCHEDULED_PASSENGER"))
    local copy = priority.new({ now = function() return clock.t end })
    copy.restore(q.snapshot())
    assert(copy.next().id == "A")
    copy.push(order("C", "SCHEDULED_PASSENGER"))
    copy.remove("A"); copy.remove("B")
    assert(copy.next().id == "C" and copy.size() == 1)
    assert(not copy.push(order("C", "SCHEDULED_PASSENGER")))
  end
}
