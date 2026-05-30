--[[
Purpose: Adapter helper tests.
Public API: returns table of tests.
]]

local helper = require("src.adapter.methods")

local function backend()
  return {
    wrap = function(id)
      if id == "DEVICE" then return { readValue = function(value) return value end } end
      return nil, "device unavailable"
    end,
    methods = function(id)
      if id == "DEVICE" then return { "readValue" } end
      return {}
    end
  }
end

return {
  test_call_known_method = function()
    local ok, value = helper.call(backend(), "DEVICE", "readValue", "ok")
    assert(ok)
    assert(value == "ok")
  end,

  test_unknown_method_returns_error = function()
    local ok, err = helper.call(backend(), "DEVICE", "otherMethod")
    assert(not ok)
    assert(type(err) == "string")
  end,

  test_unavailable_device_returns_error = function()
    local ok, err = helper.call(backend(), "OTHER", "readValue")
    assert(not ok)
    assert(err == "device unavailable")
  end
}
