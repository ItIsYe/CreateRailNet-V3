





local ui_utils=require("src.master.ui.ui_utils")
local time=require("src.shared.time")

local logs_panel={}

function logs_panel.new(collector)
local panel={page=1,level="WARN"}
local C=ui_utils.colors
local width,height=51,19
local more_pages=false

local function per_page()return math.max(1,height - 3)end

local function age_text(seconds)
if seconds<90 then return string.format("%3ds",seconds)end
if seconds<5400 then return string.format("%3dm",math.floor(seconds/60))end
return string.format("%3dh",math.floor(seconds/3600))
end

function panel.draw(monitor)
if not monitor then return end
local u=ui_utils.new(monitor)
local w,h=u.size()
width,height=w,h
u.clear(C.black)
local stats=collector and collector.stats()or{total=0,nodes=0,dropped_by_nodes=0}
u.header(1,"NETZ-LOG",string.format("%d Zeilen  %d Nodes",stats.total,stats.nodes),w)

local entries=collector and collector.recent({min_level=panel.level,limit=per_page()+1,offset=(panel.page - 1)*per_page()})or{}
more_pages=#entries>per_page()
if#entries==0 then u.write_at(2,3,"Keine Eintraege.",C.lime)end
local now=time.now_s()
for i=1,math.min(#entries,per_page())do
local e=entries[i]
local color=e.lvl=="ERROR" and C.red or C.yellow
local text=string.format("%s %-10s %s%s",age_text(math.max(0,now - e.ts)),e.node:sub(1,10),e.msg,e.n>1 and(" x" .. e.n)or "")
u.write_at(1,2+i,text:sub(1,w),color)
end
u.footer(h,string.format("[%s]   <  Seite %d  >",panel.level=="ERROR" and "ERROR" or "WARN+",panel.page),w)
end

function panel.touch(x,y)
if y~=height then return end
if x<=10 then
panel.level=panel.level=="WARN" and "ERROR" or "WARN"
panel.page=1
elseif x<=math.floor((width+10)/2)then
panel.page=math.max(1,panel.page - 1)
elseif more_pages then
panel.page=panel.page+1
end
end

return panel
end

return logs_panel
