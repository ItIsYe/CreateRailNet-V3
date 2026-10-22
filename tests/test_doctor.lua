--[[
Purpose: The doctor and the record of its result: every check on made-up computers (healthy, broken, half set up), the German texts, the
  record file (crn_status.lua) with its field by field check, and how the wizard uses both.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local memfs = require("tests.harness.memfs")
local setup_world = require("tests.harness.setup_world")
local prng = require("tests.harness.prng")
local doctor = require("src.setup.doctor")
local netplan = require("src.setup.netplan")
local setup_status = require("src.shared.setup_status")
local keystore = require("src.shared.keystore")
local startup_template = require("src.shared.startup_template")
local wizard = require("src.setup.wizard")

local MODEM, SIGNAL, OBSERVER, STATION, MONITOR = setup_world.MODEM, setup_world.SIGNAL, setup_world.OBSERVER, setup_world.STATION, setup_world.MONITOR
local MODEM2 = { name = "modem_1", type = "modem", methods = { "open", "transmit", "isOpen" } }
local MONITOR2 = { name = "monitor_1", type = "monitor", methods = { "write", "setCursorPos", "clear" } }

-- Enter n times, then the given answers
local function enters(n, extra)
  local list = {}
  for i = 1, n do list[i] = "" end
  for _, value in ipairs(extra or {}) do list[#list + 1] = value end
  return list
end

local function peripheral_api(list)
  return {
    getNames = function() local names = {}; for _, p in ipairs(list) do names[#names + 1] = p.name end; return names end,
    getType = function(name) for _, p in ipairs(list) do if p.name == name then return p.type end end end,
    getMethods = function(name) for _, p in ipairs(list) do if p.name == name then return p.methods end end end,
    call = function(name, method)
      for _, p in ipairs(list) do
        if p.name == name and method == "isWireless" and p.wireless ~= nil then return p.wireless end
      end
      error("no such method", 0)
    end,
  }
end

-- a computer: role, id, the entry in the plan (fields), more plan content, devices; the installer has been on it
local function computer(spec)
  local fs = memfs.new()
  fs.set("crn_version.txt", spec.version or "main-test0000")
  if spec.startup ~= false then
    fs.set("startup.lua", spec.startup or startup_template.render({ role = spec.role, id = spec.id, config = netplan.PATH }))
  end
  if spec.plan ~= false then
    local entry = { id = spec.id, role = spec.role }
    for key, value in pairs(spec.entry or {}) do entry[key] = value end
    local cfg = spec.cfg or netplan.short_plan(spec.role, entry, 777, spec.master_id or "MASTER-1")
    fs.set(netplan.PATH, spec.plan or netplan.encode(cfg))
  end
  for path, body in pairs(spec.files or {}) do fs.set(path, body) end
  return { fs = fs, peripheral = peripheral_api(spec.devices or { MODEM }) }
end

local function run(spec)
  local c = computer(spec)
  return doctor.run({ fs = c.fs, peripheral = c.peripheral, probe = spec.probe }), c
end

local function level(report, id)
  for _, check in ipairs(report.checks) do if check.id == id then return check.level, check end end
  return nil
end

local function healthy_signal() return { role = "signal", id = "SIG-1", entry = { adapter = "peripheral", peripheral = "Create_Signal_0" }, devices = { MODEM, SIGNAL } } end

return {
  -- the checks ---------------------------------------------------------------------------------------------------------

  test_a_healthy_signal_computer_is_ready_without_a_single_hint = function()
    local report = run(healthy_signal())
    assert(report.ready and report.fails == 0 and report.warns == 0, doctor.summary(report))
    for _, id in ipairs({ "install", "startup", "plan", "identity", "modem", "device", "version" }) do
      assert(level(report, id) == "ok", id .. " should be ok: " .. tostring(level(report, id)))
    end
    assert(doctor.summary(report):find("Alles in Ordnung", 1, true))
  end,

  test_without_startup_lua_nothing_else_about_the_plan_can_be_judged = function()
    local spec = healthy_signal()
    spec.startup = false
    local report = run(spec)
    assert(not report.ready and level(report, "startup") == "fail")
    assert(level(report, "plan") == nil and level(report, "identity") == nil, "no plan path without startup.lua")
    local other = healthy_signal()
    other.startup = "print('hand written')"
    local report2 = run(other)
    assert(level(report2, "startup") == "fail")
  end,

  test_an_unfinished_installation_is_red = function()
    local spec = healthy_signal()
    spec.files = { ["crn_install_journal.lua"] = "return {}" }
    local report = run(spec)
    assert(level(report, "install") == "fail" and select(2, level(report, "install")).fix:find("installer --resume", 1, true))
  end,

  test_a_missing_or_broken_plan_is_red_and_says_how_to_look = function()
    local spec = healthy_signal()
    spec.plan = false
    assert(level(run(spec), "plan") == "fail")
    spec.plan = "{ nope"
    assert(level(run(spec), "plan") == "fail")
    spec.plan = '{"v":1,"channel":0,"master_id":"MASTER-1","nodes":[{"id":"MASTER-1","role":"master"},{"id":"SIG-1","role":"signal"}],"blocks":[],"routes":[]}'
    local report = run(spec)
    local lvl, check = level(report, "plan")
    assert(lvl == "fail" and check.title:find("1 Fehler", 1, true))
    assert(check.fix:find("scripts/setup.lua --check", 1, true) and check.fix:find("ganze Zahl groesser 0", 1, true), "the first error comes in German: " .. check.fix)
  end,

  test_the_entry_of_this_computer_must_be_in_the_plan_with_the_same_role = function()
    local missing = healthy_signal()
    missing.entry = nil
    missing.cfg = netplan.short_plan("master", { id = "MASTER-1", role = "master" }, 777, "MASTER-1")
    assert(level(run(missing), "identity") == "fail")
    local wrong = healthy_signal()
    wrong.cfg = netplan.short_plan("sensor", { id = "SIG-1", role = "sensor", adapter = "redstone", side = "left" }, 777, "MASTER-1")
    local lvl, check = level(run(wrong), "identity")
    assert(lvl == "fail" and check.title:find("sensor", 1, true))
    -- a master whose plan names another master
    local master = { role = "master", id = "MASTER-2", devices = { MODEM, MONITOR }, cfg = netplan.short_plan("master", { id = "MASTER-1", role = "master" }, 777, "MASTER-1") }
    master.cfg.nodes[2] = { id = "MASTER-2", role = "master" }
    local report = run(master)
    assert(level(report, "identity") == "fail" and select(2, level(report, "identity")).title:find("Master%-ID"))
  end,

  test_the_modem_is_red_when_missing_or_named_and_gone_amber_when_ambiguous = function()
    local none = healthy_signal()
    none.devices = { SIGNAL }
    assert(level(run(none), "modem") == "fail")
    local one = healthy_signal()
    assert(level(run(one), "modem") == "ok")
    local two = healthy_signal()
    two.devices = { MODEM, MODEM2, SIGNAL }
    local lvl, check = level(run(two), "modem")
    assert(lvl == "warn" and check.fix:find("modem_1", 1, true) and check.fix:find("top", 1, true))
    local bound = healthy_signal()
    bound.devices = { MODEM, MODEM2, SIGNAL }
    bound.entry.modem = "modem_1"
    assert(level(run(bound), "modem") == "ok")
    local gone = healthy_signal()
    gone.entry.modem = "modem_9"
    assert(level(run(gone), "modem") == "fail")
  end,

  test_the_devices_of_a_signal_or_sensor_are_found_by_name_and_kind = function()
    local missing = healthy_signal()
    missing.devices = { MODEM }
    local lvl, check = level(run(missing), "device")
    assert(lvl == "fail" and check.title:find("Create_Signal_0 nicht gefunden", 1, true))
    local wrong = healthy_signal()
    wrong.entry.peripheral = "Create_TrainObserver_0"
    wrong.devices = { MODEM, OBSERVER }
    assert(level(run(wrong), "device") == "warn", "an observer is no signal")
    local sensor = { role = "sensor", id = "SEN-1", entry = { adapter = "peripheral", peripheral = "Create_TrainObserver_0" }, devices = { MODEM, OBSERVER } }
    assert(level(run(sensor), "device") == "ok")
    local redstone = { role = "signal", id = "SIG-1", entry = { adapter = "redstone", side = "left" } }
    assert(level(run(redstone), "device") == "ok")
    redstone.entry.side = "above"
    assert(level(run(redstone), "device") == "fail")
    local by_id = { role = "signal", id = "Create_Signal_0", entry = { adapter = "peripheral" }, devices = { MODEM, SIGNAL } }
    assert(level(run(by_id), "device") == "ok", "an entry without a device name uses its id, like the adapters do")
  end,

  test_a_switch_needs_redstone_and_a_valid_side = function()
    local ok = { role = "switch", id = "SW-1", entry = { adapter = "redstone", side = "front", active_position = "DIVERGING" } }
    assert(level(run(ok), "device") == "ok")
    ok.entry.adapter = "peripheral"
    assert(level(run(ok), "device") == "fail")
  end,

  test_station_depot_train_and_master_say_what_the_plan_still_lacks = function()
    local station = { role = "station", id = "ST-1", entry = { station_type = "mixed", create_station_name = "A" }, devices = { MODEM, MONITOR } }
    local lvl, check = level(run(station), "device")
    assert(lvl == "warn" and check.title:find("Bahnsteige", 1, true))
    station.entry.platforms = { { id = "P1", kind = "passenger" } }
    assert(level(run(station), "device") == "ok" or level(run(station), "plan") == "fail", "platforms present")
    local depot = { role = "depot", id = "D-1", entry = { depot_type = "mixed" }, devices = { MODEM, MONITOR } }
    assert(level(run(depot), "device") == "warn")
    local train = { role = "train", id = "T-1", entry = {}, devices = { MODEM, MONITOR } }
    assert(level(run(train), "device") == "warn", "no Create station entered")
    train.entry.create_station = "Create_Station_0"
    assert(level(run(train), "device") == "fail", "named but not attached")
    train.devices = { MODEM, MONITOR, STATION }
    assert(level(run(train), "device") == "ok")
    local master = { role = "master", id = "MASTER-1", devices = { MODEM, MONITOR } }
    local lvl_master, master_check = level(run(master), "device")
    assert(lvl_master == "warn" and master_check.title:find("Bloecke", 1, true), "an empty plan cannot run a train yet")
  end,

  -- the pages are built for 51 x 19 characters; a smaller monitor is said, with the way to more room
  test_a_monitor_that_is_too_small_for_the_pages_is_a_hint_with_the_text_scale_as_the_way_out = function()
    local function size_api(width, height)
      local api = peripheral_api({ MODEM, MONITOR })
      api.wrap = function(name) if name == "monitor_0" then return { getSize = function() return width, height end } end end
      return api
    end
    local function monitor_check(role, entry, width, height)
      local c = computer({ role = role, id = role == "master" and "MASTER-1" or "PANEL-1", entry = entry, devices = { MODEM, MONITOR } })
      c.peripheral = size_api(width, height)
      local report = doctor.run({ fs = c.fs, peripheral = c.peripheral })
      for _, check in ipairs(report.checks) do if check.id == "monitor" then return check end end
    end
    local small = monitor_check("master", nil, 29, 19)
    assert(small.level == "warn" and small.title:find("29 x 19", 1, true) and small.fix:find("monitor_scale", 1, true) and small.fix:find("0.5", 1, true), small.title)
    assert(monitor_check("panel", nil, 51, 12).level == "warn", "too low is too small too")
    assert(monitor_check("master", nil, 58, 24).level == "ok" and monitor_check("master", nil, 51, 19).level == "ok")
    -- a plan that asks for a scale has taken care of it
    local scaled = monitor_check("master", { monitor_scale = 0.5 }, 29, 19)
    assert(scaled.level == "ok" and scaled.title:find("0.5", 1, true), scaled.title)
    -- other roles draw small displays; and an API that cannot say the size says nothing
    assert(monitor_check("station", nil, 29, 19) == nil or monitor_check("station", nil, 29, 19).level == "ok")
    local c = computer({ role = "master", id = "MASTER-1", devices = { MODEM, MONITOR } })
    local report = doctor.run({ fs = c.fs, peripheral = c.peripheral })
    for _, check in ipairs(report.checks) do if check.id == "monitor" then assert(check.level == "ok") end end
    -- a size that is nonsense is not believed
    assert(monitor_check("master", nil, "x", 19).level == "ok")
  end,

  test_the_monitor_is_red_for_a_panel_and_amber_for_the_others = function()
    local panel = { role = "panel", id = "PANEL-1", entry = { display_name = "P" }, devices = { MODEM } }
    assert(level(run(panel), "monitor") == "fail")
    local master = { role = "master", id = "MASTER-1", devices = { MODEM } }
    assert(level(run(master), "monitor") == "warn")
    panel.devices = { MODEM, MONITOR }
    assert(level(run(panel), "monitor") == "ok")
    panel.devices = { MODEM, MONITOR, MONITOR2 }
    assert(level(run(panel), "monitor") == "warn", "two monitors and none chosen")
    panel.entry.monitor = "monitor_1"
    assert(level(run(panel), "monitor") == "ok")
    panel.entry.monitor = "monitor_7"
    assert(level(run(panel), "monitor") == "fail")
    local signal = healthy_signal()
    assert(level(run(signal), "monitor") == nil, "a signal computer has no screen")
  end,

  test_free_space_and_the_file_state_are_looked_at = function()
    local spec = healthy_signal()
    local c = computer(spec)
    local used = 0
    for _, body in pairs(c.fs.files) do used = used + #body end
    c.fs.capacity = used + 20000
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space") == "warn")
    c.fs.capacity = used + 3000
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space") == "fail")
    c.fs.capacity = used + 500000
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space") == "ok")
    c.fs.capacity = nil
    c.fs.delete("crn_version.txt")
    local report = doctor.run({ fs = c.fs, peripheral = c.peripheral })
    assert(level(report, "version") == "warn")
    assert(level(report, "space") == "ok" or level(report, "space") == nil, "no limit: nothing to say")
  end,

  test_a_cable_modem_next_to_an_ender_modem_is_no_guess = function()
    local master = { role = "master", id = "MASTER-1", devices = { setup_world.WIRED_MODEM, setup_world.ENDER_MODEM, MONITOR } }
    local c = computer(master)
    local report = doctor.run({ fs = c.fs, peripheral = c.peripheral })
    local lvl, check = level(report, "modem")
    assert(lvl == "ok" and check.title:find("right", 1, true) and check.title:find("Funk", 1, true), tostring(check and check.title))
    assert((check.hint or check.fix or ""):find("back (Kabel)", 1, true), "the cable modem is named as such")
  end,

  test_two_radio_modems_or_modems_that_do_not_say_what_they_are_stay_a_guess = function()
    local two = { role = "master", id = "MASTER-1", devices = { setup_world.ENDER_MODEM, { name = "left", type = "modem", methods = { "open", "isWireless" }, wireless = true }, MONITOR } }
    local c = computer(two)
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "modem") == "warn")
    local unknown = { role = "master", id = "MASTER-1", devices = { MODEM, MODEM2, MONITOR } }
    local u = computer(unknown)
    assert(level(doctor.run({ fs = u.fs, peripheral = u.peripheral }), "modem") == "warn")
  end,

  test_a_single_cable_modem_is_said_to_be_one = function()
    local c = computer({ role = "signal", id = "SIG-1", devices = { setup_world.WIRED_MODEM, SIGNAL } })
    local lvl, check = level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "modem")
    assert(lvl == "ok" and check.title:find("Kabel", 1, true), tostring(check and check.title))
  end,

  test_nothing_asks_for_a_bigger_computer_but_a_short_update_room_is_said = function()
    local master = { role = "master", id = "MASTER-1", devices = { MODEM, MONITOR } }
    local c = computer(master)
    c.fs.capacity = 1000000
    local report = doctor.run({ fs = c.fs, peripheral = c.peripheral })
    assert(level(report, "space_limit") == nil, "the limit of 1 MB is fixed: no advice to raise it")
    for _, check in ipairs(report.checks or {}) do
      local text = (check.title or "") .. (check.fix or "") .. (check.hint or "")
      assert(not text:find("computer_space_limit", 1, true), check.id)
    end
    -- room for the files and the state, but not for an update
    c.fs.set("filler.bin", string.rep("x", 1000000 - 500 - c.fs.used() - 20000 + 500))
    local lvl = level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space_ota")
    assert(lvl == "warn", tostring(lvl))
    -- the setup files (the doctor itself is one) leave the computer when the tool is done: their bytes count as free
    c.fs.set("src/setup/wizard.lua", string.rep("w", 90000))
    c.fs.files["filler.bin"] = nil
    c.fs.set("filler.bin", string.rep("x", 1000000 - c.fs.used() - 30000))
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space_ota") == "warn", "without the record the wizard counts as program")
    c.fs.set("crn_install.lua", 'return {\n  bundle = true,\n  bundle_files = {\n    "src/setup/wizard.lua",\n  },\n  files = {},\n}\n')
    assert(level(doctor.run({ fs = c.fs, peripheral = c.peripheral }), "space_ota") == nil, "with the record the 90 KB are free after the tool")
  end,

  test_a_startup_without_the_recovery_is_called_out = function()
    local spec = healthy_signal()
    spec.startup = 'local CRN_ROLE = "signal"\nlocal CRN_ID = "SIG-1"\nlocal CRN_CONFIG = "configs/network.json"\n'
    assert(level(run(spec), "recovery") == "warn")
  end,

  test_what_the_master_said_to_the_probe_becomes_a_check = function()
    local function with(state)
      local spec = healthy_signal()
      spec.probe = state and { state = state } or nil
      return run(spec)
    end
    assert(level(with("known"), "link") == "ok")
    assert(level(with("old_master"), "link") == "ok")
    assert(level(with("pending"), "link") == "warn")
    assert(level(with("conflict"), "link") == "fail")
    assert(level(with("no_answer"), "link") == "warn")
    assert(level(with(nil), "link") == nil, "no probe, no statement about the master")
    local master = { role = "master", id = "MASTER-1", devices = { MODEM, MONITOR }, probe = { state = "known" } }
    assert(level(run(master), "link") == nil, "the master does not ask itself")
  end,

  -- texts ---------------------------------------------------------------------------------------------------------------

  test_lines_and_fixes_fit_the_screen_and_tag_every_level = function()
    local spec = { role = "station", id = "ST-1", entry = { station_type = "mixed", create_station_name = "A" }, devices = { SIGNAL }, probe = { state = "no_answer" } }
    local report = run(spec)
    assert(report.fails >= 1 and report.warns >= 1)
    for _, width in ipairs({ 50, 30 }) do
      for _, line in ipairs(doctor.lines(report, width)) do assert(#line.text <= width, line.text) end
      for _, line in ipairs(doctor.fix_lines(report, width)) do assert(#line.text <= width, line.text) end
    end
    local text = {}
    for _, line in ipairs(doctor.lines(report, 50)) do text[#text + 1] = line.text end
    local joined = table.concat(text, "\n")
    assert(joined:find("[ OK ] ", 1, true) and joined:find("[WARN] ", 1, true) and joined:find("[FEHL] ", 1, true))
    local fixes = doctor.fix_lines(report, 50)
    assert(#fixes > 0)
    for _, line in ipairs(fixes) do assert(not line.text:find("%[ OK %]"), "nothing to fix about what is fine") end
    assert(doctor.summary(report):find("Fehler", 1, true) and doctor.summary(report):find("Hinweis", 1, true))
  end,

  -- the record -----------------------------------------------------------------------------------------------------------

  test_the_status_record_is_checked_field_by_field = function()
    local status = { state = "GEPRUEFT", role = "signal", id = "SIG-1", config = "configs/network.json", version = "main-abc", at = 1700000000, fail = 0, warn = 2 }
    local text = setup_status.render(status)
    local back = setup_status.parse(text)
    assert(back and back.state == "GEPRUEFT" and back.id == "SIG-1" and back.at == 1700000000 and back.warn == 2 and back.fail == 0)
    assert(setup_status.parse("") == nil and setup_status.parse(nil) == nil and setup_status.parse("return 5") == nil)
    assert(setup_status.parse('return { state = "FREIGEGEBEN" }') == nil, "only the states of this file")
    assert(setup_status.parse('return { state = "GEPRUEFT", id = 5 }') == nil, "a field of the wrong type")
    assert(setup_status.parse('return { state = "GEPRUEFT", at = -1 }') == nil)
    assert(setup_status.parse('return { state = "GEPRUEFT", id = "' .. string.rep("x", 300) .. '" }') == nil, "oversized field")
    assert(setup_status.parse("return { state = 'GEPRUEFT' }" .. string.rep(" ", 5000)) == nil, "oversized file")
    assert(setup_status.parse('return { state = "GEPRUEFT", extra = "ignored" }').extra == nil, "unknown fields are dropped")
  end,

  test_the_status_record_runs_without_any_globals = function()
    local leaked = false
    _G.crn_status_probe = function() leaked = true end
    local text = 'crn_status_probe(); return { state = "GEPRUEFT" }'
    assert(setup_status.parse(text) == nil and leaked == false, "the text cannot reach the globals of the computer")
    _G.crn_status_probe = nil
    assert(setup_status.parse('os.exit(); return { state = "GEPRUEFT" }') == nil)
  end,

  test_the_status_is_written_safely_and_read_back = function()
    local fs = memfs.new()
    assert(setup_status.read(fs) == nil)
    assert(setup_status.write(fs, { state = "KONFIGURIERT", role = "master", id = "M" }))
    assert(setup_status.read(fs).state == "KONFIGURIERT")
    assert(setup_status.write(fs, { state = "GEPRUEFT", role = "master", id = "M" }))
    assert(setup_status.read(fs).state == "GEPRUEFT" and fs.files["crn_status.lua.prev"], "the old record stays as .prev")
    local ok, err = setup_status.write(fs, { state = "FREIGEGEBEN" })
    assert(ok == false and err:find("unknown state", 1, true))
    fs.set("crn_status.lua", "garbage ((")
    assert(setup_status.read(fs) == nil, "a damaged record reads as none")
  end,

  test_the_status_of_a_report_follows_the_result = function()
    local report = run(healthy_signal())
    local status = doctor.status(report, { version = "main-abc", now = 1700000123 })
    assert(status.state == "GEPRUEFT" and status.role == "signal" and status.id == "SIG-1" and status.at == 1700000123 and status.fail == 0)
    local broken = healthy_signal()
    broken.devices = { SIGNAL }
    local open = doctor.status(run(broken), { now = 5 })
    assert(open.state == "PRUEFUNG_OFFEN" and open.fail >= 1)
  end,

  -- the wizard ------------------------------------------------------------------------------------------------------------

  test_a_clean_setup_records_gepruft_and_restarts_on_enter = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR } })
    local result = world.run({ "--role", "master" }, { "", "", "", "", "" })
    assert(result.ok and world.rebooted == 1)
    assert(result.report.ready and result.report.fails == 0)
    local status = setup_status.read(world.fs)
    assert(status and status.state == "GEPRUEFT" and status.role == "master" and status.id == "MASTER-1" and status.version == "main-test0000", "recorded")
    assert(world.text():find("Pruefung: Alles in Ordnung", 1, true))
  end,

  test_a_red_check_is_shown_on_two_pages_recorded_and_does_not_restart_on_enter = function()
    local world = setup_world.new({ peripherals = { MODEM } })
    -- a signal with a Create device chosen by hand that is not there: plan, channel, master, id, how=Create, name, summary, then the doctor
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "1", "Create_Signal_9", "", "", "", "" })
    assert(result.ok and result.report.fails >= 1 and world.rebooted == 0, "Enter does not restart a computer the doctor finds red")
    local status = setup_status.read(world.fs)
    assert(status.state == "PRUEFUNG_OFFEN" and status.fail >= 1)
    local text = world.text()
    assert(text:find("[FEHL] ", 1, true) and text:find("Create_Signal_9 nicht gefunden", 1, true))
    assert(text:find("Was zu tun ist", 1, true) or text:find("was zu tun ist", 1, true))
    assert(world.check_screen() == nil, tostring(world.check_screen()))
    assert(world.unused == 0)
  end,

  test_hints_alone_do_not_stop_the_restart_when_nothing_has_to_be_carried_over = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR } })
    -- a master with an empty plan: the doctor notes that no train can run yet (amber), Enter still restarts
    local result = world.run({ "--role", "master" }, { "2", "", "", "", "", "", "" })
    assert(result.ok and result.report.fails == 0 and result.report.warns >= 1)
    assert(world.rebooted == 1)
    assert(setup_status.read(world.fs).state == "GEPRUEFT")
  end,

  test_the_doctor_command_looks_and_only_records_its_result = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR, SIGNAL }, files = {
      ["startup.lua"] = startup_template.render({ role = "signal", id = "SIG-1", config = netplan.PATH }),
      [netplan.PATH] = netplan.encode(netplan.short_plan("signal", { id = "SIG-1", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_9" }, 777, "MASTER-1")),
    } })
    local before = world.fs.snapshot()
    local result = world.run({ "--doctor" }, {})
    assert(result.ok == false and result.report.fails >= 1)
    local after = world.fs.snapshot()
    for path, body in pairs(before) do assert(after[path] == body, path .. " must not change") end
    local added = {}
    for path in pairs(after) do if before[path] == nil then added[#added + 1] = path end end
    assert(#added == 1 and added[1] == "crn_status.lua", table.concat(added, ","))
    local text = world.text()
    assert(text:find("Pruefung dieses Computers", 1, true) and text:find("Was zu tun ist", 1, true) and text:find("Create_Signal_9", 1, true))
    assert(world.check_screen(true) == nil, tostring(world.check_screen(true)))
    assert(wizard.parse_args({ "--doctor" }).doctor == true)
  end,

  test_the_wizard_asks_the_master_and_a_known_computer_has_nothing_to_carry_over = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local asked = {}
    world.link = function(opts) asked[#asked + 1] = opts; return { state = "known" } end
    local result = world.run({ "--role", "signal" }, enters(7))
    assert(result.ok and world.rebooted == 1, "the master knows it: nothing to copy, Enter restarts")
    assert(#asked == 1 and asked[1].id == "SIG-1" and asked[1].role == "signal" and asked[1].master_id == "MASTER-1" and asked[1].channel == 777)
    assert(asked[1].entry.peripheral == "Create_Signal_0" and asked[1].setup.state == "KONFIGURIERT")
    local text = world.text()
    assert(text:find("Der Master kennt diesen Computer schon", 1, true) and not text:find("Trage diese Zeile", 1, true))
    assert(text:find("Master antwortet und kennt SIG-1", 1, true) == nil, "all green: no list of checks")
    assert(world.check_screen() == nil, tostring(world.check_screen()))
  end,

  test_a_master_that_has_not_decided_yet_is_told_to_be_asked_and_the_line_stays_as_a_fallback = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    world.link = function() return { state = "pending" } end
    -- the doctor has an amber point (master does not know it yet): two pages, then the restart question
    local result = world.run({ "--role", "signal" }, enters(8, { "j" }))
    assert(result.ok and result.report.fails == 0 and result.report.warns >= 1)
    local text = world.text()
    assert(text:find("Master kennt SIG-1 noch nicht", 1, true))
    assert(text:find("Am Master bestaetigen", 1, true) and text:find('"id": "SIG-1"', 1, true))
    assert(world.rebooted == 1)
    assert(world.check_screen() == nil, tostring(world.check_screen()))
  end,

  test_no_answer_from_the_master_is_an_amber_hint_not_a_stop = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    world.link = function() return { state = "no_answer" } end
    local result = world.run({ "--role", "signal" }, enters(8, { "j" }))
    assert(result.ok and result.report.fails == 0)
    assert(world.text():find("Master antwortet nicht", 1, true))
    assert(setup_status.read(world.fs).state == "GEPRUEFT", "amber does not turn the record red")
  end,

  test_the_master_itself_asks_nobody = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR } })
    local asked = 0
    world.link = function() asked = asked + 1; return { state = "known" } end
    local result = world.run({ "--role", "master" }, { "", "", "", "", "" })
    assert(result.ok and asked == 0)
  end,

  test_the_doctor_command_asks_the_master_too = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR, SIGNAL }, files = {
      ["startup.lua"] = startup_template.render({ role = "signal", id = "SIG-1", config = netplan.PATH }),
      [netplan.PATH] = netplan.encode(netplan.short_plan("signal", { id = "SIG-1", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" }, 777, "MASTER-1")),
    } })
    local asked = 0
    world.link = function() asked = asked + 1; return { state = "known" } end
    local result = world.run({ "--doctor" }, {})
    assert(result.ok and asked == 1 and result.report.ctx.link == "known")
    assert(world.text():find("Master antwortet und kennt SIG-1", 1, true))
  end,

  -- whatever the disk holds, the doctor answers -----------------------------------------------------------------------------

  test_random_disks_never_make_the_doctor_fail = function()
    local pieces = {
      "", "{", "}", "[]", "null", "5", '"x"', '{"v":1}', '{"v":1,"channel":777,"master_id":"M","nodes":[],"blocks":[],"routes":[]}',
      '{"v":1,"channel":777,"master_id":"SIG-1","nodes":[{"id":"SIG-1","role":"signal"}],"blocks":1,"routes":"x"}',
      '{"v":1,"channel":777,"master_id":"M","nodes":[{"id":"M","role":"master"},{"id":"SIG-1","role":"signal","modem":5,"peripheral":7}],"blocks":[],"routes":[]}',
      'local CRN_ROLE = "signal"', startup_template.render({ role = "signal", id = "SIG-1", config = netplan.PATH }),
      startup_template.render({ role = "station", id = "ST-1", config = "elsewhere.json" }),
    }
    local worlds = 0
    for seed = 1, 300 do
      local rng = prng.new(seed)
      local fs = memfs.new()
      if rng.chance(0.8) then fs.set("startup.lua", rng.pick(pieces)) end
      if rng.chance(0.8) then fs.set(netplan.PATH, rng.pick(pieces)) end
      if rng.chance(0.3) then fs.set("elsewhere.json", rng.pick(pieces)) end
      if rng.chance(0.3) then fs.set("crn_install_journal.lua", "return {}") end
      if rng.chance(0.5) then fs.set("crn_version.txt", rng.pick({ "", "main-1", "  ", "\n" })) end
      local devices = {}
      for _, device in ipairs({ MODEM, MODEM2, SIGNAL, OBSERVER, STATION, MONITOR, MONITOR2 }) do if rng.chance(0.5) then devices[#devices + 1] = device end end
      local ok, report = pcall(doctor.run, { fs = fs, peripheral = peripheral_api(devices), probe = rng.chance(0.3) and { state = rng.pick({ "known", "pending", "conflict", "no_answer", "old_master", "?" }) } or nil })
      assert(ok, "seed " .. seed .. ": " .. tostring(report))
      local fails, warns = 0, 0
      for _, check in ipairs(report.checks) do
        assert(check.level == "ok" or check.level == "warn" or check.level == "fail", "seed " .. seed)
        assert(type(check.title) == "string" and check.title ~= "", "seed " .. seed)
        if check.level ~= "ok" then assert(type(check.fix) == "string" and check.fix ~= "", "seed " .. seed .. ": " .. check.id .. " has no fix") end
        if check.level == "fail" then fails = fails + 1 elseif check.level == "warn" then warns = warns + 1 end
      end
      assert(fails == report.fails and warns == report.warns and report.ready == (fails == 0), "seed " .. seed)
      local lines_ok, err = pcall(function() doctor.lines(report, 50); doctor.fix_lines(report, 50); doctor.summary(report); doctor.status(report, {}) end)
      assert(lines_ok, "seed " .. seed .. ": " .. tostring(err))
      worlds = worlds + 1
    end
    assert(worlds == 300)
  end,

  -- the keys of the message authentication ---------------------------------------------------------------------------

  test_without_auth_mode_there_is_no_key_check_at_all = function()
    local report = run(healthy_signal())
    assert(level(report, "keys") == nil)
    local spec = healthy_signal()
    local cfg = netplan.short_plan(spec.role, { id = spec.id, role = spec.role, adapter = "peripheral", peripheral = "Create_Signal_0" }, 777, "MASTER-1")
    cfg.auth_mode = "off"
    spec.cfg = cfg
    assert(level(run(spec), "keys") == nil)
  end,

  test_a_computer_in_enforce_mode_needs_its_key = function()
    local function with_mode(mode, files)
      local spec = healthy_signal()
      local cfg = netplan.short_plan(spec.role, { id = spec.id, role = spec.role, adapter = "peripheral", peripheral = "Create_Signal_0" }, 777, "MASTER-1")
      cfg.auth_mode = mode
      spec.cfg = cfg
      spec.files = files
      return run(spec)
    end
    local lvl, check = level(with_mode("enforce"), "keys")
    assert(lvl == "fail" and check.fix:find("keys.lua issue SIG-1", 1, true), "no key file in enforce mode must fail")
    assert(level(with_mode("monitor"), "keys") == "warn")
    local trust = { rev = 0, nodes = {} }
    local record = keystore.issue(trust, string.rep("ab", 32), "SIG-1", "signal", 1)
    local files = { [keystore.NODE_PATH] = keystore.node_body(record) }
    assert(level(with_mode("enforce", files), "keys") == "ok")
    lvl, check = level(with_mode("monitor", files), "keys")
    assert(lvl == "warn" and check.fix:find("enforce", 1, true), "monitor mode says when to switch to enforce")
    local other = keystore.issue(trust, string.rep("ab", 32), "SIG-9", "signal", 1)
    lvl, check = level(with_mode("enforce", { [keystore.NODE_PATH] = keystore.node_body(other) }), "keys")
    assert(lvl == "fail" and check.title:find("SIG-9", 1, true), "the key of another computer is a failure")
  end,

  test_a_master_in_enforce_mode_needs_master_key_and_a_readable_list = function()
    local function master_with(files)
      local cfg = netplan.short_plan("master", { id = "MASTER-1", role = "master" }, 777, "MASTER-1")
      cfg.auth_mode = "enforce"
      return run({ role = "master", id = "MASTER-1", cfg = cfg, files = files, devices = { MODEM, MONITOR } })
    end
    local lvl, check = level(master_with({}), "keys")
    assert(lvl == "fail" and check.fix:find("keys.lua init", 1, true))
    local files = { [keystore.MASTER_PATH] = '{"v":1,"key":"' .. string.rep("ab", 32) .. '"}' }
    assert(level(master_with(files), "keys") == "ok", "a missing list is an empty list")
    files[keystore.TRUST_PATH] = "garbage"
    lvl, check = level(master_with(files), "keys")
    assert(lvl == "fail" and check.title:find("beschaedigt", 1, true))
  end,
}
