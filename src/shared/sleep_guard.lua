--[[
Purpose: os.sleep replacement that cannot hang when the timer event gets dropped.
Public API:
  sleep(seconds, opts) -> "timer" | "deadline"
    opts: start_timer(seconds)->id, pull_event()->event..., clock()->seconds
Notes:
  os.sleep waits for exactly one timer id. CC:Tweaked drops events while 256 are queued, so a dropped timer
  leaves os.sleep blocked forever. The guard also compares the clock after every event it pulls and returns
  "deadline" once the time is over. Other events are discarded, exactly as os.sleep discards them.
]]

local time = require("src.shared.time")

local sleep_guard = {}

local function default_clock() return time.now_ms() / 1000 end

function sleep_guard.sleep(seconds, opts)
  opts = opts or {}
  local clock = opts.clock or default_clock
  local start_timer = opts.start_timer or os.startTimer
  local pull_event = opts.pull_event or os.pullEvent
  local deadline = clock() + (seconds or 0)
  local id = start_timer(seconds or 0)
  while true do
    local name, param = pull_event()
    if name == "timer" and param == id then return "timer" end
    if clock() >= deadline then return "deadline" end
  end
end

return sleep_guard
