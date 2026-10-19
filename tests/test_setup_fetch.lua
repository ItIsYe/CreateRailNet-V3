--[[
Purpose: The setup wizard fetches the plan from the master for a station or depot computer: it offers it when the master knows the computer
  and the plan here has no platforms / tracks, writes it only after a yes (the old file stays as .prev), keeps the devices chosen on this
  computer, and says what went wrong when the master cannot help. The same flow runs as `scripts/setup.lua --fetch-plan` later.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_world = require("tests.harness.setup_world")
local plan_bus = require("tests.harness.plan_bus")
local plan_fetch = require("src.setup.plan_fetch")
local link = require("src.setup.link")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")
local setup_status = require("src.shared.setup_status")

local MODEM, MODEM2, STATION, MONITOR = setup_world.MODEM, { name = "modem_1", type = "modem", methods = { "open", "transmit", "isOpen" } }, setup_world.STATION, setup_world.MONITOR
local PLAN = netplan.PATH

-- answers by what the page asks: rules = { { "text in the last lines", "answer" }, ... }; the first match wins, everything else is Enter
local function responder(rules, log)
  return function(text)
    local lines = {}
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local tail = table.concat(lines, "\n", math.max(1, #lines - 5))
    if log then log[#log + 1] = tail end
    for _, rule in ipairs(rules or {}) do
      if tail:find(rule[1], 1, true) then return rule[2] end
    end
    return ""
  end
end

local function sentence(log, text)
  for _, tail in ipairs(log) do if tail:find(text, 1, true) then return true end end
  return false
end

-- the wizard on a station computer that talks to the real master over the simulated channel
local function station_world(extra)
  local o = extra or {}
  local b = plan_bus.new()
  local m = plan_bus.real_master(b, plan_bus.template("network.full.example.json"))
  local world = setup_world.new({ peripherals = o.peripherals or { MODEM, STATION, MONITOR }, files = o.files })
  local asked = { link = 0, fetch = 0 }
  local function wire(opts)
    opts.modem, opts.pull_event, opts.time, opts.now, opts.wait_s = b.client_modem, plan_bus.puller(b, m), b.time, b.time.now_s, 3
    return opts
  end
  world.link = function(opts) asked.link = asked.link + 1; return link.probe(wire(opts)) end
  world.fetch = function(opts) asked.fetch = asked.fetch + 1; return plan_fetch.fetch(wire(opts)) end
  return world, m, asked, b
end

local function plan_of(world) return assert(netplan.parse(world.fs.files[PLAN])) end

local function entry_of(cfg, id) return netplan.find_node(cfg, id) end

return {
  test_the_wizard_offers_the_plan_writes_it_after_a_yes_and_keeps_the_old_file = function()
    local world, m, asked = station_world()
    local log = {}
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "Den Plan jetzt vom Master holen?", "" } }, log))
    assert(result.ok, tostring(result.error))
    assert(sentence(log, "Den Plan jetzt vom Master holen?") and asked.fetch == 1)
    -- the plan of this computer is now the file of the master, byte for byte
    assert(world.fs.files[PLAN] == m.fs.files["configs/network.json"], "the master's file")
    assert(#entry_of(plan_of(world), "ST-B").platforms == 2)
    assert(world.fs.files[PLAN .. ".prev"] and not world.fs.files[PLAN .. ".prev"]:find("platforms", 1, true), "the short plan is kept as .prev")
    -- the doctor ran again: no warning about missing platforms any more, and the record says so
    local device
    for _, check in ipairs(result.report.checks) do if check.id == "device" then device = check end end
    assert(device and device.level == "ok" and device.title:find("2 Bahnsteig", 1, true), device and device.title)
    local status = setup_status.read(world.fs)
    assert(status and status.id == "ST-B" and status.role == "station")
    assert(world.rebooted == 1)
    local parsed = startup_template.parse(world.fs.files["startup.lua"])
    assert(parsed.role == "station" and parsed.id == "ST-B" and parsed.config == PLAN)
  end,

  test_a_no_to_the_offer_asks_nothing_and_leaves_the_short_plan = function()
    local world, _, asked = station_world()
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "Den Plan jetzt vom Master holen?", "n" } }))
    assert(result.ok and asked.fetch == 0)
    assert(entry_of(plan_of(world), "ST-B").platforms == nil)
    assert(world.fs.files[PLAN .. ".prev"] == nil)
  end,

  test_a_no_to_saving_changes_nothing = function()
    local world, _, asked = station_world()
    local result = world.run({ "--role", "station" }, responder({ { "Fassung bleibt", "n" }, { "[ST-1] >", "ST-B" } }))
    assert(result.ok and asked.fetch == 1)
    assert(entry_of(plan_of(world), "ST-B").platforms == nil, "still the short plan")
    assert(world.fs.files[PLAN .. ".prev"] == nil)
  end,

  test_the_devices_chosen_on_this_computer_stay_in_the_plan_that_is_fetched = function()
    local world = station_world({ peripherals = { MODEM, MODEM2, STATION, MONITOR } })
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "[1] > ", "" } }))
    assert(result.ok, tostring(result.error))
    local cfg = plan_of(world)
    local entry = entry_of(cfg, "ST-B")
    assert(#entry.platforms == 2, "the platforms of the master")
    assert(entry.modem == "top" or entry.modem == "modem_1", "the modem that was chosen here: " .. tostring(entry.modem))
    assert(#cfg.nodes > 5, "the rest of the master's plan is there")
  end,

  test_a_master_that_does_not_know_the_computer_gets_no_offer_but_the_doctor_says_what_to_do = function()
    local world, _, asked = station_world()
    local log = {}
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-NEU" } }, log))
    assert(result.ok)
    assert(asked.fetch == 0 and not sentence(log, "Den Plan jetzt vom Master holen?"), "the master has not accepted it: nothing to fetch")
    assert(world.text():find("--fetch-plan", 1, true), "the way is named")
  end,

  test_other_roles_are_not_offered_a_plan = function()
    local world, _, asked = station_world({ peripherals = { MODEM, setup_world.SIGNAL, MONITOR } })
    local log = {}
    local result = world.run({ "--role", "signal" }, responder({ { "[SIG-1] >", "SIG-1" } }, log))
    assert(result.ok and asked.fetch == 0 and not sentence(log, "vom Master holen"))
  end,

  test_when_the_master_cannot_help_the_player_is_told_and_the_setup_stays_done = function()
    for _, failure in ipairs({
      { ok = false, state = "no_answer", message = "Der Master antwortet nicht. TEST-A", marker = "TEST-A" },
      { ok = false, state = "refused", message = "Der Master kennt diesen Computer noch nicht. TEST-B", marker = "TEST-B" },
      { ok = false, state = "damaged", message = "Der Plan ist beschaedigt angekommen. TEST-C", marker = "TEST-C" },
    }) do
      local world = station_world()
      world.fetch = function() return failure end
      local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" } }))
      assert(result.ok and world.text():find(failure.marker, 1, true), failure.state)
      assert(entry_of(plan_of(world), "ST-B").platforms == nil and world.fs.files[PLAN .. ".prev"] == nil)
      assert(world.rebooted == 1)
    end
    -- a fetch that raises or answers nonsense is no reason to lose the setup either
    for _, broken in ipairs({ function() error("boom") end, function() return nil end, function() return "text" end, function() return {} end }) do
      local world = station_world()
      world.fetch = broken
      local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" } }))
      assert(result.ok and world.rebooted == 1 and entry_of(plan_of(world), "ST-B").platforms == nil)
    end
  end,

  test_a_plan_of_the_master_without_platforms_for_this_computer_is_not_written = function()
    local world = station_world()
    local plan = plan_bus.template("network.full.example.json")
    local cfg = netplan.parse(plan)
    world.fetch = function(opts)
      local copy = netplan.set_fields(cfg, "ST-B", {})
      for _, node in ipairs(copy.nodes) do if node.id == "ST-B" then node.platforms = {} end end
      return { ok = true, text = netplan.encode(copy), cfg = copy, entry = netplan.find_node(copy, "ST-B"), version = "00000000", size = 1, parts = 1 }
    end
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" } }))
    assert(result.ok and world.text():find("noch keine", 1, true) and world.text():find("--fetch-plan", 1, true))
    assert(entry_of(plan_of(world), "ST-B").platforms == nil and world.fs.files[PLAN .. ".prev"] == nil)
  end,

  -- scripts/setup.lua --fetch-plan ------------------------------------------------------------------------------------------

  test_fetch_plan_on_an_installed_computer_updates_the_plan_after_a_yes = function()
    -- the master's entry of this station names the monitor "monitor": this computer has one by that name, so nothing else is left to warn about
    local world, m = station_world({ peripherals = { MODEM, STATION, { name = "monitor", type = "monitor", methods = MONITOR.methods } } })
    local first = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "Den Plan jetzt vom Master holen?", "n" } }))
    assert(first.ok and entry_of(plan_of(world), "ST-B").platforms == nil)
    world.pages = { { lines = {} } }
    local log = {}
    local before = setup_status.read(world.fs)
    assert(before and before.warn and before.warn >= 1, "the record knows about the missing platforms")
    local result = world.run({ "--fetch-plan" }, responder({}, log))
    assert(result.ok and result.wrote == true and result.state == "written")
    local after = setup_status.read(world.fs)
    assert(after and after.state == "GEPRUEFT" and (after.warn or 0) == 0, "the record was written again: " .. tostring(after and after.state))
    assert(world.fs.files[PLAN] == m.fs.files["configs/network.json"])
    assert(world.fs.files[PLAN .. ".prev"], "the short plan stays as .prev")
    assert(world.text():find("Gespeichert", 1, true) and world.text():find("reboot", 1, true))
    -- again: nothing new
    world.pages = { { lines = {} } }
    local again = world.run({ "--fetch-plan" }, responder({}))
    assert(again.ok and again.state == "same" and again.wrote == false and world.text():find("schon genau diesen Plan", 1, true))
  end,

  test_the_text_scale_chosen_on_this_computer_survives_the_fetch = function()
    local world = station_world({ peripherals = { MODEM, STATION, { name = "monitor", type = "monitor", methods = MONITOR.methods } } })
    world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "Den Plan jetzt vom Master holen?", "n" } }))
    -- the operator gave this computer's monitor a text scale in its own plan; the plan of the master knows nothing of it
    world.fs.set(PLAN, netplan.encode(netplan.set_fields(plan_of(world), "ST-B", { monitor_scale = 0.5 })))
    world.pages = { { lines = {} } }
    local result = world.run({ "--fetch-plan" }, responder({}))
    assert(result.ok and result.wrote == true, tostring(result.state))
    local entry = entry_of(plan_of(world), "ST-B")
    assert(entry.monitor_scale == 0.5 and #entry.platforms == 2, "own scale kept, platforms from the master")
  end,

  test_fetch_plan_with_no_answers_to_the_question_changes_nothing = function()
    local world = station_world()
    world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "Den Plan jetzt vom Master holen?", "n" } }))
    local before = world.fs.files[PLAN]
    world.pages = { { lines = {} } }
    local result = world.run({ "--fetch-plan" }, responder({ { "[J/n]", "n" } }))
    assert(result.ok and result.state == "declined" and result.wrote == false)
    assert(world.fs.files[PLAN] == before and world.fs.files[PLAN .. ".prev"] == nil)
    -- input that ends is a no
    world.pages = { { lines = {} } }
    local ended = world.run({ "--fetch-plan" }, function() return nil end)
    assert(ended.wrote == false and world.fs.files[PLAN] == before)
  end,

  test_fetch_plan_only_for_station_and_depot_and_only_on_a_set_up_computer = function()
    local blank = station_world()
    local r1 = blank.run({ "--fetch-plan" }, responder({}))
    assert(r1.ok == false and r1.state == "setup" and blank.text():find("scripts/setup.lua", 1, true))
    local world = station_world({ peripherals = { MODEM, setup_world.SIGNAL, MONITOR } })
    world.run({ "--role", "signal" }, responder({ { "[SIG-1] >", "SIG-1" } }))
    world.pages = { { lines = {} } }
    local r2 = world.run({ "--fetch-plan" }, responder({}))
    assert(r2.ok == false and r2.state == "role" and world.text():find("Nur Bahnhof- und Depot", 1, true))
  end,

  test_a_depot_fetches_too = function()
    local world, m = station_world({ peripherals = { MODEM, MONITOR } })
    local result = world.run({ "--role", "depot" }, responder({ { "[DEPOT-1] >", "DEPOT-1" } }))
    assert(result.ok, tostring(result.error))
    assert(world.fs.files[PLAN] == m.fs.files["configs/network.json"] and #entry_of(plan_of(world), "DEPOT-1").tracks == 1)
  end,

  test_a_station_that_has_its_platforms_already_is_not_offered_a_plan = function()
    local world, m, asked = station_world({ files = {} })
    -- the plan of this computer is the master's file already (as if it had been fetched before)
    world.fs.set(PLAN, m.fs.files["configs/network.json"])
    local log = {}
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" }, { "[1] > ", "" } }, log))
    assert(result.ok, tostring(result.error))
    assert(asked.link == 1 and asked.fetch == 0 and not sentence(log, "vom Master holen"), "links " .. asked.link .. ", fetches " .. asked.fetch)
  end,

  test_without_a_fetch_function_the_offer_is_not_made = function()
    local world, _, asked = station_world()
    world.fetch = nil
    local log = {}
    local result = world.run({ "--role", "station" }, responder({ { "[ST-1] >", "ST-B" } }, log))
    assert(result.ok and asked.fetch == 0 and not sentence(log, "vom Master holen"))
    world.pages = { { lines = {} } }
    local r = world.run({ "--fetch-plan" }, responder({}))
    assert(r.ok == false and r.state == "unavailable")
  end,
}
