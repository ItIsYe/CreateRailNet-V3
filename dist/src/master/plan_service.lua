














local storage_budget=require("src.shared.storage_budget")
local checksum=require("src.shared.checksum")
local netplan=require("src.setup.netplan")
local time=require("src.shared.time")

local plan_service={}

function plan_service.new(opts)
local o=opts or{}
local fs_api=o.fs or _G.fs
local chunk_size=o.chunk_size or 3000
local max_bytes=o.max_bytes or storage_budget.PLAN_MAX_BYTES
local cache_s=o.cache_s or 60
local now=o.now_s or time.now_s
local self={}
local cache=nil

local function read_text()
if not(o.plan_path and fs_api and fs_api.exists and fs_api.exists(o.plan_path))then return nil,"Der Master findet seine Netzplan-Datei nicht." end
local fh=fs_api.open(o.plan_path,"r")
if not fh then return nil,"Der Master kann seine Netzplan-Datei nicht lesen." end
local text=fh.readAll()
fh.close()
if type(text)~="string" or text=="" then return nil,"Die Netzplan-Datei des Masters ist leer." end
return text
end

local function load()
local text,err=read_text()
if not text then return nil,err end
if#text>max_bytes then return nil,"Der Netzplan des Masters ist zu gross (" ..#text .. " Bytes)." end
local cfg,errors=netplan.parse(text)
if not cfg then return nil,"Der Netzplan des Masters ist keine gueltige JSON-Datei." end
if errors then return nil,"Der Netzplan des Masters hat " ..#errors .. " Fehler (am Master: scripts/setup.lua --check)." end
cache={
text=text,version=checksum.hex(checksum.adler32(text)),at=now(),
total=math.max(1,math.ceil(#text/chunk_size)),
}
return cache
end

function self.part(index,expect_version)
if type(index)~="number" or index~=math.floor(index)or index<1 then return{ok=false,state="error",reason="Ungueltige Teilnummer."}end
if expect_version~=nil and type(expect_version)~="string" then return{ok=false,state="error",reason="Ungueltige Version."}end
local entry=cache
local fresh=entry and now()- entry.at<=cache_s and entry.at<=now()

if index==1 or expect_version==nil or not fresh then
local loaded,err=load()
if not loaded then return{ok=false,state="error",reason=err}end
entry=loaded
end
if expect_version~=nil and expect_version~=entry.version then
return{ok=false,state="changed",reason="Der Netzplan am Master hat sich geaendert.",version=entry.version}
end
if index>entry.total then return{ok=false,state="error",reason="Teil " .. index .. " gibt es nicht (" .. entry.total .. " Teile)."}end
return{
ok=true,index=index,total=entry.total,version=entry.version,size=#entry.text,
data=entry.text:sub((index - 1)*chunk_size+1,index*chunk_size),
}
end

return self
end

return plan_service
