










local sha256=require("src.shared.sha256")
local canon=require("src.shared.canon")

local update_package={}


update_package.DATA_SCHEMA=1

local function signed_body(package)
return{format=package.format,release=package.release,roles=package.roles,protocol=package.protocol,schema=package.schema,migration=package.migration,min_free_bytes=package.min_free_bytes,rollback_to=package.rollback_to,files=package.files}
end

local function mac_of(package,key)
local text,err=canon.encode(signed_body(package))
if not text then return nil,err end
return sha256.hmac_hex(key,text)
end

function update_package.build(files,meta,key)
local list={}
for _,file in ipairs(files or{})do list[#list+1]={path=file.path,size=#file.content,sha256=sha256.hex(file.content)}end
table.sort(list,function(a,b)return a.path<b.path end)
local package={format=1,release=meta.release,roles=meta.roles,protocol=meta.protocol,schema=meta.schema,migration=meta.migration,min_free_bytes=meta.min_free_bytes or 0,rollback_to=meta.rollback_to,files=list}
package.mac=assert(mac_of(package,key))
return package
end

local function has_role(package,role)
for _,name in ipairs(package.roles or{})do if name==role or name=="*" then return true end end
return false
end


function update_package.covers(package,manifest)
local listed={}
for _,file in ipairs(package.files or{})do listed[file.path]=file end
for _,item in ipairs(manifest or{})do
local file=listed[item.path]
if not file then return false,"file " .. tostring(item.path).. " is not covered by the package" end
if file.size~=item.size then return false,"file " .. tostring(item.path).. " has another size than the package says" end
end
return true
end

function update_package.verify(package,key,ctx,contents)
if type(package)~="table" or package.format~=1 or type(package.release)~="string" or package.release=="" or type(package.roles)~="table" or type(package.files)~="table" or type(package.mac)~="string" then
return false,"bad_format","the package misses release, roles, files or proof"
end
local expected,err=mac_of(package,key)
if not expected then return false,"bad_format",err end

local diff=#expected~=#package.mac and 1 or 0
for index=1,#expected do if expected:sub(index,index)~=package.mac:sub(index,index)then diff=diff+1 end end
if diff~=0 then return false,"bad_signature","origin proof does not match" end
ctx=ctx or{}
if ctx.role and not has_role(package,ctx.role)then return false,"wrong_role","package is not for the role " .. tostring(ctx.role)end
if ctx.protocol and package.protocol~=ctx.protocol then return false,"protocol_incompatible","package speaks protocol " .. tostring(package.protocol)end
if ctx.schema and package.schema~=ctx.schema then
if package.migration then return false,"migration_required","data schema " .. tostring(ctx.schema).. " -> " .. tostring(package.schema).. ": a person decides, no automatic operation" end
return false,"schema_incompatible","data schema " .. tostring(package.schema).. " does not fit " .. tostring(ctx.schema)
end
if type(package.rollback_to)~="string" or package.rollback_to=="" then return false,"no_rollback","the package names no release to return to" end
if ctx.free_bytes then
local total=0
for _,file in ipairs(package.files)do total=total+(tonumber(file.size)or 0)end
if ctx.free_bytes<total*2+(package.min_free_bytes or 0)then return false,"no_space","needs " ..(total*2+(package.min_free_bytes or 0)).. " bytes, free " .. ctx.free_bytes end
end
if contents then
for _,file in ipairs(package.files)do
local body=contents[file.path]
if body==nil or#body~=file.size or sha256.hex(body)~=file.sha256 then return false,"bad_file","file " .. tostring(file.path).. " does not match the package" end
end
end
return true
end

return update_package
