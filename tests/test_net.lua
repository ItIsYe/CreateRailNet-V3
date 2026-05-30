--[[ Purpose: Network reliability tests. Public API: returns table of tests. ]]
local net = require("src.shared.net")
local log = require("src.shared.log")
local mock_modem = require("tests.harness.mock_modem")

local function clock(start)
  local c = { now = start or 0 }
  function c.now_ms() return c.now end
  return c
end

return {
 test_dst_filtering=function() local c=clock(); local m=mock_modem.new(); local b=net.new(m,1,"B",log.new("INFO",10),{now_ms=function() return c.now end}); assert(b.receive({v=1,id="1",src="A",dst="C",type="cmd",payload={}})=="not_for_me") end,
 test_ack_removes_pending=function() local c=clock(); local m=mock_modem.new(); local a=net.new(m,1,"A",log.new("INFO",10),{now_ms=function() return c.now end}); local msg=a.send_reliable("cmd","B",{}); assert(a.pending[msg.id]); a.receive({v=1,id="2",src="B",dst="A",type="ack",payload={ack_id=msg.id}}); assert(not a.pending[msg.id]) end,
 test_retry_after_time=function() local c=clock(); local m=mock_modem.new(); local sent=0; m.attach("B",function() sent=sent+1 end); local a=net.new(m,1,"A",log.new("INFO",10),{now_ms=function() return c.now end}); a.send_reliable("cmd","B",{}); assert(sent==1); a.tick(); assert(sent==1); c.now=300; a.tick(); assert(sent==2) end,
 test_max_retries_drop_pending=function() local c=clock(); local m=mock_modem.new(); local a=net.new(m,1,"A",log.new("INFO",10),{now_ms=function() return c.now end}); local msg=a.send_reliable("cmd","B",{}); for i=1,10 do c.now=c.now+10000; a.tick() end; assert(not a.pending[msg.id]) end
}
