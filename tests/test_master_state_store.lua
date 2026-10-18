--[[
Purpose: Persistent master state store tests.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local master_state_store = require("src.domain.master_state_store")

local TEST_PATH = "state/test_master_state.json"

return {
  test_save_and_load_dispatcher_snapshot = function()
    local store = master_state_store.new(TEST_PATH)
    store.clear()
    local ok = store.save({ blocks = { B1 = { state = "RESERVED", reserved_by = "TRAIN-1" } }, trains = {} })
    assert(ok)
    assert(store.exists())
    local snapshot = store.load()
    assert(snapshot.blocks.B1.state == "RESERVED")
    assert(snapshot.blocks.B1.reserved_by == "TRAIN-1")
    store.clear()
  end,

  test_second_save_keeps_first_as_backup_and_clear_removes_all = function()
    local store = master_state_store.new(TEST_PATH)
    store.clear()
    assert(store.save({ blocks = { B1 = { state = "FREE" } }, trains = {} }))
    assert(store.save({ blocks = { B1 = { state = "RESERVED" } }, trains = {} }))
    assert(fs.exists(TEST_PATH .. ".prev"))
    store.clear()
    assert(not fs.exists(TEST_PATH) and not fs.exists(TEST_PATH .. ".prev") and not fs.exists(TEST_PATH .. ".tmp"))
    assert(not store.exists())
  end,

  test_corrupt_primary_falls_back_to_backup = function()
    local store = master_state_store.new(TEST_PATH)
    store.clear()
    assert(store.save({ blocks = { B1 = { state = "FREE" } }, trains = {} }))
    assert(store.save({ blocks = { B1 = { state = "RESERVED" } }, trains = {} }))
    local fh = fs.open(TEST_PATH, "w"); fh.write("{half a snapshot"); fh.close()
    local snapshot, payload = store.load()
    assert(snapshot and snapshot.blocks.B1.state == "FREE", "backup generation must be restored")
    assert(payload.loaded_from == "backup")
    store.clear()
  end,

  test_missing_primary_with_backup_is_loaded = function()
    local store = master_state_store.new(TEST_PATH)
    store.clear()
    assert(store.save({ blocks = { B1 = { state = "FREE" } }, trains = {} }))
    assert(store.save({ blocks = { B1 = { state = "RESERVED" } }, trains = {} }))
    fs.delete(TEST_PATH)
    local snapshot, payload = store.load()
    assert(snapshot and snapshot.blocks.B1.state == "FREE" and payload.loaded_from == "backup")
    store.clear()
  end,

  test_corrupt_primary_without_backup_reports_error = function()
    local store = master_state_store.new(TEST_PATH)
    store.clear()
    local fh = fs.open(TEST_PATH, "w"); fh.write("{half a snapshot"); fh.close()
    local snapshot, err = store.load()
    assert(snapshot == nil and err and err ~= "missing")
    store.clear()
  end,

  test_missing_store_returns_missing = function()
    local store = master_state_store.new("state/does_not_exist_test.json")
    store.clear()
    local snapshot, err = store.load()
    assert(snapshot == nil)
    assert(err == "missing")
  end
}
