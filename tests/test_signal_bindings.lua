--[[
Purpose: The local binding of logical signals to peripherals on a multi-signal node: confirmed by the operator, kept on disk, never changed by itself (Gesamtkonzept Kap. 6, tests B-05, B-06, F-04).
Public API: returns table of tests.
]]

local signal_bindings = require("src.shared.signal_bindings")
local memfs = require("tests.harness.memfs")

local function new(fs) return signal_bindings.new({ fs = fs or memfs.new(), node_id = "SIG-NODE-1" }) end

local function meta(extra)
  local m = { confirmed = true, track_id = "T1", direction = "EAST", signal_type = "entry_signal", position = "km 1.2" }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

return {
  test_a_binding_needs_the_confirmation_of_the_operator = function()
    local b = new(); assert(b.load() == "empty")
    local ok, err = b.bind("SIG-A", "create_signal_0", { track_id = "T1" })
    assert(not ok and err:find("confirm", 1, true), tostring(err))
    assert(b.resolve("SIG-A") == nil)
    assert(b.bind("SIG-A", "create_signal_0", meta()))
    assert(b.resolve("SIG-A") == "create_signal_0")
  end,

  test_a_binding_survives_a_restart_and_a_damaged_file_is_reported_not_guessed = function()
    local fs = memfs.new()
    local b = new(fs); b.load()
    assert(b.bind("SIG-A", "create_signal_0", meta({ ptype = "Create_Signal" })))
    assert(b.bind("SIG-B", "create_signal_1", meta()))
    local again = new(fs)
    assert(again.load() == "ready")
    assert(again.resolve("SIG-B") == "create_signal_1" and again.list()[1].logical_id == "SIG-A" and again.list()[1].ptype == "Create_Signal")
    fs.set("state/signal_bindings.json", "{ not json")
    fs.set("state/signal_bindings.json.prev", "also broken")
    local broken = new(fs)
    local state, err = broken.load()
    assert(state == "corrupt" and err, "the file is damaged: no signal is bound, nothing is guessed")
    assert(broken.resolve("SIG-A") == nil)
  end,

  test_a_logical_signal_and_a_peripheral_are_bound_once = function()
    local b = new(); b.load()
    assert(b.bind("SIG-A", "create_signal_0", meta()))
    local ok, err = b.bind("SIG-B", "create_signal_0", meta())
    assert(not ok and err:find("already", 1, true) and err:find("SIG-A", 1, true), tostring(err))
    local ok2, err2 = b.bind("SIG-A", "create_signal_1", meta())
    assert(not ok2 and err2:find("already", 1, true), "an existing binding is removed explicitly, not overwritten")
    assert(b.unbind("SIG-A") and b.resolve("SIG-A") == nil)
    assert(b.bind("SIG-A", "create_signal_1", meta()))
    assert(not b.bind("", "x", meta()) and not b.bind("SIG-C", "", meta()))
  end,

  test_a_binding_that_cannot_be_written_is_not_made = function()
    local fs = memfs.new()
    local b = new(fs); b.load()
    fs.fail.open = "state/signal_bindings.json.tmp"
    local ok, err = b.bind("SIG-A", "create_signal_0", meta())
    assert(not ok and err, "the write failed")
    assert(b.resolve("SIG-A") == nil, "so the signal is not bound in memory either")
  end,

  test_a_missing_peripheral_a_new_one_and_a_changed_type_are_reported_and_nothing_is_rebound = function()
    local b = new(); b.load()
    assert(b.bind("SIG-A", "create_signal_0", meta({ ptype = "Create_Signal" })))
    assert(b.bind("SIG-B", "create_signal_1", meta({ ptype = "Create_Signal" })))
    assert(b.bind("SIG-C", "create_signal_2", meta({ ptype = "Create_Signal" })))
    -- the modem was moved: _0 is gone, a new name appeared, _2 is now something else
    local report = b.verify({ create_signal_1 = "Create_Signal", create_signal_2 = "monitor", create_signal_7 = "Create_Signal", modem_0 = "modem" })
    assert(report.ok == false)
    assert(report.missing["SIG-A"] == "create_signal_0")
    assert(report.type_changed["SIG-C"].expected == "Create_Signal" and report.type_changed["SIG-C"].found == "monitor")
    assert(#report.unbound == 1 and report.unbound[1] == "create_signal_7", "a new signal peripheral waits for a confirmed binding; the modem is no signal")
    assert(b.resolve("SIG-A") == "create_signal_0", "and the binding is exactly as it was")
    assert(b.is_usable("SIG-B", { create_signal_1 = "Create_Signal" }) == true)
    local usable, why = b.is_usable("SIG-A", { create_signal_1 = "Create_Signal" })
    assert(usable == false and why:find("missing", 1, true), tostring(why))
    local usable2, why2 = b.is_usable("SIG-C", { create_signal_2 = "monitor" })
    assert(usable2 == false and why2:find("type", 1, true), tostring(why2))
  end,

  test_everything_is_in_order_when_the_hardware_is_as_it_was = function()
    local b = new(); b.load()
    b.bind("SIG-A", "create_signal_0", meta({ ptype = "Create_Signal" }))
    local report = b.verify({ create_signal_0 = "Create_Signal", modem_0 = "modem" })
    assert(report.ok == true and next(report.missing) == nil and #report.unbound == 0)
  end,

  test_the_binding_is_compared_with_the_topology_of_the_master = function()
    local b = new(); b.load()
    b.bind("SIG-A", "create_signal_0", meta())
    b.bind("SIG-OLD", "create_signal_1", meta())
    local diff = b.compare_topology({ "SIG-A", "SIG-B" })
    assert(#diff.unbound == 1 and diff.unbound[1] == "SIG-B", "the master expects SIG-B here, nothing is bound")
    assert(#diff.unknown == 1 and diff.unknown[1] == "SIG-OLD", "bound, but the master does not know it: never used")
    assert(diff.ok == false)
    assert(b.compare_topology({ "SIG-A", "SIG-OLD" }).ok == true)
  end,

  test_the_replacement_of_a_peripheral_is_a_new_confirmed_binding_and_the_old_one_is_gone = function()
    local b = new(); b.load()
    b.bind("SIG-A", "create_signal_0", meta({ ptype = "Create_Signal" }))
    local ok, err = b.replace("SIG-A", "create_signal_9", { track_id = "T1" })
    assert(not ok and err:find("confirm", 1, true), "also a replacement needs the confirmation")
    assert(b.resolve("SIG-A") == "create_signal_0", "and nothing changed")
    assert(b.replace("SIG-A", "create_signal_9", meta({ ptype = "Create_Signal" })))
    assert(b.resolve("SIG-A") == "create_signal_9")
    assert(b.bind("SIG-X", "create_signal_0", meta()), "the old peripheral name is free again")
    assert(b.get("SIG-A").replaced_from == "create_signal_0", "the history is visible")
  end,

  test_replacing_a_signal_that_is_not_bound_is_refused = function()
    local b = new(); b.load()
    local ok, err = b.replace("SIG-Z", "create_signal_9", meta())
    assert(not ok and err:find("not bound", 1, true), tostring(err))
    assert(b.resolve("SIG-Z") == nil and #b.list() == 0)
  end,

  test_the_signals_are_listed_in_a_fixed_order_with_their_meta = function()
    local b = new(); b.load()
    b.bind("SIG-B", "create_signal_1", meta({ track_id = "T2" }))
    b.bind("SIG-A", "create_signal_0", meta({ track_id = "T1", direction = "WEST" }))
    local list = b.list()
    assert(list[1].logical_id == "SIG-A" and list[2].logical_id == "SIG-B")
    assert(list[1].direction == "WEST" and list[1].track_id == "T1" and list[1].signal_type == "entry_signal" and list[1].position == "km 1.2")
    assert(type(list[1].confirmed_at) == "number")
  end
}
