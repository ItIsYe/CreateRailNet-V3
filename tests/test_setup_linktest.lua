--[[
Purpose: scripts/setup.lua --linktest on a computer that has been set up: what it asks, what it shows, what it says for a good, a bad, a
  silent and a limited link, and that it changes nothing on the disk.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local setup_world = require("tests.harness.setup_world")
local netplan = require("src.setup.netplan")
local startup_template = require("src.shared.startup_template")

local PLAN = netplan.PATH
local SIGNAL = { id = "SIG-1", role = "signal", adapter = "redstone", side = "left" }

local function installed(role, entry)
  local cfg = netplan.short_plan(role, entry, 777, "MASTER-1")
  local files = {
    ["startup.lua"] = startup_template.render({ role = role, id = entry.id, config = PLAN }),
    [PLAN] = netplan.encode(cfg),
  }
  return setup_world.new({ files = files })
end

-- the page text as one line of words: where a long sentence wraps is not what these tests are about
local function words(world) return (world.text():gsub("%s+", " ")) end

local function snapshot(world)
  local copy = {}
  for path, body in pairs(world.fs.files) do copy[path] = body end
  return copy
end

local function same(a, b)
  for path, body in pairs(a) do if b[path] ~= body then return false, path end end
  for path in pairs(b) do if a[path] == nil then return false, path end end
  return true
end

-- a master that answers everything, and takes messages up to `limit` bytes
local function master(limit, rtt)
  local asked = { count = 0, last = nil }
  local function answer(opts)
    asked.count, asked.last = asked.count + 1, opts
    local pad, echo = opts.pad_bytes or 0, opts.echo_bytes or 0
    if pad > (limit or 10 ^ 9) or echo > (limit or 10 ^ 9) then return { state = "no_answer" } end
    return { state = "known", rtt_s = rtt or 0.05, echoed = echo }
  end
  return answer, asked
end

return {
  test_a_good_link_is_reported_with_answers_time_and_the_largest_message = function()
    local world = installed("signal", SIGNAL)
    local answer, asked = master()
    world.link = answer
    local before = snapshot(world)
    local result = world.run({ "--linktest" }, {})
    assert(result.ok and result.state == "ok", tostring(result.state))
    local text = words(world)
    assert(text:find("Fragen: 10 gestellt, 10 beantwortet, 10 sofort.", 1, true), text)
    assert(text:find("Laufzeit: im Mittel 0.05 s", 1, true), text)
    assert(text:find("4000 Byte kommt an", 1, true) and text:find("in Ordnung", 1, true) and text:find("3300 Byte", 1, true), text)
    assert(asked.count == 15, "10 questions and 5 sizes: " .. asked.count)
    assert(asked.last.id == "SIG-1" and asked.last.channel == 777 and asked.last.master_id == "MASTER-1")
    assert(world.check_screen(true) == nil, tostring(world.check_screen(true)))
    assert(same(before, snapshot(world)), "nothing is written")
  end,

  test_a_limit_of_the_link_is_named_with_its_consequence = function()
    local world = installed("signal", SIGNAL)
    world.link = master(2500)
    local result = world.run({ "--linktest" }, {})
    assert(result.ok == false and result.state == "ok" and result.result.largest == 2048)
    local text = words(world)
    assert(text:find("3300 Byte KOMMT NICHT AN", 1, true), text)
    assert(text:find("grosse nicht (bis 2048 Byte)", 1, true) and text:find("--fetch-plan", 1, true), text)
  end,

  test_a_silent_master_gets_three_questions_and_advice = function()
    local world = installed("signal", SIGNAL)
    local answer, asked = (function() local n = { count = 0 }; return function() n.count = n.count + 1; return { state = "no_answer" } end, n end)()
    world.link = answer
    local result = world.run({ "--linktest" }, {})
    assert(result.ok == false and result.state == "none" and asked.count == 3, tostring(asked.count))
    local text = words(world)
    assert(text:find("Keine Antwort vom Master", 1, true) and text:find("Kanal", 1, true), text)
    assert(world.check_screen(true) == nil, tostring(world.check_screen(true)))
  end,

  test_a_computer_without_a_modem_is_told_so = function()
    local world = installed("signal", SIGNAL)
    world.link = function() return { state = "no_modem" } end
    local result = world.run({ "--linktest" }, {})
    assert(result.state == "no_modem" and words(world):find("kein nutzbares Modem", 1, true))
  end,

  test_a_shaky_link_is_a_warning_not_an_error_in_words = function()
    local world = installed("signal", SIGNAL)
    local n = 0
    world.link = function(opts)
      n = n + 1
      if n == 4 then return { state = "no_answer" } end
      return { state = "known", rtt_s = 0.05, echoed = opts.echo_bytes or 0 }
    end
    local result = world.run({ "--linktest" }, {})
    assert(result.ok == false and result.state == "shaky", tostring(result.state))
    assert(words(world):find("Fragen: 10 gestellt, 9 beantwortet", 1, true) and words(world):find("grenzwertig", 1, true))
  end,

  test_the_master_and_a_computer_that_is_not_set_up_are_not_asked = function()
    local asked = 0
    local world = setup_world.new()
    world.link = function() asked = asked + 1; return { state = "known" } end
    assert(world.run({ "--linktest" }, {}).state == "setup" and asked == 0)
    local master_world = installed("master", { id = "MASTER-1", role = "master" })
    master_world.link = world.link
    assert(master_world.run({ "--linktest" }, {}).state == "master" and asked == 0)
    local plain = installed("signal", SIGNAL)
    assert(plain.run({ "--linktest" }, {}).state == "no_link", "no way to ask: said so")
  end,

  test_it_is_a_mode_of_the_script_and_not_the_setup = function()
    local wizard = require("src.setup.wizard")
    assert(wizard.parse_args({ "--linktest" }).linktest == true)
    assert(wizard.parse_args({ "--test" }).linktest == nil)
  end,
}
