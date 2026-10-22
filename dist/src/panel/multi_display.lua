










local views=require("src.panel.views")
local pages=require("src.panel.pages")

local multi_display={}

function multi_display.new(opts)
local registry=opts.registry
local now=opts.now or function()return 0 end
local screens={}
local self={}

local function level()return type(opts.level)=="function" and opts.level()or opts.level or "operate" end

local function screen(id,start_view)
local s=screens[id]
if not s then s={view=start_view or "overview",hits={},own={}};screens[id]=s end
return s
end

function self.view_of(id)return screens[id] and screens[id].view or nil end

function self.set_view(id,view)
if not views.VIEWS[view] then return false,"unknown view " .. tostring(view)end
if not pages.allowed(view,level())then return false,"the view " .. view .. " needs a higher level" end
local s=screen(id)
s.view=view
return true
end


local SHARED={train=true,station=true,section=true}
function self.selection_of(id,key)
if registry.group_of(id)and SHARED[key] then return registry.get_selection(id,key)end
return screens[id] and screens[id].own[key] or nil
end

function self.refresh()
local report={drawn={},missing={},errors={}}
local state=opts.model()
local age=state.last_update and state.last_update>0 and(now()- state.last_update)or nil
for _,record in ipairs(registry.list())do
local monitor,start_view=registry.open(record.logical_id)
if not monitor then
report.missing[#report.missing+1]=record.logical_id
else
local s=screen(record.logical_id,start_view)
local view=s.view
if not pages.allowed(view,level())then view="overview";s.view=view end
local ctx={
state=state,level=level(),age_s=age,now=now(),stale_after=opts.stale_after_s,label=record.label,
layout=opts.layout and opts.layout()or nil,faults=opts.faults and opts.faults()or{},op_text=opts.op_text and opts.op_text()or nil,
selection={train=self.selection_of(record.logical_id,"train"),station=self.selection_of(record.logical_id,"station"),section=self.selection_of(record.logical_id,"section"),line=self.selection_of(record.logical_id,"line")},
editor=opts.editor and opts.editor()or nil
}
local ok,hits=pcall(views.render,view,monitor,ctx)
if ok then
s.hits=hits or{}
report.drawn[#report.drawn+1]=record.logical_id
else
report.missing[#report.missing+1]=record.logical_id
report.errors[record.logical_id]=tostring(hits)
s.hits={}
end
end
end
return report
end

local function step_view(id,direction)
local visible=pages.visible(level())
local current=screen(id).view
local index=1
for i,page in ipairs(visible)do if page.id==current then index=i end end
index=index+direction
if index<1 then index=#visible end
if index>#visible then index=1 end
screens[id].view=visible[index].id
return visible[index].id
end

function self.touch(peripheral_name,x,y)
local id
for _,record in ipairs(registry.list())do if record.peripheral==peripheral_name then id=record.logical_id end end
if not id then return nil end
local s=screen(id)
if y<=3 then
local view=step_view(id,x<=10 and -1 or 1)
return{monitor=id,view=view}
end
for _,hit in ipairs(s.hits)do
if hit.y==y and x>=hit.x1 and x<=hit.x2 then
if hit.key=="edit" then return{monitor=id,edit=hit.params}end
if hit.key=="action" then
local action={action=hit.value}
for k,v in pairs(hit.params or{})do action[k]=v end
return{monitor=id,action=action}
end
local group=registry.group_of(id)
if group and SHARED[hit.key] then registry.set_selection(group,hit.key,hit.value)else s.own[hit.key]=hit.value end
return{monitor=id,selected={key=hit.key,value=hit.value}}
end
end
return{monitor=id}
end

return self
end

return multi_display
