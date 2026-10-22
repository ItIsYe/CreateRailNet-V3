










local time=require("src.shared.time")

local sleep_guard={}

local function default_clock()return time.now_ms()/1000 end

function sleep_guard.sleep(seconds,opts)
opts=opts or{}
local clock=opts.clock or default_clock
local start_timer=opts.start_timer or os.startTimer
local pull_event=opts.pull_event or os.pullEvent
local deadline=clock()+(seconds or 0)
local id=start_timer(seconds or 0)
while true do
local name,param=pull_event()
if name=="timer" and param==id then return "timer" end
if clock()>=deadline then return "deadline" end
end
end

return sleep_guard
