--[[
Purpose: Validate network configuration with actionable errors.
Public API: validate_config(cfg) -> ok, errors.
]]
local validate = {}
local roles={master=true,signal=true,sensor=true,switch=true,station=true,depot=true,panel=true,train=true}
local function add(e,p,m) table.insert(e,p..": "..m) end
local function nonempty(v) return type(v)=="string" and v~="" end
function validate.validate_config(cfg)
local e={} if type(cfg)~="table" then add(e,"config","must be an object"); return false,e end
if cfg.v~=1 then add(e,"v","must be 1") end; if type(cfg.channel)~="number" or cfg.channel<=0 or cfg.channel%1~=0 then add(e,"channel","must be integer > 0") end
if not nonempty(cfg.master_id) then add(e,"master_id","must be non-empty string") end
if type(cfg.blocks)~="table" then add(e,"blocks","must be an array") end; if type(cfg.routes)~="table" then add(e,"routes","must be an array") end; if type(cfg.nodes)~="table" then add(e,"nodes","must be an array") end
local node_ids,block_ids,route_ids,node_roles={},{},{},{}
for i,n in ipairs(cfg.nodes or {}) do local b="nodes["..i.."]"; if not nonempty(n.id) then add(e,b..".id","must be non-empty string") elseif node_ids[n.id] then add(e,b..".id","duplicate node id \""..n.id.."\"") else node_ids[n.id]=true end; if not roles[n.role] then add(e,b..".role","invalid role \""..tostring(n.role).."\"") else node_roles[n.id]=n.role end end
if cfg.master_id and node_roles[cfg.master_id]~="master" then add(e,"master_id","must reference node with role master") end
for i,b in ipairs(cfg.blocks or {}) do local p="blocks["..i.."]"; if not nonempty(b.id) then add(e,p..".id","must be non-empty string") elseif block_ids[b.id] then add(e,p..".id","duplicate block id \""..b.id.."\"") else block_ids[b.id]=true end
if not nonempty(b.entry_signal) or node_roles[b.entry_signal]~="signal" then add(e,p..".entry_signal","references unknown signal node \""..tostring(b.entry_signal).."\"") end
if not nonempty(b.exit_signal) or node_roles[b.exit_signal]~="signal" then add(e,p..".exit_signal","references unknown signal node \""..tostring(b.exit_signal).."\"") end
for j,s in ipairs(b.sensors or {}) do if node_roles[s]~="sensor" then add(e,p..".sensors["..j.."]","references unknown sensor node \""..tostring(s).."\"") end end
for j,sw in ipairs(b.switches or {}) do if node_roles[sw.id]~="switch" then add(e,p..".switches["..j.."].id","references unknown switch node \""..tostring(sw.id).."\"") end; if type(sw.position)~="string" or sw.position=="" then add(e,p..".switches["..j.."].position","must be non-empty string") end end end
for i,r in ipairs(cfg.routes or {}) do local p="routes["..i.."]"; if not nonempty(r.id) then add(e,p..".id","must be non-empty string") elseif route_ids[r.id] then add(e,p..".id","duplicate route id \""..r.id.."\"") else route_ids[r.id]=true end
if type(r.from)~="string" then add(e,p..".from","must be a string") end; if type(r.to)~="string" then add(e,p..".to","must be a string") end
for j,bid in ipairs(r.blocks or {}) do if not block_ids[bid] then add(e,p..".blocks["..j.."]","references unknown block \""..tostring(bid).."\"") end end end
return #e==0,e end
return validate
