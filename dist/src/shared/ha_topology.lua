







local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local ha_topology={}

ha_topology.DEFAULT_PATH="state/crn_ha.json"

local function sane_id(id)return type(id)=="string" and id~="" and#id<=64 end

function ha_topology.sane(masters,arbiter,master_id)
if type(masters)~="table" or#masters<2 or#masters>3 then return false,"masters must list two or three ids" end
local seen,has_primary={},false
for _,id in ipairs(masters)do
if not sane_id(id)or seen[id] then return false,"bad or repeated master id" end
seen[id]=true
if id==master_id then has_primary=true end
end
if master_id and not has_primary then return false,"the known master is not in the list" end
if arbiter~=nil and(not sane_id(arbiter)or seen[arbiter])then return false,"bad arbiter id" end
return true
end

function ha_topology.load(path,opts)
local body=safe_write.read_with_backup(path or ha_topology.DEFAULT_PATH,{fs=opts and opts.fs})
if not body then return nil end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" then return nil end
if not ha_topology.sane(decoded.masters,decoded.arbiter)then return nil end
return{masters=decoded.masters,arbiter=decoded.arbiter}
end

function ha_topology.save(masters,arbiter,path,opts)
return safe_write.write(path or ha_topology.DEFAULT_PATH,json.encode({v=1,masters=masters,arbiter=arbiter}),{fs=opts and opts.fs})
end

return ha_topology
