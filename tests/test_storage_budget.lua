--[[
Purpose: The fixed 1 000 000 byte limit of a CC:Tweaked computer holds for the state too: the design load is below the caps, a journal and a snapshot stop at their caps, an update that does not fit is refused before anything is staged.
Public API: returns table of tests.
Notes: the program part of the budget (every role's minified files plus these caps within 1 000 000 bytes) is tests/test_installer_manifest.lua, test_a_role_fits_on_a_default_computer.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local storage_budget = require("src.shared.storage_budget")
local journal_module = require("src.shared.journal")
local updater = require("src.shared.updater")
local checksum = require("src.shared.checksum")
local dispatcher = require("src.master.dispatcher")
local net_signals = require("src.master.net_signals")
local json = require("src.shared.json")
local memfs = require("tests.harness.memfs")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

-- the load of the Pruefplan: 400 signals (200 blocks), 40 trains on independent routes of 5 blocks
local function design_load()
  local cfg = { signal_transport = "network", nodes = {}, blocks = {}, routes = {} }
  local names = {}
  for i = 1, 200 do
    cfg.blocks[i] = { id = "B" .. i, entry_signal = "SE" .. i, exit_signal = "SX" .. i, sensors = { "SEN-" .. i } }
    names[#names + 1] = "SE" .. i
    names[#names + 1] = "SX" .. i
  end
  for first = 1, #names, 8 do
    local list = {}
    for index = first, math.min(first + 7, #names) do list[#list + 1] = names[index] end
    cfg.nodes[#cfg.nodes + 1] = { id = "SIGN-" .. (#cfg.nodes + 1), role = "signal", signals = list }
  end
  for first = 1, 196, 5 do
    local ids = {}
    for index = first, first + 4 do ids[#ids + 1] = "B" .. index end
    cfg.routes[#cfg.routes + 1] = { id = "R" .. (#cfg.routes + 1), from = "A" .. first, to = "Z" .. first, blocks = ids }
  end
  local net = { send_reliable = function() return { id = "m" } end }
  local adapter = net_signals.new({ network = net, config = cfg, logger = quiet })
  adapter.install(net)
  local switches = { setPosition = function() return true end, getPosition = function() return true, "STRAIGHT" end }
  local d = dispatcher.new(cfg, { signals = adapter, switches = switches })
  for index, route in ipairs(cfg.routes) do d.reserve_route("T" .. index, route.id) end
  return cfg, d
end

return {
  test_the_design_load_is_below_the_caps = function()
    local cfg, d = design_load()
    local snapshot = #json.encode(d.snapshot({ replicated = true }))
    local whole = #json.encode(d.snapshot())
    local plan = #json.encode(cfg)
    assert(snapshot < storage_budget.SNAPSHOT_MAX_BYTES, "snapshot " .. snapshot)
    assert(whole < storage_budget.SNAPSHOT_MAX_BYTES, "recovery state " .. whole)
    assert(plan < storage_budget.PLAN_MAX_BYTES, "plan " .. plan)
  end,

  test_the_state_of_a_role_fits_next_to_its_program_budget = function()
    for _, role in ipairs({ "master", "panel", "fleet", "signal", "sensor", "train" }) do
      local sum = storage_budget.program_budget(role) + storage_budget.state_worst_case(role) + storage_budget.OTA_HEADROOM
      assert(sum == storage_budget.LIMIT, role .. ": " .. sum)
    end
  end,

  test_a_journal_without_a_snapshot_function_stops_at_twice_its_size = function()
    local fs = memfs.new()
    local j = journal_module.new("state/j.log", { fs = fs, max_bytes = 2000, max_entries = 100000 })
    j.open()
    local full_at
    for i = 1, 2000 do
      local seq, err = j.append("x", { n = i, pad = string.rep("p", 50) })
      if not seq then full_at = i; assert(tostring(err):find("full", 1, true), err); break end
    end
    assert(full_at, "the journal grew without limit")
    assert(#fs.files["state/j.log"] <= 2000 * storage_budget.HARD_FACTOR, #fs.files["state/j.log"])
  end,

  test_a_snapshot_above_the_cap_is_refused_and_nothing_is_written = function()
    local fs = memfs.new()
    local j = journal_module.new("state/j.log", { fs = fs, max_snapshot_bytes = 500 })
    j.open()
    local ok, err = j.snapshot({ big = string.rep("x", 2000) })
    assert(not ok and tostring(err):find("too large", 1, true), tostring(err))
    assert(fs.files["state/j.log.snap"] == nil)
    assert(j.snapshot({ small = "x" }))
  end,

  test_a_snapshot_taken_over_from_a_leader_is_capped_too = function()
    local fs = memfs.new()
    local j = journal_module.new("state/j.log", { fs = fs, max_snapshot_bytes = 500 })
    j.open()
    local ok, err = j.install_snapshot(5, { big = string.rep("x", 2000) }, 5)
    assert(not ok and tostring(err):find("too large", 1, true), tostring(err))
    assert(fs.files["state/j.log.snap"] == nil and j.last_seq() == 0)
  end,

  test_the_plan_service_refuses_a_plan_above_the_cap_by_default = function()
    local plan_service = require("src.master.plan_service")
    local fs = memfs.new()
    fs.set("configs/network.json", string.rep(" ", storage_budget.PLAN_MAX_BYTES + 1))
    local service = plan_service.new({ plan_path = "configs/network.json", fs = fs })
    local reply = service.part(1)
    assert(reply.ok == false and reply.reason:find("zu gross", 1, true), tostring(reply.reason))
  end,

  test_an_update_is_counted_with_the_new_and_the_old_copy_of_every_file = function()
    local fs = memfs.new()
    fs.capacity = 13000
    fs.set("src/shared/net.lua", string.rep("a", 1500))
    local events = {}
    local u = updater.new({ send_reliable = function(_, _, payload) events[#events + 1] = payload end }, "N1", nil, { fs = fs, sources = { "M" }, reboot = function() end, sleep = function() end })
    local function offer(size)
      local body = string.rep("b", size)
      return u.offer({ update_id = "u" .. size, version = "v2", files = { { path = "src/shared/net.lua", size = #body, adler = checksum.adler32(body) } } }, "M")
    end
    -- free 11500: 8000 reserve + 1500 old + the new copy
    assert(not offer(2100), "3600 + 8000 do not fit 11500")
    assert(offer(1900), "3400 + 8000 fit")
  end,

  test_a_single_message_update_is_checked_for_room_too = function()
    local fs = memfs.new()
    fs.capacity = 12000
    fs.set("src/shared/net.lua", string.rep("a", 1500))
    local u = updater.new({ send_reliable = function() end }, "N1", nil, { fs = fs, sources = { "M" }, reboot = function() end, sleep = function() end })
    local ok = u.apply({ update_id = "s1", version = "v2", files = { { path = "src/shared/net.lua", content = string.rep("b", 4000) } } }, "M")
    assert(not ok, "5500 + 8000 do not fit 10500")
    assert(fs.files["src/shared/net.lua.ota_new"] == nil)
  end,

  test_an_update_that_does_not_fit_is_refused_before_anything_is_staged = function()
    local fs = memfs.new()
    fs.capacity = 5000
    local old = string.rep("a", 1500)
    fs.set("src/shared/net.lua", old)
    local events = {}
    local network = { send_reliable = function(kind, dst, payload) events[#events + 1] = payload end }
    local u = updater.new(network, "N1", nil, { fs = fs, sources = { "M" }, reboot = function() end, sleep = function() end })
    local body = string.rep("b", 2500)
    local ok = u.offer({ update_id = "u1", version = "v2", files = { { path = "src/shared/net.lua", size = #body, adler = checksum.adler32(body) } } }, "M")
    assert(not ok, "2500 new + 1500 old + reserve do not fit 5000")
    assert(fs.files["src/shared/net.lua.ota_new"] == nil and fs.files["src/shared/net.lua"] == old)
    local refused
    for _, e in ipairs(events) do if e.type == "ota_result" and e.success == false then refused = e end end
    assert(refused, "the sender is told")
  end,

  test_an_update_that_fits_is_taken = function()
    local fs = memfs.new()
    fs.capacity = 100000
    fs.set("src/shared/net.lua", "return {}\n")
    local network = { send_reliable = function() end }
    local u = updater.new(network, "N1", nil, { fs = fs, sources = { "M" }, reboot = function() end, sleep = function() end })
    local body = "return { v = 2 }\n"
    assert(u.offer({ update_id = "u1", version = "v2", files = { { path = "src/shared/net.lua", size = #body, adler = checksum.adler32(body) } } }, "M"))
  end,
}
