--[[
Purpose: The durable journal: contiguous sequence numbers, checksums, commit markers, snapshots, repair of a torn tail, refusal on damage in the middle, disk errors,
  bounded size, and a crash at every filesystem operation (Gesamtkonzept Kap. 5.2, 5.4, tests J-07, J-08, J-09).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local journal = require("src.shared.journal")
local memfs = require("tests.harness.memfs")

local PATH = "state/journal.log"

local function open(fs, opts)
  opts = opts or {}
  opts.fs = fs
  local j = journal.new(PATH, opts)
  local status, info = j.open()
  return j, status, info
end

local function seqs(list)
  local out = {}
  for i, entry in ipairs(list) do out[i] = entry.seq end
  return out
end

return {
  test_a_new_journal_is_fresh_and_appends_contiguous_sequence_numbers = function()
    local fs = memfs.new()
    local j, status = open(fs)
    assert(status == "fresh")
    for i = 1, 5 do assert(j.append("event", { n = i }) == i) end
    assert(j.last_seq() == 5 and j.committed() == 0)
    local again, status2 = open(fs)
    assert(status2 == "ok" and again.last_seq() == 5)
    local recovered = again.recovered()
    assert(#recovered.entries == 5 and recovered.entries[3].data.n == 3 and recovered.entries[3].kind == "event")
    assert(recovered.state == nil and recovered.snapshot_seq == 0)
  end,

  test_commit_markers_persist_and_cannot_run_ahead = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 4 do j.append("event", { n = i }) end
    assert(j.commit(2) and j.committed() == 2)
    assert(j.commit(1) and j.committed() == 2, "a lower commit changes nothing")
    local ok, err = j.commit(99)
    assert(ok == nil and err:find("never appended", 1, true))
    assert(j.commit(4) and j.committed() == 4)
    local again = open(fs)
    assert(again.committed() == 4)
    assert(again.last_seq() == 6, "two commit markers are entries too")
  end,

  test_a_torn_tail_is_cut_off_and_the_journal_goes_on_with_the_next_number = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 3 do j.append("event", { n = i }) end
    local whole = fs.files[PATH]
    fs.files[PATH] = whole .. "4\tevent\t{\"n\":4"   -- a write that was interrupted: no end of line, no checksum
    local again, status, info = open(fs)
    assert(status == "tail_repaired" and info.cut)
    assert(again.last_seq() == 3)
    assert(fs.files[PATH] == whole, "the torn text is gone from the file")
    assert(again.append("event", { n = 4 }) == 4)
    assert(open(fs).last_seq() == 4)
  end,

  test_a_last_line_with_a_wrong_checksum_is_treated_as_torn = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 3 do j.append("event", { n = i }) end
    local text = fs.files[PATH]
    fs.files[PATH] = text:sub(1, #text - 2) .. "0\n"
    local again, status = open(fs)
    assert(status == "tail_repaired" and again.last_seq() == 2)
  end,

  test_damage_in_the_middle_locks_the_journal = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 6 do j.append("event", { n = i }) end
    local text = fs.files[PATH]
    local damaged = text:gsub('"n":3', '"n":9', 1)
    assert(damaged ~= text)
    fs.files[PATH] = damaged
    local again, status, info = open(fs)
    assert(status == "corrupt" and info.reason:find("followed by more", 1, true))
    local seq, err = again.append("event", { n = 7 })
    assert(seq == nil and err:find("locked", 1, true))
    assert(again.status().locked == true and again.status().writable == false)
    assert(fs.files[PATH] == damaged, "a damaged journal is not touched: it is evidence")
    -- the same on a second reading
    local third, status3 = open(fs)
    assert(status3 == "corrupt" and third.status().locked)
  end,

  test_a_missing_line_in_the_middle_is_a_hole = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 5 do j.append("event", { n = i }) end
    local lines = {}
    for line in fs.files[PATH]:gmatch("[^\n]*\n") do lines[#lines + 1] = line end
    table.remove(lines, 4) -- entry 3 is gone
    fs.files[PATH] = table.concat(lines)
    local _, status = open(fs)
    assert(status == "corrupt")
  end,

  test_a_damaged_header_locks_the_journal = function()
    local fs = memfs.new()
    local j = open(fs)
    j.append("event", { n = 1 })
    fs.files[PATH] = fs.files[PATH]:gsub("#CRNJ1", "#CRNJ2", 1)
    local _, status, info = open(fs)
    assert(status == "corrupt" and info.reason:find("header", 1, true))
  end,

  test_a_snapshot_replaces_the_old_entries_and_recovery_returns_state_plus_the_rest = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 5 do j.append("event", { n = i }) end
    j.commit(5)
    assert(j.snapshot({ total = 5 }))
    assert(j.status().entries == 0 and j.snapshot_seq() == 6)
    j.append("event", { n = 7 })
    j.append("event", { n = 8 })
    local again, status = open(fs)
    assert(status == "ok")
    local recovered = again.recovered()
    assert(recovered.state.total == 5 and recovered.snapshot_seq == 6 and recovered.committed == 5)
    assert(table.concat(seqs(recovered.entries), ",") == "7,8")
    assert(again.last_seq() == 8)
    assert(#fs.files[PATH] < 400, "the journal file starts over after the snapshot")
  end,

  test_a_crash_between_snapshot_and_journal_rewrite_loses_nothing_and_finishes_the_compaction = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 4 do j.append("event", { n = i }) end
    -- the snapshot file is written, then the machine dies before the journal is rewritten: old entries 1..4 stay below the snapshot
    local snapshot_text = require("src.shared.json").encode({ v = 1, seq = 4, committed = 0, saved_at = 0, state = { total = 4 } })
    fs.files[PATH .. ".snap"] = snapshot_text
    local again, status, info = open(fs)
    assert(status == "ok" and info.finished_compaction)
    local recovered = again.recovered()
    assert(recovered.state.total == 4 and #recovered.entries == 0 and again.last_seq() == 4)
    assert(again.append("event", { n = 5 }) == 5)
    assert(open(fs).recovered().entries[1].seq == 5)
  end,

  test_a_damaged_current_snapshot_with_a_journal_that_starts_after_it_is_a_hole = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 3 do j.append("event", { n = i }) end
    assert(j.snapshot({ total = 3 }))
    for i = 4, 6 do j.append("event", { n = i }) end
    assert(j.snapshot({ total = 6 }))
    fs.files[PATH .. ".snap"] = "garbage"
    local _, status = open(fs)
    assert(status == "corrupt", "the previous snapshot is older than the journal start: not usable")
    -- both damaged
    fs.files[PATH .. ".snap.prev"] = "garbage"
    local _, status2, info = open(fs)
    assert(status2 == "corrupt" and info.reason:find("snapshot", 1, true))
  end,

  test_a_full_disk_stops_appends_and_nothing_is_lost_when_space_returns = function()
    local fs = memfs.new()
    local j = open(fs)
    for i = 1, 3 do assert(j.append("event", { n = i })) end
    fs.capacity = fs.used() + 10
    local seq, err = j.append("event", { n = 4, filler = string.rep("x", 200) })
    assert(seq == nil and err, "a write that does not fit is refused")
    assert(j.status().failed == true and j.status().writable == false)
    local again_seq, again_err = j.append("event", { n = 5 })
    assert(again_seq == nil and again_err:find("failed", 1, true), "once failed, no more appends until reopen")
    fs.capacity = nil
    local status = j.reopen()
    assert(status == "ok")
    assert(j.append("event", { n = 4 }) == 4, "the refused entry never got a number")
    assert(open(fs).last_seq() == 4)
  end,

  test_entries_that_cannot_be_written_are_refused = function()
    local fs = memfs.new()
    local j = open(fs)
    assert(j.append("bad kind with spaces", {}) == nil)
    assert(j.append("event", { f = function() end }) == nil)
    assert(j.append("event", { s = "line\nbreak and\ttab" }), "control characters are escaped, not refused")
    assert(open(fs).recovered().entries[1].data.s == "line\nbreak and\ttab")
  end,

  test_the_journal_compacts_itself_and_stays_bounded = function()
    local fs = memfs.new()
    local total = 0
    local j = journal.new(PATH, { fs = fs, max_entries = 50, max_bytes = 100000, state_fn = function() return { total = total } end })
    j.open()
    for i = 1, 1000 do
      total = i
      assert(j.append("event", { n = i }))
      assert(j.status().entries <= 51, "entries in memory stay bounded, got " .. j.status().entries)
    end
    assert(#fs.files[PATH] < 5000, "the file stays small, got " .. #fs.files[PATH])
    local again = open(fs)
    local recovered = again.recovered()
    assert(again.last_seq() == 1000)
    assert(recovered.state.total == recovered.snapshot_seq, "snapshot and sequence agree")
    assert(recovered.snapshot_seq + #recovered.entries == 1000)
  end,

  test_without_a_state_function_appends_stop_at_four_times_the_size = function()
    local fs = memfs.new()
    local j = journal.new(PATH, { fs = fs, max_bytes = 2000 })
    j.open()
    local stopped_at
    for i = 1, 1000 do
      local seq, err = j.append("event", { n = i, filler = string.rep("y", 40) })
      if not seq then stopped_at = i; assert(err:find("full", 1, true)); break end
    end
    assert(stopped_at, "a journal that cannot compact must say it is full")
    assert(#fs.files[PATH] <= 2000 * 4 + 200)
    assert(j.status().writable == false)
  end,

  -- the central claim: whatever instant the computer dies at, the journal reads back as a prefix of what was written, with everything that was acknowledged
  test_a_crash_at_every_filesystem_operation_leaves_a_consistent_journal = function()
    local function script(fs, crash_at)
      fs.ops, fs.crash_at, fs.crashed, fs.sticky_crash = 0, crash_at, false, true
      local acked_seq, acked_commit, state_total = 0, 0, 0
      local j = journal.new(PATH, { fs = fs, max_entries = 7, max_bytes = 100000, state_fn = function() return { total = state_total } end })
      local ok = pcall(function()
        j.open()
        for i = 1, 25 do
          state_total = i
          local seq = j.append("event", { n = i })
          if seq then acked_seq = seq end
          if i % 3 == 0 and seq and j.commit(seq) then acked_commit = seq end
          if i == 12 then
            j.snapshot({ total = i })
          end
        end
      end)
      return ok, acked_seq, acked_commit
    end

    -- how many operations does the whole run take?
    local probe = memfs.new()
    local finished = script(probe, nil)
    assert(finished)
    local operations = probe.ops
    assert(operations > 40, "the script must do a lot of file operations, did " .. operations)

    for crash_at = 1, operations + 1 do
      local fs = memfs.new()
      local _, acked_seq, acked_commit = script(fs, crash_at)
      -- the reboot
      fs.crash_at, fs.crashed = nil, false
      local j, status = open(fs)
      assert(status == "ok" or status == "tail_repaired" or status == "fresh", "crash " .. crash_at .. ": status " .. tostring(status))
      local recovered = j.recovered()
      local expected = recovered.snapshot_seq + 1
      for _, entry in ipairs(recovered.entries) do
        assert(entry.seq == expected, "crash " .. crash_at .. ": numbers must be contiguous")
        expected = expected + 1
      end
      assert(j.last_seq() >= acked_seq or recovered.snapshot_seq >= acked_seq, "crash " .. crash_at .. ": acknowledged entry " .. acked_seq .. " was lost (last " .. j.last_seq() .. ")")
      assert(j.last_seq() <= acked_seq + 2, "crash " .. crash_at .. ": more than one unacknowledged entry appeared")
      assert(j.committed() <= j.last_seq(), "crash " .. crash_at .. ": committed beyond the end")
      assert(j.committed() >= acked_commit, "crash " .. crash_at .. ": an acknowledged commit was lost")
      -- and it can go on
      local before = j.last_seq()
      assert(j.append("event", { n = 100 }) == before + 1, "crash " .. crash_at .. ": no append after recovery")
      local after = open(fs)
      assert(after.last_seq() == before + 1, "crash " .. crash_at .. ": the journal does not read back the same after a new append")
    end
  end,

  test_event_payloads_survive_the_trip_through_a_snapshot_and_a_crash_free_reopen = function()
    local fs = memfs.new()
    local j = open(fs)
    j.append("route_reserved", { train = "T1", route = "R-A-B", blocks = { "B1", "B2" } })
    j.append("route_released", { train = "T1", route = "R-A-B" })
    local again = open(fs)
    local entries = again.recovered().entries
    assert(entries[1].kind == "route_reserved" and entries[1].data.blocks[2] == "B2")
    assert(again.entries_after(1)[1].kind == "route_released" and #again.entries_after(2) == 0)
  end,

  test_a_header_with_a_wrong_checksum_locks_the_journal = function()
    local fs = memfs.new()
    local j = open(fs)
    j.append("event", { n = 1 })
    local text = fs.files[PATH]
    local damaged = text:gsub("^(#CRNJ1\t0\t)%x%x%x%x%x%x%x%x", "%100000000", 1)
    assert(damaged ~= text)
    fs.files[PATH] = damaged
    local _, status = open(fs)
    assert(status == "corrupt")
  end,

  test_a_last_line_without_its_line_end_is_cut_even_when_its_checksum_is_right = function()
    local fs = memfs.new()
    local j = open(fs)
    j.append("event", { n = 1 })
    j.append("event", { n = 2 })
    fs.files[PATH] = fs.files[PATH]:sub(1, #fs.files[PATH] - 1) -- the line end of entry 2 never arrived
    local again, status = open(fs)
    assert(status == "tail_repaired" and again.last_seq() == 1, "an entry whose write did not finish was never acknowledged")
    assert(again.append("event", { n = 2 }) == 2)
    assert(open(fs).last_seq() == 2, "the next entry starts on a line of its own")
  end,
}
