--[[
Purpose: The description of a new network (src/setup/layout.lua): the short text form that is typed in the game and the JSON form, the checks
  with German messages that name the line, and the defaults that fill the gaps.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local layout = require("src.setup.layout")

local SMALL = [[
# ein kleines Netz
netz Mein Netz
kanal 777
master MASTER-1
bahnhof ST-A "Station A" passenger
bahnhof ST-B "Station B" mixed 2
depot DEPOT-1 "Depot 1" 2
strecke ST-A ST-B 2 passenger
strecke ST-B DEPOT-1 1 depot einrichtung
zug TRAIN-1 "Regio 1" ST-A ST-B:2 ST-A pause=15
panel ja
]]

local function errors_of(text)
  local result, errors = layout.parse(text)
  assert(result == nil and type(errors) == "table" and #errors > 0, "expected errors")
  return table.concat(errors, "\n"), errors
end

return {
  test_the_text_form_is_read_into_the_description = function()
    local l, errors = layout.parse(SMALL)
    assert(l, table.concat(errors or {}, "\n"))
    assert(l.name == "Mein Netz" and l.channel == 777 and l.master_id == "MASTER-1" and l.panel == true)
    assert(#l.stations == 2 and l.stations[1].id == "ST-A" and l.stations[1].name == "Station A" and l.stations[1].type == "passenger" and l.stations[1].platforms == 1)
    assert(l.stations[2].type == "mixed" and l.stations[2].platforms == 2)
    assert(#l.depots == 1 and l.depots[1].id == "DEPOT-1" and l.depots[1].tracks == 2 and l.depots[1].name == "Depot 1")
    assert(#l.lines == 2 and l.lines[1].from == "ST-A" and l.lines[1].to == "ST-B" and l.lines[1].blocks == 2 and l.lines[1].kind == "passenger" and l.lines[1].oneway == false)
    assert(l.lines[2].oneway == true and l.lines[2].kind == "depot")
    local train = l.trains[1]
    assert(train.id == "TRAIN-1" and train.name == "Regio 1" and train.dwell == 15 and #train.stops == 3)
    assert(train.stops[1].id == "ST-A" and train.stops[1].platform == 1 and train.stops[2].platform == 2, "ST-B:2 is platform 2")
    assert(train.repeat_plan == true, "a round trip repeats by default")
  end,

  test_the_json_form_gives_the_same_description = function()
    local json = [[{
      "name": "Mein Netz", "channel": 777, "master_id": "MASTER-1", "panel": true,
      "stations": [ {"id": "ST-A", "name": "Station A", "type": "passenger"}, {"id": "ST-B", "name": "Station B", "type": "mixed", "platforms": 2} ],
      "depots": [ {"id": "DEPOT-1", "name": "Depot 1", "tracks": 2} ],
      "lines": [ {"from": "ST-A", "to": "ST-B", "blocks": 2, "kind": "passenger"}, {"from": "ST-B", "to": "DEPOT-1", "kind": "depot", "oneway": true} ],
      "trains": [ {"id": "TRAIN-1", "name": "Regio 1", "stops": ["ST-A", {"id": "ST-B", "platform": 2}, "ST-A"], "dwell": 15} ]
    }]]
    local l, errors = layout.parse(json)
    assert(l, table.concat(errors or {}, "\n"))
    local t = layout.parse(SMALL)
    assert(#l.stations == 2 and l.stations[2].platforms == 2 and l.stations[1].platforms == 1)
    assert(l.lines[2].blocks == 1 and l.lines[2].oneway == true and l.lines[1].oneway == false)
    assert(l.trains[1].stops[2].platform == 2 and l.trains[1].dwell == t.trains[1].dwell and l.trains[1].repeat_plan == true)
  end,

  test_defaults_fill_the_gaps = function()
    local l = assert(layout.parse("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\n"))
    assert(l.channel == 777 and l.master_id == "MASTER-1" and l.panel == true and l.name == "")
    assert(l.stations[1].name == "ST-A" and l.stations[1].type == "passenger" and l.stations[1].platforms == 1)
    assert(l.lines[1].blocks == 1 and l.lines[1].kind == "passenger" and l.lines[1].oneway == false)
    assert(l.defaults.signal.adapter == "peripheral" and l.defaults.signal.peripheral == "Create_Signal_0")
    assert(l.defaults.sensor.adapter == "peripheral" and l.defaults.sensor.peripheral == "Create_TrainObserver_0")
    assert(l.defaults.switch.adapter == "redstone" and l.defaults.switch.side == "back")
    -- the kind of a line follows its ends
    local mixed = assert(layout.parse("bahnhof ST-A freight\nbahnhof ST-B passenger\nstrecke ST-A ST-B\n"))
    assert(mixed.lines[1].kind == "mixed")
    local freight = assert(layout.parse("bahnhof ST-A freight\nbahnhof ST-B freight\nstrecke ST-A ST-B\n"))
    assert(freight.lines[1].kind == "freight")
    local depot = assert(layout.parse("bahnhof ST-A\ndepot DEPOT-1\nstrecke ST-A DEPOT-1\n"))
    assert(depot.lines[1].kind == "depot")
  end,

  test_german_words_work_like_the_english_ones = function()
    local l = assert(layout.parse('bahnhof ST-A "A" personen 2\nbahnhof ST-B "B" fracht\nbahnhof ST-C "C" gemischt\nstrecke ST-A ST-B 3 fracht eingleisig\n'))
    assert(l.stations[1].type == "passenger" and l.stations[2].type == "freight" and l.stations[3].type == "mixed" and l.stations[1].platforms == 2)
    assert(l.lines[1].kind == "freight" and l.lines[1].oneway == true)
  end,

  test_comments_blank_lines_and_hash_inside_quotes = function()
    local l = assert(layout.parse('# nur ein Kommentar\n\n  \nbahnhof ST-A "Nord #1" passenger  # und noch einer\nbahnhof ST-B\nstrecke ST-A ST-B\n'))
    assert(l.stations[1].name == "Nord #1")
  end,

  test_the_hardware_defaults_can_be_changed = function()
    local l = assert(layout.parse("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nstandard signal redstone left\nstandard melder redstone front\nstandard weiche peripheral Create_Switch_0\n"))
    assert(l.defaults.signal.adapter == "redstone" and l.defaults.signal.side == "left" and l.defaults.signal.peripheral == nil)
    assert(l.defaults.sensor.adapter == "redstone" and l.defaults.sensor.side == "front")
    assert(l.defaults.switch.adapter == "peripheral" and l.defaults.switch.peripheral == "Create_Switch_0")
    local text = errors_of("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nstandard signal redstone oben\n")
    assert(text:find("Zeile 4", 1, true) and text:find("oben", 1, true), text)
  end,

  -- ── mistakes name their line ──────────────────────────────────────────────────────────────────────────────────────

  test_an_unknown_word_names_the_line_and_the_possible_ones = function()
    local text = errors_of("bahnhof ST-A\nbahnhoff ST-B\n")
    assert(text:find("Zeile 2", 1, true) and text:find("bahnhoff", 1, true) and text:find("strecke", 1, true), text)
  end,

  test_every_kind_of_mistake_is_said_in_german_with_the_line = function()
    local cases = {
      { "bahnhof\n", "Zeile 1", "ID" },
      { "bahnhof ST-A\nbahnhof ST-A\nstrecke ST-A ST-A\n", "Zeile 2", "doppelt" },
      { "bahnhof ST-A\nstrecke ST-A ST-X\n", "Zeile 2", "ST-X" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 0\n", "Zeile 3", "Bloecke" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 99\n", "Zeile 3", "Bloecke" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nstrecke ST-A ST-B\n", "Zeile 4", "schon" },
      { "bahnhof ST-A\nstrecke ST-A ST-A\n", "Zeile 2", "selben" },
      { "bahnhof ST-A 9\n", "Zeile 1", "Bahnsteig" },
      { "depot DEPOT-1 9\n", "Zeile 1", "Gleis" },
      { "kanal 0\n", "Zeile 1", "Kanal" },
      { "kanal 70000\n", "Zeile 1", "Kanal" },
      { "kanal viel\n", "Zeile 1", "Kanal" },
      { "bahnhof ST-A\nbahnhof ST-B\nzug T1 ST-A\n", "Zeile 3", "zwei Halte" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-Q\n", "Zeile 4", "ST-Q" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-A\n", "Zeile 4", "nacheinander" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A:3 ST-B\n", "Zeile 4", "Bahnsteig 3" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-B pause=-5\n", "Zeile 4", "pause" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-B\nzug T1 ST-A ST-B\n", "Zeile 5", "doppelt" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug ST-A ST-B ST-A\n", "Zeile 4", "doppelt" },
      { "bahnhof ST-A \"offen\n", "Zeile 1", "Anfuehrungszeichen" },
      { "bahnhof \195\156ber\n", "Zeile 1", "Umlaute" },
      { "bahnhof ST-A passenger freight\n", "Zeile 1", "Typ" },
      { "bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B passenger freight\n", "Zeile 3", "Art" },
      { "panel vielleicht\n", "Zeile 1", "ja oder nein" },
      { "master\n", "Zeile 1", "ID" },
    }
    for _, case in ipairs(cases) do
      local text = errors_of(case[1])
      assert(text:find(case[2], 1, true) and text:find(case[3], 1, true), "[" .. case[1]:gsub("\n", " | ") .. "] -> " .. text)
    end
  end,

  test_the_channel_of_a_json_description_is_checked_too = function()
    local function with_channel(value)
      return '{"channel": ' .. value .. ', "stations": [{"id": "ST-A"}, {"id": "ST-B"}], "lines": [{"from": "ST-A", "to": "ST-B"}]}'
    end
    assert(layout.parse(with_channel(65535)) and layout.parse(with_channel(1)))
    for _, bad in ipairs({ "0", "65536", "70000", "1.5", '"viel"', "-3" }) do
      assert(errors_of(with_channel(bad)):find("Kanal", 1, true), bad)
    end
  end,

  test_a_trip_that_does_not_come_back_does_not_repeat_by_default = function()
    local l = assert(layout.parse("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B\nzug T1 ST-A ST-B\nzug T2 ST-A ST-B ST-A\nzug T3 ST-A ST-B ST-A einmalig\nzug T4 ST-A ST-B wiederholen\n"))
    assert(l.trains[1].repeat_plan == false and l.trains[2].repeat_plan == true and l.trains[3].repeat_plan == false and l.trains[4].repeat_plan == true)
  end,

  test_a_train_cannot_drive_where_there_is_no_line_and_a_one_way_line_is_one_way = function()
    local text = errors_of("bahnhof ST-A\nbahnhof ST-B\nbahnhof ST-C\nstrecke ST-A ST-B\nzug T1 ST-A ST-C\n")
    assert(text:find("Zeile 5", 1, true) and text:find("Strecke", 1, true) and text:find("ST-A", 1, true) and text:find("ST-C", 1, true), text)
    local back = errors_of("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 1 passenger einrichtung\nzug T1 ST-B ST-A\n")
    assert(back:find("Zeile 4", 1, true) and back:find("Richtung", 1, true), back)
    assert(layout.parse("bahnhof ST-A\nbahnhof ST-B\nstrecke ST-A ST-B 1 passenger einrichtung\nzug T1 ST-A ST-B\n"))
  end,

  test_a_network_needs_something_to_build = function()
    local text = errors_of("netz leer\n")
    assert(text:find("Bahnhof", 1, true), text)
    assert(errors_of("bahnhof ST-A\n"):find("Strecke", 1, true))
  end,

  test_many_mistakes_are_collected_but_the_list_is_bounded = function()
    local lines = {}
    for i = 1, 60 do lines[#lines + 1] = "quatsch " .. i end
    local _, errors = errors_of(table.concat(lines, "\n"))
    assert(#errors <= 21, #errors)
    assert(errors[#errors]:find("weitere", 1, true), errors[#errors])
  end,

  test_json_mistakes_name_their_place_and_garbage_is_not_believed = function()
    local text = errors_of('{"stations": [{"id": "ST-A"}, {"name": "ohne id"}], "lines": []}')
    assert(text:find("stations[2]", 1, true), text)
    assert(errors_of("{ das ist kein json"):find("JSON", 1, true))
    assert(errors_of('{"stations": "ST-A"}'):find("stations", 1, true))
    assert(errors_of('{"stations": [{"id": "ST-A"}, {"id": "ST-B"}], "lines": [{"from": "ST-A", "to": "ST-B", "blocks": "viele"}]}'):find("lines[1]", 1, true))
    assert(errors_of('{"stations": [{"id": "ST-A", "platforms": 2.5}]}'):find("platforms", 1, true))
    assert(errors_of("[1,2,3]"):find("JSON", 1, true))
    assert(errors_of(""):find("leer", 1, true))
    assert(errors_of(string.rep("x", 70000)):find("gross", 1, true))
  end,

  test_names_are_cut_to_a_sane_length_and_must_be_ascii = function()
    local text = errors_of('bahnhof ST-A "' .. string.rep("n", 41) .. '"\n')
    assert(text:find("Name", 1, true) and text:find("40", 1, true), text)
    local umlaut = errors_of('bahnhof ST-A "Bahnhof M\195\188nchen"\n')
    assert(umlaut:find("Umlaute", 1, true), umlaut)
  end,
}
