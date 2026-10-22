











local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local fence={}

fence.DEFAULT_PATH="state/crn_epoch.json"

function fence.new(opts)
opts=opts or{}
local path=opts.path or fence.DEFAULT_PATH
local io_opts={fs=opts.fs}
local masters={}
for _,id in ipairs(opts.masters or{})do masters[id]=true end
local self={}
local highest=0

do
local body=safe_write.read_with_backup(path,io_opts)
if body then
local ok,decoded=pcall(json.decode,body)
if ok and type(decoded)=="table" and type(decoded.epoch)=="number" then highest=decoded.epoch end
end
end

function self.epoch()return highest end


function self.set_topology(list,required)
masters={}
for _,id in ipairs(list or{})do masters[id]=true end
opts.required=required==true
end

function self.check(payload,src)
local epoch=payload and payload.election_epoch
if epoch==nil then
if opts.required then return false,"no_epoch" end
return true
end
if type(epoch)~="number" or epoch<1 or epoch~=math.floor(epoch)then return false,"bad_epoch" end
if payload.election_leader~=nil and payload.election_leader~=src then return false,"leader_mismatch" end
if next(masters)~=nil and not masters[src] then return false,"leader_mismatch" end
if epoch<highest then return false,"old_epoch" end
if epoch>highest then
local ok=safe_write.write(path,json.encode({v=1,epoch=epoch}),io_opts)
if not ok then return false,"epoch_not_stored" end
highest=epoch
end
return true
end

return self
end

return fence
