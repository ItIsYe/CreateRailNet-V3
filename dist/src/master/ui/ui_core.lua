









local window_buffer=require("src.shared.window_buffer")
local once_log=require("src.shared.once_log")

local ui_core={}

ui_core.PAGE_ORDER={"status","alerts","setup","overview","gleisbild","trains","stations","depots","fahrplan","cargo","diag","logs","ota"}

function ui_core.new(monitor,panels,opts)
local options=opts or{}
local ui={
monitor=monitor,
panels=panels or{},
current=nil,
dirty=true,
page_order={},
last_error=nil
}
local buffer=window_buffer.new(monitor,{window=options.window})
local once=once_log.new(options.logger,{now_ms=options.now_ms,repeat_ms=options.repeat_ms})

local function rebuild_order()
ui.page_order={}
local listed={}
for _,name in ipairs(ui_core.PAGE_ORDER)do
if ui.panels[name] then ui.page_order[#ui.page_order+1]=name;listed[name]=true end
end
local extra={}
for name in pairs(ui.panels)do if not listed[name] then extra[#extra+1]=name end end
table.sort(extra)
for _,name in ipairs(extra)do ui.page_order[#ui.page_order+1]=name end
end

function ui.set_panel(name)
ui.current=name
ui.dirty=true
end

local function step(delta)
if#ui.page_order==0 then rebuild_order()end
local count=#ui.page_order
if count==0 then return end
for i,name in ipairs(ui.page_order)do
if name==ui.current then
ui.set_panel(ui.page_order[((i - 1+delta)%count)+1])
return
end
end
ui.set_panel(ui.page_order[delta>0 and 1 or count])
end

function ui.next_panel()step(1)end
function ui.prev_panel()step(-1)end

function ui.mark_dirty()
ui.dirty=true
end

local function draw_error_page(target,name,err)
pcall(function()
if target.clear then target.clear()end
if target.setCursorPos and target.write then
target.setCursorPos(1,1);target.write("Seite " .. tostring(name).. ": Anzeigefehler")
target.setCursorPos(1,3);target.write(tostring(err):sub(1,200))
target.setCursorPos(1,5);target.write("Mit den Seitenraendern zu anderen Seiten wechseln.")
end
end)
end

local function draw_indicator(target)
if not(target.getSize and target.setCursorPos and target.write)then return end
local w=target.getSize()
local idx=0
for i,name in ipairs(ui.page_order)do
if name==ui.current then idx=i;break end
end
local nav=string.format("<%d/%d>",idx,#ui.page_order)
pcall(function()
target.setCursorPos(math.max(1,w -#nav),1)
target.write(nav)
end)
end

function ui.draw()
if not ui.dirty or not ui.current then return end
if#ui.page_order==0 then rebuild_order()end
local panel=ui.panels[ui.current]
local target=buffer.begin()
local ok,err=true,nil
if panel and panel.draw then ok,err=pcall(panel.draw,target)end
local key="panel:" .. tostring(ui.current)
if ok then
once.ok(key,"panel " .. tostring(ui.current).. " draws again")
ui.last_error=nil
else
ui.last_error={panel=ui.current,error=tostring(err)}
once.error(key,"panel draw failed",{panel=ui.current,error=tostring(err)})
draw_error_page(target,ui.current,err)
end
draw_indicator(target)
buffer.finish()
ui.dirty=false
end

function ui.handle_touch(x,y)
local w=51
if ui.monitor and ui.monitor.getSize then w=ui.monitor.getSize()end


if x<=2 then
ui.prev_panel()
return
elseif x>=w - 1 then
ui.next_panel()
return
end

local panel=ui.panels[ui.current]
if panel and panel.touch then
local ok,err=pcall(panel.touch,x,y)
if not ok then once.error("touch:" .. tostring(ui.current),"panel touch failed",{panel=ui.current,error=tostring(err)})end
ui.dirty=true
end
end

rebuild_order()

ui.rebuild_order=rebuild_order
return ui
end

return ui_core
