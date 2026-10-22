--[[
Purpose: Gets the topology of the master to a panel, part by part while the panel goes on running, so that it can draw the track diagram (Gesamtkonzept Kap. 11.3, 13).
Public API: new({ network, master_id, panel_id, now, fs, path ("state/panel_topology.json"), wait_s (5), build (function(cfg) -> graph, default src/domain/safety_graph.build) }) -> sync.
  sync.announce(version)        the master says which topology version it runs; a different one starts a transfer
  sync.tick()                   asks for the next part (again after wait_s without an answer)
  sync.on_part(payload)         the cmd plan_part of the master
  sync.previous_graph() -> the graph before (or nil)    sync.graph() -> graph | nil   the graph built from the plan, only when its version is the one the master announced
  sync.state() -> "NONE" | "WAITING" | "READY" | "MISMATCH" | "FAILED", reason
  sync.load() -> state          reads the copy of the last good transfer from disk (a restart of the panel does not wait for the master)
Notes: the plan comes in the parts of src/master/plan_service.lua (event plan_get, answer cmd plan_part), checked for size and Adler-32 before anything is used. The graph that the panel builds from it has to carry the
  topology version the master announced; a plan file on the master that is newer than the running master gives MISMATCH and is not drawn (the panel draws only what the master runs). Nothing is ever sent to the master but the request.
  Old data on disk is only used when its version equals the announced one. Everything that arrives is data: wrong sizes, wrong order or a wrong question id are ignored.
]]

local storage_budget = require("src.shared.storage_budget")
local checksum = require("src.shared.checksum")
local json = require("src.shared.json")
local safe_write = require("src.shared.safe_write")
local safety_graph = require("src.domain.safety_graph")

local topology_sync = {}

local MAX_PARTS, MAX_BYTES = 60, storage_budget.PLAN_MAX_BYTES

function topology_sync.new(opts)
  local now = opts.now or function() return 0 end
  local path = opts.path or "state/panel_topology.json"
  local io_opts = { fs = opts.fs }
  local wait_s = opts.wait_s or 5
  local build = opts.build or function(cfg) return safety_graph.build(cfg) end
  local self = {}
  local announced, current_graph, current_state, reason = nil, nil, "NONE", nil
  local previous_graph    -- the graph that was drawn before the one now (for carrying a layout over)
  local transfer      -- { index, total, version, size, pieces, asked_at, question }

  local function finish(text)
    local ok, cfg = pcall(json.decode, text)
    if not ok or type(cfg) ~= "table" then current_state, reason = "FAILED", "the plan is not readable"; return false end
    local built_ok, graph = pcall(build, cfg)
    if not built_ok or type(graph) ~= "table" then current_state, reason = "FAILED", "the topology cannot be built"; return false end
    if announced and graph.version ~= announced then
      current_graph, current_state, reason = nil, "MISMATCH", "the plan on the master is not the topology it runs"
      return false
    end
    if current_graph and current_graph.version ~= graph.version then previous_graph = current_graph end
    current_graph, current_state, reason = graph, "READY", nil
    safe_write.write(path, json.encode({ v = 1, version = graph.version, plan = text }), io_opts)
    return true
  end

  function self.load()
    local body = safe_write.read_with_backup(path, io_opts)
    if not body then return current_state end
    local ok, decoded = pcall(json.decode, body)
    if ok and type(decoded) == "table" and type(decoded.plan) == "string" then
      local cfg_ok, cfg = pcall(json.decode, decoded.plan)
      if cfg_ok and type(cfg) == "table" then
        local built_ok, graph = pcall(build, cfg)
        if built_ok and type(graph) == "table" and (announced == nil or graph.version == announced) then
          current_graph, current_state = graph, "READY"
        end
      end
    end
    return current_state
  end

  function self.announce(version)
    if type(version) ~= "string" or version == "" then return end
    announced = version
    if current_graph and current_graph.version == version then return end
    if current_state == "WAITING" then return end
    -- a copy on disk may already be the right one
    if current_state == "NONE" then self.load() end
    if current_graph and current_graph.version == version then return end
    if current_graph then previous_graph = current_graph end
    current_graph, current_state = nil, "WAITING"
    transfer = { index = 1 }
  end

  local function ask()
    local msg = opts.network.send_reliable("event", opts.master_id, { type = "plan_get", role = "panel", index = transfer.index, version = transfer.version })
    transfer.asked_at = now()
    transfer.question = msg and msg.id or nil
  end

  function self.tick()
    if current_state ~= "WAITING" or not transfer then return end
    if transfer.asked_at == nil or now() - transfer.asked_at >= wait_s then ask() end
  end

  function self.on_part(payload)
    if current_state ~= "WAITING" or not transfer or type(payload) ~= "table" then return false end
    if transfer.question == nil or payload.question ~= transfer.question then return false end
    if payload.ok ~= true then
      if payload.state == "changed" then transfer = { index = 1 }; return false end
      current_state, reason, transfer = "FAILED", tostring(payload.reason or payload.state or "refused"):sub(1, 120), nil
      return false
    end
    if payload.index ~= transfer.index or type(payload.data) ~= "string" or #payload.data == 0 or type(payload.version) ~= "string"
        or type(payload.total) ~= "number" or payload.total < 1 or payload.total > MAX_PARTS or type(payload.size) ~= "number" or payload.size < 1 or payload.size > MAX_BYTES then
      return false
    end
    if payload.index == 1 then
      transfer.version, transfer.total, transfer.size, transfer.pieces = payload.version, payload.total, payload.size, {}
    elseif payload.version ~= transfer.version or payload.total ~= transfer.total or payload.size ~= transfer.size then
      transfer = { index = 1 }
      return false
    end
    transfer.pieces[payload.index] = payload.data
    if payload.index < transfer.total then
      transfer.index = payload.index + 1
      ask()
      return true
    end
    local text = table.concat(transfer.pieces)
    transfer = nil
    if #text ~= payload.size or checksum.hex(checksum.adler32(text)) ~= payload.version then
      current_state, reason = "FAILED", "the plan arrived damaged"
      return false
    end
    return finish(text)
  end

  function self.graph() return current_graph end
  function self.previous_graph() return previous_graph end
  function self.state() return current_state, reason end
  return self
end

return topology_sync
