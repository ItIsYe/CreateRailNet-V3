













local keystore_default=require("src.shared.keystore")
local keyring=require("src.shared.keyring")

local replacement={}

function replacement.new(opts)
opts=opts or{}
local keystore=opts.keystore or keystore_default
local now=opts.now or function()return 0 end
local records={}
local self={}

local function node_entry(id)
for _,node in ipairs((opts.plan and opts.plan.nodes)or{})do if node.id==id then return node end end
return nil
end

local function hosted(entry)
if not entry then return{}end
if type(entry.signals)=="table" and#entry.signals>0 then return entry.signals end
if entry.role=="signal" then return{entry.id}end
return{}
end

function self.begin(old_id,operator)
if type(operator)~="string" or operator=="" then return nil,"operator missing" end
local entry=node_entry(old_id)
if not entry then return nil,"the plan has no computer " .. tostring(old_id)end
if entry.role=="master" then return nil,"a master is replaced with the master update procedure (docs/HA.md), not here" end
local ok,err=keystore.revoke(opts.trust,old_id)
if not ok then return nil,err end
records[old_id]={state="WAIT_NEW_COMPUTER",role=entry.role,operator=operator,started=now()}
if opts.on_hold then opts.on_hold(old_id)end
return true
end


function self.adopt(old_id,operator,new_id)
new_id=new_id or old_id
local rec=records[old_id]
if not rec or rec.state~="WAIT_NEW_COMPUTER" then return nil,"no replacement waiting for a new computer for " .. tostring(old_id)end
if type(operator)~="string" or operator=="" then return nil,"operator missing" end
if new_id~=old_id and not node_entry(new_id)then return nil,"the new id " .. tostring(new_id).. " is not in the plan: enter it in the plan first" end
if new_id~=old_id and opts.trust.nodes[new_id] and opts.trust.nodes[new_id].status=="active" then return nil,"the id " .. tostring(new_id).. " already has an active key" end
local record,err=keystore.issue(opts.trust,opts.master_key,new_id,rec.role,now())
if not record then return nil,err end
rec.state,rec.new_id,rec.fingerprint="WAIT_KEY_CHECK",new_id,keyring.fingerprint(record.key)
return record,rec.fingerprint
end


function self.confirm_key(old_id,operator,matches)
local rec=records[old_id]
if not rec or rec.state~="WAIT_KEY_CHECK" then return nil,"no replacement waiting for the fingerprint of " .. tostring(old_id)end
if type(operator)~="string" or operator=="" then return nil,"operator missing" end
if matches~=true and matches~=false then return nil,"a clear answer is needed: the fingerprints match or they do not" end
if matches==false then
keystore.revoke(opts.trust,rec.new_id)
rec.state,rec.new_id,rec.fingerprint="WAIT_NEW_COMPUTER",nil,nil
return nil,"the fingerprint does not match: the key was withdrawn again"
end
rec.state="WAIT_BINDINGS"
return true
end

function self.bindings_confirmed(old_id,confirmed,operator)
local rec=records[old_id]
if not rec or rec.state~="WAIT_BINDINGS" then return nil,"no replacement waiting for bindings for " .. tostring(old_id)end
if type(operator)~="string" or operator=="" then return nil,"operator missing" end
local have={}
for _,id in ipairs(confirmed or{})do have[id]=true end
local missing={}
for _,id in ipairs(hosted(node_entry(old_id)))do if not have[id] then missing[#missing+1]=id end end
rec.missing=missing
if#missing>0 then return nil,"not confirmed on the new computer: " .. table.concat(missing,", ")end
rec.state="WAIT_TEST"
return true
end

function self.finish(old_id,operator,test)
local rec=records[old_id]
if not rec or rec.state~="WAIT_TEST" then return nil,"no replacement waiting for a test for " .. tostring(old_id)end
if type(operator)~="string" or operator=="" then return nil,"operator missing" end
if type(test)~="table" or test.ok~=true or type(test.source)~="string" or test.source=="" then return nil,"a passed test with its source is needed" end
rec.state="DONE"
if opts.on_release then opts.on_release(old_id)end
return true
end

function self.state_of(old_id)
local rec=records[old_id]
if not rec then return nil end
return{state=rec.state,new_id=rec.new_id,missing=rec.missing,fingerprint=rec.fingerprint}
end

return self
end

return replacement
