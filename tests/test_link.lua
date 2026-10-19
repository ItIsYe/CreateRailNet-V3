--[[
Purpose: The test of the link to the master, end to end in one process: the probe of a computer that is being set up talks to the real master
  runtime and its pairing book, and what comes back decides what the doctor says.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local link = require("src.setup.link")
local net = require("src.shared.net")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local pairing_module = require("src.master.pairing")
local doctor = require("src.setup.doctor")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")
local memfs = require("tests.harness.memfs")

local PLAN = "configs/network.json"
local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

-- two computers on one channel: messages go into the inbox of the other; the clock is the test's
local function bus()
  local b = { clock = 1000, inbox = { probe = {}, master = {} } }
  b.probe_modem = {
    open = function() return true end,
    send = function(_, _, _, msg) b.inbox.master[#b.inbox.master + 1] = msg; return true end,
    broadcast = function(_, _, msg) b.inbox.master[#b.inbox.master + 1] = msg; return true end,
  }
  b.master_modem = {
    open = function() return true end,
    send = function(_, _, _, msg) b.inbox.probe[#b.inbox.probe + 1] = msg; return true end,
    broadcast = function(_, _, msg) b.inbox.probe[#b.inbox.probe + 1] = msg; return true end,
  }
  b.time = { now_ms = function() return b.clock * 1000 end, now_s = function() return b.clock end }
  return b
end

local function master_on(b, opts)
  local o = opts or {}
  local fs = memfs.new()
  local cfg = { v = 1, channel = 7, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" } }, blocks = {}, routes = {} }
  fs.set(PLAN, netplan.encode(cfg))
  local network = net.new(b.master_modem, 7, "M", quiet, b.time)
  local m = { fs = fs, cfg = cfg, network = network }
  m.alerts = alerts_module.new({ now_s = b.time.now_s })
  if not o.old then m.pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs, now_s = b.time.now_s }) end
  m.runtime = runtime_factory.new({
    config = cfg, registry = registry_factory.new(),
    dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
    network = network,
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function() end }, alerts = m.alerts, pairing = m.pairing,
    auto_restore_state = false, auto_save_state = false,
  })
  -- the master reads what is in its inbox
  function m.step()
    local inbox = b.inbox.master
    b.inbox.master = {}
    for _, msg in ipairs(inbox) do m.runtime.handle_event({ "modem_message", nil, nil, nil, msg }) end
  end
  return m
end

-- the probe pulls its events through here: the master answers first, then the probe's inbox is read; time moves by the timeout
local function puller(b, m)
  return function(timeout)
    if m then m.step() end
    local msg = table.remove(b.inbox.probe, 1)
    if msg then return { "modem_message", nil, nil, nil, msg } end
    b.clock = b.clock + timeout
    return nil
  end
end

local function probe(b, m, extra)
  local o = { channel = 7, master_id = "M", id = "SIG-9", role = "signal", entry = { id = "SIG-9", role = "signal", adapter = "redstone", side = "left" },
    setup = { state = "KONFIGURIERT" }, modem = b.probe_modem, pull_event = puller(b, m), time = b.time, now = b.time.now_s, wait_s = 6 }
  for key, value in pairs(extra or {}) do o[key] = value end
  return link.probe(o)
end

return {
  test_an_unknown_computer_is_pending_and_waits_at_the_master = function()
    local b = bus()
    local m = master_on(b)
    local result = probe(b, m)
    assert(result.state == "pending", tostring(result.state))
    local candidate = m.pairing.get("SIG-9")
    assert(candidate and candidate.entry.side == "left" and candidate.setup.state == "KONFIGURIERT")
    assert(m.runtime.registry.all()["SIG-9"] == nil, "being set up is not being a node")
    assert(m.alerts.get("pair:SIG-9"), "the operator sees a message")
  end,

  test_a_computer_of_the_plan_is_known_and_a_changed_role_is_a_conflict = function()
    local b = bus()
    local m = master_on(b)
    assert(probe(b, m, { id = "SIG-1" }).state == "known")
    assert(probe(b, m, { id = "SIG-1", role = "sensor", entry = { id = "SIG-1", role = "sensor" } }).state == "conflict")
  end,

  test_a_rejected_computer_hears_that = function()
    local b = bus()
    local m = master_on(b)
    assert(probe(b, m).state == "pending")
    assert(m.runtime.pair_decide("reject", "SIG-9", "PANEL-1"))
    assert(probe(b, m).state == "rejected", "muted for a while")
  end,

  test_an_accepted_computer_is_known_afterwards = function()
    local b = bus()
    local m = master_on(b)
    assert(probe(b, m).state == "pending")
    local ok = m.runtime.pair_decide("accept", "SIG-9", "PANEL-1")
    assert(ok)
    assert(probe(b, m).state == "known")
    assert(netplan.find_node(assert(netplan.parse(m.fs.files[PLAN])), "SIG-9").side == "left")
  end,

  -- the answer of the master to an unasked announcement is sent only when it changes; a question must not be left without an answer
  test_asking_again_with_the_same_state_gets_the_same_answer_again = function()
    local b = bus()
    local m = master_on(b)
    for round = 1, 3 do
      local result = probe(b, m)
      assert(result.state == "pending", "round " .. round .. ": " .. tostring(result.state))
    end
    for round = 1, 3 do
      local result = probe(b, m, { id = "SIG-1" })
      assert(result.state == "known", "round " .. round .. ": " .. tostring(result.state))
    end
  end,

  test_a_computer_that_announces_itself_can_still_ask = function()
    local b = bus()
    local m = master_on(b)
    -- the running node announced itself and was told "pending"; the doctor of the same computer asks later
    m.runtime.handle_event({ "modem_message", nil, nil, nil, net.new(b.probe_modem, 7, "SIG-9", quiet, b.time).send("event", "M", { type = "pair_announce", role = "signal", entry = { id = "SIG-9", role = "signal" } }) })
    b.inbox.master = {}
    b.inbox.probe = {}
    assert(probe(b, m).state == "pending")
    assert(probe(b, m).state == "pending")
  end,

  test_an_answer_to_another_question_does_not_decide_this_one = function()
    local b = bus()
    local m = master_on(b)
    local planted = false
    local function stale_first(timeout)
      if not planted then
        planted = true
        local fake = net.new(b.master_modem, 7, "M", quiet, b.time)
        fake.send("cmd", "SIG-9", { cmd = "pair_state", state = "known", probe_id = "an-earlier-probe" })
      end
      return puller(b, m)(timeout)
    end
    local result = probe(b, m, { pull_event = stale_first })
    assert(result.state == "pending", "the old answer is skipped: " .. tostring(result.state))
  end,

  test_no_master_means_no_answer_after_the_waiting_time = function()
    local b = bus()
    local start = b.clock
    local result = probe(b, nil)
    assert(result.state == "no_answer")
    assert(b.clock - start >= 6 and b.clock - start < 8, "waited about the given time: " .. (b.clock - start))
  end,

  test_a_master_from_before_pairing_only_acknowledges_and_is_called_old = function()
    local b = bus()
    local m = master_on(b, { old = true })
    local result = probe(b, m)
    assert(result.state == "old_master", tostring(result.state))
  end,

  test_without_a_modem_nothing_is_sent_and_nothing_is_raised = function()
    local b = bus()
    local result = link.probe({ channel = 7, master_id = "M", id = "SIG-9", role = "signal", peripheral = { wrap = function() return nil end, find = function() return nil end }, modem_name = "gone" })
    assert(result.state == "no_modem")
    local failing = { open = function() return false, "closed" end, send = function() return false end }
    assert(link.probe({ channel = 7, master_id = "M", id = "X", role = "signal", modem = failing }).state == "no_modem")
    local mute = { open = function() return true end, send = function() return false, "no" end }
    assert(link.probe({ channel = 7, master_id = "M", id = "X", role = "signal", modem = mute, pull_event = function() return nil end, time = bus().time, wait_s = 1 }).state == "no_answer")
  end,

  test_strangers_and_nonsense_do_not_answer_the_probe = function()
    local b = bus()
    local m = master_on(b)
    local pulls = 0
    -- before the master has said anything: a pair_state from somebody who is not the master, a message of another protocol, a string
    local function hostile(timeout)
      pulls = pulls + 1
      if pulls == 1 then
        local fake = net.new(b.master_modem, 7, "EVIL", quiet, b.time)
        fake.send("cmd", "SIG-9", { cmd = "pair_state", state = "known" })
        b.inbox.probe[#b.inbox.probe + 1] = { v = 99 }
        b.inbox.probe[#b.inbox.probe + 1] = "nope"
      elseif #b.inbox.probe == 0 then
        m.step()
      end
      local msg = table.remove(b.inbox.probe, 1)
      if msg ~= nil then return { "modem_message", nil, nil, nil, msg } end
      b.clock = b.clock + timeout
      return nil
    end
    local result = probe(b, m, { pull_event = hostile })
    assert(pulls >= 4, "the three bad messages were looked at first")
    assert(result.state == "pending", "only the master's answer counts: " .. tostring(result.state))
  end,

  test_what_the_probe_found_becomes_the_link_check_of_the_doctor = function()
    local fs = memfs.new()
    fs.set("startup.lua", startup_template.render({ role = "signal", id = "SIG-9", config = PLAN }))
    fs.set("crn_version.txt", "main-x")
    fs.set(PLAN, netplan.encode(netplan.short_plan("signal", { id = "SIG-9", role = "signal", adapter = "redstone", side = "left" }, 7, "M")))
    local peripheral = {
      getNames = function() return { "top" } end, getType = function() return "modem" end, getMethods = function() return {} end,
    }
    local asked = {}
    local function report_for(state)
      return doctor.run({ fs = fs, peripheral = peripheral, probe = function(ctx) asked[#asked + 1] = ctx.id; return { state = state } end })
    end
    local known = report_for("known")
    assert(known.ctx.link == "known" and #asked == 1 and asked[1] == "SIG-9")
    for _, check in ipairs(known.checks) do if check.id == "link" then assert(check.level == "ok") end end
    local rejected = report_for("rejected")
    local lvl
    for _, check in ipairs(rejected.checks) do if check.id == "link" then lvl = check.level end end
    assert(lvl == "warn")
    -- nobody is asked when there is nothing to ask with: no modem
    local none = doctor.run({ fs = fs, peripheral = { getNames = function() return {} end, getType = function() end, getMethods = function() return {} end }, probe = function() error("must not be asked") end })
    assert(none.ctx.link == nil)
  end,
}
