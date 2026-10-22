--[[
Purpose: The first-time setup of a computer: every role through the wizard with a scripted player, plans that are kept / copied / generated /
  used in place, input checks, back and help, nothing written before the summary, and screens that fit a 51 x 19 computer.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_world = require("tests.harness.setup_world")
local terminal = require("src.setup.terminal")
local hardware = require("src.setup.hardware")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")
local wizard = require("src.setup.wizard")
local install_plan = require("install.plan")
local prng = require("tests.harness.prng")

local MODEM, SIGNAL, OBSERVER, STATION, MONITOR = setup_world.MODEM, setup_world.SIGNAL, setup_world.OBSERVER, setup_world.STATION, setup_world.MONITOR

local MODEM2 = { name = "modem_1", type = "modem", methods = { "open", "transmit", "isOpen" } }
local MONITOR2 = { name = "monitor_1", type = "monitor", methods = { "write", "setCursorPos", "clear" } }

local function enters(n, extra)
  local list = {}
  for i = 1, n do list[i] = "" end
  for i, value in ipairs(extra or {}) do list[#list + 1] = value end
  return list
end

-- every answer is consumed, the screens fit, the computer restarts, startup.lua says what was chosen
local function assert_done(world, result, role, id, config, lenient)
  assert(result.ok, "wizard did not finish: " .. tostring(result.error) .. "\n" .. world.last_page_text())
  assert(world.unused == 0, world.unused .. " answers were not asked for")
  -- pages where the player typed wrong answers on purpose grow with every error line
  if not lenient then assert(world.check_screen() == nil, tostring(world.check_screen())) end
  assert(world.rebooted == 1)
  local parsed = startup_template.parse(world.fs.files["startup.lua"] or "")
  assert(parsed and parsed.role == role and parsed.id == id and parsed.config == (config or netplan.PATH), "startup.lua: " .. tostring(world.fs.files["startup.lua"]))
  assert(world.fs.files["startup.lua"]:find("ota_recovery", 1, true) and world.fs.files["startup.lua"]:find("crn_install_journal", 1, true))
end

local function plan_of(world)
  local cfg, errors = netplan.parse(world.fs.files[netplan.PATH] or "")
  assert(cfg, "no plan written")
  assert(errors == nil, "plan is not valid: " .. tostring(errors and errors[1]))
  return cfg
end

local function node(cfg, id) return assert(netplan.find_node(cfg, id), "no entry " .. id) end

return {
  -- one flow per role ------------------------------------------------------------------------------------------------

  test_signal_with_a_create_device_gets_a_short_valid_plan = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    -- plan, channel, master, id, "this device?", summary, restart (a node with a line to carry over asks the restart with no as the suggestion)
    local result = world.run({ "--role", "signal" }, enters(6, { "j" }))
    assert_done(world, result, "signal", "SIG-1")
    local cfg = plan_of(world)
    assert(cfg.channel == 777 and cfg.master_id == "MASTER-1" and #cfg.nodes == 2)
    local entry = node(cfg, "SIG-1")
    assert(entry.adapter == "peripheral" and entry.peripheral == "Create_Signal_0")
    assert(world.text():find('"peripheral": "Create_Signal_0"', 1, true), "the entry for the master's plan is shown")
  end,

  test_sensor_without_a_device_falls_back_to_redstone = function()
    local world = setup_world.new({ peripherals = { MODEM } })
    local result = world.run({ "--role", "sensor" }, enters(7, { "j" }))
    assert_done(world, result, "sensor", "SEN-1")
    local entry = node(plan_of(world), "SEN-1")
    assert(entry.adapter == "redstone" and entry.side == "left", entry.adapter)
    assert(world.text():find("Kein Train Observer erkannt", 1, true))
  end,

  test_sensor_with_an_observer = function()
    local world = setup_world.new({ peripherals = { MODEM, OBSERVER } })
    local result = world.run({ "--role", "sensor" }, enters(6, { "j" }))
    assert_done(world, result, "sensor", "SEN-1")
    assert(node(plan_of(world), "SEN-1").peripheral == "Create_TrainObserver_0")
  end,

  test_switch_asks_for_side_position_and_inversion = function()
    local world = setup_world.new()
    local result = world.run({ "--role", "switch" }, { "", "", "", "", "3", "2", "j", "", "j" })
    assert_done(world, result, "switch", "SW-1")
    local entry = node(plan_of(world), "SW-1")
    assert(entry.adapter == "redstone" and entry.side == "front" and entry.active_position == "STRAIGHT" and entry.invert == true)
  end,

  test_station_asks_for_type_and_the_create_name = function()
    local world = setup_world.new()
    local result = world.run({ "--role", "station" }, { "", "", "", "ST-A", "3", "Hauptbahnhof", "Haupt Bahnhof", "", "", "", "j" })
    assert_done(world, result, "station", "ST-A")
    local entry = node(plan_of(world), "ST-A")
    assert(entry.station_type == "mixed" and entry.display_name == "Hauptbahnhof" and entry.create_station_name == "Haupt Bahnhof")
  end,

  test_a_fleet_node_and_an_arbiter_need_only_a_modem_and_an_id = function()
    local fleet = setup_world.new()
    local result = fleet.run({ "--role", "fleet" }, enters(5, { "j" }))
    assert_done(fleet, result, "fleet", "FLEET-1")
    assert(node(plan_of(fleet), "FLEET-1").role == "fleet")
    local arbiter = setup_world.new()
    result = arbiter.run({ "--role", "arbiter" }, enters(5, { "j" }))
    assert_done(arbiter, result, "arbiter", "ARB-1")
  end,

  test_depot_and_train_and_panel = function()
    local depot = setup_world.new()
    local result = depot.run({ "--role", "depot" }, enters(9, { "j" }))
    assert_done(depot, result, "depot", "DEPOT-1")
    assert(node(plan_of(depot), "DEPOT-1").depot_type == "mixed")

    local train = setup_world.new({ peripherals = { MODEM, STATION } })
    result = train.run({ "--role", "train" }, enters(9, { "j" }))
    assert_done(train, result, "train", "TRAIN-1")
    local entry = node(plan_of(train), "TRAIN-1")
    assert(entry.create_station == "Create_Station_0" and entry.schedule_station == "Create_Station_0")

    local panel = setup_world.new({ peripherals = { MODEM, MONITOR } })
    result = panel.run({ "--role", "panel" }, enters(6, { "j" }))
    assert_done(panel, result, "panel", "PANEL-1")
    assert(node(plan_of(panel), "PANEL-1").monitor == "monitor_0")
  end,

  test_master_copies_an_example_and_keeps_its_formatting = function()
    local world = setup_world.new()
    local result = world.run({ "--role", "master" }, { "", "?", "", "", "", "" })
    assert_done(world, result, "master", "MASTER-1")
    assert(world.fs.files[netplan.PATH] == world.fs.files["configs/templates/network.example.json"], "copied as it is")
    assert(world.text():find("kleinster Start", 1, true), "the menu says what each example is")
    assert(world.text():find("example: 5 Computer, 1 Block", 1, true), "? gives the sizes")
  end,

  test_master_with_an_empty_plan = function()
    local world = setup_world.new()
    local result = world.run({ "--role", "master" }, { "2", "", "MASTER-7", "", "", "", "" })
    assert_done(world, result, "master", "MASTER-7")
    local cfg = plan_of(world)
    assert(#cfg.nodes == 1 and cfg.master_id == "MASTER-7" and #cfg.blocks == 0)
  end,

  -- plans ------------------------------------------------------------------------------------------------------------

  test_a_node_can_use_a_plan_file_in_place_and_pick_its_entry = function()
    local world = setup_world.new({ peripherals = { MODEM } })
    -- plan 2 = own file (read only), its path, the entry of that file, then the device the entry names is missing
    local path = "configs/templates/network.example.json"
    local result = world.run({ "--role", "signal" }, { "2", path, "", "", "", "", "", "j" })
    assert_done(world, result, "signal", "SIG-1", path)
    assert(world.fs.files[netplan.PATH] == nil, "a plan used in place is not copied")
    assert(not world.text():find("Beispiel-Netzplan verwenden", 1, true), "a node is not offered the examples: their device names are placeholders")
    assert(world.text():find("Welcher Eintrag im Netzplan ist dieser Signal", 1, true))
    assert(world.text():find("SIG-1 (NICHT gefunden)", 1, true), "the file expects a device named like the entry")
  end,

  test_an_existing_plan_is_kept_and_a_new_node_is_added_to_it = function()
    local plan = netplan.encode({
      v = 1, channel = 800, master_id = "M-1",
      nodes = { { id = "M-1", role = "master" }, { id = "SIG-1", role = "signal", adapter = "redstone", side = "right" } },
      blocks = {}, routes = {},
    })
    local world = setup_world.new({ files = { [netplan.PATH] = plan } })
    -- plan (default: keep), identity: SIG-1 exists, "other id" is the last entry; then the redstone question
    local result = world.run({ "--role", "signal" }, { "", "2", "SIG-2", "", "", "", "j" })
    assert_done(world, result, "signal", "SIG-2")
    local cfg = plan_of(world)
    assert(cfg.channel == 800 and cfg.master_id == "M-1" and #cfg.nodes == 3, "channel and master come from the plan, the entry is added")
    assert(node(cfg, "SIG-1").side == "right", "the other entry stays")
    assert(world.fs.files[netplan.PATH .. ".prev"] == plan, "the old plan is kept as .prev")
    assert(not world.text():find("Funkkanal", 1, true), "no question the plan already answers")
  end,

  test_a_plan_entry_is_used_as_it_stands = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL }, files = { [netplan.PATH] = (function()
      return netplan.encode({ v = 1, channel = 777, master_id = "MASTER-1",
        nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-9", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" } }, blocks = {}, routes = {} })
    end)() } })
    local before = world.fs.files[netplan.PATH]
    local result = world.run({ "--role", "signal" }, enters(4))
    assert_done(world, result, "signal", "SIG-9")
    assert(world.fs.files[netplan.PATH] == before, "nothing to add, the plan stays byte for byte")
    assert(world.text():find("Create_Signal_0 (gefunden)", 1, true), "the summary says the device is there")
  end,

  test_a_missing_device_named_in_the_plan_is_called_out = function()
    local world = setup_world.new({ peripherals = { MODEM }, files = { [netplan.PATH] = netplan.encode({ v = 1, channel = 777, master_id = "MASTER-1",
      nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-9", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_5" } }, blocks = {}, routes = {} }) } })
    -- the doctor finds the missing device red: two pages, and Enter does not restart
    local result = world.run({ "--role", "signal" }, enters(6, { "j" }))
    assert_done(world, result, "signal", "SIG-9")
    assert(world.text():find("Create_Signal_5", 1, true) and world.text():find("nicht angeschlossen", 1, true) and world.text():find("(NICHT gefunden)", 1, true))
  end,

  test_a_broken_plan_is_shown_and_not_taken_by_accident = function()
    local broken = '{"v":1,"channel":777,"master_id":"MASTER-1","nodes":[{"id":"MASTER-1","role":"master"}],"blocks":[{"id":"B1","entry_signal":"X","exit_signal":"Y"}],"routes":[]}'
    local world = setup_world.new({ files = { [netplan.PATH] = broken } })
    -- keep (marked FEHLERHAFT) -> errors are shown -> "no" -> back to the choice -> empty plan; overwrite question: yes
    local result = world.run({ "--role", "master" }, { "1", "n", "3", "j", "", "", "", "", "", "" })
    assert(world.text():find("FEHLERHAFT", 1, true) and world.text():find("Dieser Netzplan hat Fehler", 1, true))
    assert_done(world, result, "master", "MASTER-1")
    assert(world.fs.files[netplan.PATH .. ".prev"] == broken)
  end,

  test_an_own_file_must_exist_and_be_valid = function()
    local good = netplan.encode({ v = 1, channel = 5, master_id = "M", nodes = { { id = "M", role = "master" } }, blocks = {}, routes = {} })
    local world = setup_world.new({ files = { ["mein/netz.json"] = good, ["mein/kaputt.json"] = "{ not json" } })
    local result = world.run({ "--role", "master" }, { "3", "mein/gibt-es-nicht.json", "mein/kaputt.json", "mein/netz.json", "", "", "", "" })
    assert_done(world, result, "master", "M", "mein/netz.json")
    assert(world.text():find("Diese Datei gibt es nicht", 1, true) and world.text():find("Keine gueltige JSON-Datei", 1, true))
    assert(world.fs.files[netplan.PATH] == nil)
  end,

  -- checks and navigation --------------------------------------------------------------------------------------------

  test_input_is_checked_where_it_is_given = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({ "--role", "signal" }, { "", "99999", "abc", "888", "MASTER 1", "MASTER-1", "SIG 1", "sig-ä", "MASTER-1", "SIG-4", "", "", "j" })
    assert_done(world, result, "signal", "SIG-4", nil, true)
    local text = world.text()
    assert(text:find("Eine ganze Zahl von 1 bis 65535", 1, true))
    assert(text:find("Nur Buchstaben, Ziffern", 1, true))
    assert(text:find("Das ist die ID des Masters", 1, true))
    assert(plan_of(world).channel == 888)
  end,

  test_help_explains_the_question_and_asks_again = function()
    local world = setup_world.new()
    local result = world.run({ "--role", "signal" }, { "?", "", "", "?", "", "", "", "", "", "", "", "j" })
    assert(world.text():find("Behalten: die vorhandene Datei bleibt", 1, true))
    assert(world.text():find("Funkkanal", 1, true))
    assert(result.ok)
  end,

  test_back_goes_one_step_and_keeps_the_answers = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    -- channel 900, master MASTER-1, id: "<" back to the master question, "<" back to the channel (still 900), then on
    local result = world.run({ "--role", "signal" }, { "", "900", "", "<", "<", "", "", "", "", "", "j" })
    assert_done(world, result, "signal", "SIG-1")
    assert(plan_of(world).channel == 900, "the channel answer survived going back")
  end,

  test_changing_a_step_from_the_summary = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    -- summary: n -> change step 2 (name; the menu lists plan, name, hardware) -> new id -> hardware again (defaults) -> summary -> write
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "", "n", "2", "SIG-77", "", "", "j" })
    assert_done(world, result, "signal", "SIG-77")
    assert(netplan.find_node(plan_of(world), "SIG-77") and not netplan.find_node(plan_of(world), "SIG-1"))
  end,

  test_the_role_menu_when_the_installer_did_not_choose = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({}, { "x", "99", "2", "", "", "", "", "", "", "j" })
    assert_done(world, result, "signal", "SIG-1")
    assert(world.text():find("Bitte eine Zahl von 1 bis 10", 1, true))
    assert(world.text():find("[Rolle]  Netzplan  Name  Hardware  Pruefen", 1, true), "the trail shows where you are")
    assert(world.text():find("Netzplan  Name  Hardware  [Pruefen]", 1, true))
  end,

  test_a_wrong_role_argument_is_ignored_and_the_menu_asks = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({ "--role", "wizard" }, { "2", "", "", "", "", "", "", "j" })
    assert_done(world, result, "signal", "SIG-1")
  end,

  -- nothing without the summary --------------------------------------------------------------------------------------

  test_nothing_is_written_before_the_summary_is_confirmed = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local before = world.fs.ops
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "", "a" })
    assert(result.aborted and not result.ok)
    assert(world.fs.ops == before and world.fs.files["startup.lua"] == nil and world.fs.files[netplan.PATH] == nil, "cancelled at the summary")
    -- input that ends in the middle of a question is a cancel too
    local cut = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local cut_result = cut.run({ "--role", "signal" }, { "", "800" })
    assert(cut_result.aborted and cut.fs.ops == 0)
  end,

  test_an_installed_computer_is_not_reconfigured_by_accident = function()
    local startup = startup_template.render({ role = "sensor", id = "SEN-1", config = "configs/network.json" })
    local world = setup_world.new({ files = { ["startup.lua"] = startup } })
    local result = world.run({}, { "" })
    assert(result.aborted and world.fs.files["startup.lua"] == startup)
    assert(world.text():find("schon eingerichtet", 1, true) and world.text():find("Melder SEN-1", 1, true))
    -- yes: the old answers are the suggestions
    local again = setup_world.new({ peripherals = { MODEM, OBSERVER }, files = { ["startup.lua"] = startup } })
    local done = again.run({}, { "j", "", "", "", "", "", "", "", "j" })
    assert_done(again, done, "sensor", "SEN-1")
  end,

  test_the_installer_chosen_role_skips_the_question_for_a_computer_that_changes_its_role = function()
    local startup = startup_template.render({ role = "sensor", id = "SEN-1", config = "configs/network.json" })
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL }, files = { ["startup.lua"] = startup } })
    local result = world.run({ "--role", "signal" }, enters(6, { "j" }))
    assert_done(world, result, "signal", "SIG-1")
    assert(not world.text():find("schon eingerichtet", 1, true))
  end,

  test_a_computer_without_a_modem_is_warned_but_may_go_on = function()
    local world = setup_world.new({ peripherals = { SIGNAL } })
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "j", "", "", "j" })
    assert(world.text():find("kein Modem", 1, true))
    assert(world.text():find("FEHLT", 1, true), "the summary says it too")
    assert(result.ok)
    -- Enter alone stops here: without a modem the way on has to be chosen
    local quit = setup_world.new({ peripherals = { SIGNAL } })
    local quit_result = quit.run({ "--role", "signal" }, { "", "", "", "", "" })
    assert(quit_result.aborted and quit.fs.ops == 0)
    local no = setup_world.new({ peripherals = { SIGNAL } })
    local no_result = no.run({ "--role", "signal" }, { "", "", "", "", "n" })
    assert(no_result.aborted and no.fs.ops == 0)
  end,

  test_running_it_twice_gives_the_same_files = function()
    local function run_once(world, answers)
      return world.run({ "--role", "signal" }, answers)
    end
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    run_once(world, enters(6, { "j" }))
    local startup, plan = world.fs.files["startup.lua"], world.fs.files[netplan.PATH]
    -- second time: the plan exists, the default is to keep it (plan, entry, summary, restart)
    local second = run_once(world, enters(4))
    assert(second.ok and world.fs.files["startup.lua"] == startup and world.fs.files[netplan.PATH] == plan)
  end,

  -- screens ----------------------------------------------------------------------------------------------------------

  test_every_screen_of_every_role_fits_a_small_computer_and_is_ascii = function()
    local roles = { "master", "signal", "sensor", "switch", "station", "depot", "train", "panel" }
    for _, role in ipairs(roles) do
      local world = setup_world.new({ peripherals = { MODEM, SIGNAL, OBSERVER, STATION, MONITOR } })
      local result = world.run({ "--role", role }, enters(14))
      assert(result.ok, role .. ": " .. tostring(result.error))
      assert(world.check_screen() == nil, role .. ": " .. tostring(world.check_screen()))
    end
  end,

  test_a_narrow_screen_wraps_instead_of_overflowing = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL }, width = 30, height = 40 })
    local result = world.run({ "--role", "signal" }, enters(6, { "j" }))
    assert(result.ok and world.check_screen() == nil, tostring(world.check_screen()))
  end,

  -- the building blocks ----------------------------------------------------------------------------------------------

  test_wrap_keeps_columns_and_cuts_long_words = function()
    local lines = terminal.wrap("  Rolle     Signal", 40)
    assert(lines[1] == "  Rolle     Signal", lines[1])
    local wrapped = terminal.wrap("eins zwei drei vier fuenf sechs sieben", 14)
    for _, line in ipairs(wrapped) do assert(#line <= 14, line) end
    assert(table.concat(wrapped, " ") == "eins zwei drei vier fuenf sechs sieben")
    local path = terminal.wrap("configs/templates/network.full.example.json", 20)
    for _, line in ipairs(path) do assert(#line <= 20) end
    assert(table.concat(path) == "configs/templates/network.full.example.json")
    local hanging = terminal.wrap("    eingerueckter langer Text der umbricht", 20)
    for _, line in ipairs(hanging) do assert(line:sub(1, 4) == "    ", line) end
  end,

  test_hardware_is_recognised_by_name_type_and_methods = function()
    local list = hardware.scan({
      getNames = function() return { "top", "Create_Signal_0", "right", "weird", "left", "back" } end,
      getType = function(name)
        return ({ top = "modem", Create_Signal_0 = "Create_Signal", right = "Create_TrainObserver", weird = "thing", left = "monitor", back = "Create_Station" })[name]
      end,
      getMethods = function(name) if name == "back" then return { "setSchedule" } end; return {} end,
    })
    local classes = {}
    for _, info in ipairs(list) do classes[info.name] = info.class end
    assert(classes.top == "modem" and classes.left == "monitor" and classes.right == "train_observer" and classes.weird == "other" and classes.back == "create_station")
    assert(classes.Create_Signal_0 == "create_signal" or classes.Create_Signal_0 == "other", "a signal needs its methods to be told from other devices")
    assert(#hardware.scan(nil) == 0 and #hardware.scan({}) == 0)
    assert(hardware.side_label("left") == "links (left)")
  end,

  test_netplan_helpers = function()
    assert(netplan.valid_id("SIG-1") and netplan.valid_id("a.b_c-1"))
    assert(not netplan.valid_id("") and not netplan.valid_id("a b") and not netplan.valid_id(string.rep("x", 33)) and not netplan.valid_id("sig-\195\164"))
    local cfg = netplan.short_plan("signal", { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }, 777, "MASTER-1")
    assert(netplan.suggest_id("signal", cfg) == "SIG-2" and netplan.suggest_id("signal", nil) == "SIG-1" and netplan.suggest_id("station", cfg) == "ST-1")
    local text = netplan.encode(cfg)
    local back, errors = netplan.parse(text)
    assert(back and errors == nil, tostring(errors and errors[1]))
    assert(netplan.encode(back) == text, "encoding is stable")
    assert(text:find('"v": 1,\n  "channel": 777', 1, true), "the keys people look for come first")
    assert(netplan.parse("nope") == nil)
    local summary = netplan.summary(back)
    assert(netplan.text(summary) == "2 Computer, 0 Bloecke, 0 Routen")
    for _, line in ipairs(netplan.entry_lines({ id = "SIG-1", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" }, 40)) do assert(#line <= 41, line) end
  end,

  test_check_tells_whether_the_network_plan_is_valid_and_changes_nothing = function()
    local example = io.open("configs/templates/network.example.json", "rb"):read("*a")
    local world = setup_world.new({ files = { [netplan.PATH] = example, ["configs/other.json"] = "{ not json" } })
    local ok = world.run({ "--check" }, {})
    assert(ok.ok and ok.path == netplan.PATH and (world.text():gsub("%s+", " ")):find("in Ordnung (5 Computer, 1 Block, 1 Route)", 1, true), world.text())
    assert(world.check_screen() == nil, tostring(world.check_screen()))

    local broken = setup_world.new({ files = { [netplan.PATH] = (example:gsub('"channel": *%d+,', "")) } })
    local result = broken.run({ "--check" }, {})
    assert(not result.ok and result.errors and #result.errors > 0 and broken.text():find("Fehler", 1, true), broken.text())
    assert(broken.check_screen() == nil, tostring(broken.check_screen()))

    local garbage = world.run({ "--check", "configs/other.json" }, {})
    assert(not garbage.ok and world.text():find("keine gueltige JSON-Datei", 1, true))
    local missing = world.run({ "--check", "configs/nope.json" }, {})
    assert(not missing.ok and world.text():find("Diese Datei gibt es nicht", 1, true))

    assert(world.fs.files["startup.lua"] == nil, "check never writes")
    local args = wizard.parse_args({ "--check", "x.json", "--role", "signal" })
    assert(args.check and args.check_path == "x.json" and args.role == "signal")
    assert(wizard.parse_args({ "--check", "--role", "signal" }).check_path == nil)
  end,

  test_a_long_suggestion_does_not_push_the_prompt_off_the_screen = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR } })
    local long = string.rep("x", 80)
    local result = world.run({ "--role", "panel" }, { "", "", "", "", long, "<" })
    assert(result.aborted and world.unused == 0, "the answers end in the second display question")
    assert(world.check_screen() == nil, tostring(world.check_screen()))
    assert(world.last_page_text():find("[" .. long:sub(1, 21) .. "...] >", 1, true), world.last_page_text())
  end,

  -- whatever is typed: no Lua error, a cancelled run leaves the disk as it was, a finished run leaves a startup.lua that says what was chosen
  -- and a plan that passes the check
  test_random_answers_never_break_the_wizard_or_leave_bad_files = function()
    local example = io.open("configs/templates/network.example.json", "rb"):read("*a")
    local tokens = {
      "", "", "", "", "1", "2", "3", "4", "5", "9", "0", "-1", "1.5", "?", "<", "<", "j", "n", "a", "ja", "nein", "r",
      "SIG-9", "MASTER-1", "SEN-1", "x y", "778", "70000", "left", "up", "configs/network.json", "configs/nope.json",
      "configs/templates/network.full.example.json", string.rep("x", 80), "STRAIGHT",
    }
    local peripheral_sets = {
      { MODEM }, { MODEM, SIGNAL, OBSERVER }, { MODEM, STATION, MONITOR }, {}, { SIGNAL, MONITOR, MODEM, STATION, OBSERVER },
    }
    local roles = { "master", "signal", "sensor", "switch", "station", "depot", "train", "panel", false }
    local finished, cancelled = 0, 0
    for seed = 1, 250 do
      local rng = prng.new(seed)
      local files = {}
      local start = rng.int(1, 5)
      if start == 2 then files[netplan.PATH] = example
      elseif start == 3 then files[netplan.PATH] = "garbage"
      elseif start == 4 then files["startup.lua"] = startup_template.render({ role = "signal", id = "SIG-1", config = netplan.PATH }) end
      local world = setup_world.new({ files = files, peripherals = rng.pick(peripheral_sets) })
      local before = world.fs.snapshot()
      local answers = {}
      for i = 1, rng.int(0, 70) do answers[i] = rng.pick(tokens) end
      local role = rng.pick(roles)
      local ok, result = pcall(world.run, role and { "--role", role } or {}, answers)
      assert(ok, "seed " .. seed .. ": " .. tostring(result))
      assert(world.check_screen(true) == nil, "seed " .. seed .. ": " .. tostring(world.check_screen(true)))
      if result.ok then
        finished = finished + 1
        local parsed = startup_template.parse(world.fs.files["startup.lua"] or "")
        assert(parsed and parsed.role == result.role and parsed.id == result.id, "seed " .. seed .. ": startup.lua")
        for _, path in ipairs(result.written) do
          if path ~= "startup.lua" then
            local cfg, errors = netplan.parse(world.fs.files[path] or "")
            assert(cfg and not errors, "seed " .. seed .. ": written plan is invalid")
            if result.role ~= "master" then assert(netplan.find_node(cfg, result.id), "seed " .. seed .. ": the written plan lacks " .. result.id) end
          end
        end
      else
        cancelled = cancelled + 1
        local after = world.fs.snapshot()
        for path, body in pairs(before) do assert(after[path] == body, "seed " .. seed .. ": " .. path .. " changed although the run did not finish") end
        for path in pairs(after) do assert(before[path] ~= nil, "seed " .. seed .. ": " .. path .. " appeared although the run did not finish") end
      end
    end
    assert(finished >= 5 and cancelled >= 5, "the answers should reach both outcomes: " .. finished .. " / " .. cancelled)
  end,

  -- the keys of the wizard stand on the rule under the header of a question page, not on a page of their own
  test_the_keys_stand_on_the_rule_of_every_question_page_but_not_on_the_help_page = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({ "--role", "signal" }, { "?", "", "", "", "", "", "", "", "j" })
    assert(result.ok, tostring(result.error))
    local with_hint, help_page = 0, nil
    for _, page in ipairs(world.pages) do
      for _, line in ipairs(page.lines) do
        if line:match("^%-+ Enter ok  %? Hilfe  < zurueck$") then with_hint = with_hint + 1 end
        if line:match("^CreateRailNet  Hilfe$") then help_page = page end
      end
    end
    assert(with_hint >= 6, "the hint is on the question pages: " .. with_hint)
    assert(help_page, "the help page exists")
    for _, line in ipairs(help_page.lines) do assert(not line:find("Enter ok", 1, true), "no hint on the help page") end
    assert(not world.text():find("Weiter mit Enter. > ", 1, true))
    assert(world.pages[2].lines[1]:find("Netzplan", 1, true), "the first page is the first question, not an introduction")
  end,

  test_one_attached_device_is_confirmed_in_one_question_and_no_leads_to_the_other_ways = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    -- plan, channel, master, id, "this device?" -> no, "how?" -> redstone, side, summary, restart
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "n", "2", "3", "", "j" })
    assert_done(world, result, "signal", "SIG-1")
    local entry = node(plan_of(world), "SIG-1")
    assert(entry.adapter == "redstone" and entry.side == "front", "no: the other way is offered")
    local text = world.text()
    assert(text:find("Create-Signal erkannt: Create_Signal_0", 1, true))
    assert(not text:find("Welches gehoert zu diesem Computer", 1, true), "no list with one line")
    local yes = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local ok = yes.run({ "--role", "signal" }, enters(6, { "j" }))
    assert_done(yes, ok, "signal", "SIG-1")
    assert(not yes.text():find("Wie steuert dieser Computer", 1, true), "yes: nothing more to ask about the connection")
  end,

  test_going_back_over_a_question_that_asked_nothing_reaches_the_step_before = function()
    local world = setup_world.new({ peripherals = { MODEM } })
    -- no sensor device: the confirmation has nothing to ask. "how?" -> back -> the name again -> forward
    local result = world.run({ "--role", "sensor" }, { "", "", "", "", "<", "SEN-2", "", "", "", "j" })
    assert_done(world, result, "sensor", "SEN-2")
    assert(node(plan_of(world), "SEN-2").adapter == "redstone")
  end,

  test_two_modems_ask_which_one_and_the_name_goes_into_the_plan = function()
    local world = setup_world.new({ peripherals = { MODEM, MODEM2, SIGNAL } })
    local result = world.run({ "--role", "signal" }, { "", "", "", "", "1", "", "", "j" })
    assert_done(world, result, "signal", "SIG-1")
    assert(node(plan_of(world), "SIG-1").modem == "modem_1")
    assert(world.text():find("modem_1 (festgelegt)", 1, true), "the summary says which modem")
    assert(world.text():find("Dieser Computer hat 2 Modems", 1, true))
  end,

  test_one_modem_is_found_by_itself_and_not_written = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({ "--role", "signal" }, enters(6, { "j" }))
    assert_done(world, result, "signal", "SIG-1")
    assert(node(plan_of(world), "SIG-1").modem == nil)
    assert(world.text():find("top (automatisch)", 1, true))
  end,

  test_two_monitors_ask_which_one_for_a_station = function()
    local world = setup_world.new({ peripherals = { MODEM, MONITOR, MONITOR2 } })
    local result = world.run({ "--role", "station" }, { "", "", "", "ST-1", "2", "", "", "", "", "", "", "j" })
    assert_done(world, result, "station", "ST-1")
    assert(node(plan_of(world), "ST-1").monitor == "monitor_1")
    assert(world.text():find("monitor_1 (festgelegt)", 1, true))
    -- one monitor is found by itself
    local single = setup_world.new({ peripherals = { MODEM, MONITOR } })
    local done = single.run({ "--role", "station" }, { "", "", "", "ST-1", "", "", "", "", "", "", "j" })
    assert_done(single, done, "station", "ST-1")
    assert(node(plan_of(single), "ST-1").monitor == nil and single.text():find("monitor_0 (automatisch)", 1, true))
  end,

  test_the_master_of_a_copied_example_gets_the_chosen_modem_and_monitor = function()
    local world = setup_world.new({ peripherals = { MODEM, MODEM2, MONITOR, MONITOR2 } })
    -- plan: copy, example, then the modem and the monitor, summary, restart
    local result = world.run({ "--role", "master" }, { "", "", "2", "1", "", "" })
    assert_done(world, result, "master", "MASTER-1")
    local cfg = plan_of(world)
    local master = node(cfg, "MASTER-1")
    assert(master.modem == "top" and master.monitor == "monitor_0", tostring(master.modem) .. " / " .. tostring(master.monitor))
    assert(#cfg.nodes == 5 and #cfg.blocks == 1, "the rest of the example is untouched")
    assert(world.fs.files[netplan.PATH] ~= world.fs.files["configs/templates/network.example.json"], "devices were added, so the file is written in the stable format")
  end,

  test_a_plan_that_exists_is_not_edited_for_a_modem_choice_but_the_summary_warns = function()
    local plan = netplan.encode({ v = 1, channel = 777, master_id = "MASTER-1",
      nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-9", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" } }, blocks = {}, routes = {} })
    local world = setup_world.new({ peripherals = { MODEM, MODEM2, SIGNAL }, files = { [netplan.PATH] = plan } })
    local result = world.run({ "--role", "signal" }, enters(6))
    assert_done(world, result, "signal", "SIG-9")
    assert(world.fs.files[netplan.PATH] == plan, "the plan stays as it is")
    assert(world.text():find("Mehrere Modems, keines festgelegt", 1, true), "the doctor says it as well")
    assert(world.text():find("NICHT festgelegt (2 vorhanden)", 1, true))
    assert(not world.text():find("Ueber welches Modem", 1, true))
  end,

  test_a_node_with_a_line_to_carry_over_does_not_restart_on_a_plain_enter = function()
    local world = setup_world.new({ peripherals = { MODEM, SIGNAL } })
    local result = world.run({ "--role", "signal" }, enters(7))
    assert(result.ok and world.rebooted == 0 and not result.rebooted, "Enter answers the restart question with no")
    assert(world.last_page_text():find('"id": "SIG-1"', 1, true), "the line is still on the screen")
    assert(world.last_page_text():find("steht auch in configs/network.json", 1, true))
    assert(world.last_page_text():find("reboot", 1, true))
    local master = setup_world.new({ peripherals = { MODEM, MONITOR } })
    local done = master.run({ "--role", "master" }, enters(5))
    assert(done.ok and master.rebooted == 1, "nothing to carry over: Enter restarts")
  end,

  test_the_summary_speaks_the_words_of_the_questions = function()
    local station = setup_world.new()
    station.run({ "--role", "station" }, { "", "", "", "", "3", "", "", "", "j" })
    assert(station.text():find("(gemischt)", 1, true) and not station.text():find("(mixed)", 1, true))
    local passenger = setup_world.new()
    passenger.run({ "--role", "station" }, { "", "", "", "", "1", "", "", "", "j" })
    assert(passenger.text():find("(Personenverkehr)", 1, true))
    for _, page in ipairs(passenger.pages) do
      if page.lines[1] == "CreateRailNet  Pruefen" then
        for _, line in ipairs(page.lines) do assert(not line:find("passenger", 1, true), "the summary uses the German word: " .. line) end
      end
    end
    local switch = setup_world.new()
    switch.run({ "--role", "switch" }, { "", "", "", "", "", "2", "", "", "j" })
    assert(switch.text():find("bei Signal: geradeaus", 1, true) and not switch.text():find("bei Signal: STRAIGHT", 1, true))
    local depot = setup_world.new()
    depot.run({ "--role", "depot" }, enters(7, { "j" }))
    assert(depot.text():find("(gemischt)", 1, true))
  end,

  test_validator_messages_come_in_german_with_the_id_of_the_entry = function()
    local cfg = { nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "teleporter" } }, blocks = { { id = "B1" } } }
    assert(netplan.explain("channel: must be integer > 0", cfg) == "channel: ganze Zahl groesser 0 noetig")
    assert(netplan.explain('nodes[2].role: invalid role "teleporter"', cfg) == 'nodes[2] (SIG-1).role: unbekannte Rolle "teleporter"')
    assert(netplan.explain('blocks[1].entry_signal: references unknown signal node "nil"', cfg) == "blocks[1] (B1).entry_signal: Feld fehlt")
    assert(netplan.explain('blocks[1].sensors[1]: references unknown sensor node "S9"', cfg):find('Melder%-Eintrag, den es nicht gibt: "S9"'))
    assert(netplan.explain("blocks: must be an array") == "blocks: muss eine Liste [] sein")
    assert(netplan.explain("something: never heard of") == "something: never heard of", "unknown messages stay as they are")
    assert(netplan.explain("no colon here") == "no colon here")
    -- the real plans of the tests: every message the validator gives for a broken example is translated
    local broken = { v = 2, channel = 0, master_id = "", blocks = 1, routes = 2, nodes = { { id = "A", role = "x" } } }
    local _, errors = netplan.parse(require("src.shared.json").encode(broken))
    assert(errors and #errors >= 5)
    for _, message in ipairs(errors) do
      local shown = netplan.explain(message, broken)
      assert(not shown:find("must be", 1, true), message .. " -> " .. shown)
    end
  end,

  test_entries_carry_the_chosen_devices_and_set_fields_changes_one_entry_only = function()
    local entry = netplan.build_entry("panel", "PANEL-1", { monitor = "monitor_1", modem = "modem_1", display_name = "P" })
    assert(entry.monitor == "monitor_1" and entry.modem == "modem_1")
    local signal = netplan.build_entry("signal", "SIG-1", { adapter = "redstone", side = "left", monitor = "monitor_1" })
    assert(signal.monitor == nil, "a signal computer has no screen")
    local cfg = netplan.short_plan("master", { id = "M", role = "master" }, 777, "M")
    cfg = netplan.add_node(cfg, signal)
    local changed = netplan.set_fields(cfg, "M", { modem = "top", monitor = nil })
    assert(netplan.find_node(changed, "M").modem == "top" and netplan.find_node(cfg, "M").modem == nil, "the original is not touched")
    assert(netplan.find_node(changed, "SIG-1") == netplan.find_node(cfg, "SIG-1"), "the other entries are shared")
    assert(select(2, netplan.parse(netplan.encode(changed))) == nil)
  end,

  test_every_role_of_the_wizard_is_a_role_the_system_knows = function()
    local known = {}
    for _, role in ipairs(startup_template.ROLES) do known[role] = true end
    for _, role in ipairs(wizard.ROLES) do assert(known[role.key], role.key) end
    assert(#wizard.ROLES == #startup_template.ROLES)
  end,

  test_the_installer_menu_and_the_wizard_offer_the_same_roles_in_the_same_order_with_the_same_words = function()
    assert(#install_plan.ROLES == #wizard.ROLES)
    for i, role in ipairs(install_plan.ROLES) do
      local other = wizard.ROLES[i]
      assert(role.key == other.key, "position " .. i .. ": " .. role.key .. " / " .. other.key)
      assert(role.label == other.label and role.text == other.text, "the words of " .. role.key .. " differ: " .. role.label .. " / " .. other.label)
    end
  end,

  test_all_generated_plans_validate_for_every_role = function()
    local roles = { "master", "signal", "sensor", "switch", "station", "depot", "train", "panel" }
    for _, role in ipairs(roles) do
      local fields = { adapter = "redstone", side = "top", peripheral = "x", create_station = "Create_Station_0", display_name = "Name" }
      local entry = netplan.build_entry(role, role:upper() .. "-1", fields)
      local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
      local parsed, errors = netplan.parse(netplan.encode(cfg))
      assert(parsed and errors == nil, role .. ": " .. tostring(errors and errors[1]))
    end
  end,
}
