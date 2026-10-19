--[[
Purpose: The master hands out its plan in parts: the parts add up to the file, the version is the Adler-32 of the text, a plan that is broken
  or too big is not handed out, a plan that changes while a transfer runs is noticed, and the text of one transfer is read and checked once.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local plan_service = require("src.master.plan_service")
local checksum = require("src.shared.checksum")
local memfs = require("tests.harness.memfs")
local netplan = require("src.setup.netplan")

local PLAN = "configs/network.json"

local function cfg_with(blocks)
  local nodes = { { id = "M", role = "master" }, { id = "ST-1", role = "station", create_station_name = "Alpha" } }
  local list = {}
  for i = 1, blocks or 0 do list[#list + 1] = { id = "B" .. i, entry_signal = "SIG-1", exit_signal = "SIG-1", sensors = {} } end
  nodes[#nodes + 1] = { id = "SIG-1", role = "signal" }
  return { v = 1, channel = 7, master_id = "M", nodes = nodes, blocks = list, routes = {} }
end

local function world(opts)
  local o = opts or {}
  local fs = memfs.new()
  local clock = { t = 1000 }
  fs.set(PLAN, o.text or netplan.encode(cfg_with(o.blocks or 30)))
  local reads = 0
  local counting = { exists = fs.exists, open = function(path, mode) if path == PLAN then reads = reads + 1 end return fs.open(path, mode) end }
  setmetatable(counting, { __index = fs })
  local service = plan_service.new({ plan_path = PLAN, fs = counting, chunk_size = o.chunk_size or 300, max_bytes = o.max_bytes, cache_s = o.cache_s, now_s = function() return clock.t end })
  return { fs = fs, clock = clock, service = service, reads = function() return reads end }
end

local function all_parts(service)
  local first = service.part(1)
  assert(first.ok, tostring(first.reason))
  local text = first.data
  for index = 2, first.total do
    local part = service.part(index, first.version)
    assert(part.ok and part.index == index and part.total == first.total and part.version == first.version, tostring(part.reason))
    text = text .. part.data
  end
  return text, first
end

return {
  test_the_parts_add_up_to_the_file_and_carry_its_checksum = function()
    local w = world()
    local text, first = all_parts(w.service)
    assert(text == w.fs.files[PLAN] and first.size == #text and first.total > 3)
    assert(first.version == checksum.hex(checksum.adler32(text)) and #first.version == 8)
    for index = 1, first.total do assert(#w.service.part(index, first.version).data <= 300) end
  end,

  test_a_small_plan_is_one_part = function()
    local w = world({ blocks = 0, chunk_size = 3000 })
    local first = w.service.part(1)
    assert(first.ok and first.total == 1 and first.data == w.fs.files[PLAN])
  end,

  test_a_transfer_reads_the_file_once_not_once_per_part = function()
    local w = world()
    local _, first = all_parts(w.service)
    assert(first.total > 3 and w.reads() == 1, "reads: " .. w.reads())
  end,

  test_a_plan_that_changes_during_a_transfer_is_noticed = function()
    local w = world()
    local first = w.service.part(1)
    -- the operator saves the plan while the transfer runs: the parts that follow still belong to the text of part 1
    w.fs.set(PLAN, netplan.encode(cfg_with(5)))
    local second = w.service.part(2, first.version)
    assert(second.ok and second.version == first.version, "same text as part 1 while the cache holds")
    -- a transfer that begins again reads the new file; one that still holds the old version is told
    local again = w.service.part(1)
    assert(again.ok and again.version ~= first.version)
    local stale = w.service.part(2, first.version)
    assert(stale.ok == false and stale.state == "changed" and stale.version == again.version)
  end,

  test_the_cache_runs_out = function()
    local w = world({ cache_s = 30 })
    local first = w.service.part(1)
    w.fs.set(PLAN, netplan.encode(cfg_with(5)))
    w.clock.t = w.clock.t + 31
    local late = w.service.part(2, first.version)
    assert(late.ok == false and late.state == "changed", "after the cache ran out the file is read again")
  end,

  test_a_request_without_a_version_always_reads_the_file = function()
    local w = world()
    local a = w.service.part(1)
    w.fs.set(PLAN, netplan.encode(cfg_with(5)))
    local b = w.service.part(2)
    assert(b.ok and b.version ~= a.version, "no version: a fresh transfer")
  end,

  test_a_broken_or_invalid_plan_is_not_handed_out = function()
    local broken = world({ text = "{ not json" })
    local reply = broken.service.part(1)
    assert(reply.ok == false and reply.state == "error" and reply.data == nil and reply.reason:find("JSON", 1, true))
    local invalid = world({ text = '{"v":1,"channel":0,"master_id":"M","nodes":[{"id":"M","role":"master"}],"blocks":[],"routes":[]}' })
    local r2 = invalid.service.part(1)
    assert(r2.ok == false and r2.reason:find("Fehler", 1, true) and r2.data == nil)
    local empty = world({ text = "" })
    assert(empty.service.part(1).ok == false)
    local missing = world()
    missing.fs.files[PLAN] = nil
    local r3 = missing.service.part(1)
    assert(r3.ok == false and r3.reason:find("findet", 1, true))
  end,

  test_a_plan_that_is_too_big_is_not_handed_out = function()
    local w = world({ max_bytes = 500 })
    local reply = w.service.part(1)
    assert(reply.ok == false and reply.reason:find("zu gross", 1, true) and reply.data == nil)
  end,

  test_nonsense_requests_get_an_error_not_a_crash = function()
    local w = world()
    local _, first = all_parts(w.service)
    for _, bad in ipairs({ 0, -1, 1.5, first.total + 1, 1e9, "2", true, {} }) do
      local reply = w.service.part(bad, first.version)
      assert(reply.ok == false and reply.state == "error" and reply.data == nil, tostring(bad))
    end
    assert(w.service.part(1, 42).ok == false and w.service.part(1, {}).ok == false, "a version is a string")
  end,

  test_a_missing_service_path_or_filesystem_is_an_error = function()
    local service = plan_service.new({})
    local reply = service.part(1)
    assert(reply.ok == false and reply.state == "error")
  end,
}
