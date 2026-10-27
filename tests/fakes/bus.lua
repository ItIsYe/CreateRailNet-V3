--[[
Purpose: Fake fuer rednet ueber Funk: mehrere Computer an einem Bus, mit einstellbarem Verlust, Verdopplung und Vertauschen der Reihenfolge (festes Zufallsmuster). Nachrichten kommen als Ereignis { "rednet_message", absender, text, protokoll }.
API: bus.new{seed, drop, dup, reorder} -> b; b.attach(cid) -> rednet; b.pop(cid) -> Ereignis oder nil; b.pending(cid)
]]

local M = {}

function M.new(opts)
  opts = opts or {}
  local b = { nodes = {}, sent = 0 }
  local state = (opts.seed or 1) % 2147483647
  if state <= 0 then state = 1 end
  local function rand()
    state = (state * 48271) % 2147483647
    return state / 2147483647
  end

  local function deliver(from, to, text, proto)
    local box = b.nodes[to]
    if not box then return end
    b.sent = b.sent + 1
    if opts.drop and rand() < opts.drop then return end
    local copies = (opts.dup and rand() < opts.dup) and 2 or 1
    for _ = 1, copies do box.queue[#box.queue + 1] = { "rednet_message", from, text, proto } end
  end

  function b.attach(cid)
    local box = { queue = {}, opened = {} }
    b.nodes[cid] = box
    local r = {}
    function r.open(name) box.opened[#box.opened + 1] = name end
    function r.send(to, text, proto) deliver(cid, to, text, proto); return true end
    function r.broadcast(text, proto)
      local ids = {}
      for id in pairs(b.nodes) do if id ~= cid then ids[#ids + 1] = id end end
      table.sort(ids)
      for _, id in ipairs(ids) do deliver(cid, id, text, proto) end
    end
    r._box = box
    return r
  end

  function b.pop(cid)
    local box = b.nodes[cid]
    if #box.queue == 0 then return nil end
    local index = 1
    if opts.reorder then index = math.max(1, math.min(#box.queue, math.floor(rand() * #box.queue) + 1)) end
    return table.remove(box.queue, index)
  end

  function b.pending(cid) return #b.nodes[cid].queue end
  return b
end

return M
