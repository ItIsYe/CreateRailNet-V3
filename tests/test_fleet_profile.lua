--[[
Purpose: Train profiles of the fleet: immutable ids, operator approval for unknown trains, retired ids are archived and never reused (Gesamtkonzept Kap. 8.2, 24.3; tests D-01, D-02).
Public API: returns table of tests.
]]

local profile = require("src.fleet.profile")

local function spec(extra)
  local s = { immutable_id = "TRAIN-7", create_name_ref = "Sued Express 7", train_class = "PASSENGER", length = 8, permitted_directions = { "EAST", "WEST" },
    capabilities = { "passenger" }, depot_preference = "D1", line_permissions = { "L1", "L2" } }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local approval = { operator = "tim", confirmed = true }

return {
  test_an_unknown_train_is_seen_but_not_registered_without_the_operator = function()
    local reg = profile.new({ now = function() return 100 end })
    assert(reg.seen("Sued Express 7") == "PENDING")
    assert(reg.seen("Sued Express 7") == "PENDING" and reg.pending()[1].name == "Sued Express 7" and reg.pending()[1].count == 2)
    local ok, err = reg.register(spec(), nil)
    assert(not ok and err:find("operator", 1, true), tostring(err))
    local ok2 = reg.register(spec(), { operator = "tim" })
    assert(not ok2, "an approval without confirmed = true is no approval")
    assert(reg.register(spec(), approval))
    assert(reg.seen("Sued Express 7") == "KNOWN")
    assert(#reg.pending() == 0, "registered: no longer pending")
  end,

  test_ids_and_create_names_are_unique_and_the_record_is_complete = function()
    local reg = profile.new({})
    assert(reg.register(spec(), approval))
    local ok, err = reg.register(spec({ create_name_ref = "Other" }), approval)
    assert(not ok and err:find("already", 1, true), "same id: " .. tostring(err))
    local ok2, err2 = reg.register(spec({ immutable_id = "TRAIN-8" }), approval)
    assert(not ok2 and err2:find("Create name", 1, true), tostring(err2))
    for _, field in ipairs({ "immutable_id", "create_name_ref", "train_class", "length", "permitted_directions" }) do
      local bad = spec(); bad[field] = nil
      local ok3, err3 = reg.register(bad, approval)
      assert(not ok3 and err3:find(field, 1, true), field .. ": " .. tostring(err3))
    end
    assert(not reg.register(spec({ immutable_id = "T9", create_name_ref = "N9", train_class = "BOAT" }), approval))
    assert(not reg.register(spec({ immutable_id = "T9", create_name_ref = "N9", length = 0 }), approval))
  end,

  test_the_profile_has_a_version_and_a_lifecycle = function()
    local reg = profile.new({})
    assert(reg.register(spec(), approval))
    local p = reg.get("TRAIN-7")
    assert(p.lifecycle_status == "ACTIVE" and p.version == 1 and p.technical_state == "OK")
    assert(reg.set_technical_state("TRAIN-7", "DEFECT"))
    assert(reg.get("TRAIN-7").version == 2)
    assert(not reg.set_technical_state("TRAIN-7", "BROKEN-ISH"))
    assert(reg.by_name("Sued Express 7").immutable_id == "TRAIN-7")
  end,

  test_a_retired_id_is_archived_and_never_comes_back = function()
    local reg = profile.new({})
    reg.register(spec(), approval)
    local ok, err = reg.retire("TRAIN-7", nil)
    assert(not ok and err:find("operator", 1, true))
    assert(reg.retire("TRAIN-7", approval))
    assert(reg.get("TRAIN-7").lifecycle_status == "RETIRED")
    local again, err2 = reg.register(spec({ create_name_ref = "New name" }), approval)
    assert(not again and err2:find("archived", 1, true), tostring(err2))
    assert(reg.register(spec({ immutable_id = "TRAIN-7B", create_name_ref = "Sued Express 7" }), approval), "the Create name of a retired train may be used by a new train with a new id")
    assert(#reg.list({ lifecycle = "ACTIVE" }) == 1 and #reg.list() == 2)
  end,

  test_a_train_is_eligible_for_a_trip_only_if_everything_fits = function()
    local reg = profile.new({})
    reg.register(spec(), approval)
    assert(reg.eligible("TRAIN-7", { train_class = "PASSENGER", line = "L1", direction = "EAST" }) == true)
    local ok, why = reg.eligible("TRAIN-7", { train_class = "FREIGHT" })
    assert(not ok and why:find("class", 1, true))
    ok, why = reg.eligible("TRAIN-7", { line = "L9" })
    assert(not ok and why:find("line", 1, true))
    ok, why = reg.eligible("TRAIN-7", { direction = "NORTH" })
    assert(not ok and why:find("direction", 1, true))
    reg.set_technical_state("TRAIN-7", "MAINTENANCE")
    ok, why = reg.eligible("TRAIN-7", {})
    assert(not ok and why:find("technical", 1, true))
    reg.set_technical_state("TRAIN-7", "OK")
    reg.retire("TRAIN-7", approval)
    ok, why = reg.eligible("TRAIN-7", {})
    assert(not ok and why:find("retired", 1, true))
    ok, why = reg.eligible("NOPE", {})
    assert(not ok and why:find("unknown", 1, true))
  end,

  test_snapshot_and_restore_keep_profiles_archive_and_pending = function()
    local reg = profile.new({})
    reg.register(spec(), approval)
    reg.register(spec({ immutable_id = "OLD", create_name_ref = "Old" }), approval)
    reg.retire("OLD", approval)
    reg.seen("Mystery")
    local copy = profile.new({})
    copy.restore(reg.snapshot())
    assert(copy.get("TRAIN-7") and copy.get("OLD").lifecycle_status == "RETIRED" and #copy.pending() == 1)
    assert(not copy.register(spec({ immutable_id = "OLD", create_name_ref = "X" }), approval), "the archive came along")
  end
}
