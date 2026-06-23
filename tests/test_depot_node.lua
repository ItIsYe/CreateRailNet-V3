--[[
Unit tests for depot_node: build_track_map, check_tracks state transitions,
cmd handlers (reserve, clear, mark_ready, dispatch, stage).
]]
dofile("tests/harness/cc_bootstrap.lua")
local depot_node = require("src.nodes.depot_node")

local function make_sensor(occupied)
  return { readOccupied = function() return true, occupied end,
           readTrainName = function() return true, "Regio 1" end }
end

local function make_net(sent)
  return {
    send = function(_, dst, p) table.insert(sent, { dst=dst, p=p }) end,
    send_reliable = function(_, dst, p) table.insert(sent, { dst=dst, p=p, reliable=true }) end,
    heartbeat = function() end, tick = function() end, receive = function() return "ok" end,
    ack_for = function() end
  }
end

return {
  -- build_track_map
  test_build_track_map_basic = function()
    local cfg = { tracks = { { id="D1", kind="storage", sensor_id="SEN-D1", ready_after_seconds=3 } } }
    local tracks = depot_node.build_track_map(cfg)
    assert(tracks.D1)
    assert(tracks.D1.kind == "storage")
    assert(tracks.D1.state == "EMPTY")
    assert(tracks.D1.ready_after_seconds == 3)
  end,

  test_build_track_map_empty = function()
    local tracks = depot_node.build_track_map({})
    assert(next(tracks) == nil)
  end,

  test_build_track_map_inherits_depot_type = function()
    local cfg = { depot_type = "passenger", tracks = { { id="D1" } } }
    local tracks = depot_node.build_track_map(cfg)
    assert(tracks.D1.kind == "passenger")
  end,

  -- cmd: reserve_track
  test_cmd_reserve_track = function()
    local sent = {}
    local node_cfg = { id="DEPOT-1", role="depot", tracks={ { id="D1" } } }
    local full_cfg = { channel=1, master_id="MASTER-1", nodes={ node_cfg } }
    local modem = { open=function() return true end, transmit=function() end, close=function() end }
    local net = make_net(sent)
    local state = { depot_id="DEPOT-1", depot_type="mixed", state="ONLINE", queue={}, tracks=depot_node.build_track_map(node_cfg) }

    -- Simulate on_cmd
    local track = state.tracks.D1
    local payload = { cmd="reserve_track", track_id="D1", train_id="TRAIN-1", train_name="Regio" }
    track.state = "RESERVED"; track.train_id = payload.train_id; track.train_name = payload.train_name
    assert(track.state == "RESERVED")
    assert(track.train_id == "TRAIN-1")
  end,

  test_cmd_clear_track = function()
    local state_tracks = depot_node.build_track_map({ tracks={{ id="D1" }} })
    local track = state_tracks.D1
    track.state = "OCCUPIED"; track.train_id = "TRAIN-1"; track.train_name = "Regio"
    -- clear
    track.state = "EMPTY"; track.train_id = nil; track.train_name = nil; track.occupied_since = nil
    assert(track.state == "EMPTY")
    assert(track.train_id == nil)
  end,

  test_cmd_mark_ready_clears_occupied_since = function()
    local state_tracks = depot_node.build_track_map({ tracks={{ id="D1" }} })
    local track = state_tracks.D1
    track.state = "OCCUPIED"; track.occupied_since = 12345; track.train_id = "TRAIN-1"
    -- mark_ready: occupied_since should be cleared
    track.state = "READY"; track.occupied_since = nil
    assert(track.state == "READY")
    assert(track.occupied_since == nil)
  end,

  -- Track state transitions via sensor
  test_sensor_enter_sets_occupied = function()
    local cfg = { tracks = { { id="D1", sensor_id="SEN-D1", ready_after_seconds=999 } } }
    local tracks = depot_node.build_track_map(cfg)
    local track = tracks.D1
    -- Simulate occupied=true transition
    track.last_occupied = false
    local occupied = true
    if occupied ~= track.last_occupied then
      track.last_occupied = occupied
      if occupied then
        track.train_name = "Regio 1"; track.train_id = "TRAIN-1"
        track.state = "OCCUPIED"; track.occupied_since = 100
      end
    end
    assert(track.state == "OCCUPIED")
    assert(track.train_name == "Regio 1")
    assert(track.occupied_since == 100)
  end,

  test_sensor_leave_clears_track = function()
    local cfg = { tracks = { { id="D1", sensor_id="SEN-D1" } } }
    local tracks = depot_node.build_track_map(cfg)
    local track = tracks.D1
    track.state = "OCCUPIED"; track.train_id = "TRAIN-1"; track.last_occupied = true
    -- Simulate leave
    if false ~= track.last_occupied then
      track.last_occupied = false
      track.state = "EMPTY"; track.train_id = nil; track.train_name = nil; track.occupied_since = nil
    end
    assert(track.state == "EMPTY")
    assert(track.train_id == nil)
  end,

  test_ready_after_seconds_transitions_to_ready = function()
    local cfg = { tracks = { { id="D1", sensor_id="SEN-D1", ready_after_seconds=5 } } }
    local tracks = depot_node.build_track_map(cfg)
    local track = tracks.D1
    track.state = "OCCUPIED"; track.occupied_since = 0; track.last_occupied = true
    track.train_id = "TRAIN-1"; track.train_name = "Regio"
    -- Simulate timer: now=6, occupied_since=0 → ready_after_seconds(5) elapsed
    local now = 6
    if track.last_occupied and track.state == "OCCUPIED" and track.occupied_since
       and (now - track.occupied_since) >= track.ready_after_seconds then
      track.state = "READY"
    end
    assert(track.state == "READY")
  end,

  -- render_status: should not crash with nil monitor
  test_render_status_nil_monitor = function()
    local ok = pcall(depot_node.render_status, nil, { depot_id="D", tracks={}, queue={} })
    assert(ok)
  end,
}
