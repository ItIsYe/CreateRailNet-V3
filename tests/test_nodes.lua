--[[ Purpose: Node runtime tests. Public API: returns table of tests. ]]
local common_node=require("src.nodes.common_node")
local sensor_node=require("src.nodes.sensor_node")
return {
 test_common_node_cmd_ack=function()
  local sent={} local modem={open=function() end,send=function(_,_,_,m) table.insert(sent,m); return true end,broadcast=function(_,_,m) table.insert(sent,m); return true end}
  local n=common_node.new({id="N1",role="signal",config={channel=1,master_id="M"},modem=modem,handlers={on_cmd=function() return true end}})
  n.handle_message({v=1,id="m1",src="M",dst="N1",type="cmd",payload={}})
  assert(#sent==1 and sent[1].type=="ack")
 end,
 test_sensor_check_emits_event=function()
  local sent={} local node={net={send=function(_,t,d,p) table.insert(sent,p) end}}
  local adapter={readOccupied=function() return true,true end}
  local check=sensor_node.build_check_fn(node,adapter,"SEN-1","MASTER-1"); check(); assert(sent[1].sensor_id=="SEN-1" and sent[1].action=="enter")
 end
}
