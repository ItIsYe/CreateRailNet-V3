--[[
Purpose: Finding the monitor and the modem of a computer: the named device, the old default name, the first device by type, and what
  happens when a named device is missing.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local monitors = require("src.adapter.monitors")
local peripherals = require("src.adapter.peripherals")
local cc_modem = require("src.adapter.cc_modem")
local validate = require("src.shared.validate")
local strict_cc = require("tests.harness.strict_cc")

-- a made-up computer: name -> type
local function backend(devices)
  local names = {}
  for name in pairs(devices) do names[#names + 1] = name end
  table.sort(names)
  return {
    getNames = function() return names end,
    getType = function(name) return devices[name] end,
    getMethods = function(name) return devices[name] and { "x" } or nil end,
    wrap = function(name) if devices[name] then return { name = name, type = devices[name] } end return nil end,
    find = function(kind) for _, name in ipairs(names) do if devices[name] == kind then return { name = name, type = kind } end end return nil end,
  }
end

local function wrapper(devices) return peripherals.new(backend(devices)) end

return {
  test_the_named_monitor_is_used = function()
    local found, note = monitors.resolve(wrapper({ monitor_0 = "monitor", monitor_1 = "monitor" }), "monitor_1")
    assert(found and found.name == "monitor_1" and note == nil)
  end,

  test_without_a_name_the_first_monitor_by_type_is_used_even_though_none_is_called_monitor = function()
    local found, note = monitors.resolve(wrapper({ top = "modem", monitor_3 = "monitor", monitor_1 = "monitor" }), nil)
    assert(found and found.name == "monitor_1", "sorted names: the same monitor on every start")
    assert(note == nil)
  end,

  test_a_monitor_on_a_side_is_found_by_type = function()
    local found = monitors.resolve(wrapper({ right = "monitor", back = "modem" }), nil)
    assert(found and found.name == "right")
  end,

  test_the_old_default_name_still_works = function()
    local found = monitors.resolve(wrapper({ monitor = "monitor", monitor_0 = "monitor" }), nil)
    assert(found and found.name == "monitor", "plans and tests written before auto detection")
  end,

  test_a_named_monitor_that_is_missing_falls_back_and_says_so = function()
    local found, note = monitors.resolve(wrapper({ monitor_0 = "monitor" }), "monitor_9")
    assert(found and found.name == "monitor_0")
    assert(note and note:find("monitor_9", 1, true), tostring(note))
  end,

  test_no_monitor_at_all_gives_nothing_and_a_reason = function()
    local found, note = monitors.resolve(wrapper({ top = "modem" }), nil)
    assert(found == nil and note and note:find("no monitor", 1, true), tostring(note))
    assert(monitors.resolve(nil, nil) == nil)
  end,

  test_a_named_modem_is_used_and_never_replaced_by_another = function()
    local api = backend({ modem_a = "modem", modem_b = "modem" })
    local named = cc_modem.new({ peripheral_api = api, modem_name = "modem_b", channel = 777 })
    assert(named.modem and named.modem.name == "modem_b")
    local missing = cc_modem.new({ peripheral_api = api, modem_name = "modem_z", channel = 777 })
    assert(missing.modem == nil, "a named modem that is gone must not be swapped for another network")
    local ok, err = missing:open(777)
    assert(ok == false and err == "modem unavailable")
    local unnamed = cc_modem.new({ peripheral_api = api, channel = 777 })
    assert(unnamed.modem and unnamed.modem.name == "modem_a", "without a name: the first one, as before")
  end,

  test_for_node_reads_the_modem_from_the_entry_of_that_computer = function()
    local api = backend({ modem_a = "modem", modem_b = "modem" })
    local cfg = { channel = 777, nodes = { { id = "SIG-1", role = "signal", modem = "modem_b" }, { id = "SIG-2", role = "signal" } } }
    assert(cc_modem.for_node(cfg, "SIG-1", { peripheral_api = api }).modem.name == "modem_b")
    assert(cc_modem.for_node(cfg, "SIG-2", { peripheral_api = api }).modem.name == "modem_a")
    assert(cc_modem.for_node(cfg, "SIG-9", { peripheral_api = api }).modem.name == "modem_a")
    assert(cc_modem.for_node(cfg, "SIG-1", { peripheral_api = api }).reply_channel == 777)
  end,

  -- the text scale: a bigger area of characters on a monitor of the same size (0.5 is the smallest text)
  test_a_valid_text_scale_is_a_multiple_of_a_half_between_a_half_and_five = function()
    for _, good in ipairs({ 0.5, 1, 1.5, 2, 3.5, 5 }) do assert(monitors.valid_scale(good), tostring(good)) end
    for _, bad in ipairs({ 0, 0.25, 0.75, 1.3, 2.25, 5.5, 6, -1, "1", "0.5", true, false }) do assert(not monitors.valid_scale(bad), tostring(bad)) end
    assert(not monitors.valid_scale(nil) and not monitors.valid_scale({}) and not monitors.valid_scale(0 / 0))
  end,

  test_resolve_sets_the_text_scale_of_the_monitor_it_finds = function()
    local monitor = strict_cc.monitor(51, 19)
    local api = strict_cc.peripheral({ monitor_0 = { type = "monitor", methods = { "write", "setTextScale" }, object = monitor } })
    local found, note = monitors.resolve(peripherals.new(api), "monitor_0", 0.5)
    assert(found == monitor and note == nil)
    assert(monitor.surface.scale == 0.5, "the scale was set")
    assert(#monitor.violations == 0)
    -- without a scale the monitor is left as it is
    local other = strict_cc.monitor(51, 19)
    monitors.resolve(peripherals.new(strict_cc.peripheral({ monitor_0 = { type = "monitor", methods = {}, object = other } })), "monitor_0")
    assert(other.surface.scale == nil)
  end,

  test_a_scale_that_is_not_valid_is_not_sent_to_the_monitor_and_is_said = function()
    local monitor = strict_cc.monitor(51, 19)
    local api = strict_cc.peripheral({ monitor_0 = { type = "monitor", methods = {}, object = monitor } })
    local found, note = monitors.resolve(peripherals.new(api), "monitor_0", 7)
    assert(found == monitor and monitor.surface.scale == nil and #monitor.violations == 0)
    assert(note and note:find("monitor_scale", 1, true), tostring(note))
  end,

  test_a_monitor_that_cannot_set_the_scale_or_fails_at_it_still_works = function()
    local bare = { write = function() end, name = "plain" }
    local found, note = monitors.resolve(wrapper({ monitor_0 = "monitor" }), "monitor_0", 0.5)
    assert(found and found.name == "monitor_0" and note and note:find("monitor_scale", 1, true), "no setTextScale: said, not raised: " .. tostring(note))
    local failing = { setTextScale = function() error("too big") end }
    local api = { getNames = function() return { "monitor_0" } end, getType = function() return "monitor" end, getMethods = function() return { "setTextScale" } end,
      wrap = function() return failing end, find = function() return failing end }
    local _, note2 = monitors.resolve(peripherals.new(api), "monitor_0", 0.5)
    assert(note2 and note2:find("monitor_scale", 1, true), tostring(note2))
    assert(bare.name == "plain")
  end,

  test_the_plan_checks_the_text_scale_of_a_monitor = function()
    local base = function(scale, top)
      return { v = 1, channel = 777, master_id = "M", blocks = {}, routes = {}, monitor_scale = top, nodes = { { id = "M", role = "master", monitor_scale = scale } } }
    end
    assert(validate.validate_config(base(0.5)))
    assert(validate.validate_config(base(nil, 1.5)))
    for _, bad in ipairs({ 0, 0.3, 0.75, 1.3, 6, "1" }) do
      local ok, errors = validate.validate_config(base(bad))
      assert(not ok and table.concat(errors, "\n"):find("nodes[1].monitor_scale", 1, true), tostring(bad))
    end
    local ok, errors = validate.validate_config(base(nil, 9))
    assert(not ok and table.concat(errors, "\n"):find("monitor_scale", 1, true))
  end,

  test_the_plan_checks_modem_and_monitor_fields = function()
    local base = function(node)
      return { v = 1, channel = 777, master_id = "M", blocks = {}, routes = {}, nodes = { { id = "M", role = "master", modem = node.modem, monitor = node.monitor } } }
    end
    assert(validate.validate_config(base({ modem = "top", monitor = "monitor_0" })))
    local ok, errors = validate.validate_config(base({ modem = "", monitor = 5 }))
    assert(not ok)
    local text = table.concat(errors, "\n")
    assert(text:find("nodes[1].modem", 1, true) and text:find("nodes[1].monitor", 1, true), text)
  end,
}
