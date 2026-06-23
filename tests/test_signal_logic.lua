--[[
Unit tests for signal_logic: set_aspect, set_block_red, set_entry_green,
nil safety, error propagation.
]]
dofile("tests/harness/cc_bootstrap.lua")
local signal_logic = require("src.domain.signal_logic")

local function make_adapter(should_fail)
  local calls = {}
  local adapter = {
    calls = calls,
    setAspect = function(sig_id, aspect)
      table.insert(calls, { sig=sig_id, aspect=aspect })
      if should_fail then return false, "hardware error" end
      return true
    end
  }
  return adapter
end

return {
  -- set_aspect
  test_set_aspect_calls_adapter = function()
    local a = make_adapter(false)
    local ok, err = signal_logic.set_aspect("SIG-1", "RED", a)
    assert(ok)
    assert(err == nil)
    assert(a.calls[1].sig == "SIG-1")
    assert(a.calls[1].aspect == "RED")
  end,

  test_set_aspect_nil_signal_returns_true = function()
    local a = make_adapter(false)
    local ok = signal_logic.set_aspect(nil, "RED", a)
    assert(ok)
    assert(#a.calls == 0)
  end,

  test_set_aspect_nil_adapter_returns_true = function()
    local ok = signal_logic.set_aspect("SIG-1", "RED", nil)
    assert(ok)
  end,

  test_set_aspect_propagates_failure = function()
    local a = make_adapter(true)
    local ok, err = signal_logic.set_aspect("SIG-1", "GREEN", a)
    assert(not ok)
    assert(err == "hardware error")
  end,

  -- set_block_red
  test_set_block_red_sets_both_signals = function()
    local a = make_adapter(false)
    local block = { entry_signal="SIG-IN", exit_signal="SIG-OUT" }
    local ok, err = signal_logic.set_block_red(block, a)
    assert(ok)
    assert(#a.calls == 2)
    local sigs = {}
    for _, c in ipairs(a.calls) do sigs[c.sig] = c.aspect end
    assert(sigs["SIG-IN"] == "RED")
    assert(sigs["SIG-OUT"] == "RED")
  end,

  test_set_block_red_nil_block_returns_true = function()
    local a = make_adapter(false)
    local ok = signal_logic.set_block_red(nil, a)
    assert(ok)
    assert(#a.calls == 0)
  end,

  test_set_block_red_entry_signal_failure_propagates = function()
    local calls = {}
    local adapter = {
      setAspect = function(sig, asp)
        table.insert(calls, sig)
        if sig == "SIG-IN" then return false, "entry hw error" end
        return true
      end
    }
    local block = { entry_signal="SIG-IN", exit_signal="SIG-OUT" }
    local ok, err = signal_logic.set_block_red(block, adapter)
    assert(not ok)
    assert(err:find("entry signal failed"))
  end,

  test_set_block_red_exit_signal_failure_propagates = function()
    local adapter = {
      setAspect = function(sig, asp)
        if sig == "SIG-OUT" then return false, "exit hw error" end
        return true
      end
    }
    local block = { entry_signal="SIG-IN", exit_signal="SIG-OUT" }
    local ok, err = signal_logic.set_block_red(block, adapter)
    assert(not ok)
    assert(err:find("exit signal failed"))
  end,

  test_set_block_red_only_entry_signal = function()
    local a = make_adapter(false)
    local block = { entry_signal="SIG-IN" }  -- no exit_signal
    local ok = signal_logic.set_block_red(block, a)
    assert(ok)
    assert(#a.calls == 1)
    assert(a.calls[1].sig == "SIG-IN")
  end,

  -- set_entry_green
  test_set_entry_green_sets_green = function()
    local a = make_adapter(false)
    local block = { entry_signal="SIG-IN", exit_signal="SIG-OUT" }
    local ok = signal_logic.set_entry_green(block, a)
    assert(ok)
    assert(#a.calls == 1)
    assert(a.calls[1].aspect == "GREEN")
    assert(a.calls[1].sig == "SIG-IN")
  end,

  test_set_entry_green_nil_block_returns_true = function()
    local a = make_adapter(false)
    local ok = signal_logic.set_entry_green(nil, a)
    assert(ok)
    assert(#a.calls == 0)
  end,
}
