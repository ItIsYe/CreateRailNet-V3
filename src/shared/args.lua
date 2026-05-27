--[[
Purpose: Shared command-line argument parsing for CC:Tweaked entrypoints.
Public API: parse(argv, spec) -> args table or error.
]]

local args = {}

local function normalize_spec(spec)
  local out = {}
  for name, opts in pairs(spec or {}) do
    out["--" .. name] = opts or {}
  end
  return out
end

function args.parse(argv, spec)
  local parsed = {}
  local normalized = normalize_spec(spec or { config = {}, id = {} })
  local i = 1

  while i <= #(argv or {}) do
    local token = argv[i]
    local opt = normalized[token]
    if opt then
      local key = string.sub(token, 3)
      if opt.boolean then
        parsed[key] = true
        i = i + 1
      else
        local value = argv[i + 1]
        if value == nil or string.sub(tostring(value), 1, 2) == "--" then
          error("missing value for argument " .. token)
        end
        parsed[key] = value
        i = i + 2
      end
    else
      parsed._extra = parsed._extra or {}
      table.insert(parsed._extra, token)
      i = i + 1
    end
  end

  return parsed
end

return args
