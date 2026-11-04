





local M={}

function M.new(env,spec)
local o={}

local function read()
if spec.relay then
local ok,v=pcall(env.peripheral.call,spec.relay,"getOutput",spec.side)
if ok then return v end
return nil
end
local ok,v=pcall(env.redstone.getOutput,spec.side)
if ok then return v end
return nil
end

function o.get()return read()end

function o.set(on)
local ok,err
if spec.relay then
ok,err=pcall(env.peripheral.call,spec.relay,"setOutput",spec.side,on)
else
ok,err=pcall(env.redstone.setOutput,spec.side,on)
end
if not ok then return{requested=on,confirmed=false,error=tostring(err)}end
return{requested=on,confirmed=(read()==on)}
end

return o
end

return M
