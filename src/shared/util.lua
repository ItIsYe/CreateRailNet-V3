--[[
Purpose: Utility helpers (safe calls, table helpers, id generation).
Public API: safe_call(fn,...), deepcopy(tbl), index_by(list, key), gen_id(prefix).
]]

local util = {}

local id_counter = 0

function util.safe_call(fn, ...)
  local ok, result = pcall(fn, ...)
  if ok then
    return true, result
  end
  return false, result
end

function util.deepcopy(tbl)
  if type(tbl) ~= "table" then
    return tbl
  end
  local copy = {}
  for k, v in pairs(tbl) do
    copy[k] = util.deepcopy(v)
  end
  return copy
end

function util.index_by(list, key)
  local out = {}
  for _, item in ipairs(list or {}) do
    out[item[key]] = item
  end
  return out
end

function util.gen_id(prefix)
  id_counter = id_counter + 1
  return string.format("%s-%d", prefix or "id", id_counter)
end

return util
