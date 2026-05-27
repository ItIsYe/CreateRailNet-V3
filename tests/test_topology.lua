--[[
Purpose: Domain topology tests.
Public API: returns table of tests.
]]

local blocks = require("src.domain.blocks")
local topology = require("src.domain.topology")

return {
  test_sensor_to_block = function()
    local block_map = blocks.build_map({
      { id = "B1", entry_signal = "SIG-1", exit_signal = "SIG-2", sensors = { "SEN-1" }, switches = {} }
    })
    local lookup = topology.build_sensor_to_block(block_map)
    assert(lookup["SEN-1"] == "B1")
    assert(topology.block_for_sensor(lookup, "SEN-1") == "B1")
  end,

  test_references_node = function()
    local block = {
      entry_signal = "SIG-1",
      exit_signal = "SIG-2",
      sensors = { "SEN-1" },
      switches = { { id = "SW-1" } }
    }
    assert(topology.references_node(block, "SIG-1"))
    assert(topology.references_node(block, "SEN-1"))
    assert(topology.references_node(block, "SW-1"))
    assert(not topology.references_node(block, "OTHER"))
  end
}
