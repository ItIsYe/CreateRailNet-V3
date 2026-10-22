--[[
Purpose: A command with an effect in the world is carried out once even when the sender repeats it after a restart of the node (Gesamtkonzept Kap. 7.3, 12.2).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local common_node = require("src.nodes.common_node")
local journal = require("src.shared.journal")
local idempotency = require("src.shared.idempotency")
local memfs = require("tests.harness.memfs")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

local function make_node(fs, opts)
  opts = opts or {}
  local sent, ran = {}, {}
  local modem = {
    open = function() return true end,
    send = function(_, _, _, msg) sent[#sent + 1] = msg; return true end,
    broadcast = function(_, _, msg) sent[#sent + 1] = msg; return true end
  }
  local node = common_node.new({
    id = "T-1", role = "train", config = { channel = 1, master_id = "M", durable_commands = opts.durable }, modem = modem, logger = quiet,
    ledger = opts.ledger, journal_fs = fs, fence_fs = fs,
    handlers = { on_cmd = function(payload)
      ran[#ran + 1] = payload.cmd
      if payload.fail then return false, "schedule failed" end
      return true
    end }
  })
  return node, sent, ran
end

local function command(id, cmd, extra)
  local payload = { cmd = cmd }
  for k, v in pairs(extra or {}) do payload[k] = v end
  return { v = 1, id = id, src = "M", dst = "T-1", type = "cmd", payload = payload, ts = 0 }
end

local function last_answer(sent) return sent[#sent] end

return {
  test_a_schedule_command_runs_once_and_a_retry_after_a_restart_is_answered_without_running_again = function()
    local fs = memfs.new()
    local node, sent, ran = make_node(fs, { ledger = true })
    node.handle_message(command("M.boot1.7", "set_schedule"))
    assert(#ran == 1 and last_answer(sent).type == "ack" and last_answer(sent).payload.applied == true)
    -- the node restarts; the master never saw the ack and sends the same message again
    local again, sent2, ran2 = make_node(fs, { ledger = true })
    again.handle_message(command("M.boot1.7", "set_schedule"))
    assert(#ran2 == 0, "the schedule must not be set a second time")
    assert(last_answer(sent2).type == "ack" and last_answer(sent2).payload.applied == true, "but the sender gets its answer")
  end,

  -- the command_id of the commit barrier names the command itself: a resend with a new message id (or from the other master) is the same command
  test_the_same_command_id_is_carried_out_once_whatever_the_message_id = function()
    local fs = memfs.new()
    local node, _, ran = make_node(fs, { ledger = true })
    node.handle_message(command("M.boot1.7", "depart_authorized", { command_id = "12.1", election_epoch = 3, election_leader = "M" }))
    local again, sent2, ran2 = make_node(fs, { ledger = true })
    again.handle_message(command("M.boot2.1", "depart_authorized", { command_id = "12.1", election_epoch = 3, election_leader = "M" }))
    assert(#ran == 1 and #ran2 == 0, "carried out once")
    assert(last_answer(sent2).type == "ack" and last_answer(sent2).payload.applied == true)
    again.handle_message(command("M.boot2.2", "depart_authorized", { command_id = "12.1", election_epoch = 4, election_leader = "M" }))
    assert(#ran2 == 1, "the same index in another epoch is another command")
    again.handle_message(command("M.boot2.3", "depart_authorized", { command_id = "12.2", election_epoch = 4, election_leader = "M" }))
    assert(#ran2 == 2)
  end,

  test_a_failed_command_is_answered_with_the_same_error_after_a_restart = function()
    local fs = memfs.new()
    local node, sent = make_node(fs, { ledger = true })
    node.handle_message(command("M.b.1", "depart_authorized", { fail = true }))
    assert(last_answer(sent).type == "err" and last_answer(sent).payload.error == "schedule failed")
    local again, sent2, ran2 = make_node(fs, { ledger = true })
    again.handle_message(command("M.b.1", "depart_authorized", { fail = true }))
    assert(#ran2 == 0 and last_answer(sent2).type == "err" and last_answer(sent2).payload.error == "schedule failed")
  end,

  test_a_command_that_was_begun_but_never_finished_is_not_repeated_blindly = function()
    local fs = memfs.new()
    -- the node died between the record and the action: only the begin is in the journal
    local j = journal.new("state/node_commands.log", { fs = fs })
    j.open()
    idempotency.new({ journal = j }).begin("M/M.b.9")
    local node, sent, ran = make_node(fs, { ledger = true })
    node.handle_message(command("M.b.9", "set_schedule"))
    assert(#ran == 0, "the outcome is unknown: not carried out again")
    assert(last_answer(sent).type == "err" and last_answer(sent).payload.error:find("uncertain", 1, true))
  end,

  test_without_a_durable_record_the_command_is_refused = function()
    local fs = memfs.new()
    local node, sent, ran = make_node(fs, { ledger = true })
    fs.capacity = fs.used()
    node.handle_message(command("M.b.2", "set_schedule"))
    assert(#ran == 0 and last_answer(sent).type == "err" and last_answer(sent).payload.error:find("no durable record", 1, true))
  end,

  test_a_damaged_command_journal_refuses_the_durable_commands_but_not_the_others = function()
    local fs = memfs.new()
    local node = make_node(fs, { ledger = true })
    node.handle_message(command("M.b.1", "set_schedule"))
    node.handle_message(command("M.b.2", "set_schedule"))
    node.handle_message(command("M.b.3", "set_schedule"))
    fs.files["state/node_commands.log"] = fs.files["state/node_commands.log"]:gsub('"id":"M/M.b.2"', '"id":"M/M.b.X"', 1)
    local again, sent, ran = make_node(fs, { ledger = true })
    again.handle_message(command("M.b.4", "set_schedule"))
    assert(#ran == 0 and last_answer(sent).type == "err")
    again.handle_message(command("M.b.5", "hold_position"))
    assert(#ran == 1 and ran[1] == "hold_position" and last_answer(sent).type == "ack")
  end,

  test_commands_without_a_lasting_effect_do_not_touch_the_journal = function()
    local fs = memfs.new()
    local node, sent, ran = make_node(fs, { ledger = true })
    node.handle_message(command("M.b.1", "update_display"))
    node.handle_message(command("M.b.2", "hold_position"))
    assert(#ran == 2, "both ran; these are not bookkept")
    local text = fs.files["state/node_commands.log"] or ""
    assert(not text:find("idem_begin", 1, true))
  end,

  test_the_ledger_is_off_in_offline_tests_and_can_be_switched_on_or_off_by_the_config = function()
    local plain = make_node(memfs.new(), {})
    assert(plain.ledger == nil, "no _HOST: off unless asked for")
    local on = make_node(memfs.new(), { durable = true })
    assert(on.ledger ~= nil)
    local off = make_node(memfs.new(), { durable = false, ledger = nil })
    assert(off.ledger == nil)
    local forced_off = make_node(memfs.new(), { durable = true, ledger = false })
    assert(forced_off.ledger == nil)
    rawset(_G, "_HOST", "ComputerCraft test")
    local ok, in_game = pcall(make_node, memfs.new(), {})
    rawset(_G, "_HOST", nil)
    assert(ok and in_game.ledger ~= nil, "in the game it is on by default")
  end,

  test_the_command_journal_compacts_and_stays_small = function()
    local fs = memfs.new()
    local node, _, ran = make_node(fs, { ledger = true })
    for i = 1, 600 do node.handle_message(command("M.b." .. i, "set_schedule")) end
    assert(#ran == 600)
    assert(#fs.files["state/node_commands.log"] < 16000, "bounded, got " .. #fs.files["state/node_commands.log"])
    local again, _, ran2 = make_node(fs, { ledger = true })
    again.handle_message(command("M.b.600", "set_schedule"))
    again.handle_message(command("M.b.599", "set_schedule"))
    assert(#ran2 == 0, "recent commands are still remembered after compaction")
  end,

  test_the_command_journal_never_snapshots_above_the_cap = function()
    -- ids of 150 bytes: the 250 remembered commands would be a snapshot of about 47 000 bytes, above the cap of a computer with a fixed 1 MB
    local fs = memfs.new()
    local node = make_node(fs, { ledger = true })
    for i = 1, 600 do node.handle_message(command("M." .. string.rep("i", 140) .. "." .. i, "set_schedule")) end
    assert(fs.files["state/node_commands.log.snap"] == nil or #fs.files["state/node_commands.log.snap"] <= 30000, "snapshot " .. #(fs.files["state/node_commands.log.snap"] or ""))
    assert(#fs.files["state/node_commands.log"] <= 16100, "journal " .. #fs.files["state/node_commands.log"])
  end
}
