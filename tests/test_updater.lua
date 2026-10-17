--[[
Purpose: Node side OTA: path rules, offer/need/chunk/commit, verification, swap, rollback and trial boot, on an in-memory fs.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local updater = require("src.shared.updater")
local checksum = require("src.shared.checksum")
local ota_recovery = require("src.shared.ota_recovery")
local memfs = require("tests.harness.memfs")

local OLD = {
  ["src/shared/net.lua"] = "-- net v1\nreturn {}\n",
  ["src/nodes/signal_node.lua"] = "-- signal v1\nreturn {}\n",
  ["crn_version.txt"] = "v1"
}
local NEW = {
  ["src/shared/net.lua"] = "-- net v2\nreturn { fixed = true }\n",
  ["src/nodes/signal_node.lua"] = OLD["src/nodes/signal_node.lua"],
  ["src/nodes/sensor_node.lua"] = "-- sensor v2\nreturn {}\n"
}

local function manifest(files)
  local list = {}
  for path, body in pairs(files) do list[#list + 1] = { path = path, size = #body, adler = checksum.adler32(body) } end
  table.sort(list, function(a, b) return a.path < b.path end)
  return list
end

local function world(opts)
  local w = { fs = memfs.new(), events = {}, reboots = 0, quiesced = 0 }
  for path, body in pairs(OLD) do w.fs.set(path, body) end
  local network = { send_reliable = function(kind, dst, payload) w.events[#w.events + 1] = { kind = kind, dst = dst, payload = payload } end }
  w.updater = updater.new(network, "N1", nil, {
    fs = w.fs, sources = (opts and opts.sources) or { "M" },
    quiesce = function() w.quiesced = w.quiesced + 1; if opts and opts.quiesce_fails then return false, "outputs busy" end; return true end,
    reboot = function() w.reboots = w.reboots + 1 end, sleep = function() end
  })
  return w
end

local function last_event(w, event_type)
  for i = #w.events, 1, -1 do if w.events[i].payload.type == event_type then return w.events[i].payload end end
  return nil
end

-- offer + all chunks of the needed files (optionally split in pieces)
local function stage_all(w, files, pieces)
  assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest(files) }, "M"))
  local need = last_event(w, "ota_need").need
  for _, path in ipairs(need) do
    local body = files[path]
    local count = math.max(1, math.min(pieces or 1, #body))
    local size = math.ceil(#body / count)
    for i = 1, count do
      local ok, err = w.updater.chunk({ update_id = "u1", path = path, index = i, total = count, data = body:sub((i - 1) * size + 1, i * size) }, "M")
      assert(ok, err)
    end
  end
  return need
end

local function state_of(w, files)
  local out = {}
  for path in pairs(files) do out[path] = w.fs.files[path] end
  return out
end

local function leftovers(w)
  local found = {}
  for path in pairs(w.fs.files) do if path:find("%.ota_") or path == ota_recovery.JOURNAL or path == ota_recovery.STAGE_LIST or path:find("%.tmp$") then found[#found + 1] = path end end
  table.sort(found)
  return found
end

return {
  test_path_rules = function()
    for _, good in ipairs({ "src/shared/net.lua", "scripts/start_master.lua", "scripts/ota_push.lua", "configs/templates/network.full.example.json" }) do
      assert(updater.valid_path(good), good)
    end
    for _, bad in ipairs({ "startup.lua", "../etc/passwd.lua", "/abs.lua", "src/../x.lua", "state/master_state.json", "src/a.ota_new", "src/x.txt", "src//x.lua", "scripts/", "configs/node.json", "src/a b.lua", "", "src/x.lua\n" }) do
      assert(not updater.valid_path(bad), "accepted: " .. bad)
    end
    assert(not updater.valid_path(nil) and not updater.valid_path(12))
  end,

  test_offer_requests_only_files_that_differ = function()
    local w = world()
    assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest(NEW) }, "M"))
    local need = last_event(w, "ota_need")
    assert(need and need.update_id == "u1" and #need.need == 2)
    assert(need.need[1] == "src/nodes/sensor_node.lua" and need.need[2] == "src/shared/net.lua", "unchanged signal_node must not be requested")
    assert(w.events[#w.events].dst == "M")
  end,

  test_offer_for_current_files_answers_up_to_date_and_changes_nothing = function()
    local w = world()
    local current = { ["src/shared/net.lua"] = OLD["src/shared/net.lua"] }
    assert(w.updater.offer({ update_id = "u2", version = "v1", files = manifest(current) }, "M"))
    local result = last_event(w, "ota_result")
    assert(result and result.success and result.up_to_date and w.updater.session_id() == nil)
    assert(w.reboots == 0)
  end,

  test_offer_from_unknown_source_is_refused_without_touching_anything = function()
    local w = world()
    local ok, err = w.updater.offer({ update_id = "u1", files = manifest(NEW) }, "EVIL")
    assert(ok == false and tostring(err):find("not allowed"))
    assert(#w.events == 0 and w.updater.session_id() == nil)
  end,

  test_offer_with_a_path_outside_the_allowed_roots_is_refused = function()
    local w = world()
    local files = manifest(NEW)
    files[#files + 1] = { path = "state/master_state.json", size = 1, adler = 1 }
    local ok = w.updater.offer({ update_id = "u1", files = files }, "M")
    assert(ok == false)
    local result = last_event(w, "ota_result")
    assert(result and result.success == false and tostring(result.errors[1]):find("path not allowed"))
  end,

  test_chunks_may_arrive_out_of_order_and_twice = function()
    local w = world()
    assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest({ ["src/shared/net.lua"] = NEW["src/shared/net.lua"] }) }, "M"))
    local body = NEW["src/shared/net.lua"]
    local a, b = body:sub(1, 10), body:sub(11)
    assert(w.updater.chunk({ update_id = "u1", path = "src/shared/net.lua", index = 2, total = 2, data = b }, "M"))
    assert(w.updater.chunk({ update_id = "u1", path = "src/shared/net.lua", index = 2, total = 2, data = b }, "M"))
    assert(w.fs.files["src/shared/net.lua.ota_new"] == nil, "not complete yet")
    assert(w.updater.chunk({ update_id = "u1", path = "src/shared/net.lua", index = 1, total = 2, data = a }, "M"))
    assert(w.fs.files["src/shared/net.lua.ota_new"] == body)
    assert(w.fs.files["src/shared/net.lua"] == OLD["src/shared/net.lua"], "live file untouched while staging")
  end,

  test_damaged_file_is_never_staged_and_asked_for_again = function()
    local w = world()
    assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest({ ["src/shared/net.lua"] = NEW["src/shared/net.lua"] }) }, "M"))
    local damaged = NEW["src/shared/net.lua"]:gsub("v2", "vX")
    local ok, err = w.updater.chunk({ update_id = "u1", path = "src/shared/net.lua", index = 1, total = 1, data = damaged }, "M")
    assert(ok == true and tostring(err):find("asked again"), "the chunk was handled; the remedy is the new ota_need")
    assert(w.fs.files["src/shared/net.lua.ota_new"] == nil)
    local again = last_event(w, "ota_need")
    assert(again and again.need[1] == "src/shared/net.lua" and tostring(again.reason):find("checksum"))
  end,

  test_chunk_for_a_file_that_was_not_requested_is_refused = function()
    local w = world()
    assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest(NEW) }, "M"))
    local ok = w.updater.chunk({ update_id = "u1", path = "src/nodes/signal_node.lua", index = 1, total = 1, data = "x" }, "M")
    assert(ok == false)
    assert(w.updater.chunk({ update_id = "other", path = "src/shared/net.lua", index = 1, total = 1, data = "x" }, "M") == false)
  end,

  test_commit_before_everything_arrived_changes_nothing = function()
    local w = world()
    assert(w.updater.offer({ update_id = "u1", version = "v2", files = manifest(NEW) }, "M"))
    local before = state_of(w, OLD)
    local ok, err = w.updater.commit({ update_id = "u1" }, "M")
    assert(ok == false and tostring(err):find("incomplete"))
    assert(w.reboots == 0 and w.quiesced == 0)
    for path, body in pairs(before) do assert(w.fs.files[path] == body) end
    assert(#last_event(w, "ota_need").need == 2)
  end,

  test_commit_swaps_all_files_writes_version_and_reboots_once = function()
    local w = world()
    stage_all(w, NEW, 3)
    assert(w.updater.commit({ update_id = "u1" }, "M"))
    assert(w.fs.files["src/shared/net.lua"] == NEW["src/shared/net.lua"])
    assert(w.fs.files["src/nodes/sensor_node.lua"] == NEW["src/nodes/sensor_node.lua"])
    assert(w.fs.files["src/nodes/signal_node.lua"] == OLD["src/nodes/signal_node.lua"])
    assert(w.fs.files["crn_version.txt"] == "v2")
    assert(w.reboots == 1 and w.quiesced == 1)
    local result = last_event(w, "ota_result")
    assert(result.success and result.version == "v2" and result.files == 2)
    local journal = ota_recovery.read_journal(w.fs)
    assert(journal and journal.state == "trial" and journal.boots == 0)
    assert(w.fs.files["src/shared/net.lua.ota_bak"] == OLD["src/shared/net.lua"], "old content is kept for the trial boot")
  end,

  test_quiesce_failure_aborts_before_any_file_is_touched = function()
    local w = world({ quiesce_fails = true })
    stage_all(w, NEW)
    local ok, err = w.updater.commit({ update_id = "u1" }, "M")
    assert(ok == false and tostring(err):find("quiesce"))
    assert(w.reboots == 0)
    for path, body in pairs(OLD) do assert(w.fs.files[path] == body) end
    assert(#leftovers(w) == 0, table.concat(leftovers(w), ","))
    local result = last_event(w, "ota_result")
    assert(result.success == false and tostring(result.errors[1]):find("outputs busy"))
  end,

  test_failing_move_rolls_everything_back = function()
    local w = world()
    stage_all(w, NEW)
    w.fs.fail.move_for = "src/shared/net.lua"
    local ok = w.updater.commit({ update_id = "u1" }, "M")
    assert(ok == false)
    for path, body in pairs(OLD) do assert(w.fs.files[path] == body, path .. " must be back to the old content") end
    assert(w.fs.files["src/nodes/sensor_node.lua"] == nil, "a file that did not exist before must be gone again")
    assert(#leftovers(w) == 0, table.concat(leftovers(w), ","))
    assert(w.reboots == 0)
    assert(last_event(w, "ota_result").success == false)
  end,

  test_trial_boot_is_kept_and_confirmed = function()
    local w = world()
    stage_all(w, NEW)
    assert(w.updater.commit({ update_id = "u1" }, "M"))
    local action = ota_recovery.recover(w.fs)
    assert(action == "kept")
    assert(w.fs.files["src/shared/net.lua"] == NEW["src/shared/net.lua"])
    assert(w.updater.confirm_boot() == true)
    assert(#leftovers(w) == 0, table.concat(leftovers(w), ","))
    assert(ota_recovery.recover(w.fs) == "none")
  end,

  test_unconfirmed_trial_is_rolled_back_on_the_next_boot = function()
    local w = world()
    stage_all(w, NEW)
    assert(w.updater.commit({ update_id = "u1" }, "M"))
    assert(ota_recovery.recover(w.fs) == "kept", "first boot of the new code")
    -- the new code crashed before it confirmed; the computer is started again
    assert(ota_recovery.recover(w.fs) == "rolled_back")
    for path, body in pairs(OLD) do assert(w.fs.files[path] == body, path) end
    assert(w.fs.files["src/nodes/sensor_node.lua"] == nil)
    assert(#leftovers(w) == 0, table.concat(leftovers(w), ","))
  end,

  test_new_offer_is_refused_while_the_last_update_is_unconfirmed = function()
    local w = world()
    stage_all(w, NEW)
    assert(w.updater.commit({ update_id = "u1" }, "M"))
    local ok = w.updater.offer({ update_id = "u9", version = "v3", files = manifest(NEW) }, "M")
    assert(ok == false)
  end,

  -- the strongest check: the computer dies at every single filesystem operation of the commit
  test_a_crash_at_any_point_of_the_swap_leaves_all_old_or_all_new_files = function()
    local function run(crash_offset)
      local w = world()
      stage_all(w, NEW)
      w.fs.crash_at = crash_offset and (w.fs.ops + crash_offset) or nil
      local ran = pcall(w.updater.commit, { update_id = "u1" }, "M")
      w.fs.crash_at = nil
      return w, ran
    end

    local probe = world()
    stage_all(probe, NEW)
    local start = probe.fs.ops
    assert(probe.updater.commit({ update_id = "u1" }, "M"))
    local total = probe.fs.ops - start
    assert(total > 10)

    local paths = { "src/shared/net.lua", "src/nodes/signal_node.lua", "src/nodes/sensor_node.lua", "crn_version.txt" }
    local final_new = { ["src/shared/net.lua"] = NEW["src/shared/net.lua"], ["src/nodes/signal_node.lua"] = OLD["src/nodes/signal_node.lua"], ["src/nodes/sensor_node.lua"] = NEW["src/nodes/sensor_node.lua"], ["crn_version.txt"] = "v2" }
    local final_old = { ["src/shared/net.lua"] = OLD["src/shared/net.lua"], ["src/nodes/signal_node.lua"] = OLD["src/nodes/signal_node.lua"], ["crn_version.txt"] = "v1" }

    local function matches(w, expected)
      for _, path in ipairs(paths) do if w.fs.files[path] ~= expected[path] then return false end end
      return true
    end

    for offset = 1, total do
      local w = run(offset)
      local action = ota_recovery.recover(w.fs)
      local is_old, is_new = matches(w, final_old), matches(w, final_new)
      assert(is_old or is_new, string.format("crash at op %d/%d left a mix (recovery: %s)", offset, total, tostring(action)))
      if is_new then
        -- the update completed before the crash: it stays in trial and the next unconfirmed boot undoes it
        assert(ota_recovery.recover(w.fs) == "rolled_back")
        assert(matches(w, final_old), "unconfirmed trial must roll back, crash at op " .. offset)
      end
      assert(#leftovers(w) == 0, string.format("crash at op %d left %s", offset, table.concat(leftovers(w), ",")))
    end
  end,

  test_single_message_update_goes_through_the_same_safe_path = function()
    local w = world()
    local ok = w.updater.apply({ update_id = "legacy", version = "v2", files = {
      { path = "src/shared/net.lua", content = NEW["src/shared/net.lua"], adler = checksum.adler32(NEW["src/shared/net.lua"]) },
      { path = "src/nodes/sensor_node.lua", content = NEW["src/nodes/sensor_node.lua"] }
    } }, "M")
    assert(ok == true)
    assert(w.fs.files["src/shared/net.lua"] == NEW["src/shared/net.lua"] and w.fs.files["crn_version.txt"] == "v2" and w.reboots == 1)
    assert(ota_recovery.read_journal(w.fs).state == "trial")
  end,

  test_single_message_update_rejects_bad_path_and_bad_checksum = function()
    local w = world()
    local ok1 = w.updater.apply({ files = { { path = "state/master_state.json", content = "{}" } } }, "M")
    assert(ok1 == false)
    local ok2 = w.updater.apply({ files = { { path = "src/shared/net.lua", content = "x", adler = 1 } } }, "M")
    assert(ok2 == false)
    for path, body in pairs(OLD) do assert(w.fs.files[path] == body) end
    assert(w.reboots == 0)
  end
}
