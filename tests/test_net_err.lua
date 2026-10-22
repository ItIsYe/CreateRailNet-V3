--[[
Purpose: An err answers a reliable message: the retries stop and the sender is told (net.on_err); an unrelated err changes nothing.
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local net = require("src.shared.net")
local function counting_modem()
  local m = { sent = {} }
  function m.open() return true end
  function m.send(_, _, _, msg) m.sent[#m.sent + 1] = msg; return true end
  function m.broadcast(_, _, msg) m.sent[#m.sent + 1] = msg; return true end
  return m
end

local clock = { t = 0 }
local time_mod = { now_ms = function() return clock.t end }

return {
  test_an_err_ends_the_retries_of_the_message_it_names_and_is_reported = function()
    clock.t = 0
    local modem = counting_modem()
    local endpoint = net.new(modem, 1, "M", nil, time_mod)
    local heard = {}
    endpoint.on_err = function(payload, original, source) heard[#heard + 1] = { payload.ref_id, original and original.id, source } end
    local msg = endpoint.send_reliable("cmd", "N", { cmd = "x" })
    assert(endpoint.pending[msg.id])
    local status = endpoint.receive({ v = 1, id = "N.1", src = "N", dst = "M", type = "err", payload = { ref_id = msg.id, error = "refused" } })
    assert(status == "ok", "the runtime still gets to see the message")
    assert(endpoint.pending[msg.id] == nil, "no more retries")
    assert(#heard == 1 and heard[1][1] == msg.id and heard[1][2] == msg.id and heard[1][3] == "N")
    local sent_before = #modem.sent
    clock.t = 120000
    endpoint.tick()
    assert(#modem.sent == sent_before, "nothing is sent again")
  end,

  test_an_err_for_an_unknown_message_is_reported_with_no_original_and_changes_nothing_else = function()
    clock.t = 0
    local endpoint = net.new(counting_modem(), 1, "M", nil, time_mod)
    local msg = endpoint.send_reliable("cmd", "N", { cmd = "x" })
    local heard
    endpoint.on_err = function(payload, original) heard = { payload.ref_id, original } end
    endpoint.receive({ v = 1, id = "N.2", src = "N", dst = "M", type = "err", payload = { ref_id = "other", error = "e" } })
    assert(heard[1] == "other" and heard[2] == nil)
    assert(endpoint.pending[msg.id], "the other message is still pending")
    -- an err without a ref_id is not an answer
    endpoint.on_err = function() error("must not be called") end
    endpoint.receive({ v = 1, id = "N.3", src = "N", dst = "M", type = "err", payload = { error = "e" } })
  end
}
