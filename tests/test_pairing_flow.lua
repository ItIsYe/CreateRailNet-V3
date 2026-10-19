--[[
Purpose: Pairing between a node and the master: the node announces its entry once the master understands it, the master keeps a candidate
  and tells the operator, the operator accepts or rejects, and the answer reaches the node. Old peers are left alone.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local common_node = require("src.nodes.common_node")
local runtime_factory = require("src.master.runtime")
local registry_factory = require("src.shared.registry")
local alerts_module = require("src.domain.alerts")
local pairing_module = require("src.master.pairing")
local memfs = require("tests.harness.memfs")
local netplan = require("src.setup.netplan")
local setup_status = require("src.shared.setup_status")

local PLAN = "configs/network.json"

-- ── a node on a fake clock ─────────────────────────────────────────────────────────────────────────────────────────
local function fake_node(extra)
  local env = { now = 0, last_id = 0, sent = {}, infos = {} }
  env.clock = function() return env.now end
  env.start_timer = function() env.last_id = env.last_id + 1; return env.last_id end
  env.modem = {
    open = function() return true end,
    send = function(_, _, _, m) env.sent[#env.sent + 1] = m; return true end,
    broadcast = function(_, _, m) env.sent[#env.sent + 1] = m; return true end,
  }
  env.logger = { info = function(msg, data) env.infos[#env.infos + 1] = { msg = msg, data = data } end, debug = function() end, error = function() end, warn = function() end }
  local cfg = { channel = 1, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" } } }
  for key, value in pairs(extra or {}) do cfg[key] = value end
  env.node = common_node.new({ id = "SIG-1", role = "signal", config = cfg, modem = env.modem, logger = env.logger, clock = env.clock, start_timer = env.start_timer })
  return env
end

local function announcements(env)
  local list = {}
  for _, m in ipairs(env.sent) do if m.type == "event" and m.payload.type == "pair_announce" then list[#list + 1] = m end end
  return list
end

-- the master answers with some protocol revision (it is how the node learns what the master understands)
local function master_says(env, revision, payload, id)
  env.node.handle_message({ v = 1, pv = revision, id = id or ("m." .. env.now), src = "M", dst = "SIG-1", type = "cmd", payload = payload or { cmd = "noop" } })
end

local function tick(env, seconds)
  env.now = env.now + seconds
  env.node.handle_event({ "peripheral", "left" })
end

-- ── a master with a plan on a disk ──────────────────────────────────────────────────────────────────────────────────
local function fake_master(opts)
  local o = opts or {}
  local fs = memfs.new()
  local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" }, { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" } }, blocks = {}, routes = {} }
  fs.set(PLAN, netplan.encode(cfg))
  local env = { fs = fs, cfg = cfg, sent = {}, acks = 0, audits = {}, revisions = o.revisions or {} }
  env.alerts = alerts_module.new()
  env.pairing = pairing_module.new({ config = cfg, plan_path = PLAN, fs = fs, audit = function(kind, data) env.audits[#env.audits + 1] = { kind = kind, data = data } end })
  env.runtime = runtime_factory.new({
    config = cfg, registry = registry_factory.new(),
    dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
    network = {
      receive = function() return "ok" end, ack_for = function() env.acks = env.acks + 1 end, tick = function() end,
      send = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload } end,
      send_reliable = function(kind, dst, payload) env.sent[#env.sent + 1] = { kind = kind, dst = dst, payload = payload, reliable = true } end,
      peer_revision = function(id) return env.revisions[id] end,
    },
    ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
    audit_log = { record = function(kind, data) env.audits[#env.audits + 1] = { kind = kind, data = data } end },
    alerts = env.alerts, pairing = env.pairing,
    auto_restore_state = false, auto_save_state = false,
  })
  function env.event(src, payload)
    env.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = src .. "." .. tostring(payload.type) .. math.random(1, 1e9), type = "event", src = src, dst = "M", payload = payload } })
  end
  function env.message(src, kind, payload)
    env.runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = src .. "." .. kind .. math.random(1, 1e9), type = kind, src = src, dst = "M", payload = payload } })
  end
  function env.replies(dst)
    local list = {}
    for _, item in ipairs(env.sent) do if item.kind == "cmd" and item.dst == dst and item.payload.cmd == "pair_state" then list[#list + 1] = item.payload end end
    return list
  end
  return env
end

return {
  -- the node -------------------------------------------------------------------------------------------------------------

  test_a_node_announces_its_entry_once_the_master_has_shown_that_it_understands_it = function()
    local env = fake_node()
    env.node.start()
    tick(env, 6)
    assert(#announcements(env) == 0, "the master has not been heard yet: nothing to announce to")
    master_says(env, 3)
    tick(env, 6)
    local list = announcements(env)
    assert(#list == 1, "announced once")
    local payload = list[1].payload
    assert(payload.role == "signal" and payload.entry.id == "SIG-1" and payload.entry.side == "left" and list[1].dst == "M")
  end,

  test_an_older_master_is_not_bothered = function()
    local env = fake_node()
    env.node.start()
    master_says(env, 2)
    tick(env, 30)
    tick(env, 30)
    assert(#announcements(env) == 0)
    local plain = fake_node()
    plain.node.start()
    plain.node.handle_message({ v = 1, id = "m.1", src = "M", dst = "SIG-1", type = "cmd", payload = { cmd = "noop" } })
    tick(plain, 30)
    assert(#announcements(plain) == 0, "a master that sends no revision counts as revision 1")
  end,

  test_the_setup_record_goes_along_and_nothing_is_announced_without_a_plan_entry = function()
    local env = fake_node()
    local fs = memfs.new()
    fs.set("crn_status.lua", setup_status.render({ state = "GEPRUEFT", role = "signal", id = "SIG-1", version = "main-abc", fail = 0, warn = 1, at = 5 }))
    local real_fs = _G.fs
    _G.fs = fs
    env.node.start()
    master_says(env, 3)
    tick(env, 6)
    _G.fs = real_fs
    local payload = announcements(env)[1].payload
    assert(payload.setup and payload.setup.state == "GEPRUEFT" and payload.setup.version == "main-abc" and payload.setup.warn == 1 and payload.setup.at == nil)
    local bare = fake_node({ nodes = {} })
    bare.node.start()
    master_says(bare, 3)
    tick(bare, 6)
    assert(announcements(bare)[1].payload.entry == nil, "no entry in the plan: the master gets role and id only")
  end,

  test_the_node_asks_again_while_the_master_does_not_know_it_and_less_often_once_it_does = function()
    local env = fake_node()
    env.node.start()
    master_says(env, 3)
    tick(env, 6)
    assert(#announcements(env) == 1)
    tick(env, 10)
    assert(#announcements(env) == 1, "not again within 20 seconds")
    tick(env, 12)
    assert(#announcements(env) == 2, "again after 20 seconds without an answer")
    master_says(env, 3, { cmd = "pair_state", state = "pending", detail = "x" }, "m.pending")
    tick(env, 100)
    assert(#announcements(env) == 2, "pending: every 5 minutes")
    tick(env, 250)
    assert(#announcements(env) == 3)
    master_says(env, 3, { cmd = "pair_state", state = "known" }, "m.known")
    tick(env, 400)
    assert(#announcements(env) == 3, "known: not within 10 minutes")
    tick(env, 400)
    assert(#announcements(env) == 4, "known: every 10 minutes, so a master that restarted learns the setup record again")
  end,

  test_pair_state_is_acknowledged_logged_once_per_change_and_only_taken_from_the_master = function()
    local env = fake_node()
    env.node.start()
    master_says(env, 3, { cmd = "pair_state", state = "pending", detail = "bitte bestaetigen" }, "m.1")
    master_says(env, 3, { cmd = "pair_state", state = "pending" }, "m.2")
    assert(env.node.pair.state == "pending")
    local logged = 0
    for _, info in ipairs(env.infos) do if info.msg == "pairing" then logged = logged + 1 end end
    assert(logged == 1, "the same state is logged once")
    local acks = 0
    for _, m in ipairs(env.sent) do if m.type == "ack" then acks = acks + 1 end end
    assert(acks == 2)
    env.node.handle_message({ v = 1, id = "x.1", src = "STRANGER", dst = "SIG-1", type = "cmd", payload = { cmd = "pair_state", state = "known" } })
    assert(env.node.pair.state == "pending", "a stranger cannot tell the node that it is known")
  end,

  -- the master -------------------------------------------------------------------------------------------------------------

  test_an_unknown_node_becomes_a_candidate_with_an_alert_and_is_told_it_is_pending = function()
    local m = fake_master({ revisions = { ["SIG-7"] = 3 } })
    m.event("SIG-7", { type = "pair_announce", role = "signal", entry = { id = "SIG-7", role = "signal", adapter = "redstone", side = "back" }, setup = { state = "GEPRUEFT", fail = 0, warn = 0 } })
    local candidate = m.pairing.get("SIG-7")
    assert(candidate and candidate.state == "pending" and candidate.entry.side == "back" and candidate.setup.state == "GEPRUEFT")
    local alert = m.alerts.get("pair:SIG-7")
    assert(alert and alert.severity == "YELLOW" and alert.text:find("SIG-7", 1, true) and alert.text:find("wartet", 1, true), alert and alert.text)
    local replies = m.replies("SIG-7")
    assert(#replies == 1 and replies[1].state == "pending")
    assert(m.acks == 1, "the event is acknowledged")
    m.event("SIG-7", { type = "pair_announce", role = "signal" })
    assert(#m.replies("SIG-7") == 1, "told again only when the state changes")
  end,

  test_a_known_node_is_just_acknowledged_and_its_alert_goes_away = function()
    local m = fake_master({ revisions = { ["SIG-1"] = 3 } })
    m.alerts.raise("pair:SIG-1", "YELLOW", "old")
    m.event("SIG-1", { type = "pair_announce", role = "signal", setup = { state = "PRUEFUNG_OFFEN", fail = 2, warn = 1 } })
    assert(m.pairing.count() == 0)
    assert(m.replies("SIG-1")[1].state == "known")
    assert(m.alerts.get("pair:SIG-1").state == "CLEARED", "the cause is gone")
    assert(m.pairing.setup_of("SIG-1").state == "PRUEFUNG_OFFEN" and m.pairing.setup_of("SIG-1").fail == 2, "what the node reports about its setup is kept")
  end,

  test_old_nodes_get_no_pair_state_and_registration_and_heartbeat_make_candidates = function()
    local m = fake_master({ revisions = { ["OLD-1"] = 2 } })
    m.message("OLD-1", "register", { role = "sensor" })
    assert(m.pairing.get("OLD-1") and #m.replies("OLD-1") == 0, "a node from before pairing is listed but not talked to")
    m.message("NEW-2", "heartbeat", { role = "switch" })
    assert(m.pairing.get("NEW-2"), "a heartbeat of an unknown node (after a master restart) makes it a candidate too")
    assert(m.pairing.get("NEW-2").entry.role == "switch")
    m.message("SIG-1", "heartbeat", { role = "signal" })
    assert(m.pairing.get("SIG-1") == nil)
  end,

  test_a_peer_that_does_not_understand_revision_3_is_not_sent_pair_state_even_if_it_announces = function()
    local m = fake_master({ revisions = { ["ODD-1"] = 2 } })
    m.event("ODD-1", { type = "pair_announce", role = "sensor" })
    m.event("STRANGE-2", { type = "pair_announce", role = "sensor" })
    assert(m.pairing.get("ODD-1") and m.pairing.get("STRANGE-2"), "both are listed")
    assert(#m.replies("ODD-1") == 0 and #m.replies("STRANGE-2") == 0, "nobody is told something it may not understand")
    assert(m.acks == 2)
  end,

  test_the_probe_of_the_wizard_is_answered_and_does_not_register_a_node = function()
    local m = fake_master({ revisions = { ["SIG-9"] = 3 } })
    m.event("SIG-9", { type = "pair_probe", role = "signal", entry = { id = "SIG-9", role = "signal", adapter = "redstone", side = "left" } })
    assert(m.replies("SIG-9")[1].state == "pending")
    assert(m.runtime.registry.all()["SIG-9"] == nil, "a computer that is only being set up is no node: it would time out and raise alarms")
    assert(m.pairing.get("SIG-9") ~= nil)
  end,

  test_accepting_writes_the_plan_tells_the_node_and_clears_the_alert = function()
    local m = fake_master({ revisions = { ["SEN-4"] = 3 } })
    m.event("SEN-4", { type = "pair_announce", role = "sensor", entry = { id = "SEN-4", role = "sensor", adapter = "redstone", side = "right" } })
    local ok, message = m.runtime.pair_decide("accept", "SEN-4", "PANEL-1")
    assert(ok, tostring(message))
    assert(netplan.find_node(assert(netplan.parse(m.fs.files[PLAN])), "SEN-4").side == "right")
    local replies = m.replies("SEN-4")
    assert(replies[#replies].state == "known", "the node learns that it is in")
    assert(m.pairing.count() == 0)
    assert(m.alerts.get("pair:SEN-4").state == "CLEARED", "the message about the waiting computer is done")
    local kinds = {}
    for _, a in ipairs(m.audits) do kinds[#kinds + 1] = a.kind end
    assert(table.concat(kinds, ","):find("node_accepted", 1, true))
  end,

  test_rejecting_is_told_to_the_node_and_the_id_is_ignored_afterwards = function()
    local m = fake_master({ revisions = { ["SEN-4"] = 3 } })
    m.event("SEN-4", { type = "pair_announce", role = "sensor" })
    local ok = m.runtime.pair_decide("reject", "SEN-4", "PANEL-1")
    assert(ok)
    local replies = m.replies("SEN-4")
    assert(replies[#replies].state == "rejected")
    m.event("SEN-4", { type = "pair_announce", role = "sensor" })
    assert(m.pairing.count() == 0, "muted")
    assert(m.replies("SEN-4")[#m.replies("SEN-4")].state == "muted")
    local bad, why = m.runtime.pair_decide("explode", "SEN-4", "x")
    assert(bad == false and why:find("Unbekannte Aktion", 1, true))
    local none, why2 = m.runtime.pair_decide("accept", "NOBODY", "x")
    assert(none == false and why2:find("Kein wartender", 1, true))
  end,

  test_a_master_without_pairing_behaves_as_before = function()
    local fs = memfs.new()
    local acks = 0
    local runtime = runtime_factory.new({
      config = { nodes = { { id = "X-1", role = "signal" } } }, registry = registry_factory.new(),
      dispatcher = { get_overview = function() return {} end, timeout_node = function() end },
      network = { receive = function() return "ok" end, ack_for = function() acks = acks + 1 end, send = function() end, tick = function() end },
      ui = { mark_dirty = function() end, draw = function() end, handle_touch = function() end },
      auto_restore_state = false, auto_save_state = false,
    })
    runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "a.1", type = "event", src = "X-1", dst = "M", payload = { type = "pair_announce", role = "signal" } } })
    runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "a.2", type = "register", src = "X-1", dst = "M", payload = { role = "signal" } } })
    assert(runtime.registry.all()["X-1"], "a computer of the plan registers as always")
    runtime.handle_event({ "modem_message", nil, nil, nil, { v = 1, id = "a.3", type = "register", src = "X-2", dst = "M", payload = { role = "signal" } } })
    assert(runtime.registry.all()["X-2"] == nil, "a computer that is not in the plan does not, with or without a pairing book")
    local ok, err = runtime.pair_decide("accept", "X-1", "x")
    assert(ok == false and err:find("nicht verfuegbar", 1, true))
    assert(fs ~= nil)
  end,
}
