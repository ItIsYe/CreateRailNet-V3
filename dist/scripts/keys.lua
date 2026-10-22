









package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local keys_tool=require("src.setup.keys_tool")
local config_module=require("src.shared.config")

local cfg
if fs and fs.exists and fs.exists("configs/network.json")then
local ok,loaded=pcall(config_module.load,"configs/network.json")
if ok then cfg=loaded end
end

local code=keys_tool.run({...},{
fs=fs,
peripheral=peripheral,
say=print,
ask=function(prompt)write(prompt);return read()end,
now=function()return os.epoch and math.floor(os.epoch("utc")/1000)or os.time()end,
entropy=function()return tostring(os.clock()).. tostring(os.epoch and os.epoch("utc")or 0)end,
config=cfg
})
if code~=0 then error("",0)end
