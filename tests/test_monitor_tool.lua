--[[
Purpose: The tool that binds monitors: a big number picks the screen, a second confirmation binds it, nothing is bound by itself, a damaged file blocks everything (Pruefplan H-01, H-14).
Public API: returns table of tests.
]]

local monitor_tool = require("src.setup.monitor_tool")
local monitor_registry = require("src.panel.monitor_registry")
local memfs = require("tests.harness.memfs")

local function world(names)
  local devices = {}
  for _, name in ipairs(names) do
    local d = { texts = {}, scale = nil }
    function d.setTextScale(scale) d.scale = scale end
    function d.clear() end
    function d.setCursorPos() end
    function d.write(text) d.texts[#d.texts + 1] = text end
    devices[name] = d
  end
  local api = {
    getNames = function() local out = {} for name in pairs(devices) do out[#out + 1] = name end table.sort(out) return out end,
    getType = function(name) return devices[name] and "monitor" or nil end,
    wrap = function(name) return devices[name] end,
  }
  local w = { devices = devices, api = api, fs = memfs.new(), said = {}, answers = {} }
  function w.run(argv)
    return monitor_tool.run(argv, { fs = w.fs, peripheral = api, id = "PANEL-1", say = function(t) w.said[#w.said + 1] = t end,
      ask = function(prompt) w.asked = prompt; return table.remove(w.answers, 1) end })
  end
  function w.text() return table.concat(w.said, "\n") end
  function w.registry() local r = monitor_registry.new({ fs = w.fs, peripheral = api, node_id = "PANEL-1" }); r.load(); return r end
  return w
end

return {
  test_a_big_number_on_every_free_monitor_and_the_pick_binds_that_one = function()
    local w = world({ "monitor_0", "monitor_1", "monitor_2" })
    w.answers = { "2", "j" }
    assert(w.run({ "bind", "LEIT-1", "trains", "1" }) == 0, w.text())
    for index, name in ipairs({ "monitor_0", "monitor_1", "monitor_2" }) do
      assert(w.devices[name].texts[1] == tostring(index) and w.devices[name].scale == 5, name .. " shows its number")
    end
    local record = w.registry().get("LEIT-1")
    assert(record and record.peripheral == "monitor_1" and record.start_view == "trains")
  end,

  test_a_wrong_answer_or_no_confirmation_binds_nothing = function()
    local w = world({ "monitor_0", "monitor_1" })
    w.answers = { "9" }
    assert(w.run({ "bind", "A" }) == 1 and #w.registry().list() == 0)
    w.answers = { "x" }
    assert(w.run({ "bind", "A" }) == 1)
    w.answers = { "1", "n" }
    assert(w.run({ "bind", "A" }) == 1 and #w.registry().list() == 0, w.text())
  end,

  test_one_free_monitor_still_has_to_be_confirmed = function()
    local w = world({ "monitor_0" })
    w.answers = { "n" }
    assert(w.run({ "bind", "A" }) == 1 and #w.registry().list() == 0)
    w.answers = { "j", "j" }
    assert(w.run({ "bind", "A" }) == 0 and w.registry().get("A").peripheral == "monitor_0")
  end,

  test_a_bound_id_is_not_bound_again_and_a_replacement_needs_the_same_questions = function()
    local w = world({ "monitor_0", "monitor_1" })
    w.answers = { "1", "j" }
    assert(w.run({ "bind", "A" }) == 0)
    assert(w.run({ "bind", "A" }) == 1 and w.text():find("replace", 1, true))
    -- monitor_0 is replaced by a new one called monitor_5
    w.devices.monitor_5 = w.devices.monitor_0; w.devices.monitor_0 = nil
    assert(w.run({ "check" }) == 1 and w.text():find("FEHLT: A", 1, true), "a vanished monitor is reported, not rebound")
    assert(w.registry().get("A").peripheral == "monitor_0")
    w.answers = { "1", "j" }
    -- two free monitors now (monitor_1, monitor_5): the number picks one
    assert(w.run({ "replace", "A" }) == 0)
    local record = w.registry().get("A")
    assert(record.peripheral ~= "monitor_0" and record.replaced_from == "monitor_0")
  end,

  test_unknown_views_and_unknown_commands_are_refused = function()
    local w = world({ "monitor_0" })
    assert(w.run({ "bind", "A", "nonsense" }) == 1 and w.text():find("Unbekannte Ansicht", 1, true))
    assert(w.run({ "frobnicate" }) == 1)
    assert(w.run({}) == 0 and w.text():find("bind <ID>", 1, true))
    assert(w.run({ "bind" }) == 1)
  end,

  test_groups_labels_scale_and_view_are_set_and_checked = function()
    local w = world({ "monitor_0", "monitor_1" })
    w.answers = { "1", "j" }; assert(w.run({ "bind", "A" }) == 0)
    w.answers = { "j", "j" }; assert(w.run({ "bind", "B" }) == 0)
    assert(w.run({ "group", "G1", "A", "B" }) == 0 and w.registry().group_of("A") == "G1")
    assert(w.run({ "group", "G2", "A", "X" }) == 1, "an unbound monitor is no member")
    assert(w.run({ "scale", "A", "2" }) == 0 and w.registry().get("A").scale == 2)
    assert(w.run({ "scale", "A", "7" }) == 1)
    assert(w.run({ "view", "A", "cargo" }) == 0 and w.registry().get("A").start_view == "cargo")
    assert(w.run({ "label", "A", "Leitstand" }) == 0 and w.registry().get("A").label == "Leitstand")
    assert(w.run({ "list" }) == 0 and w.text():find("Gruppe G1", 1, true))
    assert(w.run({ "ungroup", "G1" }) == 0 and w.registry().group_of("A") == nil)
    w.answers = { "j" }
    assert(w.run({ "unbind", "A" }) == 0 and w.registry().get("A") == nil)
  end,

  test_a_damaged_file_blocks_every_command = function()
    local w = world({ "monitor_0" })
    w.fs.set("state/panel_monitors.json", "{{{")
    w.answers = { "j", "j" }
    assert(w.run({ "bind", "A" }) == 1 and w.text():find("nicht lesbar", 1, true))
    assert(w.run({ "check" }) == 1)
  end
}
