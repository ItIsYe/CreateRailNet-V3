--[[
Purpose: The cargo ledger of the fleet: only proven quantities count, partial deliveries stay assignable, duplicate reports never make a second delivery, departure rules (Gesamtkonzept Kap. 10, 24.2; tests D-11 to D-14 of the concept's freight checks).
Public API: returns table of tests.
]]

local cargo = require("src.fleet.cargo_ledger")

local function order(extra)
  local o = { id = "FR-001", cargo_type = "item", unit = "stack", target_qty = 1000, source = "MINE", destination = "HUB", load_track = "L1", unload_track = "U1",
    train_class = "FREIGHT", min_load = 600, departure_rule = "MIN_PARTIAL", proof_mode = "AUTO_INVENTORY", deadline = 5000 }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

local function loaded(ref, qty, quality, extra)
  local e = { order_id = "FR-001", shipment_id = "S1", kind = "loaded", qty = qty, quality = quality or "AUTO_INVENTORY", ref = ref }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end

local function unloaded(ref, qty, quality, extra)
  local e = loaded(ref, qty, quality, extra); e.kind = "unloaded"; return e
end

return {
  test_the_example_of_the_concept_700_loaded_650_arrived = function()
    local l = cargo.new({})
    assert(l.create_order(order()))
    assert(l.report(loaded("inv-1", 700)))
    assert(l.report(unloaded("inv-2", 650)))
    local s = l.summary("FR-001")
    assert(s.delivered == 650 and s.open == 350 and s.in_transit_or_unresolved == 50, string.format("%d %d %d", s.delivered, s.open, s.in_transit_or_unresolved))
    assert(s.loaded == 700)
    local shipment = l.shipment("S1")
    assert(shipment.loaded_proven == 700 and shipment.unloaded_proven == 650 and shipment.unresolved == 50)
  end,

  test_the_unloaded_parts_and_the_unresolved_difference_do_not_fall_together_in_one_shipment_id = function()
    local l = cargo.new({})
    l.create_order(order())
    l.report(loaded("a", 700)); l.report(unloaded("b", 650))
    l.report(loaded("c", 300, nil, { shipment_id = "S2" }))
    assert(l.shipment("S1").unresolved == 50 and l.shipment("S2").unresolved == 300 and l.shipment("S2").unloaded_proven == 0)
    assert(l.summary("FR-001").in_transit_or_unresolved == 350)
    assert(l.shipments("FR-001")[1].shipment_id == "S1" and #l.shipments("FR-001") == 2)
  end,

  test_a_message_twice_never_makes_a_second_delivery = function()
    local l = cargo.new({})
    l.create_order(order())
    l.report(loaded("inv-1", 700))
    local ok, note = l.report(loaded("inv-1", 700))
    assert(ok == true and note == "duplicate")
    l.report(unloaded("inv-2", 650)); l.report(unloaded("inv-2", 650))
    assert(l.summary("FR-001").delivered == 650 and l.summary("FR-001").loaded == 700)
  end,

  test_time_and_arrival_are_no_proof_of_goods = function()
    local l = cargo.new({})
    l.create_order(order())
    for _, quality in ipairs({ "TIME", "ARRIVAL", "CREATE_ARRIVAL", "SCHEDULE_ACCEPTED", "", "GUESS" }) do
      local ok, err = l.report(loaded("x-" .. quality, 700, quality))
      assert(not ok and err:find("proof", 1, true), quality .. ": " .. tostring(err))
    end
    assert(l.summary("FR-001").loaded == 0)
    local ok = l.report(loaded("y", 700, nil, { qty = -5 }))
    assert(not ok, "negative amounts are no report")
    assert(not l.report(loaded("z", 0)))
    assert(not l.report(loaded("w", 700, nil, { order_id = "NOPE" })))
  end,

  test_a_manual_check_needs_the_name_of_the_person_who_is_allowed_to_do_it = function()
    local l = cargo.new({ may_check = function(person) return person == "tim" end })
    l.create_order(order({ proof_mode = "MANUAL_AUTH" }))
    local ok, err = l.report(loaded("m1", 700, "MANUAL_AUTH"))
    assert(not ok and err:find("person", 1, true), tostring(err))
    ok, err = l.report(loaded("m2", 700, "MANUAL_AUTH", { by = "mallory" }))
    assert(not ok and err:find("allowed", 1, true), tostring(err))
    assert(l.report(loaded("m3", 700, "MANUAL_AUTH", { by = "tim" })))
    assert(l.shipment("S1").evidence_refs[1].quality == "MANUAL_AUTH" and l.shipment("S1").evidence_refs[1].by == "tim")
  end,

  test_the_proof_mode_of_the_order_sets_the_lowest_quality_that_is_accepted = function()
    local l = cargo.new({})
    l.create_order(order({ proof_mode = "EXTERNAL_AUTH" }))
    assert(not l.report(loaded("a", 700, "MANUAL_AUTH", { by = "tim" })), "lower than asked")
    assert(l.report(loaded("b", 700, "EXTERNAL_AUTH")))
    assert(l.report(loaded("c", 10, "AUTO_INVENTORY", { shipment_id = "S9" })), "higher is fine")
  end,

  test_unloaded_goods_that_were_never_proven_loaded_are_delivered_but_flagged = function()
    local l = cargo.new({})
    l.create_order(order())
    l.report(unloaded("u1", 100))
    local s = l.summary("FR-001")
    assert(s.delivered == 100 and s.discrepancies == 1, "received is received, the missing loading proof is a difference to explain")
    assert(l.shipment("S1").unresolved == 0 and l.shipment("S1").excess == 100)
  end,

  test_the_departure_rules_full_partial_and_time = function()
    local l = cargo.new({})
    l.create_order(order({ id = "FULL", departure_rule = "FULL" }))
    l.create_order(order({ id = "PART", departure_rule = "MIN_PARTIAL", min_load = 600 }))
    l.create_order(order({ id = "TIME", departure_rule = "TIME", deadline = 100, allow_empty_run = false }))
    l.create_order(order({ id = "EMPTYOK", departure_rule = "TIME", deadline = 100, allow_empty_run = true }))
    local function load(id, qty) l.report({ order_id = id, shipment_id = id .. "-S", kind = "loaded", qty = qty, quality = "AUTO_INVENTORY", ref = id .. qty }) end
    load("FULL", 999); load("PART", 599); load("TIME", 0 + 1)
    assert(not l.may_depart("FULL", 0) and not l.may_depart("PART", 0))
    load("FULL", 1); load("PART", 1)
    -- the second report of one shipment adds up: 1000 and 600
    assert(l.may_depart("FULL", 0) and l.may_depart("PART", 0))
    local ok, why = l.may_depart("TIME", 50)
    assert(not ok and why:find("deadline", 1, true), tostring(why))
    assert(l.may_depart("TIME", 100) == true, "the deadline came and something is loaded")
    ok, why = l.may_depart("EMPTYOK", 100)
    assert(ok == true, "an empty run is allowed when the order says so")
    local l2 = cargo.new({})
    l2.create_order(order({ id = "T2", departure_rule = "TIME", deadline = 100, allow_empty_run = false }))
    ok, why = l2.may_depart("T2", 200)
    assert(not ok and why:find("empty", 1, true), "unknown or missing cargo is not booked as loaded: " .. tostring(why))
  end,

  test_the_rule_of_the_order_beats_the_default_of_the_line = function()
    assert(cargo.rule_for({ departure_rule = "FULL" }, { departure_rule = "TIME" }) == "FULL")
    assert(cargo.rule_for({}, { departure_rule = "TIME" }) == "TIME")
    assert(cargo.rule_for({}, {}) == "FULL", "without any rule the safe one: everything loaded")
  end,

  test_a_closed_order_takes_no_more_reports_and_snapshot_restore_keeps_everything = function()
    local l = cargo.new({})
    l.create_order(order())
    l.report(loaded("a", 700)); l.report(unloaded("b", 650))
    local copy = cargo.new({}); copy.restore(l.snapshot())
    assert(copy.summary("FR-001").delivered == 650)
    local ok, note = copy.report(unloaded("b", 650))
    assert(ok == true and note == "duplicate", "the restored ledger still knows the reports")
    assert(not copy.create_order(order()), "an order exists once")
    assert(copy.close("FR-001"))
    local ok2, err2 = copy.report(unloaded("c", 10))
    assert(not ok2 and err2:find("closed", 1, true), tostring(err2))
  end
}
