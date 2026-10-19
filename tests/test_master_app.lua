--[[
Purpose: The master as the game starts it: src/master/app.lua with the real wiring, on peripherals that check their arguments like the ones in
  CC:Tweaked (tests/harness/strict_cc.lua). Nothing else of the suite starts the application, and the other fakes accept any call, so a modem
  that is asked wrongly, a monitor that gets a fraction as a position or a page that raises would be found out in the game only.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local strict_cc = require("tests.harness.strict_cc")
local plan_bus = require("tests.harness.plan_bus")

local created = {}

local function write_file(path, text)
  local fh = assert(io.open(path, "w"))
  fh:write(text)
  fh:close()
  created[#created + 1] = path
end

-- the full example, with the state file and the files of the repository left alone
local function plan_path()
  local text = plan_bus.template("network.full.example.json")
  local state = os.tmpname()
  os.remove(state)
  created[#created + 1] = state
  created[#created + 1] = state .. ".prev"
  created[#created + 1] = state .. ".tmp"
  local patched, count = text:gsub('"v": 1,', '"v": 1, "startup_autoupgrade": false, "state_file": "' .. state .. '",', 1)
  assert(count == 1, "the example starts with its version")
  local path = os.tmpname()
  write_file(path, patched)
  return path
end

local function cleanup()
  for _, path in ipairs(created) do os.remove(path) end
  created = {}
end

-- a master on strict peripherals; run(world) is called with the application in place; the globals are restored afterwards
local function with_master(opts, run)
  local o = opts or {}
  local modem = strict_cc.modem()
  local monitor = strict_cc.monitor(o.w or 51, o.h or 19)
  local redstone = strict_cc.redstone()
  local devices = {
    top = { type = "modem", methods = { "open", "close", "isOpen", "transmit" }, object = modem },
    monitor_0 = { type = "monitor", methods = { "write", "setCursorPos", "getSize", "clear", "isColor", "setTextColor", "setBackgroundColor" }, object = monitor },
  }
  local restore = strict_cc.install({ peripheral = strict_cc.peripheral(devices), window = o.no_window and nil or strict_cc.window_api(), redstone = redstone })
  local world = { modem = modem, monitor = monitor, redstone = redstone }
  local ok, err = pcall(function()
    package.loaded["src.master.app"] = nil
    local app = require("src.master.app")
    world.path = plan_path()
    world.instance = app.new({ config = world.path, id = "MASTER-1" })
    run(world)
  end)
  restore()
  cleanup()
  if not ok then error(err, 0) end
end

local function violations_of(world)
  local all = {}
  for _, list in ipairs({ world.monitor.violations, world.modem.violations, world.redstone.violations }) do
    for _, item in ipairs(list) do all[#all + 1] = item end
  end
  return all
end

local function sent_by_the_nodes(world, messages)
  local runtime = world.instance.runtime
  for index, msg in ipairs(messages) do
    msg.v, msg.pv, msg.id, msg.dst = 1, 4, msg.src .. ".test." .. index, "MASTER-1"
    runtime.handle_event({ "modem_message", "top", 777, 777, msg, 4 })
  end
end

local function every_node_online(world)
  local messages = {}
  for _, node in ipairs(world.instance.context.config.nodes) do
    if node.role ~= "master" then
      messages[#messages + 1] = { src = node.id, type = "register", payload = { role = node.role } }
      messages[#messages + 1] = { src = node.id, type = "heartbeat", payload = { role = node.role } }
    end
  end
  sent_by_the_nodes(world, messages)
end

local function pages(world) return world.instance.context.ui.page_order end

local function problems_of(world)
  local list = {}
  for _, entry in ipairs(world.instance.context.logger.get_buffer()) do
    if entry.level == "WARN" or entry.level == "ERROR" then list[#list + 1] = entry end
  end
  return list
end

return {
  test_the_master_opens_the_channel_of_its_plan_on_a_modem_that_checks_its_arguments = function()
    with_master({}, function(world)
      assert(world.modem.opened[777], "the channel is open")
      assert(#world.modem.violations == 0, table.concat(world.modem.violations, "; "))
    end)
  end,

  test_the_master_answers_a_node_through_the_same_modem = function()
    with_master({}, function(world)
      -- a signal node of the plan registers: the master acknowledges it on the channel, with numbers as channel and reply channel
      sent_by_the_nodes(world, { { src = "SIG-AB-IN", type = "register", payload = { role = "signal" } } })
      assert(#world.modem.transmitted >= 1, "the master said something")
      for _, sent in ipairs(world.modem.transmitted) do
        assert(sent.channel == 777 and type(sent.reply) == "number" and type(sent.payload) == "table" and sent.payload.dst ~= nil)
      end
      assert(#world.modem.violations == 0, table.concat(world.modem.violations, "; "))
    end)
  end,

  test_every_page_draws_without_a_single_wrong_call = function()
    with_master({}, function(world)
      local ui = world.instance.context.ui
      assert(#pages(world) >= 13, "all pages are there: " .. table.concat(pages(world), ","))
      for _, name in ipairs(pages(world)) do
        ui.set_panel(name)
        ui.draw()
        assert(ui.last_error == nil, name .. ": " .. tostring(ui.last_error and ui.last_error.error))
        assert(world.monitor.text() ~= "", name .. ": the page shows something")
      end
      assert(#violations_of(world) == 0, table.concat(violations_of(world), "; "))
    end)
  end,

  test_with_every_node_online_the_pages_still_draw_cleanly = function()
    with_master({}, function(world)
      every_node_online(world)
      local ui = world.instance.context.ui
      for _, name in ipairs(pages(world)) do
        ui.set_panel(name)
        ui.mark_dirty()
        ui.draw()
        assert(ui.last_error == nil, name .. ": " .. tostring(ui.last_error and ui.last_error.error))
      end
      assert(#violations_of(world) == 0, table.concat(violations_of(world), "; "))
    end)
  end,

  test_a_touch_anywhere_on_any_page_raises_nothing_and_asks_nothing_wrong = function()
    with_master({}, function(world)
      every_node_online(world)
      local ui = world.instance.context.ui
      for _, name in ipairs(pages(world)) do
        for y = 1, 19, 2 do
          for x = 3, 49, 4 do
            ui.set_panel(name)
            ui.handle_touch(x, y)
            ui.set_panel(name)
            ui.mark_dirty()
            ui.draw()
            assert(ui.last_error == nil, name .. " after a touch at " .. x .. "," .. y .. ": " .. tostring(ui.last_error and ui.last_error.error))
          end
        end
      end
      assert(#violations_of(world) == 0, table.concat(violations_of(world), "; "))
      for _, entry in ipairs(world.instance.context.logger.get_buffer()) do
        assert(entry.msg ~= "panel touch failed" and entry.msg ~= "panel draw failed", entry.msg)
      end
    end)
  end,

  test_small_monitors_are_drawn_without_wrong_calls_too = function()
    for _, size in ipairs({ { 29, 19 }, { 36, 13 }, { 18, 12 }, { 15, 10 } }) do
      with_master({ w = size[1], h = size[2] }, function(world)
        every_node_online(world)
        local ui = world.instance.context.ui
        for _, name in ipairs(pages(world)) do
          ui.set_panel(name)
          ui.mark_dirty()
          ui.draw()
          assert(ui.last_error == nil, size[1] .. "x" .. size[2] .. " " .. name .. ": " .. tostring(ui.last_error and ui.last_error.error))
        end
        assert(#violations_of(world) == 0, size[1] .. "x" .. size[2] .. ": " .. table.concat(violations_of(world), "; "))
      end)
    end
  end,

  test_without_the_window_api_the_pages_draw_on_the_monitor_itself = function()
    with_master({ no_window = true }, function(world)
      local ui = world.instance.context.ui
      ui.set_panel("status")
      ui.draw()
      assert(ui.last_error == nil and world.monitor.text() ~= "")
      assert(#violations_of(world) == 0, table.concat(violations_of(world), "; "))
    end)
  end,

  test_signals_are_driven_with_the_redstone_the_game_has = function()
    with_master({}, function(world)
      every_node_online(world)
      -- the master puts the signals of its plan to RED when it stops: sides and values must be what redstone.setOutput takes
      local failed = world.instance.context.dispatcher.shutdown_red()
      assert(failed == 0, "signals that did not take their output: " .. tostring(failed))
      assert(#world.redstone.violations == 0, table.concat(world.redstone.violations, "; "))
    end)
  end,

  test_nothing_in_the_log_is_a_warning_after_a_normal_start = function()
    with_master({}, function(world)
      every_node_online(world)
      local ui = world.instance.context.ui
      for _, name in ipairs(pages(world)) do ui.set_panel(name); ui.mark_dirty(); ui.draw() end
      local problems = problems_of(world)
      local text = {}
      for _, entry in ipairs(problems) do text[#text + 1] = tostring(entry.msg) end
      assert(#problems == 0, table.concat(text, "; "))
    end)
  end,
}
