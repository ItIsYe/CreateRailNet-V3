--[[
Purpose: The link test (src/setup/linktest.lua) against the real master runtime on a bus that loses messages, delays them and drops large
  ones, and against scripted answers: what it counts, what it reports as the largest message that went through, and that it stops when
  nobody answers.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local link = require("src.setup.link")
local linktest = require("src.setup.linktest")
local netplan = require("src.setup.netplan")
local plan_bus = require("tests.harness.plan_bus")

local function size_of(value)
  if type(value) == "string" then return #value end
  local sum = 0
  if type(value) == "table" then for _, item in pairs(value) do sum = sum + size_of(item) end end
  return sum
end

-- a station of the full example, on a bus with a real master; run(b, m, ctx, probe) with probe = the link function the test uses
local function with_master(run)
  local b = plan_bus.new()
  local m = plan_bus.real_master(b, plan_bus.template("network.full.example.json"))
  local entry = netplan.find_node(m.cfg, "ST-B")
  local ctx = { id = "ST-B", role = "station", cfg = m.cfg, entry = entry }
  -- like plan_bus.puller, and the master's protocol repeats what was not acknowledged while time passes
  local function pull(timeout)
    m.step()
    m.network.tick()
    local msg = table.remove(b.inbox.client, 1)
    if msg then return { "modem_message", nil, nil, nil, msg } end
    b.clock = b.clock + timeout
    return nil
  end
  local function probe(opts)
    opts.modem, opts.pull_event, opts.time, opts.now = b.client_modem, pull, b.time, b.time.now_s
    return link.probe(opts)
  end
  run(b, m, ctx, probe)
end

return {
  test_a_clean_link_is_ok_and_carries_the_parts_of_the_plan = function()
    with_master(function(_, _, ctx, probe)
      local result = linktest.run(ctx, { link = probe, pings = 5 })
      assert(result.state == "ok", tostring(result.state))
      assert(result.sent == 5 and result.answered == 5 and result.quick == 5)
      assert(result.rtt_min and result.rtt_avg and result.rtt_max and result.rtt_min <= result.rtt_max)
      assert(result.largest == 4000 and result.part_ok == true, tostring(result.largest))
      assert(#result.sizes == 5 and result.sizes[5].ok)
    end)
  end,

  test_a_link_that_drops_large_messages_says_where_the_limit_is = function()
    with_master(function(b, _, ctx, probe)
      b.filter = function(msg) return size_of(msg) <= 2500 end
      local result = linktest.run(ctx, { link = probe, pings = 3 })
      assert(result.state == "ok", "small messages are fine: " .. tostring(result.state))
      assert(result.largest == 2048 and result.part_ok == false, tostring(result.largest))
      local last = result.sizes[#result.sizes]
      assert(last.bytes == 3300 and last.ok == false, "the ladder stops at the first size that does not go through")
      assert(#result.sizes == 4)
    end)
  end,

  test_one_direction_is_enough_to_fail_a_size = function()
    with_master(function(b, _, ctx, probe)
      -- only the answer of the master is too large for the link (the direction the plan parts travel)
      b.filter = function(msg, direction) return direction == "to_master" or size_of(msg) <= 1500 end
      local result = linktest.run(ctx, { link = probe, pings = 2 })
      assert(result.largest == 1024 and not result.part_ok, tostring(result.largest))
      b.filter = function(msg, direction) return direction == "to_client" or size_of(msg) <= 1500 end
      assert(linktest.run(ctx, { link = probe, pings = 2 }).largest == 1024, "and the other way round")
    end)
  end,

  -- an answer of the master (cmd pair_state) is lost on its first way and arrives with the repetition of the protocol
  test_lost_messages_are_counted_and_make_the_link_shaky = function()
    with_master(function(b, _, ctx, probe)
      local answers, lost = {}, 0
      b.filter = function(msg, direction)
        if direction ~= "to_client" or type(msg.payload) ~= "table" or msg.payload.cmd ~= "pair_state" then return true end
        if answers[msg.id] == nil then
          lost = lost + 1
          answers[msg.id] = (lost % 3 == 0)
        end
        return answers[msg.id]
      end
      -- an answer is lost for good unless it is the first of three: the master repeats it, the repetition has the same fate
      local result = linktest.run(ctx, { link = probe, pings = 9, sizes = {}, wait_s = 4 })
      assert(result.answered < 9 and result.answered >= 1, "some answers never came: " .. result.answered)
      assert(result.state == "shaky" or result.state == "bad", tostring(result.state))
    end)
  end,

  test_a_late_answer_is_counted_but_not_as_quick = function()
    with_master(function(b, _, ctx, probe)
      -- the first transmission of every answer is lost, the repetition (after 0.2 s of the protocol) arrives
      local first = {}
      b.filter = function(msg, direction)
        if direction ~= "to_client" or type(msg.payload) ~= "table" or msg.payload.cmd ~= "pair_state" then return true end
        if first[msg.id] then return true end
        first[msg.id] = true
        return false
      end
      local result = linktest.run(ctx, { link = probe, pings = 6, sizes = {}, wait_s = 4 })
      assert(result.answered == 6, "the protocol repeats: " .. result.answered)
      assert(result.quick == 0, "none at the first try: " .. result.quick)
      assert(result.state == "shaky" or result.state == "bad", "late is not ok: " .. tostring(result.state))
    end)
  end,

  test_one_answer_lost_in_ten_is_not_ok = function()
    with_master(function(b, _, ctx, probe)
      local seen, kept = {}, 0
      b.filter = function(msg, direction)
        if direction ~= "to_client" or type(msg.payload) ~= "table" or msg.payload.cmd ~= "pair_state" then return true end
        if seen[msg.id] == nil then
          kept = kept + 1
          seen[msg.id] = (kept ~= 4)
        end
        return seen[msg.id]
      end
      local result = linktest.run(ctx, { link = probe, pings = 10, sizes = {}, wait_s = 4 })
      assert(result.answered == 9 and result.quick == 9, result.answered .. " " .. result.quick)
      assert(result.state == "shaky", "9 of 10 is not ok: " .. tostring(result.state))
    end)
  end,

  test_a_link_that_loses_most_is_bad_and_one_that_loses_everything_is_none = function()
    with_master(function(b, _, ctx, probe)
      local seen, kept = {}, 0
      b.filter = function(msg, direction)
        if direction ~= "to_client" or type(msg.payload) ~= "table" or msg.payload.cmd ~= "pair_state" then return true end
        if seen[msg.id] == nil then
          kept = kept + 1
          seen[msg.id] = (kept % 5 == 0)
        end
        return seen[msg.id]
      end
      local bad = linktest.run(ctx, { link = probe, pings = 10, sizes = {}, wait_s = 4 })
      assert(bad.state == "bad", tostring(bad.state) .. " " .. bad.answered)
      assert(bad.answered == 2 and bad.sent == 10, "one in five: " .. bad.answered)
      b.filter = function() return false end
      local none = linktest.run(ctx, { link = probe, pings = 10, wait_s = 1 })
      assert(none.state == "none" and none.answered == 0 and none.aborted == true)
      assert(none.sent == 3, "three questions without any answer are enough: " .. none.sent)
      assert(none.sizes == nil and none.rtt_avg == nil)
    end)
  end,

  test_a_master_from_before_the_filler_is_called_old_and_no_size_is_claimed = function()
    local asked = 0
    local old = function(opts)
      asked = asked + 1
      return { state = "old_master", rtt_s = 0.05, echoed = 0 }
    end
    local result = linktest.run({ id = "X", role = "signal", cfg = { channel = 1, master_id = "M" }, entry = {} }, { link = old, pings = 4 })
    assert(result.state == "old_master" and result.sizes == nil and result.part_ok == nil)
    assert(asked == 4, "no filler is asked for")
  end,

  test_a_master_that_answers_without_filler_does_not_pass_a_size = function()
    local liar = function(opts)
      return { state = "known", rtt_s = 0.05, echoed = 0 }
    end
    local result = linktest.run({ id = "X", role = "signal", cfg = { channel = 1, master_id = "M" }, entry = {} }, { link = liar, pings = 2 })
    assert(result.state == "ok" and result.largest == 0 and result.part_ok == false)
    -- an answer with less filler than asked is a failed size too
    local short = function(opts)
      return { state = "known", rtt_s = 0.05, echoed = (opts.echo_bytes or 0) - 1 }
    end
    assert(linktest.run({ id = "X", role = "signal", cfg = { channel = 1, master_id = "M" }, entry = {} }, { link = short, pings = 1 }).largest == 0)
  end,

  test_no_modem_ends_the_test_at_once = function()
    local calls = 0
    local result = linktest.run({ id = "X", role = "signal", cfg = { channel = 1, master_id = "M" }, entry = {} },
      { link = function() calls = calls + 1; return { state = "no_modem" } end })
    assert(result.state == "no_modem" and calls == 1)
  end,

  test_a_link_function_that_raises_or_answers_nonsense_is_no_answer = function()
    local cfg = { id = "X", role = "signal", cfg = { channel = 1, master_id = "M" }, entry = {} }
    assert(linktest.run(cfg, { link = function() error("boom") end, pings = 3 }).state == "none")
    assert(linktest.run(cfg, { link = function() return "yes" end, pings = 3 }).state == "none")
    assert(linktest.run(cfg, { link = function() return { state = "known", rtt_s = "fast", echoed = {} } end, pings = 2, sizes = {} }).state == "ok", "a rtt that is no number counts as 0")
  end,

  test_the_probe_carries_what_the_computer_is = function()
    local seen
    local ctx = { id = "ST-B", role = "station", cfg = { channel = 777, master_id = "MASTER-1" }, entry = { id = "ST-B", role = "station", modem = "top" } }
    linktest.run(ctx, { link = function(opts) seen = opts; return { state = "known", rtt_s = 0.01, echoed = opts.echo_bytes or 0 } end, pings = 1, sizes = { 100 }, peripheral = "api", wait_s = 3 })
    assert(seen.channel == 777 and seen.master_id == "MASTER-1" and seen.id == "ST-B" and seen.role == "station" and seen.modem_name == "top")
    assert(seen.peripheral == "api" and seen.wait_s == 3 and seen.pad_bytes == 100 and seen.echo_bytes == 100)
  end,

  test_progress_is_reported_but_never_needed = function()
    with_master(function(_, _, ctx, probe)
      local pings, sizes = 0, 0
      linktest.run(ctx, { link = probe, pings = 3, sizes = { 100, 200 }, on_progress = function(kind) if kind == "ping" then pings = pings + 1 else sizes = sizes + 1 end end })
      assert(pings == 3 and sizes == 2)
      linktest.run(ctx, { link = probe, pings = 1, sizes = {}, on_progress = function() error("progress is not a result") end })
    end)
  end,
}
