--[[
Purpose: Pairing on the master: candidates, what is cut down before it is kept, the limits, and what accepting does to the plan file.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local memfs = require("tests.harness.memfs")
local prng = require("tests.harness.prng")
local pairing = require("src.master.pairing")
local netplan = require("src.setup.netplan")
local json = require("src.shared.json")

local PLAN = "configs/network.json"

local function base_cfg()
  return {
    v = 1, channel = 777, master_id = "MASTER-1",
    nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-1", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_0" } },
    blocks = {}, routes = {},
  }
end

-- a master with its plan on a disk and a clock that the test moves
local function master(cfg_override)
  local fs = memfs.new()
  local cfg = cfg_override or base_cfg()
  fs.set(PLAN, netplan.encode(cfg))
  local clock = { t = 1000 }
  local audits = {}
  local p = pairing.new({
    config = cfg, plan_path = PLAN, fs = fs, now_s = function() return clock.t end,
    audit = function(kind, data) audits[#audits + 1] = { kind = kind, data = data } end,
  })
  return p, { fs = fs, cfg = cfg, clock = clock, audits = audits }
end

local function plan_on_disk(world) return assert(netplan.parse(world.fs.files[PLAN])) end

return {
  test_a_computer_that_is_in_the_plan_is_known_and_leaves_no_candidate = function()
    local p = master()
    assert(p.announce("SIG-1", { role = "signal" }) == "known")
    assert(p.announce("MASTER-1", { role = "master" }) == "known")
    assert(p.count() == 0 and #p.list() == 0)
  end,

  test_an_unknown_computer_becomes_a_candidate_and_a_later_entry_replaces_the_guess = function()
    local p, w = master()
    assert(p.announce("SIG-7", { role = "signal" }) == "pending")
    local first = p.get("SIG-7")
    assert(first.state == "pending" and first.role == "signal" and first.entry.id == "SIG-7" and first.entry.peripheral == nil, "a heartbeat tells no more than id and role")
    local first_seen, first_last = first.first_seen, first.last_seen
    w.clock.t = w.clock.t + 5
    assert(p.announce("SIG-7", { role = "signal", entry = { id = "SIG-7", role = "signal", adapter = "peripheral", peripheral = "Create_Signal_3" }, setup = { state = "GEPRUEFT", fail = 0, warn = 1, version = "main-abc" } }) == "pending")
    local second = p.get("SIG-7")
    assert(second.entry.peripheral == "Create_Signal_3" and second.setup.state == "GEPRUEFT" and second.setup.warn == 1 and second.first_seen == first_seen and second.last_seen > first_last)
    -- a heartbeat afterwards does not throw the entry away
    assert(p.announce("SIG-7", { role = "signal" }) == "pending")
    assert(p.get("SIG-7").entry.peripheral == "Create_Signal_3")
    assert(p.count() == 1)
    local kinds = {}
    for _, a in ipairs(w.audits) do kinds[#kinds + 1] = a.kind end
    assert(table.concat(kinds, ",") == "pair_candidate", "one audit line for the first sight, not one per heartbeat")
  end,

  test_a_known_id_with_another_role_is_a_conflict_that_cannot_be_accepted = function()
    local p, w = master()
    local state, detail = p.announce("SIG-1", { role = "sensor" })
    assert(state == "conflict" and detail == "signal")
    assert(p.get("SIG-1").state == "conflict")
    local ok, message = p.accept("SIG-1", "PANEL-1")
    assert(ok == false and message:find("anderer Rolle", 1, true))
    assert(w.fs.files[PLAN] == netplan.encode(w.cfg), "the plan is untouched")
  end,

  test_ids_and_roles_that_make_no_sense_are_refused = function()
    local p = master()
    assert(p.announce("bad id!", { role = "signal" }) == "invalid")
    assert(p.announce("", { role = "signal" }) == "invalid")
    assert(p.announce(nil, { role = "signal" }) == "invalid")
    assert(p.announce("X-1", { role = "wizard" }) == "invalid")
    assert(p.announce("X-1", { role = 5 }) == "invalid")
    assert(p.announce("X-1", nil) == "invalid")
    assert(p.announce("MASTER-2", { role = "master" }) == "invalid", "a second master is no candidate")
    assert(p.count() == 0)
  end,

  test_what_arrives_is_cut_down_before_it_is_kept = function()
    local p = master()
    local cyclic = { id = "SIG-8", role = "signal" }
    cyclic.self = cyclic
    p.announce("SIG-8", { role = "signal", entry = cyclic })
    assert(pcall(json.encode, p.get("SIG-8").entry), "a cycle is cut: what is kept can be written out")

    p.announce("SIG-9", { role = "signal", entry = { id = "SOMEONE-ELSE", role = "master", adapter = "redstone", side = "left" } })
    local entry = p.get("SIG-9").entry
    assert(entry.id == "SIG-9" and entry.role == "signal" and entry.adapter == "redstone", "id and role are those of the sender")

    local big = { id = "SIG-10", role = "signal", notes = {} }
    for i = 1, 30 do big.notes[i] = string.rep("x", 90) end
    p.announce("SIG-10", { role = "signal", entry = big })
    assert(p.get("SIG-10").entry.notes == nil, "an entry that is too large becomes the minimal one")

    p.announce("SIG-11", { role = "signal", entry = { id = "SIG-11", role = "signal", long = string.rep("y", 500), fn = function() end, nan = 0 / 0, deep = { a = { b = { c = { d = { e = 1 } } } } }, ok = "fine" } })
    local cleaned = p.get("SIG-11").entry
    assert(cleaned.long == nil and cleaned.fn == nil and cleaned.nan == nil and cleaned.ok == "fine")
    assert(cleaned.deep and cleaned.deep.a and cleaned.deep.a.b and cleaned.deep.a.b.c == nil, "nothing deeper than four levels")

    p.announce("SIG-12", { role = "signal", setup = { state = "FREIGEGEBEN", fail = -3, warn = 5000, version = string.rep("v", 100), junk = 1 } })
    assert(p.get("SIG-12").setup == nil, "no known field survives: " .. tostring(p.get("SIG-12").setup and json.encode(p.get("SIG-12").setup)))
    p.announce("SIG-13", { role = "signal", setup = { state = "PRUEFUNG_OFFEN", fail = 2.7, warn = 1, junk = 1 } })
    local setup = p.get("SIG-13").setup
    assert(setup.state == "PRUEFUNG_OFFEN" and setup.fail == 2 and setup.warn == 1 and setup.junk == nil)
  end,

  test_the_number_of_candidates_and_their_age_are_bounded = function()
    local p, w = master()
    for i = 1, 64 do assert(p.announce("N-" .. i, { role = "signal" }) == "pending", i) end
    assert(p.announce("N-65", { role = "signal" }) == "full" and p.count() == 64)
    assert(p.announce("N-1", { role = "signal" }) == "pending", "a candidate that is there is only refreshed")
    w.clock.t = w.clock.t + 3601
    assert(p.count() == 0, "forgotten when not heard for an hour")
    assert(p.announce("N-65", { role = "signal" }) == "pending", "room again")
  end,

  test_a_rejected_id_is_ignored_for_a_while = function()
    local p, w = master()
    p.announce("SIG-7", { role = "signal" })
    local ok = p.reject("SIG-7", "PANEL-1")
    assert(ok and p.count() == 0)
    assert(p.announce("SIG-7", { role = "signal" }) == "muted" and p.count() == 0)
    w.clock.t = w.clock.t + 601
    assert(p.announce("SIG-7", { role = "signal" }) == "pending")
    assert(p.reject("NOBODY") == false)
  end,

  test_accepting_writes_the_entry_into_the_plan_keeps_the_rest_and_the_old_file = function()
    local cfg = base_cfg()
    cfg.blocks = { { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-1", sensors = {}, switches = {} } }
    cfg.tuning = nil
    local p, w = master(cfg)
    local before = w.fs.files[PLAN]
    p.announce("SEN-4", { role = "sensor", entry = { id = "SEN-4", role = "sensor", adapter = "redstone", side = "back" } })
    local ok, message = p.accept("SEN-4", "PANEL-1")
    assert(ok, tostring(message))
    local plan = plan_on_disk(w)
    local entry = assert(netplan.find_node(plan, "SEN-4"))
    assert(entry.role == "sensor" and entry.adapter == "redstone" and entry.side == "back")
    assert(#plan.nodes == 3 and plan.channel == 777 and #plan.blocks == 1 and plan.master_id == "MASTER-1", "the rest of the plan is as it was")
    assert(w.fs.files[PLAN .. ".prev"] == before, "the old plan stays as .prev")
    assert(select(2, netplan.parse(w.fs.files[PLAN])) == nil, "the new plan validates")
    assert(netplan.find_node(w.cfg, "SEN-4"), "the loaded plan knows it too")
    assert(p.count() == 0)
    assert(p.announce("SEN-4", { role = "sensor" }) == "known", "from now on it is known")
    local audited = false
    for _, a in ipairs(w.audits) do if a.kind == "node_accepted" and a.data.node_id == "SEN-4" and a.data.by == "PANEL-1" then audited = true end end
    assert(audited)
    local again, why = p.accept("SEN-4", "PANEL-1")
    assert(again == false and why:find("Kein wartender", 1, true))
  end,

  test_the_resolver_of_the_running_master_finds_an_accepted_computer = function()
    local hardware_config = require("src.adapter.hardware_config")
    local p, w = master()
    local hw = hardware_config.new(w.cfg)
    assert(hw.adapter("SIG-9") == "peripheral" and hw.side("SIG-9") == nil, "unknown so far")
    p.announce("SIG-9", { role = "signal", entry = { id = "SIG-9", role = "signal", adapter = "redstone", side = "left" } })
    local ok, message = p.accept("SIG-9", "PANEL-1")
    assert(ok, message)
    assert(hw.adapter("SIG-9") == "redstone" and hw.side("SIG-9") == "left", "the entry of the accepted computer is used, not only after a restart")
    assert(hw.target("SIG-1") == "Create_Signal_0", "the others are untouched")
    assert(message:find("Neustart des Masters", 1, true), "the operator is told what a restart is still needed for")
  end,

  test_a_broken_plan_file_is_not_touched = function()
    local p, w = master()
    p.announce("SIG-7", { role = "signal" })
    w.fs.set(PLAN, "{ not json")
    local ok, message = p.accept("SIG-7", "PANEL-1")
    assert(ok == false and message:find("kein gueltiges JSON", 1, true))
    assert(w.fs.files[PLAN] == "{ not json" and w.fs.files[PLAN .. ".prev"] == nil)
    w.fs.set(PLAN, '{"v":1,"channel":0,"master_id":"MASTER-1","nodes":[{"id":"MASTER-1","role":"master"}],"blocks":[],"routes":[]}')
    local ok2, message2 = p.accept("SIG-7", "PANEL-1")
    assert(ok2 == false and message2:find("Fehler", 1, true) and message2:find("nichts geaendert", 1, true), message2)
    w.fs.files[PLAN] = nil
    local ok3, message3 = p.accept("SIG-7", "PANEL-1")
    assert(ok3 == false and message3:find("nicht gefunden", 1, true))
    assert(p.get("SIG-7"), "the candidate waits for the plan to be repaired")
  end,

  test_an_entry_that_would_break_the_plan_is_not_written = function()
    local p, w = master()
    p.announce("ST-7", { role = "station", entry = { id = "ST-7", role = "station", station_type = "sideways", create_station_name = "Q" } })
    local before = w.fs.files[PLAN]
    local ok, message = p.accept("ST-7", "PANEL-1")
    assert(ok == false and message:find("ungueltig", 1, true), tostring(message))
    assert(w.fs.files[PLAN] == before and p.get("ST-7"))
  end,

  test_an_entry_that_was_added_by_hand_meanwhile_is_taken_over_not_duplicated = function()
    local p, w = master()
    p.announce("SIG-7", { role = "signal" })
    local plan = plan_on_disk(w)
    plan = netplan.add_node(plan, { id = "SIG-7", role = "signal", adapter = "redstone", side = "left" })
    w.fs.set(PLAN, netplan.encode(plan))
    local ok, message = p.accept("SIG-7", "PANEL-1")
    assert(ok and message:find("schon im Netzplan", 1, true))
    local count = 0
    for _, node in ipairs(plan_on_disk(w).nodes) do if node.id == "SIG-7" then count = count + 1 end end
    assert(count == 1 and netplan.find_node(w.cfg, "SIG-7"))
  end,

  test_random_announcements_never_break_the_book = function()
    local ids = { "SIG-1", "SIG-2", "X", "bad id", "A-1", "A-2", "MASTER-1", "MASTER-9", "", "a.b" }
    local roles = { "signal", "sensor", "switch", "master", "station", "wizard", 5 }
    for seed = 1, 200 do
      local rng = prng.new(seed)
      local p, w = master()
      for _ = 1, 80 do
        local payload = rng.chance(0.2) and nil or { role = rng.pick(roles) }
        if payload and rng.chance(0.6) then
          payload.entry = rng.pick({ { id = "Z", role = "x" }, { adapter = "redstone", side = "left" }, 5, "text", { a = { b = { c = { d = { e = {} } } } } } })
          payload.setup = rng.chance(0.5) and { state = rng.pick({ "GEPRUEFT", "x", 5 }), fail = rng.pick({ 0, -1, 2.5, "a" }) } or nil
        end
        local ok, err = pcall(p.announce, rng.pick(ids), payload)
        assert(ok, "seed " .. seed .. ": " .. tostring(err))
        if rng.chance(0.1) then w.clock.t = w.clock.t + rng.int(1, 4000) end
        if rng.chance(0.1) then local list = p.list(); if #list > 0 then pcall(p.reject, list[rng.int(1, #list)].id, "x") end end
        if rng.chance(0.1) then local list = p.list(); if #list > 0 then assert(pcall(p.accept, list[rng.int(1, #list)].id, "x")) end end
      end
      local list = p.list()
      assert(#list <= 64 and #list == p.count(), "seed " .. seed)
      local previous
      for _, candidate in ipairs(list) do
        assert(candidate.entry.id == candidate.id and candidate.entry.role == candidate.role, "seed " .. seed)
        assert(netplan.valid_id(candidate.id), "seed " .. seed)
        assert(not previous or previous < candidate.id, "sorted, seed " .. seed)
        previous = candidate.id
      end
      assert(select(2, netplan.parse(w.fs.files[PLAN])) == nil, "the plan on disk stays valid, seed " .. seed)
    end
  end,
}
