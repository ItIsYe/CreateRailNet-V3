





package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local setup_bundle=require("src.shared.setup_bundle")

local ok,err=setup_bundle.run("scripts/setup_main.lua",{...},{fs=fs,shell=shell,say=print})
if not ok then
if err and err~="failed" then print(err)end
error("",0)
end
