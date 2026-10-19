--[[
Purpose: Which computers an OTA rollout reaches: all nodes of the plan, those of one role, the first few of them (to try a new version on one
  signal before it goes to all), or one named node. The master is never a target. A wrong role or an empty result is an error before anything
  is sent.
Public API:
  select(cfg, { role, limit, node }) -> list of node ids (sorted) | nil, message
    role: one of the roles of the plan   limit: a whole number >= 1 (the first n of the sorted list)   node: one id (combined with nothing)
  describe(list, opts) -> text for the operator: what will be offered to whom
Notes: used by scripts/ota_push.lua (--role, --limit, --node, --dry-run). The messages are German because they are shown to the operator.
]]

local ota_targets = {}

local ROLES = { "master", "signal", "sensor", "switch", "station", "depot", "train", "panel" }

local function known_role(role)
  for _, name in ipairs(ROLES) do if name == role then return true end end
  return false
end

function ota_targets.select(cfg, o)
  local opts = o or {}
  if opts.node ~= nil then
    if opts.role ~= nil or opts.limit ~= nil then return nil, "--node wird mit nichts anderem kombiniert (weder --role noch --limit)." end
    return { tostring(opts.node) }
  end
  if opts.role ~= nil then
    if not known_role(opts.role) then return nil, "Unbekannte Rolle '" .. tostring(opts.role) .. "' (moeglich: " .. table.concat(ROLES, ", ") .. ")." end
    if opts.role == "master" then return nil, "Der Master ist kein Ziel einer Verteilung (er verteilt selbst)." end
  end
  local limit
  if opts.limit ~= nil then
    limit = tonumber(opts.limit)
    if not limit or limit < 1 or limit ~= math.floor(limit) then return nil, "--limit muss eine ganze Zahl ab 1 sein, nicht '" .. tostring(opts.limit) .. "'." end
  end
  local list = {}
  for _, node in ipairs((cfg and cfg.nodes) or {}) do
    if type(node) == "table" and type(node.id) == "string" and node.id ~= "" and node.role ~= "master" and node.id ~= (cfg and cfg.master_id)
      and (opts.role == nil or node.role == opts.role) then
      list[#list + 1] = node.id
    end
  end
  table.sort(list)
  if #list == 0 then
    return nil, opts.role and ("Im Netzplan gibt es keinen Computer mit der Rolle '" .. opts.role .. "'.") or "Im Netzplan gibt es keine Computer ausser dem Master."
  end
  if limit and limit < #list then
    local first = {}
    for index = 1, limit do first[index] = list[index] end
    list = first
  end
  return list
end

function ota_targets.describe(list, o)
  local opts = o or {}
  if not list or #list == 0 then return "Angeboten wird jedem Computer, der auf dem Kanal antwortet." end
  local what = opts.role and (" mit der Rolle " .. opts.role) or ""
  local first = opts.limit and (" (die ersten " .. #list .. ")") or ""
  return "Angeboten wird " .. #list .. " Computer" .. what .. first .. ": " .. table.concat(list, ", ")
end

return ota_targets
