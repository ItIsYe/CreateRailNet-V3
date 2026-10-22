--[[
Purpose: The station node gives a train its schedule on the order of the fleet: only a train that stands on a platform with a Create station, with the Create name of the destination platform, once per command (Gesamtkonzept Kap. 7.1, 7.3).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local station_node = require("src.nodes.station_node")
local peripherals = require("src.adapter.peripherals")
local hardware_config = require("src.adapter.hardware_config")
local strict_cc = require("tests.harness.strict_cc")
local memfs = require("tests.harness.memfs")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function plan()
  return {
    v = 1, channel = 1, master_id = "MASTER-1", cmd_sources = { "FLEET-A" }, durable_commands = true,
    nodes = {
      { id = "MASTER-1", role = "master" }, { id = "FLEET-A", role = "fleet" },
      { id = "STATION-N", role = "station", station_id = "NORD", create_station_name = "Nord Hbf",
        platforms = { { id = "N1", sensor_id = "SEN-N1", create_station = "Create_Station_0", dwell_seconds = 20 }, { id = "N2", sensor_id = "SEN-N2" } } },
      { id = "STATION-S", role = "station", station_id = "SUED", create_station_name = "Sued Hbf",
        platforms = { { id = "P1", create_station_name = "Sued Gleis 1" }, { id = "P2", create_station_name = "Sued Gleis 2" } } }
    }
  }
end

local function build(opts)
  opts = opts or {}
  local sent, calls = {}, {}
  local station = { isTrainPresent = function() return opts.present ~= false end, setSchedule = function(schedule) calls[#calls + 1] = schedule; if opts.fail then error("create said no") end return true end }
  local devices = { Create_Station_0 = { type = "Create_Station", methods = { "isTrainPresent", "setSchedule" }, object = station }, modem_0 = { type = "modem", methods = {}, object = {} } }
  local modem = { open = function() return true end, send = function(_, _, _, msg) sent[#sent + 1] = msg; return true end, broadcast = function(_, _, msg) sent[#sent + 1] = msg; return true end }
  local cfg = plan()
  local node = station_node.new_runtime({ id = "STATION-N", role = "station", config = cfg, logger = quiet, peripherals = peripherals.new(strict_cc.peripheral(devices)), hardware = hardware_config.new(cfg), modem = modem,
    journal_fs = memfs.new(), fence_fs = memfs.new() })
  return node, sent, calls
end

local function order(extra)
  local p = { cmd = "apply_schedule", trip_id = "T1", leg_id = "T1/L1", command_id = "T1/C2", train_id = "TRAIN-1", destination = "SUED", platform = "P1", route_id = "R-NS" }
  for k, v in pairs(extra or {}) do p[k] = v end
  return { v = 1, id = "FLEET-A.x." .. (extra and extra.command_id or "1"), src = "FLEET-A", dst = "STATION-N", type = "cmd", payload = p, ts = 0 }
end

return {
  test_the_schedule_goes_to_the_create_station_of_the_platform_the_train_stands_on_with_the_create_name_of_the_destination_platform = function()
    local node, sent, calls = build()
    -- the train is on platform N1 (set by the platform logic; here directly)
    local state_platforms = nil
    node.handle_message({ v = 1, id = "M.1", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N1", train_id = "TRAIN-1" }, ts = 0 })
    node.handle_message(order())
    assert(#calls == 1, "one setSchedule call")
    local entry = calls[1].entries[1]
    assert(entry.instruction.data.text == "Sued Gleis 1", entry.instruction.data.text)
    assert(entry.conditions[1][1].data.value == 20, "the dwell of the platform")
    local answer = sent[#sent]
    assert(answer.type == "ack" and answer.payload.applied == true)
  end,

  test_a_repeated_call_with_the_same_command_id_is_answered_not_made_again = function()
    local node, sent, calls = build()
    node.handle_message({ v = 1, id = "M.1", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N1", train_id = "TRAIN-1" }, ts = 0 })
    node.handle_message(order())
    local again = order(); again.id = "FLEET-A.y.1"      -- the fleet sent it once more with another message id
    node.handle_message(again)
    assert(#calls == 1, "setSchedule was called once: " .. #calls)
    assert(sent[#sent].type == "ack" and sent[#sent].payload.applied == true)
  end,

  test_a_train_that_is_not_on_a_platform_with_a_create_station_gets_no_schedule = function()
    local node, sent, calls = build()
    node.handle_message(order())
    assert(#calls == 0)
    local answer = sent[#sent]
    assert(answer.type == "err" and answer.payload.error:find("not on a platform", 1, true), tostring(answer.payload and answer.payload.error))
    -- on platform N2, which has no Create station
    node.handle_message({ v = 1, id = "M.2", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N2", train_id = "TRAIN-2" }, ts = 0 })
    node.handle_message(order({ command_id = "T1/C3", train_id = "TRAIN-2" }))
    assert(#calls == 0 and sent[#sent].type == "err")
  end,

  test_when_create_refuses_the_station_says_so_and_does_not_claim_success = function()
    local node, sent, calls = build({ fail = true })
    node.handle_message({ v = 1, id = "M.1", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N1", train_id = "TRAIN-1" }, ts = 0 })
    node.handle_message(order())
    assert(sent[#sent].type == "err" and sent[#sent].payload.error:find("create said no", 1, true), tostring(sent[#sent].payload and sent[#sent].payload.error))
  end,

  test_a_station_that_has_no_train_present_does_not_pretend = function()
    local node, sent, calls = build({ present = false })
    node.handle_message({ v = 1, id = "M.1", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N1", train_id = "TRAIN-1" }, ts = 0 })
    node.handle_message(order())
    assert(#calls == 0 and sent[#sent].type == "err" and sent[#sent].payload.error:find("no train present", 1, true), tostring(sent[#sent].payload and sent[#sent].payload.error))
  end,

  test_only_the_master_and_the_listed_fleet_nodes_may_order_a_schedule = function()
    local node, sent, calls = build()
    node.handle_message({ v = 1, id = "M.1", src = "MASTER-1", dst = "STATION-N", type = "cmd", payload = { cmd = "reserve_platform", platform_id = "N1", train_id = "TRAIN-1" }, ts = 0 })
    local stranger = order(); stranger.src = "FLEET-X"; stranger.id = "FLEET-X.1"
    node.handle_message(stranger)
    assert(#calls == 0 and sent[#sent].type == "err" and sent[#sent].payload.error:find("not allowed", 1, true))
  end,

  test_the_destination_name_falls_back_to_the_station_and_then_to_the_id = function()
    local cfg = plan()
    assert(station_node.destination_name(cfg, "SUED", "P2") == "Sued Gleis 2")
    assert(station_node.destination_name(cfg, "SUED", "PX") == "Sued Hbf")
    assert(station_node.destination_name(cfg, "NORD", "N9") == "Nord Hbf")
    assert(station_node.destination_name(cfg, "UNKNOWN", "P1") == "UNKNOWN")
  end
}
