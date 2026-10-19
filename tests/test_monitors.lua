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
