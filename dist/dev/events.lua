





local M = {}

local EVENT_KIND = {
train_imminent = "station",
train_arrival = "station",
train_departure = "station",
train_passing = "observer",
train_passed = "observer",
train_signal_state_change = "signal",
}
M.EVENT_KIND = EVENT_KIND

function M.router(opts)
local r = {}
function r.route(ev)
local kind = EVENT_KIND[ev[1]]
if not kind then return nil end
local out = { type = ev[1], device = ev[2], t = opts.now(), source = "ereignis" }
if kind == "signal" then out.state = ev[3] else out.train = ev[3] end
local binding = opts.bindings[ev[2]]
if not binding then
out.problem = "unbekanntes Geraet"
return out
end
out.id, out.kind = binding.id, binding.kind
if binding.kind ~= kind then out.problem = "Ereignis passt nicht zur Art des Geraets" end
return out
end
return r
end

return M
