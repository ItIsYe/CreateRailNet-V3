






local status_model=require("src.domain.status_model")

local alert_rules={}

function alert_rules.new(alerts)
local self={}
local raised={}

function self.evaluate(inputs)
local model=status_model.build(inputs)
local now_set={}
for _,problem in ipairs(model.problems)do
local key=problem.kind .. ":" .. tostring(problem.id)
now_set[key]=true
alerts.raise(key,problem.severity,problem.text,{kind=problem.kind,id=problem.id})
end
for key in pairs(raised)do
if not now_set[key] then alerts.clear(key)end
end
raised=now_set
return#model.problems
end

return self
end

return alert_rules
