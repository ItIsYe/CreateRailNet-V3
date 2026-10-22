--[[
Purpose: Every node role as the game starts it: the real module, the plan file the wizard writes, the bootstrap of src/nodes, and peripherals
  that check their arguments like the ones in CC:Tweaked (tests/harness/strict_cc.lua). The node opens its channel, registers, sends
  heartbeats, answers a command of the master with the hardware call that role makes (redstone output, signal, switch), and draws its monitor
  without a single wrong call. Nothing else of the suite starts a node this way.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local strict_cc = require("tests.harness.strict_cc")
local netplan = require("src.setup.netplan")
local net = require("src.shared.net")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }
local created = {}

local function write_file(path, text)
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  created[#created + 1] = path
end

local function cleanup()
  for _, path in ipairs(created) do os.remove(path) end
  created = {}
end

-- the entry the wizard would write for this role (plus whatever the role needs), as a short plan on the disk of the computer
local function plan_file(role, entry)
  local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
  cfg.startup_autoupgrade = false
  local path = os.tmpname()
  write_file(path, netplan.encode(cfg))
  return path
end

-- a signal like the one Create adds: setForcedRed(boolean) and isForcedRed()
local function create_signal()
  local obj = { forced = nil, violations = {} }
  function obj.setForcedRed(value)
    if type(value) ~= "boolean" then obj.violations[#obj.violations + 1] = "setForcedRed: boolean expected, got " .. type(value); error("bad argument #1 (boolean expected)", 2) end
    obj.forced = value
  end
  function obj.isForcedRed() return obj.forced == true end
  return obj
end

local function train_observer()
  local obj = { passing = false, name = "Zug 1" }
  function obj.isTrainPassing() return obj.passing end
  function obj.getPassingTrainName() return obj.passing and obj.name or nil end
  return obj
end

local function create_station()
  local obj = { present = false }
  function obj.getStationName() return "Hauptbahnhof" end
  function obj.isTrainPresent() return obj.present end
  function obj.setSchedule() return true end
  return obj
end

-- a node on strict peripherals; run(world, node) is called with the node started; the globals are restored afterwards
local function with_node(role, entry, extra_devices, run)
  local modem = strict_cc.modem()
  local monitor = strict_cc.monitor(51, 19)
  local redstone = strict_cc.redstone()
  local devices = {
    top = { type = "modem", methods = { "open", "close", "isOpen", "transmit" }, object = modem },
    monitor_0 = { type = "monitor", methods = { "write", "setCursorPos", "getSize", "clear", "isColor", "setTextColor", "setBackgroundColor" }, object = monitor },
  }
  for name, device in pairs(extra_devices or {}) do devices[name] = device end
  local restore = strict_cc.install({ peripheral = strict_cc.peripheral(devices), window = strict_cc.window_api(), redstone = redstone })
  local world = { modem = modem, monitor = monitor, redstone = redstone, clock = 1000, devices = devices }
  local ok, err = pcall(function()
    local path = plan_file(role, entry)
    local bootstrap = require("src.nodes.bootstrap")
    local context = bootstrap.create_context({ "--id", entry.id, "--config", path }, role)
    context.clock = function() return world.clock end
    context.start_timer = function() return 1 end
    local node = require("src.nodes." .. role .. "_node").new_runtime(context)
    world.node, world.logger = node, context.logger
    -- the master, as a net instance on a loopback modem: what it sends is handed to the node
    local sink = { send = function(_, _, _, msg) world.last_from_master = msg; return true end, broadcast = function(_, _, msg) world.last_from_master = msg; return true end }
    world.master = net.new(sink, 777, "MASTER-1", quiet)
    function world.command(payload)
      world.master.send("cmd", entry.id, payload)
      node.handle_event({ "modem_message", "top", 777, 777, world.last_from_master, 3 })
    end
    function world.advance(seconds, steps)
      for _ = 1, steps or 1 do
        world.clock = world.clock + seconds
        node.handle_event({ "timer", 1 })
      end
    end
    -- the events (message type "event") of one kind that the node sent
    function world.sent(kind)
      local list = {}
      for _, t in ipairs(modem.transmitted) do
        if t.payload.type == "event" and t.payload.payload and t.payload.payload.type == kind then list[#list + 1] = t.payload.payload end
      end
      return list
    end
    node.start()
    run(world, node)
  end)
  restore()
  cleanup()
  if not ok then error(err, 0) end
end

local function violations(world)
  local all = {}
  for _, list in ipairs({ world.monitor.violations, world.modem.violations, world.redstone.violations }) do
    for _, item in ipairs(list) do all[#all + 1] = item end
  end
  for _, device in pairs(world.devices) do
    if device.object and device.object.violations and device.object ~= world.monitor and device.object ~= world.modem then
      for _, item in ipairs(device.object.violations) do all[#all + 1] = item end
    end
  end
  return all
end

local function warnings(world)
  local list = {}
  for _, entry in ipairs(world.logger.get_buffer()) do
    if entry.level == "WARN" or entry.level == "ERROR" then list[#list + 1] = tostring(entry.msg) end
  end
  return list
end

local function assert_clean(world)
  assert(#violations(world) == 0, table.concat(violations(world), "; "))
  local w = warnings(world)
  assert(#w == 0, table.concat(w, "; "))
end

local function assert_alive(world)
  assert(world.modem.opened[777], "the channel of the plan is open")
  local registered = false
  for _, t in ipairs(world.modem.transmitted) do
    assert(type(t.channel) == "number" and type(t.reply) == "number" and type(t.payload) == "table")
    if t.payload.type == "register" then registered = true end
  end
  assert(registered, "the node registered itself at the master")
  local before = #world.modem.transmitted
  world.advance(3, 4)
  assert(#world.modem.transmitted > before, "heartbeats go out while the clock runs")
end

return {
  test_a_signal_with_redstone_starts_red_and_follows_the_master = function()
    with_node("signal", { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }, nil, function(world)
      assert_alive(world)
      assert(world.redstone.outputs.left == false, "red at the start")
      world.command({ cmd = "set_aspect", aspect = "GREEN" })
      assert(world.redstone.outputs.left == true, "the master's green is a redstone output")
      world.command({ cmd = "set_aspect", aspect = "RED" })
      assert(world.redstone.outputs.left == false)
      assert_clean(world)
    end)
  end,

  test_a_create_signal_is_forced_red_with_a_boolean = function()
    local signal = create_signal()
    with_node("signal", { id = "SIG-2", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" },
      { Create_Signal_0 = { type = "Create_Signal", methods = { "setForcedRed", "isForcedRed" }, object = signal } }, function(world)
      assert_alive(world)
      assert(signal.forced == true, "red at the start")
      world.command({ cmd = "set_aspect", aspect = "GREEN" })
      assert(signal.forced == false)
      world.command({ cmd = "set_aspect", aspect = "RED" })
      assert(signal.forced == true)
      assert_clean(world)
    end)
  end,

  test_a_switch_follows_the_position_the_master_sends = function()
    with_node("switch", { id = "SW-1", role = "switch", adapter = "redstone", side = "back" }, nil, function(world)
      assert_alive(world)
      world.command({ cmd = "set_position", position = "DIVERGING" })
      assert(world.redstone.outputs.back == true)
      world.command({ cmd = "set_position", position = "STRAIGHT" })
      assert(world.redstone.outputs.back == false)
      assert_clean(world)
    end)
  end,

  test_a_sensor_with_a_train_observer_reports_enter_and_leave = function()
    local observer = train_observer()
    with_node("sensor", { id = "SEN-1", role = "sensor", adapter = "peripheral", peripheral = "Create_TrainObserver_0" },
      { Create_TrainObserver_0 = { type = "Create_TrainObserver", methods = { "isTrainPassing", "getPassingTrainName" }, object = observer } }, function(world)
      assert_alive(world)
      observer.passing = true
      world.advance(1, 5)
      observer.passing = false
      world.advance(1, 5)
      local events = world.sent("sensor")
      assert(#events == 2 and events[1].action == "enter" and events[2].action == "leave", "enter and leave reached the master")
      assert_clean(world)
    end)
  end,

  test_a_sensor_on_a_redstone_input_works_too = function()
    with_node("sensor", { id = "SEN-2", role = "sensor", adapter = "redstone", side = "front" }, nil, function(world)
      assert_alive(world)
      world.redstone.inputs.front = true
      world.advance(1, 5)
      local events = world.sent("sensor")
      assert(#events == 1 and events[1].action == "enter" and events[1].sensor_id == "SEN-2")
      assert_clean(world)
    end)
  end,

  test_a_station_starts_and_draws_its_monitor = function()
    local station = create_station()
    with_node("station", { id = "ST-1", role = "station", create_station_name = "Hauptbahnhof", display_name = "Hauptbahnhof", station_type = "mixed" },
      { Create_Station_0 = { type = "Create_Station", methods = { "getStationName", "isTrainPresent", "setSchedule" }, object = station } }, function(world)
      assert_alive(world)
      world.command({ cmd = "set_station_message", message = "Gleis 1" })
      assert(world.monitor.text():find("Hauptbahnhof", 1, true) or world.monitor.text() ~= "", "the station shows something")
      assert_clean(world)
    end)
  end,

  test_a_node_sets_the_text_scale_of_its_entry_on_its_monitor = function()
    with_node("depot", { id = "DEPOT-1", role = "depot", display_name = "Depot 1", depot_type = "mixed", monitor_scale = 0.5 }, nil, function(world)
      assert(world.monitor.surface.scale == 0.5, tostring(world.monitor.surface.scale))
      assert_clean(world)
    end)
    with_node("panel", { id = "PANEL-1", role = "panel", monitor_scale = 2 }, nil, function(world)
      assert(world.monitor.surface.scale == 2)
      assert_clean(world)
    end)
    with_node("depot", { id = "DEPOT-1", role = "depot", display_name = "Depot 1", depot_type = "mixed" }, nil, function(world)
      assert(world.monitor.surface.scale == nil, "no key, no change")
    end)
  end,

  test_a_depot_starts_and_draws_its_monitor = function()
    with_node("depot", { id = "DEPOT-1", role = "depot", display_name = "Depot 1", depot_type = "mixed" }, nil, function(world)
      assert_alive(world)
      assert_clean(world)
    end)
  end,

  test_a_train_computer_starts_and_draws_its_monitor = function()
    local station = create_station()
    with_node("train", { id = "TRAIN-1", role = "train", create_station = "Create_Station_0", schedule_station = "Create_Station_0" },
      { Create_Station_0 = { type = "Create_Station", methods = { "getStationName", "isTrainPresent", "setSchedule" }, object = station } }, function(world)
      assert_alive(world)
      assert_clean(world)
    end)
  end,

  test_a_panel_starts_and_draws_its_monitor = function()
    with_node("panel", { id = "PANEL-1", role = "panel" }, nil, function(world)
      assert_alive(world)
      assert_clean(world)
    end)
  end,

  test_a_panel_without_the_level_sends_no_critical_action_and_asks_twice_for_one_it_may_send = function()
    local entry = { id = "PANEL-1", role = "panel", permission = "operate", pages = { "manual" }, manual_actions = { { label = "Halt", action = "hold_train", train_id = "T1" }, { label = "Freigabe", action = "release_train", train_id = "T1" } } }
    with_node("panel", entry, nil, function(world)
      world.command({ cmd = "panel_update", master_state = "ONLINE" })
      local function touch(row) world.node.handle_event({ "monitor_touch", "monitor_0", 5, row }) end
      touch(7)
      assert(#world.sent("manual_control") == 1, "operate may hold a train at once")
      touch(8); touch(8)
      assert(#world.sent("manual_control") == 1, "admin action is not sent by an operate panel")
    end)
    entry.permission = "admin"
    with_node("panel", entry, nil, function(world)
      world.command({ cmd = "panel_update", master_state = "ONLINE" })
      local function touch(row) world.node.handle_event({ "monitor_touch", "monitor_0", 5, row }) end
      touch(8)
      assert(#world.sent("manual_control") == 0, "a critical action waits for the second touch")
      touch(8)
      local sent = world.sent("manual_control")
      assert(#sent == 1 and sent[1].confirm == true and sent[1].action == "release_train", "second touch sends with confirm")
      touch(8)
      world.command({ cmd = "panel_update", master_state = "ONLINE" })
      world.advance(5); world.command({ cmd = "panel_update", master_state = "ONLINE" })
      world.advance(5); world.command({ cmd = "panel_update", master_state = "ONLINE" })
      world.advance(5); world.command({ cmd = "panel_update", master_state = "ONLINE" })
      touch(8)
      assert(#world.sent("manual_control") == 1, "a second touch after the window starts over and sends nothing")
    end)
  end,

  test_a_panel_that_has_not_heard_its_master_sends_no_manual_action = function()
    local entry = { id = "PANEL-1", role = "panel", pages = { "manual" }, manual_actions = { { label = "Halt", action = "hold_train", train_id = "T1" } } }
    with_node("panel", entry, nil, function(world)
      world.node.handle_event({ "monitor_touch", "monitor_0", 5, 7 })
      assert(#world.sent("manual_control") == 0, "offline: nothing is sent")
      world.command({ cmd = "panel_update", master_state = "ONLINE" })
      world.node.handle_event({ "monitor_touch", "monitor_0", 5, 7 })
      assert(#world.sent("manual_control") == 1, "online again")
      world.advance(11)
      world.node.handle_event({ "monitor_touch", "monitor_0", 5, 7 })
      assert(#world.sent("manual_control") == 1, "silent master: offline again")
    end)
  end,

  test_a_node_with_no_modem_says_so_and_does_not_crash = function()
    local restore = strict_cc.install({ peripheral = strict_cc.peripheral({}), window = strict_cc.window_api(), redstone = strict_cc.redstone() })
    local ok, err = pcall(function()
      local path = plan_file("signal", { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" })
      local bootstrap = require("src.nodes.bootstrap")
      local context = bootstrap.create_context({ "--id", "SIG-1", "--config", path }, "signal")
      context.clock = function() return 1000 end
      context.start_timer = function() return 1 end
      local node = require("src.nodes.signal_node").new_runtime(context)
      node.start()
      node.handle_event({ "timer", 1 })
      local logged = false
      for _, entry in ipairs(context.logger.get_buffer()) do if entry.msg == "node modem open failed" then logged = true end end
      assert(logged, "the missing modem is in the log")
    end)
    restore()
    cleanup()
    assert(ok, tostring(err))
  end,
}
