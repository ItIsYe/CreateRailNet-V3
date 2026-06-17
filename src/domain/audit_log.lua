--[[
Purpose: In-memory event audit log with bounded ring buffer.
Public API: new(limit) -> log with record, list, filter.
]]

local time = require("src.shared.time")

local audit_log = {}

local function copy_table(src)
  local dst = {}
  for k, v in pairs(src or {}) do
    if type(v) == "table" then dst[k] = copy_table(v) else dst[k] = v end
  end
  return dst
end

function audit_log.new(limit)
  local max = limit or 200
  local entries = {}
  local seq = 0
  local self = {}

  function self.record(kind, data)
    seq = seq + 1
    local entry = {
      seq = seq,
      ts = time.now_s(),
      kind = kind or "event",
      data = copy_table(data or {})
    }
    table.insert(entries, entry)
    if #entries > max then table.remove(entries, 1) end
    return entry
  end

  function self.list(count)
    local out = {}
    local max_count = count or #entries
    local start = math.max(1, #entries - max_count + 1)
    for i = start, #entries do out[#out + 1] = copy_table(entries[i]) end
    return out
  end

  function self.filter(kind, count)
    local out = {}
    for i = #entries, 1, -1 do
      if entries[i].kind == kind then
        table.insert(out, 1, copy_table(entries[i]))
        if count and #out >= count then break end
      end
    end
    return out
  end

  return self
end

return audit_log
