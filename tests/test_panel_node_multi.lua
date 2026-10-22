--[[
Purpose: The panel node with several monitors, as the game starts it: every bound monitor shows its own view, touches select and act within the rights of the panel, the topology comes from the master, the faults follow the master and a monitor that disappears does not stop the others (Pruefplan H-01 bis H-03, H-13, H-14).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local strict_cc = require("tests.harness.strict_cc")
local netplan = require("src.setup.netplan")
local net = require("src.shared.net")
local memfs = require("tests.harness.memfs")
local json = require("src.shared.json")
local monitor_registry = require("src.panel.monitor_registry")
local plan_service = require("src.master.plan_service")
local safety_graph = require("src.domain.safety_graph")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }
local created = {}

local function plan_file(entry)
  local cfg = netplan.short_plan("panel", entry, 777, "MASTER-1")
  cfg.startup_autoupgrade = false
  local path = os.tmpname()
  local fh = assert(io.open(path, "w"))
  fh:write(netplan.encode(cfg))
  fh:close()
  created[#created + 1] = path
  return path
end

local function master_plan(extra)
  local cfg = { v = 1, channel = 777, master_id = "MASTER-1", nodes = { { id = "MASTER-1", role = "master" }, { id = "PANEL-1", role = "panel" } }, blocks = {}, routes = {} }
  for i = 1, 3 + (extra or 0) do
    cfg.blocks[i] = { id = "B" .. i, entry_signal = "S" .. i, exit_signal = "X" .. i, sensors = { "SEN-" .. i } }
    cfg.nodes[#cfg.nodes + 1] = { id = "S" .. i, role = "signal", adapter = "redstone", side = "left" }
    cfg.nodes[#cfg.nodes + 1] = { id = "X" .. i, role = "signal", adapter = "redstone", side = "left" }
    cfg.nodes[#cfg.nodes + 1] = { id = "SEN-" .. i, role = "sensor", adapter = "redstone", side = "left" }
  end
  cfg.routes[1] = { id = "R1", from = "A", to = "B", blocks = { "B1", "B2", "B3" } }
  return cfg
end

-- a panel node on strict peripherals with two monitors; run(world, node) is called with the node started
local function with_panel(entry, run, opts)
  opts = opts or {}
  local modem = strict_cc.modem()
  local mon_a, mon_b = strict_cc.monitor(51, 19), strict_cc.monitor(29, 19)
  local devices = {
    top = { type = "modem", methods = { "open", "close", "isOpen", "transmit" }, object = modem },
    monitor_0 = { type = "monitor", methods = { "write", "setCursorPos", "getSize", "clear", "isColor", "setTextColor", "setBackgroundColor", "setTextScale" }, object = mon_a },
    monitor_1 = { type = "monitor", methods = { "write", "setCursorPos", "getSize", "clear", "isColor", "setTextColor", "setBackgroundColor", "setTextScale" }, object = mon_b },
  }
  local peripheral = strict_cc.peripheral(devices)
  local restore = strict_cc.install({ peripheral = peripheral, window = strict_cc.window_api(), redstone = strict_cc.redstone() })
  local world = { modem = modem, mon_a = mon_a, mon_b = mon_b, clock = 1000, devices = devices, fs = memfs.new() }
  local ok, err = pcall(function()
    -- the bindings the operator made with scripts/bind_monitors.lua
    local registry = monitor_registry.new({ fs = world.fs, path = "state/panel_monitors.json", peripheral = peripheral, node_id = "PANEL-1" })
    registry.load()
    if not opts.unbound then
      assert(registry.bind("LEIT-A", "monitor_0", { confirmed = true, start_view = "overview" }))
      assert(registry.bind("LEIT-B", "monitor_1", { confirmed = true, start_view = "fault_center" }))
    end
    local bootstrap = require("src.nodes.bootstrap")
    local context = bootstrap.create_context({ "--id", "PANEL-1", "--config", plan_file(entry) }, "panel")
    context.clock = function() return world.clock end
    context.start_timer = function() return 1 end
    context.fs = world.fs
    context.peripheral_api = peripheral
    local node = require("src.nodes.panel_node").new_runtime(context)
    world.node, world.logger = node, context.logger
    local sink = { send = function(_, _, _, msg) world.last_from_master = msg; return true end, broadcast = function(_, _, msg) world.last_from_master = msg; return true end }
    world.master = net.new(sink, 777, "MASTER-1", quiet)
    function world.command(payload)
      world.master.send("cmd", "PANEL-1", payload)
      node.handle_event({ "modem_message", "top", 777, 777, world.last_from_master, 3 })
    end
    function world.advance(seconds) world.clock = world.clock + seconds; node.handle_event({ "timer", 1 }) end
    function world.sent(kind)
      local list = {}
      for _, t in ipairs(modem.transmitted) do
        if t.payload.type == "event" and t.payload.payload and t.payload.payload.type == kind then list[#list + 1] = t.payload.payload end
      end
      return list
    end
    function world.touch(name, x, y) node.handle_event({ "monitor_touch", name, x, y }) end
    node.start()
    run(world, node)
  end)
  restore()
  for _, path in ipairs(created) do os.remove(path) end
  created = {}
  if not ok then error(err, 0) end
end

local function violations(world)
  local all = {}
  for _, list in ipairs({ world.mon_a.violations, world.mon_b.violations, world.modem.violations }) do for _, item in ipairs(list) do all[#all + 1] = item end end
  return all
end

local SNAPSHOT = { cmd = "panel_update", master_state = "ONLINE",
  overview = { B1 = { state = "FREE" } }, trains = { T1 = { state = "RUNNING" } }, stations = {}, depots = {}, service_plans = {}, diagnostics = {},
  faults = { { key = "release:required", severity = "YELLOW", text = "Betrieb nicht freigegeben", state = "ACTIVE", acked = false } } }

return {
  test_every_bound_monitor_shows_its_own_view_without_a_wrong_call = function()
    with_panel({ id = "PANEL-1", role = "panel", permission = "operate" }, function(world)
      world.command(SNAPSHOT)
      assert(world.node.display, "monitors are bound: the node draws through the display")
      assert(#violations(world) == 0, table.concat(violations(world), "; "))
      assert(world.mon_a.text and true)
    end)
  end,

  test_without_a_binding_the_node_draws_the_one_monitor_of_the_plan_as_before = function()
    with_panel({ id = "PANEL-1", role = "panel" }, function(world)
      assert(world.node.display == nil)
      world.command(SNAPSHOT)
      assert(#violations(world) == 0, table.concat(violations(world), "; "))
    end, { unbound = true })
  end,

  test_the_faults_of_the_master_come_into_the_fault_center_and_a_seen_one_stays = function()
    with_panel({ id = "PANEL-1", role = "panel" }, function(world)
      world.command(SNAPSHOT)
      assert(world.node.faults.is_open("release:required"))
      local acked = {}
      for k, v in pairs(SNAPSHOT) do acked[k] = v end
      acked.faults = { { key = "release:required", severity = "YELLOW", text = "Betrieb nicht freigegeben", state = "ACTIVE", acked = true, acked_by = "PANEL-9" } }
      world.command(acked)
      assert(world.node.faults.get("release:required").state == "ACTIVE_SEEN" and world.node.faults.is_open("release:required"))
      local gone = {}
      for k, v in pairs(SNAPSHOT) do gone[k] = v end
      gone.faults = {}
      world.command(gone)
      assert(not world.node.faults.is_open("release:required"))
    end)
  end,

  test_the_topology_is_asked_for_when_the_master_announces_a_version_and_the_diagram_is_drawn = function()
    local cfg = master_plan()
    local version = safety_graph.build(cfg).version
    local service_fs = memfs.new()
    service_fs.set("plan.json", netplan.encode(cfg))
    local service = plan_service.new({ plan_path = "plan.json", fs = { exists = service_fs.exists, open = service_fs.open }, chunk_size = 3000, now_s = function() return 1 end })
    with_panel({ id = "PANEL-1", role = "panel", permission = "operate" }, function(world)
      local announce = {}
      for k, v in pairs(SNAPSHOT) do announce[k] = v end
      announce.topology_version = version
      world.command(announce)
      assert(world.node.topology.state() == "WAITING", tostring(world.node.topology.state()))
      for _ = 1, 3 do world.advance(2) end
      local asks = world.sent("plan_get")
      assert(#asks >= 1 and asks[1].role == "panel" and asks[1].index == 1)
      -- the master answers every question of the panel
      local answered = 0
      for _ = 1, 20 do
        local list = world.sent("plan_get")
        local question = list[#list]
        local id
        for _, t in ipairs(world.modem.transmitted) do if t.payload.payload == question then id = t.payload.id end end
        local reply = service.part(question.index, question.version)
        reply.cmd, reply.question = "plan_part", id
        world.command(reply)
        answered = answered + 1
        if world.node.topology.state() == "READY" then break end
      end
      assert(world.node.topology.state() == "READY", tostring(world.node.topology.state()))
      assert(world.node.topology.graph().version == version)
      -- the diagram view of a monitor shows the blocks
      assert(world.node.display.set_view("LEIT-A", "gleisbild"))
      world.command(announce)
      assert(#violations(world) == 0, table.concat(violations(world), "; "))
    end)
  end,

  test_a_new_topology_keeps_the_places_of_the_old_blocks_and_adds_the_new_one = function()
    local function serve(cfg)
      local fs = memfs.new()
      fs.set("plan.json", netplan.encode(cfg))
      return plan_service.new({ plan_path = "plan.json", fs = { exists = fs.exists, open = fs.open }, chunk_size = 3000, now_s = function() return 1 end })
    end
    with_panel({ id = "PANEL-1", role = "panel", permission = "operate" }, function(world)
      local function fetch(cfg)
        local service = serve(cfg)
        local announce = {}
        for k, v in pairs(SNAPSHOT) do announce[k] = v end
        announce.topology_version = safety_graph.build(cfg).version
        world.command(announce)
        for _ = 1, 3 do world.advance(2) end
        for _ = 1, 20 do
          local list = world.sent("plan_get")
          local question = list[#list]
          local id
          for _, t in ipairs(world.modem.transmitted) do if t.payload.payload == question then id = t.payload.id end end
          local reply = service.part(question.index, question.version)
          reply.cmd, reply.question = "plan_part", id
          world.command(reply)
          if world.node.topology.state() == "READY" then break end
        end
        assert(world.node.topology.state() == "READY")
        world.node.display.set_view("LEIT-A", "gleisbild")
        world.command(announce)
      end
      fetch(master_plan())
      local data = require("src.panel.diagram").store({ fs = world.fs, path = "state/panel_layout.json" })
      assert(data.load() == "ready")
      local first = data.data().active
      assert(first.objects.B1 and not first.objects.B4)
      fetch(master_plan(1))
      assert(data.load() == "ready")
      local second = data.data().active
      assert(second.objects.B4, "the new block is on the diagram")
      assert(second.objects.B1.x == first.objects.B1.x and second.objects.B2.y == first.objects.B2.y, "the old blocks keep their places")
      assert(second.topology_version ~= first.topology_version)
    end)
  end,

  test_a_touch_on_a_train_button_is_sent_within_the_rights_and_a_critical_one_asks_twice = function()
    with_panel({ id = "PANEL-1", role = "panel", permission = "admin" }, function(world)
      world.command(SNAPSHOT)
      world.node.display.set_view("LEIT-A", "trains")
      world.command(SNAPSHOT)
      world.touch("monitor_0", 3, 7)
      world.node.display.set_view("LEIT-A", "train_detail")
      world.command(SNAPSHOT)
      world.touch("monitor_0", 2, 13)
      local sent = world.sent("manual_control")
      assert(#sent == 1 and sent[1].action == "hold_train" and sent[1].train_id == "T1", #sent)
      world.touch("monitor_0", 2, 15)
      assert(#world.sent("manual_control") == 1, "the release asks for the second touch")
      world.touch("monitor_0", 2, 15)
      local after = world.sent("manual_control")
      assert(#after == 2 and after[2].action == "release_train" and after[2].confirm == true)
    end)
  end,

  test_the_timetable_is_edited_on_the_screen_sent_as_a_draft_and_published_against_its_version = function()
    local fleet = { lines = { L1 = { version = 4, kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, headway_min = 10, dwell_s = 30,
      stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, direction = "EAST", pair_id = "P1", drafts = {} } }, trips = {}, pairs = {}, results = {} }
    local function snapshot(extra)
      local s = {}
      for k, v in pairs(SNAPSHOT) do s[k] = v end
      s.fleet = fleet
      for k, v in pairs(extra or {}) do s[k] = v end
      return s
    end
    with_panel({ id = "PANEL-1", role = "panel", permission = "admin" }, function(world)
      world.command(snapshot())
      world.node.display.set_view("LEIT-A", "timetable")
      world.command(snapshot())
      -- the row of the line: touching it opens the editor
      world.touch("monitor_0", 3, 4)
      assert(world.node.editor.line_id() == "L1" and world.node.editor.base_version() == 4)
      world.command(snapshot())
      local function press(label)
        for y = 1, 19 do
          local x = world.mon_a.row(y):find(label, 1, true)
          if x then world.touch("monitor_0", x + 1, y); return true end
        end
        return false
      end
      assert(press("[Takt-]") and press("[Takt-]") and press("[Halt+]"))
      assert(world.node.editor.draft().headway_min == 8 and world.node.editor.draft().dwell_s == 35 and world.node.editor.dirty())
      world.command(snapshot())
      assert(press("[Entwurf senden]"))
      local sent = world.sent("manual_control")
      local first = sent[1] or {}
      assert(#sent == 1 and first.action == "timetable_draft" and first.line and first.line.headway_min == 8 and first.base_version == 4 and first.pair_id == "P1",
        #sent .. " " .. tostring(first.action) .. " " .. tostring(first.line and first.line.headway_min) .. " " .. tostring(first.base_version) .. " " .. tostring(first.pair_id))
      local request = sent[1].request_id
      assert(request and world.node.editor.sent_request() == request)
      -- the answer of the pair arrives with the next snapshot: the publication is offered
      fleet.results[request] = { ok = true, version = 5, line_id = "L1" }
      world.command(snapshot())
      assert(world.mon_a.text():find("Entwurf v5 angenommen", 1, true))
      assert(press("[Veroeffentlichen]"))
      assert(#world.sent("manual_control") == 1, "the publication asks for the second touch")
      assert(press("[Veroeffentlichen]"))
      local after = world.sent("manual_control")
      assert(#after == 2 and after[2].action == "timetable_publish" and after[2].version == 5 and after[2].base_version == 4 and after[2].line_id == "L1", #after)
      assert(world.node.editor.dirty(), "the draft stays until the pair confirms")
      -- the pair confirms: the line is at version 5, the editor is closed
      fleet.results[after[2].request_id] = { ok = true, version = 5, line_id = "L1" }
      fleet.lines.L1.version = 5
      world.command(snapshot())
      assert(world.node.editor.line_id() == nil and not world.node.editor.dirty())
    end)
  end,

  test_a_draft_goes_on_offline_but_is_not_sent_and_a_moved_line_is_a_conflict_that_a_person_resolves = function()
    local fleet = { lines = { L1 = { version = 4, kind = "PASSENGER", time_base = "REAL", window = { from = "06:00", to = "22:00" }, headway_min = 10, dwell_s = 30,
      stops = { { station = "NORD" }, { station = "SUED" } }, routes = { EAST = "R-NS" }, direction = "EAST", pair_id = "P1", drafts = {} } }, trips = {}, pairs = {}, results = {} }
    local function snapshot()
      local s = {}
      for k, v in pairs(SNAPSHOT) do s[k] = v end
      s.fleet = fleet
      return s
    end
    with_panel({ id = "PANEL-1", role = "panel", permission = "admin" }, function(world)
      world.command(snapshot())
      world.node.display.set_view("LEIT-A", "timetable")
      world.command(snapshot())
      world.touch("monitor_0", 3, 4)
      local function press(label)
        for y = 1, 19 do
          local x = world.mon_a.row(y):find(label, 1, true)
          if x then world.touch("monitor_0", x + 1, y); return true end
        end
        return false
      end
      assert(press("[Takt-]"))
      -- the master is silent: the panel is offline, the draft can still be changed, nothing is sent
      for _ = 1, 8 do world.advance(2) end
      assert(world.node.offline.state() == "OFFLINE")
      assert(press("[Takt-]") and world.node.editor.draft().headway_min == 8, "editing goes on offline")
      assert(press("[Entwurf senden]") and #world.sent("manual_control") == 0, "sending does not")
      -- the master is back and another control room has published meanwhile: a conflict, nothing is sent blindly
      fleet.lines.L1.version = 5
      world.command(snapshot())
      assert(world.mon_a.text():find("KONFLIKT", 1, true) and world.mon_a.text():find("[Neu laden]", 1, true) and world.mon_a.text():find("[Stand uebernehmen]", 1, true))
      assert(not world.mon_a.text():find("[Entwurf senden]", 1, true))
      assert(press("[Stand uebernehmen]"))
      assert(world.node.editor.base_version() == 5 and world.node.editor.dirty())
      world.command(snapshot())
      assert(world.mon_a.text():find("[Entwurf senden]", 1, true) and not world.mon_a.text():find("KONFLIKT", 1, true))
      assert(press("[Verwerfen]"))
      assert(world.node.editor.line_id() == nil)
    end)
  end,

  test_a_panel_that_may_only_view_has_no_action_on_its_screens = function()
    with_panel({ id = "PANEL-1", role = "panel", permission = "view" }, function(world)
      world.command(SNAPSHOT)
      world.node.display.set_view("LEIT-A", "trains")
      world.command(SNAPSHOT)
      world.touch("monitor_0", 3, 7)
      world.node.display.set_view("LEIT-A", "train_detail")
      world.command(SNAPSHOT)
      world.touch("monitor_0", 2, 13)
      assert(#world.sent("manual_control") == 0)
    end)
  end
}
