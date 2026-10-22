























package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local wizard=require("src.setup.wizard")
local link=require("src.setup.link")
local plan_fetch=require("src.setup.plan_fetch")
local setup_bundle=require("src.shared.setup_bundle")

local result=wizard.run({
args={...},
env={
print=print,
write=write or io.write,
read=read or function()return io.read()end,
term=term,
colors=colors,
fs=fs,
peripheral=peripheral,
os=os,
host=_HOST,
link=link.probe,
fetch=plan_fetch.fetch,
sleep=sleep,
redstone=redstone,
before_reboot=function()setup_bundle.slim({fs=fs,shell=shell,say=print})end,
},
})

if result.aborted then
print("")
print("Abgebrochen. Es wurde nichts geaendert.")
end
