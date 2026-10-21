--[[
Purpose: Canonical text form of a Lua value, the input of message authentication codes (Gesamtkonzept Kap. 12.2).
Public API: encode(value) -> text | nil, err.
Notes: the same value always gives the same text on every computer, whatever pairs() order, integer or float subtype or table layout the
  runtime has: tables are written with their keys sorted (numbers before strings), strings are length-prefixed, numbers use %.17g. Only
  nil, booleans, finite numbers, strings and tables of those are allowed; a cycle, NaN, an infinite number, a function or a table that
  is nested deeper than MAX_DEPTH is an error (an authenticated message must never carry something that cannot be written down).
]]

local canon = {}

local MAX_DEPTH = 24
local MAX_NODES = 20000

local format, concat = string.format, table.concat

local function encode_into(out, value, depth, state)
  state.nodes = state.nodes + 1
  if state.nodes > MAX_NODES then return nil, "too many values" end
  local kind = type(value)
  if kind == "nil" then out[#out + 1] = "n"
  elseif kind == "boolean" then out[#out + 1] = value and "t" or "f"
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil, "number is not finite" end
    out[#out + 1] = "d" .. format("%.17g", value) .. ";"
  elseif kind == "string" then out[#out + 1] = "s" .. #value .. ":" .. value
  elseif kind == "table" then
    if depth >= MAX_DEPTH then return nil, "nested too deep" end
    if state.open[value] then return nil, "cycle" end
    state.open[value] = true
    local keys = {}
    for key in pairs(value) do
      local key_kind = type(key)
      if key_kind ~= "number" and key_kind ~= "string" then return nil, "key of type " .. key_kind end
      keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta == "number" end
      return a < b
    end)
    out[#out + 1] = "{" .. #keys .. ":"
    for _, key in ipairs(keys) do
      local ok, err = encode_into(out, key, depth + 1, state)
      if not ok and err then return nil, err end
      ok, err = encode_into(out, value[key], depth + 1, state)
      if not ok and err then return nil, err end
    end
    out[#out + 1] = "}"
    state.open[value] = nil
  else
    return nil, "value of type " .. kind
  end
  return true
end

function canon.encode(value)
  local out = {}
  local ok, err = encode_into(out, value, 0, { nodes = 0, open = {} })
  if not ok then return nil, err end
  return concat(out)
end

return canon
