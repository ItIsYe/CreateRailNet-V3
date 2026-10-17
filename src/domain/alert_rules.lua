--[[
Purpose: Turns the current problems of the network into alerts and closes them when the cause is gone.
Public API: new(alerts) -> rules with evaluate(inputs) -> number of problems; inputs as for status_model.build.
Notes: one pass over nodes and blocks per evaluation. Keys are "<kind>:<id>" (node:SIG-1, block:B4, ota:TRAIN-2, recovery:recovery), so
  a node that keeps flapping is one entry with a counter, and the status lamp and the message list always agree.
]]

local status_model = require("src.domain.status_model")

local alert_rules = {}

function alert_rules.new(alerts)
  local self = {}
  local raised = {}

  function self.evaluate(inputs)
    local model = status_model.build(inputs)
    local now_set = {}
    for _, problem in ipairs(model.problems) do
      local key = problem.kind .. ":" .. tostring(problem.id)
      now_set[key] = true
      alerts.raise(key, problem.severity, problem.text, { kind = problem.kind, id = problem.id })
    end
    for key in pairs(raised) do
      if not now_set[key] then alerts.clear(key) end
    end
    raised = now_set
    return #model.problems
  end

  return self
end

return alert_rules
