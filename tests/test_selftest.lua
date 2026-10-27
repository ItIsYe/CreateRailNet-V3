--[[
Purpose: Das Selbsttest-Programm des Kerns (src/app/selftest.lua) gegen Fakes: lokale Pruefungen, Ping zwischen zwei Computern ueber den Fake-Bus, Aufruf ueber main.
]]

local t = dofile("tests/lib/t.lua")
local cc = dofile("tests/fakes/cc.lua")
local busLib = dofile("tests/fakes/bus.lua")
local selftest = require("app.selftest")
local main = dofile("src/app/main.lua")

-- Computer mit eigener Spielzeit; pull(timeout) laesst die Zeit verstreichen und liefert Ereignisse vom Bus
local function computer(bus, cid, opts)
  opts = opts or {}
  local fs = cc.fs()
  fs.makeDir("/crn_data")
  local env = { fs = fs, lines = {}, raw = 0 }
  env.print = function(text) env.lines[#env.lines + 1] = text end
  env.raw_clock = function() return env.raw end
  env.rednet = bus.attach(cid)
  env.peripheral = {
    getNames = function() return opts.no_modem and {} or { "left" } end,
    getType = function() return "modem" end,
    call = function() return true end,
  }
  env.pull = function(timeout)
    local ev = bus.pop(cid)
    if ev then return ev end
    env.raw = env.raw + timeout
    if env.on_idle then env.on_idle() end
    return nil
  end
  function env.output() return table.concat(env.lines, "\n") end
  return env
end

return {
  { "lokale Pruefungen laufen durch und raeumen auf", function()
    local bus = busLib.new()
    local env = computer(bus, 1)
    t.eq(selftest.run(env, {}), true, env.output())
    t.contains(env.output(), "Alle lokalen Pruefungen bestanden.")
    t.ok(not env.fs.exists("/crn_data/selftest"), "aufgeraeumt")
  end },
  { "ohne Funkmodem meldet der Test den Fehler", function()
    local bus = busLib.new()
    local env = computer(bus, 1, { no_modem = true })
    t.eq(selftest.run(env, {}), false)
    t.contains(env.output(), "FEHLER  Funkmodem vorhanden")
  end },
  { "Ping: fuenf Antworten, wenn der Gegenueber antwortet", function()
    local bus = busLib.new()
    local a = computer(bus, 1)
    local b = computer(bus, 2)
    -- b antwortet, sobald a wartet (Zeit verstreicht)
    -- b laeuft in kleinen Schritten mit: pull von b liefert Ereignisse, sonst yield
    b.pull = function(timeout)
      while true do
        local ev = bus.pop(2)
        if ev then return ev end
        coroutine.yield()
      end
    end
    local co = coroutine.create(function() selftest.listen(b, "zentrale-1") end)
    local orig_pull = a.pull
    a.pull = function(timeout)
      local ev = orig_pull(timeout)
      -- nach jeder Wartezeit darf b arbeiten
      if coroutine.status(co) == "suspended" then coroutine.resume(co) end
      return ev
    end
    coroutine.resume(co)
    local ok = selftest.run(a, { "ping", "bahnhof-1", "zentrale-1" })
    t.eq(ok, true, a.output())
    t.contains(a.output(), "5 von 5 Antworten")
    t.contains(b.output(), "Ping von bahnhof-1 (Nr. 5)")
  end },
  { "Ping ohne Gegenueber: keine Antwort, Test schlaegt fehl", function()
    local bus = busLib.new()
    local a = computer(bus, 1)
    t.eq(selftest.run(a, { "ping", "bahnhof-1", "zentrale-1" }), false)
    t.contains(a.output(), "Ping 1: keine Antwort")
    t.contains(a.output(), "0 von 5 Antworten")
  end },
  { "Aufruf ueber main und falsche Aufrufe", function()
    local bus = busLib.new()
    local env = computer(bus, 1)
    t.eq(main.run(env, { "selftest" }), true, env.output())
    local env2 = computer(bus, 2)
    t.eq(main.run(env2, { "selftest", "blabla" }), false)
    t.contains(env2.output(), "Aufruf: main selftest")
    local env3 = computer(bus, 3)
    t.eq(main.run(env3, { "selftest", "ping", "nur-einer" }), false)
  end },
}
