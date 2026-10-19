--[[
Purpose: A station or depot computer fetches the plan from the master (the part of the setup wizard that replaces copying the plan by hand):
  end to end against the real master runtime and its plan service, with lost and doubled messages, and against a master that says
  something wrong (damaged, changed, foreign, nonsense) -- whatever it says, the result is checked and nothing is raised.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local plan_fetch = require("src.setup.plan_fetch")
local net = require("src.shared.net")
local checksum = require("src.shared.checksum")
local netplan = require("src.setup.netplan")

local plan_bus = require("tests.harness.plan_bus")
local PLAN = plan_bus.PLAN
local quiet = plan_bus.quiet
local template, bus, puller = plan_bus.template, plan_bus.new, plan_bus.puller
local function real_master(b, plan_name, opts) return plan_bus.real_master(b, template(plan_name), opts) end

-- a master that says what the test tells it to: handler(payload, message) -> list of payloads (or nil: silence); it acknowledges like the real one
local function scripted_master(b, handler, channel, master_id)
  local network = net.new(b.master_modem, channel, master_id, quiet, b.time)
  local m = { network = network, channel = channel, master_id = master_id, seen = 0 }
  function m.step()
    local inbox = b.inbox.master
    b.inbox.master = {}
    for _, msg in ipairs(inbox) do
      if network.receive(msg) == "ok" and msg.type == "event" and type(msg.payload) == "table" and msg.payload.type == "plan_get" then
        m.seen = m.seen + 1
        network.ack_for(msg, true)
        for _, payload in ipairs(handler(msg.payload, msg, m.seen) or {}) do
          payload.cmd = payload.cmd or "plan_part"
          if payload.question == nil then payload.question = msg.id end
          network.send("cmd", msg.src, payload)
        end
      end
    end
  end
  return m
end

local function fetch(b, m, extra)
  local o = { channel = m and m.channel or 777, master_id = m and m.master_id or "MASTER-1", id = "ST-B", role = "station",
    modem = b.client_modem, pull_event = puller(b, m), time = b.time, now = b.time.now_s, wait_s = 3 }
  for key, value in pairs(extra or {}) do o[key] = value end
  return plan_fetch.fetch(o)
end

-- a plan text with its numbers, cut into parts of `size` bytes, for the scripted master
local function parts_of(text, size)
  local list = {}
  for position = 1, #text, size do list[#list + 1] = text:sub(position, position + size - 1) end
  return list
end

local function honest(text, size)
  local pieces = parts_of(text, size or 300)
  local version = checksum.hex(checksum.adler32(text))
  return function(payload)
    return { { ok = true, index = payload.index, total = #pieces, version = version, size = #text, data = pieces[payload.index] or "" } }
  end, version
end

return {
  test_a_station_fetches_the_plan_in_parts_and_gets_exactly_the_file = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local totals = {}
    local result = fetch(b, m, { on_total = function(parts, bytes) totals[#totals + 1] = { parts, bytes } end })
    assert(result.ok, tostring(result.message))
    assert(result.text == m.fs.files[PLAN] and result.parts > 3 and result.size == #result.text)
    assert(result.entry.id == "ST-B" and #result.entry.platforms == 2 and result.cfg.master_id == m.master_id)
    assert(#totals == 1 and totals[1][1] == result.parts and totals[1][2] == result.size)
  end,

  test_a_depot_fetches_its_plan_too = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local result = fetch(b, m, { id = "DEPOT-1", role = "depot" })
    assert(result.ok, tostring(result.message))
    assert(#result.entry.tracks == 1)
  end,

  test_fetching_again_works_every_time = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    for round = 1, 3 do
      local result = fetch(b, m)
      assert(result.ok and result.text == m.fs.files[PLAN], "round " .. round .. ": " .. tostring(result.message))
    end
  end,

  test_a_plan_that_the_operator_edits_between_two_fetches_is_the_new_one = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local first = fetch(b, m)
    local edited = first.text:gsub('"dwell_seconds": 10', '"dwell_seconds": 12', 1)
    assert(edited ~= first.text)
    m.fs.set(PLAN, edited)
    local second = fetch(b, m)
    assert(second.ok and second.text == edited and second.version ~= first.version)
  end,

  test_lost_messages_are_asked_for_again = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local dropped = 0
    -- every second answer of the master is lost, and one request
    b.filter = function(msg, direction)
      if direction == "to_client" and msg.type == "cmd" then
        b.cmds = (b.cmds or 0) + 1
        if b.cmds % 2 == 0 then dropped = dropped + 1; return false end
      end
      return true
    end
    local result = fetch(b, m)
    assert(result.ok, tostring(result.message))
    assert(dropped >= 2 and result.text == m.fs.files[PLAN])
  end,

  test_a_doubled_answer_does_no_harm = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    b.filter = function(msg, direction)
      if direction == "to_client" and msg.type == "cmd" then b.inbox.client[#b.inbox.client + 1] = msg end
      return true
    end
    local result = fetch(b, m)
    assert(result.ok and result.text == m.fs.files[PLAN])
  end,

  test_a_master_that_does_not_know_the_computer_says_so = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local result = fetch(b, m, { id = "ST-NEW" })
    assert(result.ok == false and result.state == "refused" and result.message:find("kennt diesen Computer noch nicht", 1, true), tostring(result.message))
    assert(result.text == nil)
  end,

  test_roles_without_platforms_are_not_served = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local signal_id
    for _, node in ipairs(m.cfg.nodes) do if node.role == "signal" then signal_id = node.id end end
    local result = fetch(b, m, { id = signal_id, role = "signal" })
    assert(result.ok == false and result.state == "refused" and result.message:find("nur Bahnhof und Depot", 1, true), tostring(result.message))
  end,

  test_a_role_that_differs_from_the_plan_is_a_conflict = function()
    local b = bus()
    local m = real_master(b, "network.full.example.json")
    local result = fetch(b, m, { id = "ST-B", role = "depot" })
    assert(result.ok == false and result.state == "refused" and result.message:find("anderen Rolle", 1, true), tostring(result.message))
  end,

  test_no_master_means_no_answer_after_the_waiting_time = function()
    local b = bus()
    local start = b.clock
    local result = fetch(b, nil, { attempts = 2, wait_s = 2 })
    assert(result.ok == false and result.state == "no_answer" and result.message:find("antwortet nicht", 1, true))
    assert(b.clock - start >= 4 and b.clock - start < 8, "asked twice, two seconds each: " .. (b.clock - start))
  end,

  test_an_older_master_that_only_acknowledges_is_no_answer = function()
    local b = bus()
    local old = net.new(b.master_modem, 777, "MASTER-1", quiet, b.time)
    local m = { channel = 777, master_id = "MASTER-1", step = function()
      local inbox = b.inbox.master
      b.inbox.master = {}
      for _, msg in ipairs(inbox) do if old.receive(msg) == "ok" and msg.type == "event" then old.ack_for(msg, true) end end
    end }
    local result = fetch(b, m, { attempts = 1, wait_s = 2 })
    assert(result.ok == false and result.state == "no_answer")
  end,

  test_without_a_modem_nothing_is_sent_and_nothing_is_raised = function()
    local result = plan_fetch.fetch({ channel = 7, master_id = "M", id = "ST-B", role = "station", peripheral = { wrap = function() return nil end, find = function() return nil end }, modem_name = "gone" })
    assert(result.ok == false and result.state == "no_modem")
    local closed = { open = function() return false end, send = function() return false end }
    assert(plan_fetch.fetch({ channel = 7, master_id = "M", id = "ST-B", role = "station", modem = closed }).state == "no_modem")
    local mute = { open = function() return true end, send = function() return false, "no" end }
    local r = plan_fetch.fetch({ channel = 7, master_id = "M", id = "ST-B", role = "station", modem = mute, pull_event = function() return nil end, time = bus().time, now = bus().time.now_s })
    assert(r.ok == false and r.state == "no_answer")
  end,

  -- a master that says something wrong ------------------------------------------------------------------------------------

  test_a_plan_that_arrives_damaged_is_fetched_again_and_then_given_up = function()
    local text = template("network.full.example.json")
    local good, version = honest(text, 300)
    local function damage(reply) reply[1].data = reply[1].data:sub(1, -2) .. "#"; return reply end
    -- once: one byte of part 2 is wrong, the second transfer is fine
    local b = bus()
    local damaged_once = false
    local m = scripted_master(b, function(payload)
      local reply = good(payload)
      if payload.index == 2 and not damaged_once then damaged_once = true; return damage(reply) end
      return reply
    end, 777, "MASTER-1")
    local result = fetch(b, m)
    assert(result.ok and result.text == text and result.version == version, tostring(result.message))
    -- always: given up with the right words
    local b2 = bus()
    local bad = scripted_master(b2, function(payload) return damage(good(payload)) end, 777, "MASTER-1")
    local r2 = fetch(b2, bad)
    assert(r2.ok == false and r2.state == "damaged" and r2.message:find("beschaedigt", 1, true), tostring(r2.message))
  end,

  test_a_plan_that_changes_during_the_transfer_is_fetched_again = function()
    local old_text = template("network.full.example.json")
    local new_text = old_text:gsub('"dwell_seconds": 10', '"dwell_seconds": 12', 1)
    assert(new_text ~= old_text)
    local old_reply = honest(old_text, 300)
    local new_reply = honest(new_text, 300)
    local b = bus()
    local flips = 0
    local m = scripted_master(b, function(payload)
      -- the master answers parts 1 and 2 from the old plan, then the file changed
      if payload.index == 3 and flips == 0 then flips = 1; return { { ok = false, state = "changed", reason = "x" } } end
      if flips == 0 then return old_reply(payload) end
      return new_reply(payload)
    end, 777, "MASTER-1")
    local result = fetch(b, m)
    assert(result.ok and result.text == new_text, tostring(result.message))
  end,

  test_parts_of_two_different_plans_are_not_put_together = function()
    local a = template("network.full.example.json")
    local c = a:gsub('"dwell_seconds": 10', '"dwell_seconds": 12', 1)
    assert(c ~= a)
    local reply_a, reply_c = honest(a, 300), honest(c, 300)
    local b = bus()
    local m = scripted_master(b, function(payload, _, seen)
      if payload.index == 1 then return reply_a(payload) end
      return reply_c(payload)   -- every other part belongs to another version
    end, 777, "MASTER-1")
    local result = fetch(b, m, { restarts = 0 })
    assert(result.ok == false and result.state == "changed", tostring(result.state))
  end,

  test_an_answer_of_somebody_else_or_to_another_question_is_ignored = function()
    local text = template("network.full.example.json")
    local good = honest(text, 300)
    local b = bus()
    local pulls = 0
    local m = scripted_master(b, function(payload) return good(payload) end, 777, "MASTER-1")
    local function hostile(timeout)
      pulls = pulls + 1
      if pulls == 1 then
        -- a computer that is not the master tells us a plan, and the master answers a question that was not ours
        local evil = net.new(b.master_modem, 777, "EVIL", quiet, b.time)
        evil.send("cmd", "ST-B", { cmd = "plan_part", question = "anything", ok = true, index = 1, total = 1, version = "00000000", size = 3, data = "{}\\n" })
        local master_net = net.new(b.master_modem, 777, "MASTER-1", quiet, b.time)
        master_net.send("cmd", "ST-B", { cmd = "plan_part", question = "somebody-elses", ok = true, index = 1, total = 1, version = "00000000", size = 3, data = "abc" })
        -- the question of the asker is on the channel for everybody to read: an answer to it from somebody else still does not count
        local sniffed = b.sent_to_master[#b.sent_to_master]
        local forged = text:gsub('"dwell_seconds": 10', '"dwell_seconds": 99', 1)
        evil.send("cmd", "ST-B", { cmd = "plan_part", question = sniffed.id, ok = true, index = 1, total = 1, version = checksum.hex(checksum.adler32(forged)), size = #forged, data = forged })
      end
      return puller(b, m)(timeout)
    end
    local result = fetch(b, m, { pull_event = hostile })
    assert(pulls >= 3 and result.ok and result.text == text, tostring(result.message))
  end,

  test_nonsense_numbers_are_refused_without_a_crash = function()
    local text = template("network.full.example.json")
    local version = checksum.hex(checksum.adler32(text))
    local cases = {
      { total = 0 }, { total = 61 }, { total = 1.5 }, { total = "3" }, { total = math.huge }, { total = -1 }, { size = 0 }, { size = 200001 }, { size = "x" },
      { version = "xyz" }, { version = 12345678 }, { version = "0123456" }, { data = "" }, { data = 5 }, { data = string.rep("x", 9000) }, { index = 2 }, { index = "1" },
    }
    for n, case in ipairs(cases) do
      local b = bus()
      local m = scripted_master(b, function(payload)
        local reply = { ok = true, index = payload.index, total = 1, version = version, size = #text, data = text }
        for key, value in pairs(case) do reply[key] = value end
        return { reply }
      end, 777, "MASTER-1")
      local result = fetch(b, m, { restarts = 0, attempts = 1 })
      assert(result.ok == false and result.state == "damaged" and result.message:find("unbrauchbare", 1, true), "case " .. n .. ": " .. tostring(result.message))
    end
  end,

  test_a_master_that_sends_garbage_instead_of_an_error_is_handled = function()
    for n, reply in ipairs({ { ok = false }, { ok = false, state = "error" }, { ok = false, state = "error", reason = string.rep("x", 5000) }, { ok = false, state = {} }, { ok = "yes" }, {} }) do
      local b = bus()
      local m = scripted_master(b, function() return { reply } end, 777, "MASTER-1")
      local result = fetch(b, m, { restarts = 0, attempts = 1 })
      assert(result.ok == false and result.state ~= nil, "case " .. n)
      assert(#result.message < 300, "a long reason of the master is cut: " .. #result.message)
    end
  end,

  test_a_plan_that_is_not_valid_or_not_ours_is_not_accepted = function()
    local good_text = template("network.full.example.json")
    local function run(text, extra)
      local b = bus()
      local reply = honest(text, 400)
      local m = scripted_master(b, function(payload) return reply(payload) end, 777, "MASTER-1")
      return fetch(b, m, extra)
    end
    local r1 = run("{ not json at all")
    assert(r1.ok == false and r1.state == "invalid", tostring(r1.state))
    local r2 = run('{"v":1,"channel":777,"master_id":"MASTER-1","nodes":[{"id":"MASTER-1","role":"master"}],"blocks":[{"id":"B"}],"routes":[]}')
    assert(r2.ok == false and r2.state == "invalid" and r2.message:find("Fehler", 1, true))
    -- a valid plan of another network
    local other = good_text:gsub('"channel": 777', '"channel": 778', 1)
    assert(other ~= good_text)
    local r3 = run(other)
    assert(r3.ok == false and r3.state == "mismatch" and r3.message:find("anderen Netz", 1, true), tostring(r3.message))
    -- a valid plan without this computer, or with another role for it
    local r4 = run(good_text, { id = "ST-X" })
    assert(r4.ok == false and r4.state == "mismatch" and r4.message:find("fehlt der Eintrag", 1, true), tostring(r4.message))
    local r5 = run(good_text, { role = "depot" })
    assert(r5.ok == false and r5.state == "mismatch")
    local ok = run(good_text)
    assert(ok.ok, tostring(ok.message))
  end,

  test_the_whole_transfer_has_a_time_limit = function()
    local b = bus()
    local text = template("network.full.example.json")
    local good = honest(text, 100)
    local m = scripted_master(b, function(payload)
      -- every answer comes, but the clock runs: each exchange costs ten seconds
      b.clock = b.clock + 10
      return good(payload)
    end, 777, "MASTER-1")
    local result = fetch(b, m, { deadline_s = 30 })
    assert(result.ok == false and result.state == "no_answer", tostring(result.state))
  end,
}
