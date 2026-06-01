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

  test_missing_store_returns_missing = function()
    local store = master_state_store.new("state/does_not_exist_test.json")
    store.clear()
    local snapshot, err = store.load()
    assert(snapshot == nil)
    assert(err == "missing")
  end
}
