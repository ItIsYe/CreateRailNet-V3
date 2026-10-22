












local safe_write={}

local function resolve_fs(opts)
return(opts and opts.fs)or _G.fs
end

local function dirname(path)
local dir=tostring(path or ""):match("^(.*)/[^/]+$")
if dir=="" then return nil end
return dir
end

local function raw_read(fsys,path)
if fsys and fsys.open then
if fsys.exists and not fsys.exists(path)then return nil,"missing" end
local fh=fsys.open(path,"r")
if not fh then return nil,"cannot open " .. tostring(path)end
local body=fh.readAll()
fh.close()
if body==nil then return nil,"cannot read " .. tostring(path)end
return body
end
if io and io.open then
local fh=io.open(path,"r")
if not fh then return nil,"missing" end
local body=fh:read("*a")
fh:close()
return body
end
return nil,"no file API available"
end

local function raw_write(fsys,path,body)
if fsys and fsys.open then
local fh=fsys.open(path,"w")
if not fh then return false,"cannot open " .. tostring(path)end
fh.write(body)
fh.close()
return true
end
if io and io.open then
local fh=io.open(path,"w")
if not fh then return false,"cannot open " .. tostring(path)end
fh:write(body)
fh:close()
return true
end
return false,"no file API available"
end

local function raw_exists(fsys,path)
if fsys and fsys.exists then return fsys.exists(path)end
if io and io.open then
local fh=io.open(path,"r")
if fh then fh:close();return true end
end
return false
end

local function raw_delete(fsys,path)
if fsys and fsys.delete then
if not fsys.exists or fsys.exists(path)then fsys.delete(path)end
return true
end
if os and os.remove then os.remove(path);return true end
return false
end

local function raw_move(fsys,src,dst)
if fsys and fsys.move then fsys.move(src,dst);return true end
if os and os.rename then
local ok=os.rename(src,dst)
return ok~=nil and ok~=false
end
return false
end

function safe_write.backup_path(path)
return tostring(path).. ".prev"
end

function safe_write.read(path,opts)
return raw_read(resolve_fs(opts),path)
end

function safe_write.read_with_backup(path,opts)
local fsys=resolve_fs(opts)
local body,err=raw_read(fsys,path)
if body then return body,"primary" end
local prev=raw_read(fsys,safe_write.backup_path(path))
if prev then return prev,"backup" end
return nil,err
end

function safe_write.write(path,body,opts)
local fsys=resolve_fs(opts)
local keep_backup=not(opts and opts.keep_backup==false)
local tmp=path .. ".tmp"
local prev=safe_write.backup_path(path)
if type(body)~="string" then return false,"body must be a string" end

local dir=dirname(path)
if dir and fsys and fsys.exists and fsys.makeDir and not fsys.exists(dir)then fsys.makeDir(dir)end



if keep_backup and fsys and fsys.getFreeSpace and raw_exists(fsys,path)then
local okf,free=pcall(fsys.getFreeSpace,"/")
if okf and type(free)=="number" then
local current=raw_read(fsys,path)or ""
local old_prev=raw_read(fsys,prev)or ""

if free+math.max(#old_prev,old_prev=="" and 0 or 500)<math.max(#body,500)+math.max(#current,500)+500 then
raw_delete(fsys,prev)
keep_backup=false
end
end
end

local ok,err=raw_write(fsys,tmp,body)
if not ok then raw_delete(fsys,tmp);return false,err end

local back,read_err=raw_read(fsys,tmp)
if back~=body then
raw_delete(fsys,tmp)
return false,"verify failed for " .. tmp .. ": " .. tostring(read_err or "content differs")
end

local had_current=raw_exists(fsys,path)
if had_current and keep_backup then
local current=raw_read(fsys,path)
if current then
local copied,copy_err=raw_write(fsys,prev,current)
if not copied then raw_delete(fsys,tmp);return false,"backup failed: " .. tostring(copy_err)end
end
end
if had_current then raw_delete(fsys,path)end

if not raw_move(fsys,tmp,path)or not raw_exists(fsys,path)then

local old=keep_backup and raw_read(fsys,prev)or nil
if old then raw_write(fsys,path,old)end
return false,"move failed for " .. tostring(path)
end
return true
end

return safe_write
