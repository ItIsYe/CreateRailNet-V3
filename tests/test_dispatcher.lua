--[[ Purpose: Dispatcher logic tests. Public API: returns table of tests. ]]
local dispatcher = require("src.master.dispatcher")
local function build(fail_signal, fail_switch)
  local cfg={blocks={{id="B1",entry_signal="SIG-1",exit_signal="SIG-2",sensors={"SEN-1"},switches={{id="SW-1",position="STRAIGHT"}}},{id="B2",entry_signal="SIG-3",exit_signal="SIG-4",sensors={"SEN-2"},switches={}}},routes={{id="R1",from="A",to="B",blocks={"B1"}},{id="R2",from="A",to="B",blocks={"B1","B2"}}}}
  local signals={} ;local adapters={signals={setAspect=function(id,a) if fail_signal and a=="GREEN" then return false,"boom" end signals[id]=a return true end},switches={setPosition=function(id,p) if fail_switch then return false,"swerr" end return true end}}
  return dispatcher.new(cfg,adapters),signals
end
return {
 test_sensor_mapping=function() local d=build(); d.reserve_route("T1","R1"); local ok=d.on_sensor_event_by_sensor("SEN-1","enter"); assert(ok); assert(d.get_block("B1").state==dispatcher.STATES.OCCUPIED) end,
 test_unknown_sensor=function() local d=build(); local ok,err=d.on_sensor_event_by_sensor("SEN-X","enter"); assert(not ok and err:find("unknown sensor")) end,
 test_switch_failure_rollback=function() local d=build(false,true); local ok=d.reserve_route("T1","R1"); assert(not ok); assert(d.get_block("B1").state==dispatcher.STATES.FREE) end,
 test_signal_failure_rollback=function() local d=build(true,false); local ok=d.reserve_route("T1","R1"); assert(not ok); assert(d.get_block("B1").state==dispatcher.STATES.FREE) end,
 test_only_first_signal_green=function() local d,s=build(); local ok=d.reserve_route("T1","R2"); assert(ok); assert(s["SIG-1"]=="GREEN"); assert(s["SIG-3"]=="RED") end
}
