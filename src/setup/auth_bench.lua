--[[
Purpose: Measures what the message authentication costs on this computer (benchmark of Gesamtkonzept risk R-05 / test J-04): hash, signing, checking.
Public API: run(opts) -> { backend, hash_ms, sign_ms, verify_ms, per_second, rounds } ; lines(result) -> list of German text lines.
  opts: rounds (default 200), clock (function -> seconds, default os.clock), payload_size (default 120).
Notes: in the game one tick is 50 ms of server time but os.clock counts real processor time of the computer, so the figures are what the computer needs, not what the
  server grants it; run it on the master with the plan loaded and compare with the number of messages per second the net carries (docs/KEYS.md).
]]

local sha256 = require("src.shared.sha256")
local auth = require("src.shared.auth")
local keyring = require("src.shared.keyring")
local keystore = require("src.shared.keystore")

local auth_bench = {}

function auth_bench.run(opts)
  opts = opts or {}
  local rounds = opts.rounds or 200
  local clock = opts.clock or os.clock
  local text = string.rep("x", opts.payload_size or 120)

  local started = clock()
  for i = 1, rounds do sha256.hmac_hex("benchmark key", text .. i) end
  local hash_ms = (clock() - started) * 1000 / rounds

  -- a master and a node with real keys, the handshake done, then messages in a row
  local master_key = sha256.hex("benchmark master key")
  local trust = { rev = 1, nodes = {} }
  local record = keystore.issue(trust, master_key, "BENCH-1", "signal", 0)
  local now = 0
  local function now_ms() return now end
  local master = auth.new({ node_id = "M", mode = "enforce", now_ms = now_ms, budget = 1000000,
    keyring = keyring.master({ id = "M", master_key = master_key, trust = trust, masters = { "M" } }), session = "bench-master" })
  local node = auth.new({ node_id = "BENCH-1", mode = "enforce", now_ms = now_ms, budget = 1000000,
    keyring = keyring.node({ id = "BENCH-1", key = record.key, epoch = record.epoch, masters = { "M" } }), session = "bench-node" })
  local function message(n)
    return { v = 1, pv = 5, id = "bench." .. n, src = "BENCH-1", dst = "M", type = "event", ts = n, payload = { type = "sensor", sensor_id = "BENCH-1", filler = text } }
  end
  local first = message(0)
  node.sign(first)
  local verdict, nonce = master.verify(first)
  assert(verdict == "challenge", "benchmark handshake: " .. tostring(verdict))
  node.accept_challenge({ src = "M", payload = { kind = "challenge", for_ss = "bench-node", nonce = nonce } })

  local signed = {}
  started = clock()
  for i = 1, rounds do
    local msg = message(i)
    node.sign(msg)
    signed[i] = msg
  end
  local sign_ms = (clock() - started) * 1000 / rounds

  started = clock()
  local accepted = 0
  for i = 1, rounds do
    local verdict_i = master.verify(signed[i])
    if verdict_i == "ok" then accepted = accepted + 1 end
  end
  local verify_ms = (clock() - started) * 1000 / rounds
  assert(accepted == rounds, "benchmark messages were refused: " .. accepted .. "/" .. rounds)

  local per_second = verify_ms > 0 and math.floor(1000 / verify_ms) or math.huge
  return { backend = sha256.backend(), hash_ms = hash_ms, sign_ms = sign_ms, verify_ms = verify_ms, per_second = per_second, rounds = rounds }
end

function auth_bench.lines(result)
  local function ms(value) return string.format("%.2f", value) end
  return {
    "Pruefcode-Messung (" .. result.rounds .. " Runden, Bit-Operationen: " .. result.backend .. ")",
    "  ein HMAC-SHA-256:        " .. ms(result.hash_ms) .. " ms",
    "  eine Nachricht signieren: " .. ms(result.sign_ms) .. " ms",
    "  eine Nachricht pruefen:   " .. ms(result.verify_ms) .. " ms  (" .. tostring(result.per_second) .. " Nachrichten pro Sekunde)",
    "Der Master braucht davon so viele, wie sein Netz Nachrichten pro Sekunde traegt (Heartbeats, Melder, Befehle)."
  }
end

return auth_bench
