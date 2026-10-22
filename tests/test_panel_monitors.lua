--[[
Purpose: Many monitors on one panel computer: discovered, identified by a big id, bound for good with the operator's confirmation, described by a name apart from the peripheral name, grouped by choice, never re-bound by themselves (Gesamtkonzept Kap. 11.1).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local monitor_registry = require("src.panel.monitor_registry")
local strict_cc = require("tests.harness.strict_cc")
local memfs = require("tests.harness.memfs")

local function world(names)
  local devices = { modem_0 = { type = "modem", methods = {}, object = {} } }
  local screens = {}
  for _, name in ipairs(names or {}) do
    local m = strict_cc.monitor(50, 19)
    screens[name] = m
    devices[name] = { type = "monitor", methods = { "write", "setCursorPos", "clear", "setTextScale", "getSize" }, object = m }
  end
  local fs = memfs.new()
  local api = strict_cc.peripheral(devices)
  local reg = monitor_registry.new({ fs = fs, peripheral = api, node_id = "PANEL-1" })
  reg.load()
  return { reg = reg, fs = fs, devices = devices, screens = screens, api = api }
end

local function confirm(extra)
  local m = { confirmed = true, label = "Leitstand Nord", scale = 1, start_view = "overview" }
  for k, v in pairs(extra or {}) do m[k] = v end
  return m
end

return {
  test_the_monitors_in_reach_are_found_and_unbound_ones_are_listed = function()
    local w = world({ "monitor_0", "monitor_1" })
    local found = w.reg.discover()
    assert(#found == 2 and found[1].name == "monitor_0" and found[2].name == "monitor_1")
    assert(#w.reg.verify().unbound == 2 and w.reg.verify().ok == false)
  end,

  test_a_candidate_shows_a_big_id_so_the_operator_can_tell_which_screen_it_is = function()
    local w = world({ "monitor_0", "monitor_1" })
    assert(w.reg.identify("monitor_1", "2"))
    local m = w.screens.monitor_1
    assert(m.surface.scale == 5, "the id is written as big as the monitor allows")
    assert(m.text():find("2", 1, true))
    assert(#w.screens.monitor_0.violations == 0 and not w.screens.monitor_0.text():find("2", 1, true), "the other screen is untouched")
    assert(not w.reg.identify("monitor_9", "9"))
  end,

  test_a_binding_needs_the_confirmation_and_keeps_the_label_apart_from_the_peripheral_name = function()
    local w = world({ "monitor_0" })
    local ok, err = w.reg.bind("M1", "monitor_0", { label = "x" })
    assert(not ok and err:find("confirm", 1, true))
    assert(w.reg.bind("M1", "monitor_0", confirm()))
    local rec = w.reg.get("M1")
    assert(rec.peripheral == "monitor_0" and rec.label == "Leitstand Nord" and rec.start_view == "overview" and rec.scale == 1)
    assert(w.reg.set_label("M1", "Leitstand Sued") and w.reg.get("M1").peripheral == "monitor_0" and w.reg.get("M1").label == "Leitstand Sued")
    local copy = monitor_registry.new({ fs = w.fs, peripheral = w.api, node_id = "PANEL-1" })
    assert(copy.load() == "ready" and copy.get("M1").label == "Leitstand Sued")
  end,

  test_a_monitor_and_a_peripheral_are_bound_once = function()
    local w = world({ "monitor_0", "monitor_1" })
    assert(w.reg.bind("M1", "monitor_0", confirm()))
    local ok, err = w.reg.bind("M2", "monitor_0", confirm())
    assert(not ok and err:find("already", 1, true))
    ok, err = w.reg.bind("M1", "monitor_1", confirm())
    assert(not ok and err:find("already", 1, true))
    assert(not w.reg.bind("M3", "monitor_9", confirm()), "a monitor that is not there cannot be bound")
  end,

  test_a_monitor_that_vanished_or_was_replaced_is_reported_and_nothing_is_rebound = function()
    local w = world({ "monitor_0", "monitor_1" })
    w.reg.bind("M1", "monitor_0", confirm()); w.reg.bind("M2", "monitor_1", confirm({ label = "zwei" }))
    w.devices.monitor_0 = nil
    w.devices.monitor_7 = { type = "monitor", methods = { "write" }, object = strict_cc.monitor(50, 19) }
    local report = w.reg.verify()
    assert(report.ok == false and report.missing.M1 == "monitor_0" and report.unbound[1] == "monitor_7")
    assert(w.reg.get("M1").peripheral == "monitor_0", "the binding is as it was")
    local mon, why = w.reg.resolve("M1")
    assert(mon == nil and why:find("missing", 1, true))
    assert(w.reg.resolve("M2") ~= nil)
    -- a replacement is a new confirmed binding
    assert(not w.reg.replace("M1", "monitor_7", { label = "neu" }))
    assert(w.reg.replace("M1", "monitor_7", confirm()))
    assert(w.reg.get("M1").peripheral == "monitor_7" and w.reg.get("M1").replaced_from == "monitor_0")
  end,

  test_scale_and_start_view_are_set_and_applied_when_the_monitor_is_opened = function()
    local w = world({ "monitor_0" })
    w.reg.bind("M1", "monitor_0", confirm({ scale = 2, start_view = "gleisbild" }))
    local mon, view = w.reg.open("M1")
    assert(mon and view == "gleisbild" and w.screens.monitor_0.surface.scale == 2)
    assert(not w.reg.set_scale("M1", 7) and not w.reg.set_scale("M1", 0.3) and w.reg.set_scale("M1", 0.5))
    assert(w.reg.set_start_view("M1", "fault_center") and w.reg.get("M1").start_view == "fault_center")
    assert(not w.reg.set_start_view("M1", "nonsense"))
  end,

  test_groups_share_a_selection_but_never_issue_a_command = function()
    local w = world({ "monitor_0", "monitor_1", "monitor_2" })
    for i = 0, 2 do w.reg.bind("M" .. i, "monitor_" .. i, confirm({ label = "m" .. i })) end
    assert(w.reg.define_group("G1", { "M0", "M1" }))
    assert(w.reg.group_of("M0") == "G1" and w.reg.group_of("M2") == nil)
    assert(w.reg.group_members("G1")[2] == "M1")
    assert(w.reg.set_selection("G1", "train", "TRAIN-1") and w.reg.get_selection("M1", "train") == "TRAIN-1" and w.reg.get_selection("M0", "train") == "TRAIN-1")
    assert(w.reg.get_selection("M2", "train") == nil, "a monitor that is not in the group stays independent")
    assert(not w.reg.set_selection("G1", "route_command", "R1"), "a group shares what is shown: train, station, section; never a command")
    assert(not w.reg.define_group("G2", { "M1", "M2" }), "a monitor is in one group")
    assert(not w.reg.define_group("G3", { "M9" }))
    assert(w.reg.dissolve_group("G1") and w.reg.group_of("M0") == nil)
  end,

  test_a_damaged_file_binds_nothing = function()
    local w = world({ "monitor_0" })
    w.reg.bind("M1", "monitor_0", confirm())
    w.fs.set("state/panel_monitors.json", "{ broken")
    w.fs.set("state/panel_monitors.json.prev", "broken too")
    local copy = monitor_registry.new({ fs = w.fs, peripheral = w.api, node_id = "PANEL-1" })
    local state, err = copy.load()
    assert(state == "corrupt" and err and copy.get("M1") == nil)
  end,

  test_the_list_is_in_a_fixed_order = function()
    local w = world({ "monitor_0", "monitor_1" })
    w.reg.bind("M2", "monitor_1", confirm({ label = "b" })); w.reg.bind("M1", "monitor_0", confirm({ label = "a" }))
    local list = w.reg.list()
    assert(list[1].logical_id == "M1" and list[2].logical_id == "M2")
  end
}
