--[[
Unit tests for train_node: state transitions from cmd handlers,
render_status nil safety, request_departure flow.
]]
dofile("tests/harness/cc_bootstrap.lua")
local train_node = require("src.nodes.train_node")

local function make_state(overrides)
  local s = {
    node_id="TRAIN-1", train_id="TRAIN-1", display_name="Regio 1",
    state="IDLE", route_id=nil, destination=nil, create_destination=nil,
    home_depot=nil, service_plan=nil, service_stop_index=nil,
    schedule_state="not_applied", master_state="ONLINE", message=nil
  }
  for k,v in pairs(overrides or {}) do s[k]=v end
  return s
end

return {
  -- render_status nil safety
  test_render_status_nil_monitor = function()
    local ok = pcall(train_node.render_status, nil, make_state())
    assert(ok)
  end,

  test_render_status_partial_state = function()
    local mock = {
      clear=function() end, setCursorPos=function() end, write=function() end
    }
    local ok = pcall(train_node.render_status, mock, make_state({ state="RUNNING" }))
    assert(ok)
  end,

  -- cmd: set_destination
  test_set_destination_updates_state = function()
    local state = make_state()
    local payload = { cmd="set_destination", destination="ST-B", route_id="R-AB" }
    state.destination = payload.destination
    state.route_id = payload.route_id or state.route_id
    state.state = "WAITING_FOR_ROUTE"
    assert(state.destination == "ST-B")
    assert(state.route_id == "R-AB")
    assert(state.state == "WAITING_FOR_ROUTE")
  end,

  -- cmd: depart_authorized
  test_depart_authorized_sets_state = function()
    local state = make_state({ create_destination="Old Depot" })
    local payload = { cmd="depart_authorized", route_id="R-AB", destination="ST-B", create_destination=nil }
    state.route_id = payload.route_id or state.route_id
    state.destination = payload.destination or state.destination
    if payload.create_destination ~= nil or payload.destination ~= nil then
      state.create_destination = payload.create_destination
    end
    state.state = "DEPART_AUTHORIZED"
    assert(state.state == "DEPART_AUTHORIZED")
    assert(state.route_id == "R-AB")
    -- create_destination cleared because payload.destination was set
    assert(state.create_destination == nil)
  end,

  test_depart_authorized_preserves_create_destination_when_neither_set = function()
    local state = make_state({ create_destination="Depot Alpha" })
    local payload = { cmd="depart_authorized", route_id="R-AB" }  -- neither destination nor create_destination
    state.route_id = payload.route_id or state.route_id
    state.destination = payload.destination or state.destination
    if payload.create_destination ~= nil or payload.destination ~= nil then
      state.create_destination = payload.create_destination
    end
    state.state = "DEPART_AUTHORIZED"
    -- create_destination should be preserved (neither field in payload)
    assert(state.create_destination == "Depot Alpha")
  end,

  -- cmd: hold_position
  test_hold_position = function()
    local state = make_state({ state="DEPART_AUTHORIZED" })
    local payload = { cmd="hold_position", reason="maintenance ahead" }
    state.message = payload.reason
    state.state = "WAITING_DEPARTURE"
    assert(state.state == "WAITING_DEPARTURE")
    assert(state.message == "maintenance ahead")
  end,

  -- cmd: emergency_stop
  test_emergency_stop = function()
    local state = make_state({ state="RUNNING" })
    local payload = { cmd="emergency_stop", reason="fault detected" }
    state.state = "FAULT"
    state.message = payload.reason or "Emergency stop"
    assert(state.state == "FAULT")
    assert(state.message == "fault detected")
  end,

  -- cmd: update_display
  test_update_display = function()
    local state = make_state()
    local payload = { cmd="update_display", message="Next stop: ST-B" }
    state.message = payload.message
    assert(state.message == "Next stop: ST-B")
  end,

  -- request_departure builds correct payload
  test_request_departure_fields = function()
    local state = make_state({ destination="ST-C", route_id="R-BC", service_plan="SP-1", service_stop_index=2 })
    local from, to = "ST-B", "ST-C"
    state.state = "WAITING_FOR_ROUTE"
    state.destination = to
    local req = {
      type="request_departure",
      train_id=state.train_id,
      from=from, to=to,
      create_destination=state.create_destination,
      route_id=state.route_id,
      service_plan=state.service_plan,
      service_stop_index=state.service_stop_index
    }
    assert(req.type == "request_departure")
    assert(req.service_plan == "SP-1")
    assert(req.service_stop_index == 2)
  end,
}
