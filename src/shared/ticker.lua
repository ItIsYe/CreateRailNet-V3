--[[
Purpose: Timer guard for event loops. Runs periodic jobs and recovers when a timer event gets lost.
Public API:
  new(opts) -> ticker            opts: start_timer(seconds)->id, clock()->seconds, grace, on_error(name, err)
  ticker.every(name, seconds, fn, grace_seconds) -> job
  ticker.start()                 arms every registered job
  ticker.handle_event(event)     fires the job owning a timer event, then recovers overdue jobs -> consumed
  ticker.poll()                  recovers overdue jobs without an event -> number of recovered jobs
  ticker.stats()                 -> { recovered, errors, jobs = { [name] = counters } }
Notes:
  CC:Tweaked drops every event once 256 are queued, timer events included. A loop that waits for exactly one
  os.startTimer id then hangs forever. A drop needs a full queue, so more events always follow; every call of
  handle_event() compares the job deadlines with the clock and fires jobs whose timer never arrived.
  A job is re-armed before it runs, so a failing job cannot stop its own schedule.
]]

local time = require("src.shared.time")

local ticker = {}

local DEFAULT_GRACE_S = 1.0
local ERROR_LOG_EVERY = 50

local function default_clock() return time.now_ms() / 1000 end
local function default_start_timer(seconds) return os.startTimer(seconds) end

function ticker.new(opts)
  opts = opts or {}
  local clock = opts.clock or default_clock
  local start_timer = opts.start_timer or default_start_timer
  local default_grace = opts.grace or DEFAULT_GRACE_S
  local on_error = opts.on_error

  local self = { started = false }
  local jobs = {}

  local function arm(job)
    job.due = clock() + job.period
    job.timer = start_timer(job.period)
  end

  local function report_error(job, err)
    job.errors = job.errors + 1
    local text = tostring(err)
    local changed = text ~= job.last_error
    job.last_error = text
    -- same failure every 0.2 s must not flood the log
    if on_error and (changed or job.errors % ERROR_LOG_EVERY == 0) then pcall(on_error, job.name, text, job.errors) end
  end

  local function fire(job, recovered)
    if recovered then
      job.recovered = job.recovered + 1
      local late = clock() - job.due
      if late > job.max_late then job.max_late = late end
    end
    arm(job)
    job.fired = job.fired + 1
    local ok, err = pcall(job.fn)
    if not ok then report_error(job, err) end
  end

  function self.every(name, seconds, fn, grace_seconds)
    local job = {
      name = name, period = seconds, fn = fn, grace = grace_seconds or default_grace,
      timer = nil, due = nil,
      fired = 0, recovered = 0, errors = 0, max_late = 0, last_error = nil
    }
    jobs[#jobs + 1] = job
    if self.started then arm(job) end
    return job
  end

  function self.start()
    self.started = true
    for _, job in ipairs(jobs) do arm(job) end
  end

  function self.poll()
    if not self.started then return 0 end
    local now = clock()
    local count = 0
    for _, job in ipairs(jobs) do
      if job.due and now >= job.due + job.grace then
        fire(job, true)
        count = count + 1
      end
    end
    return count
  end

  function self.handle_event(event)
    local consumed = false
    if self.started and event and event[1] == "timer" then
      for _, job in ipairs(jobs) do
        if job.timer ~= nil and job.timer == event[2] then
          fire(job, false)
          consumed = true
          break
        end
      end
    end
    self.poll()
    return consumed
  end

  function self.stats()
    local out = { recovered = 0, errors = 0, jobs = {} }
    for _, job in ipairs(jobs) do
      out.recovered = out.recovered + job.recovered
      out.errors = out.errors + job.errors
      out.jobs[job.name] = {
        period = job.period, fired = job.fired, recovered = job.recovered,
        errors = job.errors, max_late = job.max_late, last_error = job.last_error
      }
    end
    return out
  end

  return self
end

return ticker
