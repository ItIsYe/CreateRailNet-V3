







package.path="/?.lua;/?/init.lua;" ..(package.path or "")

local auth_bench=require("src.setup.auth_bench")

local arguments={...}
local result=auth_bench.run({rounds=tonumber(arguments[1])or 200})
for _,line in ipairs(auth_bench.lines(result))do print(line)end
