--[[
Purpose: Minimal JSON encode/decode without external deps.
Public API: decode(str), encode(value).
]]

local json = {}

local function decode_error(msg, idx)
  error(string.format("JSON decode error at %d: %s", idx or -1, msg))
end

local function skip_ws(str, i)
  local len = #str
  while i <= len do
    local c = string.sub(str, i, i)
    if c ~= " " and c ~= "\n" and c ~= "\r" and c ~= "\t" then
      break
    end
    i = i + 1
  end
  return i
end

local function parse_string(str, i)
  i = i + 1
  local out = {}
  local len = #str
  while i <= len do
    local c = string.sub(str, i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local n = string.sub(str, i + 1, i + 1)
      if n == '"' or n == "\\" or n == "/" then
        table.insert(out, n)
      elseif n == "b" then
        table.insert(out, "\b")
      elseif n == "f" then
        table.insert(out, "\f")
      elseif n == "n" then
        table.insert(out, "\n")
      elseif n == "r" then
        table.insert(out, "\r")
      elseif n == "t" then
        table.insert(out, "\t")
      else
        decode_error("invalid escape", i)
      end
      i = i + 2
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  decode_error("unterminated string", i)
end

local function parse_number(str, i)
  local s = string.match(str, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not s or #s == 0 then
    decode_error("invalid number", i)
  end
  return tonumber(s), i + #s
end

local function parse_literal(str, i, literal, value)
  if string.sub(str, i, i + #literal - 1) == literal then
    return value, i + #literal
  end
  decode_error("invalid literal", i)
end

local parse_value

local function parse_array(str, i)
  local out = {}
  i = skip_ws(str, i + 1)
  if string.sub(str, i, i) == "]" then
    return out, i + 1
  end
  while true do
    local v
    v, i = parse_value(str, i)
    table.insert(out, v)
    i = skip_ws(str, i)
    local c = string.sub(str, i, i)
    if c == "," then
      i = skip_ws(str, i + 1)
    elseif c == "]" then
      return out, i + 1
    else
      decode_error("expected ',' or ']'", i)
    end
  end
end

local function parse_object(str, i)
  local out = {}
  i = skip_ws(str, i + 1)
  if string.sub(str, i, i) == "}" then
    return out, i + 1
  end
  while true do
    if string.sub(str, i, i) ~= '"' then
      decode_error("expected string key", i)
    end
    local key
    key, i = parse_string(str, i)
    i = skip_ws(str, i)
    if string.sub(str, i, i) ~= ":" then
      decode_error("expected ':'", i)
    end
    i = skip_ws(str, i + 1)
    local val
    val, i = parse_value(str, i)
    out[key] = val
    i = skip_ws(str, i)
    local c = string.sub(str, i, i)
    if c == "," then
      i = skip_ws(str, i + 1)
    elseif c == "}" then
      return out, i + 1
    else
      decode_error("expected ',' or '}'", i)
    end
  end
end

parse_value = function(str, i)
  i = skip_ws(str, i)
  local c = string.sub(str, i, i)
  if c == '"' then
    return parse_string(str, i)
  elseif c == "{" then
    return parse_object(str, i)
  elseif c == "[" then
    return parse_array(str, i)
  elseif c == "t" then
    return parse_literal(str, i, "true", true)
  elseif c == "f" then
    return parse_literal(str, i, "false", false)
  elseif c == "n" then
    return parse_literal(str, i, "null", nil)
  else
    return parse_number(str, i)
  end
end

function json.decode(str)
  if type(str) ~= "string" then
    decode_error("expected string", 1)
  end
  local value, idx = parse_value(str, 1)
  idx = skip_ws(str, idx)
  if idx <= #str then
    decode_error("trailing data", idx)
  end
  return value
end

local function encode_string(str)
  local replacements = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
  }
  return '"' .. str:gsub('["\\\b\f\n\r\t]', replacements) .. '"'
end

local function is_array(tbl)
  local i = 1
  for k, _ in pairs(tbl) do
    if k ~= i then
      return false
    end
    i = i + 1
  end
  return true
end

local function encode_value(val)
  local t = type(val)
  if t == "string" then
    return encode_string(val)
  elseif t == "number" or t == "boolean" then
    return tostring(val)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    if is_array(val) then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = encode_value(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(val) do
        parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(v)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  error("unsupported type in json encode: " .. t)
end

function json.encode(val)
  return encode_value(val)
end

return json
