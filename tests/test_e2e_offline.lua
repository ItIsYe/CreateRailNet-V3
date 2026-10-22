--[[
Purpose: The offline part of the end-to-end checks of the concept (Kap. 20, E2E-08): after a restart of every computer the trains in the world keep their reservations, nothing is repeated and nothing counts as free until it was proven again.
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")

local function cfg()
  return {
    occupancy_proof = "on", sensor_guard_min_occupy_ms = 0,
    blocks = {
      { id = "B1", entry_signal = "S1", exit_signal = "X1", sensors = { "SEN-1" } },
      { id = "B2", entry_signal = "S2", exit_signal = "X2", sensors = { "SEN-2" } },
      { id = "B3", entry_signal = "S3", exit_signal = "X3", sensors = { "SEN-3" } },
      { id = "B4", entry_signal = "S4", exit_signal = "X4", sensors = { "SEN-4" } },
      { id = "B5", entry_signal = "S5", exit_signal = "X5", sensors = { "SEN-5" } },
      { id = "B6", entry_signal = "S6", exit_signal = "X6", sensors = { "SEN-6" } }
    },
    routes = {
      { id = "R1", from = "A", to = "B", blocks = { "B1", "B2" } },
      { id = "R2", from = "C", to = "D", blocks = { "B3", "B4" } },
      { id = "R3", from = "E", to = "F", blocks = { "B5", "B6" } },
      { id = "R4", from = "B", to = "G", blocks = { "B2", "B3" } }
    },
    safe_stops = { { block = "B2", proven = true }, { block = "B4", proven = true }, { block = "B6", proven = true }, { block = "B3", proven = true } }
  }
end

local function adapters()
  local log = { signals = {}, switches = {} }
  return {
    log = log,
    signals = { setAspect = function(id, aspect) log.signals[#log.signals + 1] = id .. "=" .. aspect; return true end },
    switches = { setPosition = function(id, position) log.switches[#log.switches + 1] = id .. "=" .. position; return true end }
  }
end

return {
  test_e2e_08_after_a_complete_restart_the_world_is_protected_and_no_old_command_is_repeated = function()
    local before = dispatcher.new(cfg(), adapters())
    for _, id in ipairs({ "B1", "B2", "B3", "B4", "B5", "B6" }) do assert(before.observe_block(id, "FREE_PROVEN", "observer", { at = 1 })) end
    assert(before.reserve_route("T1", "R1") and before.reserve_route("T2", "R2") and before.reserve_route("T3", "R3"))
    local snapshot = before.snapshot()

    -- every computer restarts: new dispatcher, new actuators, only the saved state
    local io = adapters()
    local after = dispatcher.new(cfg(), io)
    after.restore(snapshot)

    -- the restart may only close signals (RED, restrictive); nothing that gives movement, no switch, is repeated
    for _, command in ipairs(io.log.signals) do assert(command:match("=RED$"), "an old command was replayed: " .. command) end
    assert(#io.log.switches == 0, "no switch is moved by a restore")
    for id, owner in pairs({ B1 = "T1", B2 = "T1", B3 = "T2", B4 = "T2", B5 = "T3", B6 = "T3" }) do
      assert(after.get_block(id).reserved_by == owner, id .. " keeps its reservation")
      assert(after.get_occupancy(id).state == "UNKNOWN", id .. " is not free: nothing was proven since the restart")
    end
    -- a fourth train gets nothing over the blocks of the trains in the world
    local ok = after.reserve_route("T4", "R4")
    assert(not ok, "the block under a reservation is not given")
    for _, command in ipairs(io.log.signals) do assert(command:match("=RED$"), "the refused request opened a signal: " .. command) end
    -- the trains are not released by the restart; their end has to be proven
    for _, id in ipairs({ "T1", "T2", "T3" }) do
      local train = after.get_trains()[id]
      assert(train and train.phase ~= "RELEASED_PROVEN", id .. " is not cleared")
    end
  end,

  test_e2e_08_a_block_comes_back_only_with_a_proof_and_only_that_block = function()
    local before = dispatcher.new(cfg(), adapters())
    for _, id in ipairs({ "B1", "B2", "B3", "B4", "B5", "B6" }) do before.observe_block(id, "FREE_PROVEN", "observer", { at = 1 }) end
    local snapshot = before.snapshot()
    local after = dispatcher.new(cfg(), adapters())
    after.restore(snapshot)
    assert(after.observe_block("B5", "FREE_PROVEN", "observer", { at = 9 }))
    assert(after.get_occupancy("B5").state == "FREE_PROVEN")
    for _, id in ipairs({ "B1", "B2", "B3", "B4", "B6" }) do assert(after.get_occupancy(id).state == "UNKNOWN", id) end
    assert(not after.reserve_route("T1", "R1"), "R1 is still unproven")
  end
}
