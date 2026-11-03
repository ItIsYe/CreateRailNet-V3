




local M = {}

function M.new(env, name)
local o = {}
function o.read()
local state = { name = name }
local ok, passing = pcall(env.peripheral.call, name, "isTrainPassing")
if not ok then
state.available = false
return state
end
state.available = true
state.passing = passing == true
local ok_n, train = pcall(env.peripheral.call, name, "getPassingTrainName")
if ok_n and train ~= nil then state.train = train end
return state
end
return o
end

return M
