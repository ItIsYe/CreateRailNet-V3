--[[
Purpose: A duplicate of a reliable message means the sender never saw our answer; answer again without redoing the work.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local common_node = require("src.nodes.common_node")
local runtime_factory = require("src.master.runtime")

local function sent_modem(log)
  return {
    open = function() return true end,
    send = function(_, _, _, m) log[#log + 1] = m; return true end,
    broadcast = function(_, _, m) log[#log + 1] = m; return true end
  }
end

local function node_with(on_cmd, log)
  return common_node.new({ id = "N1", role = "signal", config = { channel = 1, master_id = "M" }, modem = sent_modem(log), handlers = { on_cmd = on_cmd } })
end

local function count(log, message_type)
  local n = 0
  for _, m in ipairs(log) do if m.type == message_type then n = n + 1 end end
  return n
end

return {
  test_node_confirms_a_duplicate_command_again_without_applying_it_twice = function()
    local log, applied = {}, 0
    local node = node_with(function() applied = applied + 1; return true end, log)
    local msg = { v = 1, id = "m-1", src = "M", dst = "N1", type = "cmd", payload = { cmd = "set" } }
    node.handle_message(msg)
    node.handle_message(msg)
    node.handle_message(msg)
    assert(applied == 1, "applied " .. applied .. " times")
    assert(count(log, "ack") == 3, "every copy must be confirmed, got " .. count(log, "ack"))
  end,

  test_node_repeats_the_error_for_a_duplicate_of_a_failed_command = function()
    local log = {}
    local node = node_with(function() return false, "no such aspect" end, log)
    local msg = { v = 1, id = "m-2", src = "M", dst = "N1", type = "cmd", payload = { cmd = "set" } }
    node.handle_message(msg)
    node.handle_message(msg)
    assert(count(log, "err") == 2 and count(log, "ack") == 0, "a failed command must never be confirmed as done")
  end,

  test_node_stays_silent_for_duplicates_it_never_processed = function()
    local log = {}
    local node = node_with(function() return true end, log)
    node.net.dedup["m-3"] = 0
    node.handle_message({ v = 1, id = "m-3", src = "M", dst = "N1", type = "cmd", payload = {} })
    assert(#log == 0)
  end,

  test_master_confirms_a_duplicate_event_again_without_handling_it_twice = function()
    local acks, handled, statuses = 0, 0, { "ok", "duplicate", "duplicate" }
    local position = 0
    local rt = runtime_factory.new({
      config = { nodes = {} },
      registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = {
        receive = function() position = position + 1; return statuses[position] end,
        ack_for = function() acks = acks + 1 end, send = function() end, tick = function() end
      },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      train_registry = { update_status = function() handled = handled + 1 end, register = function() end },
      auto_restore_state = false, auto_save_state = false
    })
    local msg = { type = "event", src = "TRAIN-1", id = "e-1", payload = { type = "train_status", train_id = "TRAIN-1" } }
    for _ = 1, 3 do rt.handle_event({ "modem_message", nil, nil, nil, msg }) end
    assert(handled == 1, "handled " .. handled .. " times")
    assert(acks == 3, "every copy needs an ack, got " .. acks)
  end,

  test_master_does_not_answer_duplicate_heartbeats_or_acks = function()
    local acks = 0
    local rt = runtime_factory.new({
      config = { nodes = {} },
      registry = { all = function() return {} end, register = function() end, heartbeat = function() end },
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "duplicate" end, ack_for = function() acks = acks + 1 end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false
    })
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "heartbeat", src = "N1", id = "h-1", payload = {} } })
    rt.handle_event({ "modem_message", nil, nil, nil, { type = "ack", src = "N1", id = "a-1", payload = { ack_id = "x" } } })
    assert(acks == 0)
  end
}
