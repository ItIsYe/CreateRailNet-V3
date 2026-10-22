--[[
Purpose: The loading point measures what moved in the inventory next to the track and says nothing when it cannot be sure; the station node reports it to the fleet pair (Pruefplan G-05 bis G-10).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local cargo_meter = require("src.domain.cargo_meter")

local function inventory(initial)
  local inv = { items = initial, calls = 0, broken = false, nonsense = false, moving = false }
  function inv.call(name, method)
    inv.calls = inv.calls + 1
    if inv.broken or name ~= "chest_0" or method ~= "list" then error("peripheral gone") end
    if inv.nonsense then return { { name = "coal", count = "many" } } end
    if inv.moving then inv.items = { { name = "minecraft:coal", count = inv.calls * 7 } } end
    local out = {}
    for slot, stack in pairs(inv.items) do out[slot] = { name = stack.name, count = stack.count } end
    return out
  end
  return inv
end

local function meter(inv) return cargo_meter.new({ peripheral = inv, now = function() return 100 end }) end

return {
  test_a_loading_chest_that_lost_items_is_a_measurement_of_what_was_loaded = function()
    local inv = inventory({ { name = "minecraft:coal", count = 64 }, { name = "minecraft:coal", count = 64 }, { name = "minecraft:iron_ingot", count = 10 } })
    local m = meter(inv)
    assert(m.begin("NORD/P1", "chest_0", "minecraft:coal") and m.pending("NORD/P1"))
    inv.items = { { name = "minecraft:coal", count = 20 }, { name = "minecraft:iron_ingot", count = 10 } }
    local result = m.finish("NORD/P1", "loaded")
    assert(result.ok and result.qty == 108 and result.quality == "AUTO_INVENTORY" and result.ref:find("NORD/P1#1", 1, true), tostring(result.reason))
    assert(not m.pending("NORD/P1"))
  end,

  test_an_unloading_point_that_gained_items_is_a_measurement_of_what_was_delivered_and_other_items_do_not_count = function()
    local inv = inventory({ { name = "minecraft:coal", count = 5 } })
    local m = meter(inv)
    m.begin("SUED/P1", "chest_0", "minecraft:coal")
    inv.items = { { name = "minecraft:coal", count = 55 }, { name = "minecraft:dirt", count = 999 } }
    local result = m.finish("SUED/P1", "unloaded")
    assert(result.ok and result.qty == 50)
  end,

  test_items_that_moved_the_wrong_way_are_no_loading = function()
    local inv = inventory({ { name = "minecraft:coal", count = 10 } })
    local m = meter(inv)
    m.begin("k", "chest_0", "minecraft:coal")
    inv.items = { { name = "minecraft:coal", count = 30 } }
    local result = m.finish("k", "loaded")
    assert(result.ok == false and result.reason:find("wrong way", 1, true))
  end,

  test_nothing_moved_is_a_result_of_zero_and_not_a_failure = function()
    local inv = inventory({ { name = "minecraft:coal", count = 10 } })
    local m = meter(inv)
    m.begin("k", "chest_0")
    local result = m.finish("k", "loaded")
    assert(result.ok and result.qty == 0)
  end,

  test_a_gone_peripheral_or_nonsense_is_no_measurement_and_no_zero = function()
    local inv = inventory({ { name = "minecraft:coal", count = 10 } })
    local m = meter(inv)
    inv.broken = true
    local ok, err = m.begin("k", "chest_0")
    assert(ok == false and err:find("cannot be read", 1, true) and not m.pending("k"))
    inv.broken = false
    assert(m.begin("k", "chest_0"))
    inv.broken = true
    local result = m.finish("k", "loaded")
    assert(result.ok == false and result.reason:find("cannot be read", 1, true))
    inv.broken = false; inv.nonsense = true
    local bad, why = m.begin("k2", "chest_0")
    assert(bad == false and why:find("nonsense", 1, true))
    assert(m.finish("never started", "loaded").ok == false and m.finish("k2", "bogus").ok == false)
  end,

  test_an_inventory_that_still_moves_is_not_read = function()
    local inv = inventory({ { name = "minecraft:coal", count = 10 } })
    local m = meter(inv)
    m.begin("k", "chest_0", "minecraft:coal")
    inv.moving = true
    local result = m.finish("k", "unloaded")
    assert(result.ok == false and result.reason:find("hold still", 1, true))
  end,

  test_the_references_differ_per_measurement = function()
    local inv = inventory({ { name = "minecraft:coal", count = 10 } })
    local m = meter(inv)
    m.begin("k", "chest_0"); local a = m.finish("k", "loaded")
    m.begin("k", "chest_0"); local b = m.finish("k", "loaded")
    assert(a.ref ~= b.ref)
  end,

  test_the_config_check_knows_a_loading_point = function()
    local validate = require("src.shared.validate")
    local function errors_of(cargo, report_to)
      local cfg = { v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" },
        { id = "ST", role = "station", station_type = "freight", create_station_name = "X", cargo_report_to = report_to, platforms = { { id = "P1", kind = "freight", cargo = cargo } } } } }
      local _, errs = validate.validate_config(cfg)
      return table.concat(errs or {}, "\n")
    end
    assert(not errors_of({ inventory = "chest_0", item = "minecraft:coal", kind = "loaded" }, { "FLEET-A" }):find("cargo", 1, true))
    assert(errors_of({ inventory = "", kind = "loaded" }):find("cargo.inventory", 1, true))
    assert(errors_of({ inventory = "c", kind = "full" }):find("cargo.kind", 1, true))
    assert(errors_of("chest"):find("platforms[1].cargo", 1, true))
    assert(errors_of({ inventory = "c", kind = "loaded" }, { "" }):find("cargo_report_to[1]", 1, true))
  end
}
