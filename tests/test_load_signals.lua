--[[
Purpose: A network with 300 and 400 signals: every signal command reaches the node that hosts that signal, many independent trains run at once without a double reservation, the work per change stays small (deltas, not snapshots), and the track diagram keeps every state with its own object (Pruefplan J-01, J-02, J-03, J-05, H-13).
  This is the offline part: counts and sizes, not times. The load on a real server (TPS, queue lengths, UI latency) is measured in the game (docs/INGAME_TESTS.md).
Public API: returns table of tests.
]]

local dispatcher = require("src.master.dispatcher")
local net_signals = require("src.master.net_signals")
local safety_graph = require("src.domain.safety_graph")
local state_delta = require("src.domain.state_delta")
local diagram = require("src.panel.diagram")
local json = require("src.shared.json")

local quiet = { info = function() end, warn = function() end, error = function() end, debug = function() end }

-- `blocks` blocks of two signals each (entry and exit), chains of CHAIN blocks as routes, signals spread over nodes of 8
local CHAIN = 5
local function network(blocks)
  local cfg = { signal_transport = "network", nodes = {}, blocks = {}, routes = {} }
  local names = {}
  for i = 1, blocks do
    local entry, exit = "SE" .. i, "SX" .. i
    cfg.blocks[i] = { id = "B" .. i, entry_signal = entry, exit_signal = exit, sensors = { "SEN-" .. i } }
    names[#names + 1] = entry
    names[#names + 1] = exit
  end
  local per_node = 8
  for first = 1, #names, per_node do
    local list = {}
    for index = first, math.min(first + per_node - 1, #names) do list[#list + 1] = names[index] end
    cfg.nodes[#cfg.nodes + 1] = { id = "SIGN-" .. #cfg.nodes + 1, role = "signal", signals = list }
  end
  for first = 1, blocks - CHAIN + 1, CHAIN do
    local ids = {}
    for index = first, first + CHAIN - 1 do ids[#ids + 1] = "B" .. index end
    cfg.routes[#cfg.routes + 1] = { id = "R" .. #cfg.routes + 1, from = "A" .. first, to = "Z" .. first, blocks = ids }
  end
  return cfg, names
end

local function fake_network()
  local n = { sent = {}, seq = 0 }
  function n.send_reliable(msg_type, dst, payload)
    n.seq = n.seq + 1
    local msg = { id = "m" .. n.seq, type = msg_type, dst = dst, payload = payload }
    n.sent[#n.sent + 1] = msg
    return msg
  end
  return n
end

local function run(blocks)
  local cfg, names = network(blocks)
  local net = fake_network()
  local adapter = net_signals.new({ network = net, config = cfg, logger = quiet })
  adapter.install(net)
  local switches = { setPosition = function() return true end, getPosition = function() return true, "STRAIGHT" end }
  local d = dispatcher.new(cfg, { signals = adapter, switches = switches })
  return cfg, names, net, adapter, d
end

local function hosts_of(cfg)
  local host = {}
  for _, node in ipairs(cfg.nodes) do for _, id in ipairs(node.signals) do host[id] = node.id end end
  return host
end

return {
  test_300_signals_each_command_reaches_the_node_that_hosts_that_signal_and_no_other = function()
    local cfg, names, net, adapter = run(150)
    assert(#names == 300)
    local host = hosts_of(cfg)
    for _, id in ipairs(names) do assert(adapter.setAspect(id, "GREEN"), id) end
    assert(#net.sent == 300)
    local seen = {}
    for _, msg in ipairs(net.sent) do
      local id = msg.payload.signal_id
      assert(msg.dst == host[id], id .. " went to " .. msg.dst .. " instead of " .. tostring(host[id]))
      assert(not seen[id], "one command per signal")
      seen[id] = true
    end
  end,

  test_400_signals_stay_apart_when_nodes_answer_in_any_order = function()
    local cfg, names, net, adapter = run(200)
    assert(#names == 400)
    for _, id in ipairs(names) do adapter.setAspect(id, "GREEN") end
    -- the answers come back reversed: every status lands on its own signal
    for index = #net.sent, 1, -1 do
      local msg = net.sent[index]
      if index % 2 == 0 then net.on_ack({ ack_id = msg.id, applied = true }) end
    end
    local applied, pending = 0, 0
    for _, id in ipairs(names) do
      local status = adapter.status(id)
      if status == "APPLIED" then applied = applied + 1 elseif status == "PENDING" then pending = pending + 1 end
    end
    assert(applied + pending == 400 and applied == 200 and pending == 200, applied .. "/" .. pending)
    for index, msg in ipairs(net.sent) do
      local expected = (index % 2 == 0) and "APPLIED" or "PENDING"
      assert(adapter.status(msg.payload.signal_id) == expected, msg.payload.signal_id)
    end
  end,

  test_many_trains_on_independent_routes_run_at_once_without_a_double_reservation = function()
    local cfg, _, net, _, d = run(200)
    local granted = 0
    net.sent = {}
    for index, route in ipairs(cfg.routes) do
      local ok = d.reserve_route("T" .. index, route.id)
      if ok then granted = granted + 1 end
    end
    assert(granted == #cfg.routes and granted == 40, "40 independent routes, " .. granted .. " granted")
    local owner = {}
    for _, block in ipairs(cfg.blocks) do
      local rec = d.get_block(block.id)
      assert(rec.reserved_by ~= nil, block.id .. " belongs to a train")
      owner[block.id] = rec.reserved_by
    end
    for index, route in ipairs(cfg.routes) do
      for _, id in ipairs(route.blocks) do assert(owner[id] == "T" .. index, id .. " belongs to " .. tostring(owner[id])) end
    end
    -- a second train for a route that is taken gets nothing
    assert(not d.reserve_route("LATE", cfg.routes[7].id))
    assert(#net.sent <= 5 * #cfg.blocks, "the work per reservation is bounded: " .. #net.sent .. " commands for " .. #cfg.blocks .. " blocks")
  end,

  test_the_replicated_change_of_one_train_is_small_next_to_the_whole_state = function()
    local cfg, _, _, _, d = run(200)
    for index, route in ipairs(cfg.routes) do d.reserve_route("T" .. index, route.id) end
    local before = d.snapshot({ replicated = true })
    d.release_route("T3")
    local after = d.snapshot({ replicated = true })
    local delta = state_delta.diff(before, after)
    assert(delta, "something changed")
    local whole, small = #json.encode(after), #json.encode(delta)
    assert(small * 10 < whole, "delta " .. small .. " bytes against " .. whole .. " for the whole state")
    assert(state_delta.equal(state_delta.apply(before, delta), after))
  end,

  test_a_large_layout_change_marks_only_the_changed_objects = function()
    local cfg = network(200)
    local old_graph = safety_graph.build(cfg)
    local layout = diagram.propose(old_graph)
    local changed_cfg = network(200)
    for _, id in ipairs({ 10, 11, 12 }) do changed_cfg.blocks[id].sensors = { "SEN-NEW-" .. id } end
    changed_cfg.blocks[201] = { id = "B201", entry_signal = "SE201", exit_signal = "SX201", sensors = { "SEN-201" } }
    local new_graph = safety_graph.build(changed_cfg)
    local carried = diagram.carry_over(layout, old_graph, new_graph)
    assert(#carried.added == 1 and carried.added[1] == "B201", "one new block")
    assert(#carried.removed == 0)
    assert(#carried.changed <= 3, "no complete redraw: " .. #carried.changed .. " objects changed")
    local kept = 0
    for id, object in pairs(layout.objects) do
      local now = carried.layout.objects[id]
      if now and now.x == object.x and now.y == object.y then kept = kept + 1 end
    end
    assert(kept == 200, "the position of every old block is kept, " .. kept)
  end,

  test_the_drawing_model_of_400_signals_keeps_every_state_with_its_own_object = function()
    local cfg, names = network(200)
    local layout = diagram.propose(safety_graph.build(cfg))
    local states = {}
    for index, id in ipairs(names) do states[id] = (index % 3 == 0) and "GREEN" or "RED" end
    local model = diagram.render_model(layout, { blocks = {}, signals = states, now = 0 })
    assert(#model == 200)
    for _, item in ipairs(model) do
      local number = tonumber(item.id:match("%d+"))
      assert(item.signals.entry == states["SE" .. number] and item.signals.exit == states["SX" .. number], item.id .. " shows the state of another signal")
    end
    -- one signal changes: exactly one object shows it
    states.SE78 = "GREEN"
    local again = diagram.render_model(layout, { blocks = {}, signals = states, now = 0 })
    local differing = 0
    for index, item in ipairs(again) do if item.signals.entry ~= model[index].signals.entry or item.signals.exit ~= model[index].signals.exit then differing = differing + 1 end end
    assert(differing == 1, differing .. " objects changed for one signal")
  end
}
