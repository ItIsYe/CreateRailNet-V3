--[[
Purpose: The test of the radio / cable link between this computer and the master (scripts/setup.lua --linktest): how many questions are
  answered, how fast, and how large a message gets through in both directions. The plan hand-out (--fetch-plan) sends parts of about 3000
  bytes; this tells before whether such a message arrives. Nothing is switched and nothing is written; the master sees ordinary probes.
Public API:
  run(ctx, o) -> result
    ctx: what the doctor found out (role, id, cfg, entry)
    o: link(opts) -> { state, rtt_s, echoed } (src/setup/link.lua), peripheral (CC api), pings (10), wait_s (2: how long one question may take),
       sizes (list of bytes, default 256 / 1024 / 2048 / 3300 / 4000), tries (2 per size), on_progress(kind, a, b, c) (optional, never needed)
    result: { state = "ok" | "shaky" | "bad" | "none" | "no_modem" | "old_master",
              sent, answered, quick (answered within QUICK_S), rtt_min, rtt_avg, rtt_max (seconds, nil when nothing was answered),
              sizes = list of { bytes, ok } (nil when the ladder was not run), largest (bytes that went through in both directions),
              part_ok (a message of PART_BYTES goes through), aborted (the first questions got no answer) }
  PART_BYTES = 3300 (a plan part of 3000 bytes with its envelope), QUICK_S = 0.35
Notes: a question is a probe of the setup wizard: the master answers it and counts the computer as a candidate when it is not in the plan yet, as
  it does for the doctor. The ladder puts the filler into the probe and asks for the same amount back, so both directions are tried at once; a
  master that does not know the filler (older revision) is reported as old_master with the answers counted. "quick" is an answer that came before
  the first retry of the protocol would have gone out (0.2 s), so it says how many messages arrive at the first try.
]]

local linktest = {}

linktest.PART_BYTES = 3300
linktest.QUICK_S = 0.35

local DEFAULT_SIZES = { 256, 1024, 2048, 3300, 4000 }
local ANSWERS = { known = true, pending = true, conflict = true, rejected = true, old_master = true }

function linktest.run(ctx, o)
  local opts = o or {}
  local cfg, entry = ctx.cfg or {}, ctx.entry or {}
  local pings = opts.pings or 10
  local wait_s = opts.wait_s or 2
  local result = { sent = 0, answered = 0, quick = 0 }
  local function progress(...) if opts.on_progress then pcall(opts.on_progress, ...) end end

  local function ask(extra)
    local probe = { channel = cfg.channel, master_id = cfg.master_id, id = ctx.id, role = ctx.role, entry = ctx.entry,
      setup = { state = "KONFIGURIERT" }, modem_name = entry.modem, peripheral = opts.peripheral, wait_s = wait_s }
    for key, value in pairs(extra or {}) do probe[key] = value end
    local called, answer = pcall(opts.link, probe)
    if not called or type(answer) ~= "table" then return { state = "no_answer" } end
    return answer
  end

  -- A question counts as answered when the master said something (pair_state). A master that only acknowledged it is one from before
  -- pairing -- or one whose answer was lost: that is told apart afterwards, from what the other questions found.
  local total, lowest, highest, misses, acked_only = 0, nil, nil, 0, 0
  local function note(rtt)
    total = total + rtt
    if lowest == nil or rtt < lowest then lowest = rtt end
    if highest == nil or rtt > highest then highest = rtt end
    if rtt < linktest.QUICK_S then result.quick = result.quick + 1 end
  end
  local acked_rtt = {}
  for index = 1, pings do
    local answer = ask()
    result.sent = result.sent + 1
    if answer.state == "no_modem" then result.state = "no_modem"; return result end
    if answer.state == "old_master" then
      misses = 0
      acked_only = acked_only + 1
      acked_rtt[#acked_rtt + 1] = tonumber(answer.rtt_s) or 0
      progress("ping", index, pings, nil)
    elseif ANSWERS[answer.state] then
      misses = 0
      result.answered = result.answered + 1
      local rtt = tonumber(answer.rtt_s) or 0
      note(rtt)
      progress("ping", index, pings, rtt)
    else
      misses = misses + 1
      progress("ping", index, pings, nil)
      -- three questions in a row without an answer and none before: nobody is there, more questions would only take time
      if misses >= 3 and result.answered == 0 and acked_only == 0 then result.aborted = true; break end
    end
  end
  if result.answered == 0 and acked_only > 0 then
    -- only acknowledgements, never an answer: a master from before pairing; what is measured is the acknowledgement
    result.old_master, result.answered = true, acked_only
    for _, rtt in ipairs(acked_rtt) do note(rtt) end
  end

  if result.answered > 0 then
    result.rtt_min, result.rtt_max, result.rtt_avg = lowest, highest, total / result.answered
  end
  if result.answered == 0 then result.state = "none"; return result end
  if result.answered == result.sent and result.quick * 10 >= result.sent * 9 then result.state = "ok"
  elseif result.answered * 5 >= result.sent * 4 then result.state = "shaky"
  else result.state = "bad" end

  -- an older master answers but cannot send filler back: the sizes are not tried
  if result.old_master then
    result.state = result.state == "ok" and "old_master" or result.state
    return result
  end

  result.sizes, result.largest = {}, 0
  local tries = opts.tries or 2
  for _, bytes in ipairs(opts.sizes or DEFAULT_SIZES) do
    local went = false
    for _ = 1, tries do
      local answer = ask({ pad_bytes = bytes, echo_bytes = bytes })
      if ANSWERS[answer.state] and answer.state ~= "old_master" and answer.echoed == bytes then went = true; break end
    end
    result.sizes[#result.sizes + 1] = { bytes = bytes, ok = went }
    progress("size", bytes, went)
    if not went then break end
    result.largest = bytes
  end
  result.part_ok = result.largest >= linktest.PART_BYTES
  return result
end

return linktest
