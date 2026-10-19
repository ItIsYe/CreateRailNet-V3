--[[
Purpose: The build list (src/setup/bauliste.lua): what has to be put up for a generated network and how each computer is set up -- the parts with
  their numbers, the names the Create station blocks must carry, the order, and one entry per computer of the plan.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local layout = require("src.setup.layout")
local plan_builder = require("src.setup.plan_builder")
local bauliste = require("src.setup.bauliste")

local TEXT = [[
netz Nordbahn
bahnhof ST-A "Station A" passenger
bahnhof ST-B "Station B" mixed 2
depot DEPOT-1 "Depot 1" 2
strecke ST-A ST-B 2
strecke ST-B DEPOT-1 1 depot
zug TRAIN-1 "Regio 1" ST-A ST-B ST-A
]]

local function generate()
  local l = assert(layout.parse(TEXT))
  local plan, meta = plan_builder.build(l)
  assert(plan, table.concat(meta or {}, "\n"))
  return plan, meta, l, bauliste.render(plan, meta, l)
end

local function count(text, needle)
  local n, start = 0, 1
  while true do
    local from = text:find(needle, start, true)
    if not from then return n end
    n = n + 1
    start = from + #needle
  end
end

return {
  test_the_list_names_the_network_and_counts_the_parts = function()
    local plan, meta, _, text = generate()
    assert(text:find("Bauliste", 1, true) and text:find("Nordbahn", 1, true))
    assert(text:find("Computer gesamt: " .. #plan.nodes, 1, true), text)
    assert(text:find("Signale (Create): " .. meta.stats.signals, 1, true))
    assert(text:find("Melder (Train Observer): " .. meta.stats.sensors, 1, true))
    assert(text:find("Weichen: " .. meta.stats.switches, 1, true))
    assert(text:find("Modems: " .. #plan.nodes, 1, true), "one modem for every computer")
    assert(text:find("Bloecke: " .. meta.stats.blocks, 1, true) and text:find("Routen: " .. meta.stats.routes, 1, true))
  end,

  test_the_create_station_names_must_be_copied_exactly = function()
    local _, _, _, text = generate()
    assert(text:find('ST-A  "Station A"', 1, true) and text:find('DEPOT-1  "Depot 1"', 1, true), text)
    assert(text:find("genau so", 1, true))
  end,

  test_every_computer_is_listed_once_with_what_it_is_and_where_it_stands = function()
    local plan, _, _, text = generate()
    for _, node in ipairs(plan.nodes) do
      -- the id starts a line, once in the list of all computers
      local lines = 0
      for line in text:gmatch("[^\n]+") do if line:match("^" .. node.id:gsub("%p", "%%%0") .. "%s%s") then lines = lines + 1 end end
      assert(lines == 1, node.id .. " appears " .. lines .. " times as an entry")
    end
    assert(text:find("Computer am Create-Signal", 1, true) and text:find("Computer an der Weiche", 1, true) and text:find("Train Observer", 1, true))
    assert(text:find("Einfahrt zu Bahnsteig 2", 1, true), "the throat is described by platform")
  end,

  test_the_order_and_the_way_to_set_up_a_computer_are_told = function()
    local _, _, _, text = generate()
    assert(text:find("wget run", 1, true) and text:find("installer", 1, true))
    assert(text:find("Kurzplan", 1, true) and text:find("GENAU", 1, true) and text:find("--fetch-plan", 1, true))
    assert(text:find("scripts/setup.lua --layout", 1, true), "how the plan came about")
    assert(text:find("--doctor", 1, true) and text:find("--test", 1, true))
    local flat = text:gsub("%s+", " ")
    local master, signals, trains = flat:find("1. Master mit Monitor", 1, true), flat:find("Signale und Melder", 1, true), flat:find("5. Zuege", 1, true)
    assert(master and signals and trains and master < signals and signals < trains, "the order starts with the master and ends with the trains")
  end,

  test_the_notes_about_the_model_are_in_it = function()
    local _, meta, _, text = generate()
    for _, note in ipairs(meta.notes) do assert(text:find(note:sub(1, 30), 1, true), note) end
  end,

  test_lines_fit_a_small_screen_and_everything_is_ascii = function()
    local _, _, _, text = generate()
    for line in text:gmatch("[^\n]*") do
      assert(#line <= 50, "too long (" .. #line .. "): " .. line)
      assert(not line:find("[\128-\255]"), "not ASCII: " .. line)
    end
  end,

  test_the_same_input_gives_the_same_list = function()
    local _, _, _, a = generate()
    local _, _, _, b = generate()
    assert(a == b)
  end,

  test_without_trains_and_panel_those_parts_are_not_mentioned_as_to_build = function()
    local l = assert(layout.parse("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\npanel nein\n"))
    local plan, meta = plan_builder.build(l)
    local text = bauliste.render(plan, meta, l)
    assert(not text:find("Panel:", 1, true) and not text:find("Zuege:", 1, true), text)
  end,

  test_a_big_network_gives_a_long_but_bounded_list = function()
    local lines = {}
    for i = 1, 8 do lines[#lines + 1] = string.format("bahnhof S%d", i) end
    for i = 1, 7 do lines[#lines + 1] = string.format("strecke S%d S%d 4", i, i + 1) end
    local l = assert(layout.parse(table.concat(lines, "\n")))
    local plan, meta = plan_builder.build(l)
    local text = bauliste.render(plan, meta, l)
    assert(#text < 120000 and count(text, "\n") > #plan.nodes * 2)
  end,
}
