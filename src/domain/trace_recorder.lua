--[[
Purpose: Records what the dispatcher was asked to do, in the game, so the same run can be replayed offline.
Public API:
  new(opts) -> recorder        opts: capacity (500), now_ms()
  recorder.attach(dispatcher) -> dispatcher      wraps the dispatcher in place; records the start state (snapshot) once
  recorder.record(kind, data) / recorder.entries() / recorder.size() / recorder.clear()
  recorder.to_table() -> { version, entries }    recorder.dump(path, opts) -> ok, err      (safe_write; opts.fs for tests)
  recorder.dump_slot(prefix, slots, opts) -> path | nil, err    rotating files <prefix>1.json .. <prefix>N.json, oldest overwritten
  decode(text) -> trace | nil, err       load(path, opts) -> trace | nil, err
  entry = { t = ms on the recorder's clock, op = name, a = { arguments }, r = { result, info } }
Notes: only calls from outside are recorded (a request that reserves internally is one entry, not two), arguments and results are
  plain values, the buffer is a ring of `capacity` entries so the master's memory stays bounded. tests/harness/trace_replay.lua plays a
  trace against a fresh dispatcher and checks the safety invariants after every step; scripts/replay_trace.lua does it for a file.
]]

local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")
local time = require("src.shared.time")

local trace_recorder = {}

local TRACE_VERSION = 1

-- name -> names of the positional arguments that matter for a replay
local OPS = {
  request_route = { "train_id", "route_id", "priority" },
  reserve_route = { "train_id", "route_id" },
  process_queue = { "limit" },
  on_sensor_event_by_sensor = { "sensor_id", "action", "ts" },
  on_sensor_event = { "block_id", "action", "sensor_id", "ts" },
  timeout_node = { "node_id" },
  release_route = { "train_id", "route_id" },
  clear_fault = { "block_id" },
  restore = { "snapshot" }
}

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for k, v in pairs(value) do copy[k] = deep_copy(v) end
  return copy
end

local function plain(value)
  local kind = type(value)
  if kind == "string" then return value:sub(1, 80) end
  if kind == "number" or kind == "boolean" then return value end
  return nil
end

function trace_recorder.new(opts)
  local options = opts or {}
  local capacity = options.capacity or 500
  local now_ms = options.now_ms or time.now_ms
  local self = {}
  local entries = {}
  local start_state = nil

  function self.record(kind, data)
    local entry = { t = now_ms(), op = kind }
    for k, v in pairs(data or {}) do entry[k] = v end
    entries[#entries + 1] = entry
    if #entries > capacity then table.remove(entries, 1) end
    return entry
  end

  function self.attach(dispatcher)
    if dispatcher.snapshot then
      local ok, snapshot = pcall(dispatcher.snapshot)
      if ok then start_state = snapshot end
    end
    local depth = 0
    for name, arg_names in pairs(OPS) do
      local original = dispatcher[name]
      if original then
        dispatcher[name] = function(...)
          local top = depth == 0
          depth = depth + 1
          local ok, r1, r2, r3, r4 = pcall(original, ...)
          depth = depth - 1
          if top then
            local args = {}
            for i, arg_name in ipairs(arg_names) do
              local value = select(i, ...)
              if value ~= nil then
                if arg_name == "snapshot" then
                  args[arg_name] = deep_copy(value)
                else
                  if type(value) == "table" and arg_name == "priority" then value = nil end
                  args[arg_name] = plain(value)
                end
              end
            end
            local entry = self.record(name, { a = args })
            if ok then entry.r = { plain(r1), plain(r2) } else entry.r = { "error", plain(tostring(r1)) } end
          end
          if not ok then error(r1, 0) end
          return r1, r2, r3, r4
        end
      end
    end
    return dispatcher
  end

  function self.entries()
    local copy = {}
    for i, e in ipairs(entries) do copy[i] = e end
    return copy
  end

  function self.size() return #entries end

  function self.clear() entries = {} end

  function self.to_table()
    local snapshot = start_state
    -- the snapshot belongs to the first recorded call only while nothing has rolled out of the ring
    return { version = TRACE_VERSION, start = snapshot, entries = self.entries() }
  end

  function self.dump(path, dump_opts)
    local ok_encode, body = pcall(json.encode, self.to_table())
    if not ok_encode then return false, tostring(body) end
    return safe_write.write(path, body, { fs = dump_opts and dump_opts.fs, keep_backup = false })
  end

  local next_slot = 0
  function self.dump_slot(prefix, slots, dump_opts)
    next_slot = (next_slot % (slots or 5)) + 1
    local path = prefix .. next_slot .. ".json"
    local ok, err = self.dump(path, dump_opts)
    if not ok then return nil, err end
    return path
  end

  return self
end

function trace_recorder.decode(text)
  local ok, decoded = pcall(json.decode, text)
  if not ok then return nil, tostring(decoded) end
  if type(decoded) ~= "table" or decoded.version ~= TRACE_VERSION or type(decoded.entries) ~= "table" then return nil, "not a CreateRailNet trace" end
  return decoded
end

function trace_recorder.load(path, opts)
  local body, err = safe_write.read(path, { fs = opts and opts.fs })
  if not body then return nil, err end
  return trace_recorder.decode(body)
end

trace_recorder.OPS = OPS

return trace_recorder
