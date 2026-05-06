--[[ Purpose: Config validation tests. Public API: returns table of tests. ]]
local validate=require("src.shared.validate")
local function base() return {v=1,channel=777,master_id="MASTER-1",blocks={{id="B1",entry_signal="SIG-1",exit_signal="SIG-2",sensors={"SEN-1"},switches={{id="SW-1",position="STRAIGHT"}}}},routes={{id="R1",from="A",to="B",blocks={"B1"},priority=1}},nodes={{id="MASTER-1",role="master"},{id="SIG-1",role="signal"},{id="SIG-2",role="signal"},{id="SEN-1",role="sensor"},{id="SW-1",role="switch"}}} end
return {
 test_valid_config=function() local ok,er=validate.validate_config(base()); assert(ok,table.concat(er,",")) end,
 test_duplicate_node_id_fails=function() local c=base(); table.insert(c.nodes,{id="SW-1",role="switch"}); local ok=validate.validate_config(c); assert(not ok) end,
 test_unknown_route_block_fails=function() local c=base(); c.routes[1].blocks={"B9"}; local ok=validate.validate_config(c); assert(not ok) end,
 test_unknown_signal_ref_fails=function() local c=base(); c.blocks[1].entry_signal="SIG-X"; local ok=validate.validate_config(c); assert(not ok) end,
 test_invalid_role_fails=function() local c=base(); c.nodes[1].role="oops"; local ok=validate.validate_config(c); assert(not ok) end
}
