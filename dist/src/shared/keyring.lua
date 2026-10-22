













local sha256=require("src.shared.sha256")

local keyring={}

function keyring.derive_node_key(master_key,id,epoch)
return sha256.hmac_hex(master_key,"crn1|node|" .. tostring(id).. "|" .. tostring(epoch))
end

function keyring.derive_link_key(master_key,id_a,id_b)
local low,high=tostring(id_a),tostring(id_b)
if high<low then low,high=high,low end
return sha256.hmac_hex(master_key,"crn1|link|" .. low .. "|" .. high)
end


function keyring.fingerprint(secret)
local digest=sha256.hex("crn1|fingerprint|" .. tostring(secret))
return digest:sub(1,4).. "-" .. digest:sub(5,8).. "-" .. digest:sub(9,12)
end

local function id_set(list,extra)
local set={}
for _,id in ipairs(list or{})do set[id]=true end
if extra then set[extra]=true end
return set
end

local function valid_key(key)return type(key)=="string" and#key==64 and key:match("^%x+$")~=nil end
keyring.valid_key=valid_key

function keyring.node(opts)
local self={kind="node",id=opts.id}
local masters=id_set(opts.masters)
local key,epoch=opts.key,tonumber(opts.epoch)

function self.epoch_for()return epoch end
function self.has_key()return valid_key(key)end

function self.pair_key(src,dst,message_epoch)
if not valid_key(key)then return nil,"no_key" end
local peer
if src==self.id then peer=dst elseif dst==self.id then peer=src else return nil,"not_mine" end
if peer~="broadcast" and not masters[peer] then return nil,"unknown_peer" end
if peer=="broadcast" and src~=self.id then return nil,"unknown_peer" end
if message_epoch~=nil and message_epoch~=epoch then return nil,"stale_key" end
return key
end
return self
end

function keyring.master(opts)
local self={kind="master",id=opts.id}
local masters=id_set(opts.masters,opts.id)
local master_key=opts.master_key
local trust=opts.trust or{nodes={}}

local derived={}
local function node_key(peer,entry_epoch)
local name=peer .. "|" .. entry_epoch
local key=derived[name]
if not key then
key=keyring.derive_node_key(master_key,peer,entry_epoch)
derived[name]=key
end
return key
end

function self.epoch_for(peer)
local entry=trust.nodes and trust.nodes[peer]
return type(entry)=="table" and entry.epoch or nil
end
function self.has_key()return valid_key(master_key)end


function self.set_trust(new_trust)trust=new_trust or{nodes={}};derived={}end
function self.entry(id)return trust.nodes and trust.nodes[id] end

function self.pair_key(src,dst,message_epoch)
if not valid_key(master_key)then return nil,"no_key" end
local peer
if src==self.id then peer=dst
elseif dst==self.id or dst=="broadcast" then peer=src
else return nil,"not_mine" end
if peer=="broadcast" or peer==self.id then return nil,"unknown_peer" end
if masters[peer] then
local link="link|" .. peer
derived[link]=derived[link] or keyring.derive_link_key(master_key,self.id,peer)
return derived[link]
end
local entry=trust.nodes and trust.nodes[peer]
if type(entry)~="table" then return nil,"unknown_peer" end
if entry.status~="active" then return nil,"revoked" end
if message_epoch~=nil and message_epoch~=entry.epoch then return nil,"stale_key" end
return node_key(peer,entry.epoch)
end
return self
end

return keyring
