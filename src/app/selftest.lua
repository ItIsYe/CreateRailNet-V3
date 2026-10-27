--[[
Purpose: Selbsttest des Kerns im Spiel (Stufe 1): prueft Uhr, sicheres Speichern, Journal und Funk auf dem echten Computer und zwischen zwei Computern. Schreibt nur in /crn_data/selftest und raeumt danach auf.
API: selftest.run(env, args): args = {} (lokale Pruefungen), {"listen", node_id} (antwortet auf Pings), {"ping", eigene_id, ziel_id} (fuenf Pings mit Laufzeit in Spielsekunden)
Notes: env = { fs, raw_clock, peripheral, rednet, pull(timeout) -> Ereignis oder nil, print, real_clock }.
]]

local storelib = require("core.store")
local journal = require("core.journal")
local clocklib = require("core.clock")
local tickerlib = require("core.ticker")
local msg = require("core.msg")
local netlib = require("core.net")

local M = {}

local DIR = "/crn_data/selftest"

local function check(env, results, name, ok, detail)
  results[#results + 1] = { name = name, ok = ok }
  env.print((ok and "  ok      " or "  FEHLER  ") .. name .. (detail and (" - " .. detail) or ""))
end

local function wipe(env)
  if env.fs.exists(DIR) then env.fs.delete(DIR) end
end

function M.local_checks(env)
  local results = {}
  env.print("Lokale Pruefungen")
  env.fs.makeDir(DIR)
  local store = storelib.new(env.fs)

  -- sicheres Speichern
  local path = DIR .. "/wert.lua"
  local saved = store.save(path, { n = 1, text = "Umlaut-frei" })
  check(env, results, "Speichern", saved == true)
  store.save(path, { n = 2 })
  local value, source = store.load(path)
  check(env, results, "Laden der neuesten Fassung", value ~= nil and value.n == 2 and source == "main")
  check(env, results, "Vorversion bleibt erhalten", env.fs.exists(path .. ".prev"))

  -- Uhr in Spielzeit
  local clock = clocklib.new({ raw = env.raw_clock, store = store, path = DIR .. "/uhr.lua" })
  local t0 = clock.now()
  local ticker = tickerlib.new(clock)
  local fired = 0
  ticker.every("test", 1, function() fired = fired + 1 end)
  local deadline = env.raw_clock() + 3.5
  while env.raw_clock() < deadline do
    env.pull(0.5)
    ticker.poll()
  end
  local elapsed = clock.now() - t0
  check(env, results, "Uhr laeuft in Spielzeit", elapsed >= 3 and elapsed < 5, string.format("%.2f s Spielzeit", elapsed))
  check(env, results, "Aufgaben nach Betriebszeit", fired >= 2 and fired <= 4, fired .. " Aufrufe in 3,5 s")
  clock.save()
  local clock2 = clocklib.new({ raw = env.raw_clock, store = store, path = DIR .. "/uhr.lua" })
  check(env, results, "Uhr setzt nach Neustart fort", clock2.resumed() and clock2.now() >= elapsed - 0.01 and clock2.boot_id() == clock.boot_id() + 1)

  -- Journal
  local j = journal.new({ fs = env.fs, path = DIR .. "/journal.log", now = clock.now, max_bytes = 800, keep = 3 })
  local open_id = j.begin("selbsttest.offen", { zug = "GZ-001" })
  for i = 1, 30 do j.finish(j.begin("selbsttest.fertig", { i = i }), { ok = true }) end
  local j2 = journal.new({ fs = env.fs, path = DIR .. "/journal.log", now = clock.now, max_bytes = 800, keep = 3 })
  local pending = j2.pending()
  check(env, results, "Journal behaelt offene Vorgaenge", #pending == 1 and pending[1].id == open_id)
  check(env, results, "Journal bleibt klein", j2.size() < 2000, j2.size() .. " Byte")

  -- Modems
  local wireless, wired = 0, 0
  for _, name in ipairs(env.peripheral.getNames()) do
    if env.peripheral.getType(name) == "modem" then
      local ok, w = pcall(env.peripheral.call, name, "isWireless")
      if ok and w then wireless = wireless + 1 elseif ok then wired = wired + 1 end
    end
  end
  check(env, results, "Funkmodem vorhanden", wireless > 0, wireless .. " Funk, " .. wired .. " Kabel")

  wipe(env)
  local failed = 0
  for _, r in ipairs(results) do if not r.ok then failed = failed + 1 end end
  env.print(failed == 0 and "Alle lokalen Pruefungen bestanden." or (failed .. " Pruefung(en) fehlgeschlagen."))
  return failed == 0
end

local function setup_net(env, node_id)
  local store = storelib.new(env.fs)
  env.fs.makeDir(DIR)
  local clock = clocklib.new({ raw = env.raw_clock, store = store, path = DIR .. "/uhr-" .. node_id .. ".lua" })
  local factory = msg.new({ node_id = node_id, boot_id = clock.boot_id(), epoch = 0 })
  local inbox = msg.inbox({ node_id = node_id })
  local info = netlib.open(env)
  local net = netlib.new({ rednet = env.rednet, factory = factory, inbox = inbox, clock = clock })
  return net, factory, clock, info
end

function M.listen(env, node_id)
  local net, _, _, info = setup_net(env, node_id)
  env.print("Antwortet als '" .. node_id .. "' auf Pings. Beenden mit Strg+T.")
  env.print("Funk: " .. (#info.opened > 0 and table.concat(info.opened, ", ") or "KEIN MODEM"))
  while true do
    local ev = env.pull(5)
    if ev then
      local m, status = net.receive(ev)
      if m and status == "ok" and m.messageType == "auftrag" and m.payload.kind == "ping" then
        env.print("Ping von " .. m.senderNodeId .. " (Nr. " .. tostring(m.payload.n) .. ")")
        net.reply(m, "angenommen", { n = m.payload.n })
      elseif m then
        env.print("Nachricht " .. status .. " von " .. m.senderNodeId)
      end
    end
  end
end

function M.ping(env, node_id, target)
  local net, factory, clock, info = setup_net(env, node_id)
  env.print("Pingt '" .. target .. "' als '" .. node_id .. "'. Funk: " .. (#info.opened > 0 and table.concat(info.opened, ", ") or "KEIN MODEM"))
  local ok_count, lost = 0, 0
  local total = 0
  for n = 1, 5 do
    local m = factory.make("auftrag", target, { kind = "ping", n = n }, { requestId = "ping" .. n })
    local started = clock.now()
    net.send(target, m)
    local answered = false
    local deadline = env.raw_clock() + 10
    while not answered and env.raw_clock() < deadline do
      local ev = env.pull(1)
      if ev then
        local reply, status = net.receive(ev)
        if reply and reply.correlationId == m.messageId and reply.payload.status == "angenommen" then
          answered = true
          local rtt = clock.now() - started
          total = total + rtt
          env.print(string.format("  Ping %d: %.2f s Spielzeit", n, rtt))
        end
      end
    end
    if answered then ok_count = ok_count + 1 else lost = lost + 1; env.print("  Ping " .. n .. ": keine Antwort") end
  end
  env.print(string.format("%d von 5 Antworten, Mittel %.2f s Spielzeit", ok_count, ok_count > 0 and total / ok_count or 0))
  return ok_count == 5
end

function M.run(env, args)
  if args[1] == "listen" and args[2] then return M.listen(env, args[2]) end
  if args[1] == "ping" and args[2] and args[3] then return M.ping(env, args[2], args[3]) end
  if args[1] == nil or args[1] == "local" then return M.local_checks(env) end
  env.print("Aufruf: main selftest | main selftest listen ID | main selftest ping EIGENE_ID ZIEL_ID")
  return false
end

return M
