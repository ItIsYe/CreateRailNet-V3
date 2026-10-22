








package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local signal_tool=require("src.setup.signal_tool")
local config_module=require("src.shared.config")

local args={...}
local id
local rest={}
local i=1
while i<=#args do
if args[i]=="--id" then id=args[i+1];i=i+2 else rest[#rest+1]=args[i];i=i+1 end
end

local cfg
if fs and fs.exists and fs.exists("configs/network.json")then
local ok,loaded=pcall(config_module.load,"configs/network.json")
if ok then cfg=loaded end
end
if not id and cfg then
for _,node in ipairs(cfg.nodes or{})do
if node.role=="signal" and type(node.signals)=="table" then id=id or node.id end
end
end

local code=signal_tool.run(rest,{
fs=fs,peripheral=peripheral,config=cfg,id=id,
say=print,
ask=function(prompt)write(prompt);return read()end,
now=function()return os.epoch and math.floor(os.epoch("utc")/1000)or os.time()end
})
if code~=0 then error("",0)end
