--[[
Purpose: The operator's tool to bind the signals of a multi-signal node one by one: connect one, see it go red, confirm, give track and direction (Gesamtkonzept Kap. 6; tests B-05, B-06, F-04).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local signal_tool = require("src.setup.signal_tool")
local signal_bindings = require("src.shared.signal_bindings")
local strict_cc = require("tests.harness.strict_cc")
local memfs = require("tests.harness.memfs")

local function computer(opts)
  opts = opts or {}
  local c = { fs = memfs.new(), said = {}, asked = {}, answers = opts.answers or {}, reds = {}, devices = {} }
  c.devices.modem_0 = { type = "modem", methods = { "getNameLocal" }, object = {} }
  function c.add_signal(name, ptype)
    c.devices[name] = { type = ptype or "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = { setForcedRed = function(red) c.reds[#c.reds + 1] = name .. "=" .. tostring(red); return true end, isForcedRed = function() return true end } }
  end
  for _, name in ipairs(opts.present or {}) do c.add_signal(name) end
  c.api = strict_cc.peripheral(c.devices)
  c.config = { nodes = { { id = "SIGN-1", role = "signal", signals = opts.signals or { "S-A", "S-B" } } } }
  c.env = {
    fs = c.fs, peripheral = c.api, config = c.config, id = "SIGN-1",
    say = function(text) c.said[#c.said + 1] = text end,
    ask = function(prompt)
      c.asked[#c.asked + 1] = prompt
      if c.on_ask then c.on_ask(prompt) end
      return table.remove(c.answers, 1) or ""
    end,
    now = function() return 1000 end
  }
  function c.run(...) return signal_tool.run({ ... }, c.env) end
  function c.output() return table.concat(c.said, "\n") end
  function c.bindings()
    local b = signal_bindings.new({ fs = c.fs, node_id = "SIGN-1" }); b.load(); return b
  end
  return c
end

return {
  test_no_command_prints_the_help = function()
    local c = computer()
    assert(c.run() == 0 and c.output():find("bind <ID>", 1, true))
    assert(c.run("nonsense") == 1)
  end,

  test_binding_one_signal_connects_it_alone_shows_it_red_and_asks_for_the_data = function()
    local c = computer({ answers = { "", "j", "T3", "OST", "Einfahrt", "km 4" } })
    -- the operator connects the modem of the signal while the tool waits for Enter
    c.on_ask = function(prompt) if prompt:find("Enter", 1, true) and not c.devices.create_signal_4 then c.add_signal("create_signal_4") end end
    assert(c.run("bind", "S-A") == 0, c.output())
    local record = c.bindings().get("S-A")
    assert(record and record.peripheral == "create_signal_4" and record.track_id == "T3" and record.direction == "OST" and record.signal_type == "Einfahrt" and record.position == "km 4", c.output())
    assert(record.ptype == "Create_Signal")
    assert(c.reds[1] == "create_signal_4=true" and #c.reds == 1, "the tool only ever forces RED")
    assert(c.output():find("create_signal_4", 1, true))
  end,

  test_if_the_operator_does_not_see_the_signal_red_nothing_is_bound = function()
    local c = computer({ answers = { "", "n" } })
    c.on_ask = function(prompt) if prompt:find("Enter", 1, true) and not c.devices.create_signal_4 then c.add_signal("create_signal_4") end end
    assert(c.run("bind", "S-A") == 1)
    assert(c.bindings().get("S-A") == nil)
    assert(c.output():find("nicht gebunden", 1, true))
  end,

  test_two_new_signal_peripherals_at_once_are_refused_because_they_cannot_be_told_apart = function()
    local c = computer({ answers = { "" } })
    c.on_ask = function(prompt) if prompt:find("Enter", 1, true) then c.add_signal("create_signal_4"); c.add_signal("create_signal_5") end end
    assert(c.run("bind", "S-A") == 1)
    assert(c.bindings().get("S-A") == nil and #c.reds == 0, "no signal was touched")
    assert(c.output():find("genau ein", 1, true))
  end,

  test_no_new_peripheral_is_reported_and_nothing_changes = function()
    local c = computer({ answers = { "" } })
    assert(c.run("bind", "S-A") == 1)
    assert(c.output():find("kein neues", 1, true) and #c.reds == 0)
  end,

  test_a_signal_the_master_does_not_know_cannot_be_bound = function()
    local c = computer({ answers = {} })
    assert(c.run("bind", "S-NOPE") == 1)
    assert(c.output():find("kennt", 1, true))
  end,

  test_an_already_bound_signal_needs_replace_and_replace_binds_the_new_one_after_confirmation = function()
    local c = computer({ present = { "create_signal_0" }, answers = { "", "j", "T1", "OST", "Einfahrt", "km 1" } })
    local b = c.bindings()
    assert(b.bind("S-A", "create_signal_0", { confirmed = true, ptype = "Create_Signal" }))
    assert(c.run("bind", "S-A") == 1 and c.output():find("replace", 1, true), "an existing binding is not overwritten by bind")
    c.on_ask = function(prompt) if prompt:find("Enter", 1, true) and not c.devices.create_signal_7 then c.add_signal("create_signal_7") end end
    c.said = {}
    assert(c.run("replace", "S-A") == 0, c.output())
    local rec = c.bindings().get("S-A")
    assert(rec.peripheral == "create_signal_7" and rec.replaced_from == "create_signal_0")
  end,

  test_check_lists_what_is_missing_new_or_unknown_and_never_changes_anything = function()
    local c = computer({ present = { "create_signal_0", "create_signal_9" } })
    local b = c.bindings()
    b.bind("S-A", "create_signal_0", { confirmed = true, ptype = "Create_Signal" })
    b.bind("S-B", "create_signal_1", { confirmed = true, ptype = "Create_Signal" })
    b.bind("S-OLD", "create_signal_2", { confirmed = true, ptype = "Create_Signal" })
    assert(c.run("check") == 1)
    local out = c.output()
    assert(out:find("S-B", 1, true) and out:find("fehlt", 1, true), out)
    assert(out:find("create_signal_9", 1, true) and out:find("neu", 1, true), out)
    assert(out:find("S-OLD", 1, true), out)
    assert(c.bindings().get("S-B").peripheral == "create_signal_1", "nothing was rebound")
    assert(#c.reds == 0, "check touches no signal")
  end,

  test_check_is_clean_when_everything_is_as_bound = function()
    local c = computer({ present = { "create_signal_0", "create_signal_1" } })
    local b = c.bindings()
    b.bind("S-A", "create_signal_0", { confirmed = true, ptype = "Create_Signal" })
    b.bind("S-B", "create_signal_1", { confirmed = true, ptype = "Create_Signal" })
    assert(c.run("check") == 0 and c.output():find("in Ordnung", 1, true), c.output())
  end,

  test_unbind_asks_for_the_word_and_list_shows_the_table = function()
    local c = computer({ present = { "create_signal_0" }, answers = { "nein" } })
    local b = c.bindings()
    b.bind("S-A", "create_signal_0", { confirmed = true, ptype = "Create_Signal", track_id = "T1" })
    assert(c.run("list") == 0 and c.output():find("S-A", 1, true) and c.output():find("create_signal_0", 1, true) and c.output():find("T1", 1, true))
    assert(c.run("unbind", "S-A") == 1 and c.bindings().get("S-A"), "answer no: still bound")
    c.answers = { "JA" }
    assert(c.run("unbind", "S-A") == 0 and c.bindings().get("S-A") == nil)
  end
}
