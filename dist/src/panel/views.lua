










local renderer=require("src.nodes.panel_renderer")
local pages=require("src.panel.pages")
local diagram=require("src.panel.diagram")
local permissions=require("src.panel.permissions")

local views={}

views.VIEWS={overview=true,gleisbild=true,trains=true,train_detail=true,trip_assistant=true,stations=true,depots=true,timetable=true,cargo=true,fault_center=true,nodes=true,maintenance=true,audit=true}

local DELEGATE={overview="overview",trains="trains",stations="stations",depots="depots",nodes="diagnostics",audit="audit"}

local function size(monitor)
if monitor and monitor.getSize then
local ok,w,h=pcall(monitor.getSize)
if ok and type(w)=="number" and type(h)=="number" then return w,h end
end
return 51,19
end

local function put(monitor,w,x,y,text)
if y<1 then return end
local s=tostring(text)
if x>w then return end
if x - 1+#s>w then s=s:sub(1,w - x+1)end
monitor.setCursorPos(x,y)
monitor.write(s)
end

local function sorted_keys(t)
local out={}
for k in pairs(t or{})do out[#out+1]=k end
table.sort(out,function(a,b)return tostring(a)<tostring(b)end)
return out
end

function views.footer(monitor,ctx)
local w,h=size(monitor)
local fresh=pages.freshness(ctx.age_s)
local text="Daten: " .. pages.label(fresh)
if ctx.age_s and fresh~="none" then text=text .. " (" .. math.floor(ctx.age_s).. " s)" end
if ctx.op_text then text=text .. " | " .. ctx.op_text end
put(monitor,w,1,h,text)
end

local function header(monitor,ctx,title)
local w=size(monitor)
monitor.clear()
put(monitor,w,1,1," CreateRailNet  " .. tostring(ctx.label or ""))
put(monitor,w,math.max(1,w -#title),1,title)
put(monitor,w,1,2,"Master: " .. tostring(ctx.state.master_state or "UNBEKANNT"))
end


local function cell_of(item)
if item.fault then return "X" end
if item.occupancy=="OCCUPIED_PROVEN" then return item.train and "T" or "O" end
if item.reserved_by then return "R" end
if item.occupancy=="FREE_PROVEN" then return item.certainty=="stale" and "f" or "." end
return "?"
end

local function render_gleisbild(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"GLEISBILD")
local hits={}
if not ctx.layout then
put(monitor,w,1,4,"Kein bestaetigtes Gleisbild.")
return hits
end
local state=ctx.state
local blocks={}
for id,block in pairs(state.overview or{})do blocks[id]=block end
local model=diagram.render_model(ctx.layout,{blocks=blocks,signals=state.signals or{},now=ctx.now or 0,stale_after=ctx.stale_after or 30})
for _,item in ipairs(model)do
local x,y=item.x+1,item.y+3
if y<h and x<=w then
local mark=cell_of(item)
local label=tostring(item.label)
put(monitor,w,x,y,mark .. label)
hits[#hits+1]={x1=x,x2=x+#label,y=y,key="section",value=item.id}
end
end
put(monitor,w,1,h - 1,". frei  ? unklar  R reserviert  O besetzt  T Zug  X Stoerung  f veraltet")
return hits
end

local function render_train_detail(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"ZUGDETAIL")
local id=ctx.selection and ctx.selection.train
if not id then put(monitor,w,1,4,"Zug auf der Seite ZUEGE antippen.");return{}end
local train=(ctx.state.trains or{})[id]
if not train then put(monitor,w,1,4,"Zug " .. tostring(id).. ": keine Daten.");return{}end
put(monitor,w,1,4,"Zug " .. tostring(id).. "  Zustand " .. tostring(train.state or "-"))
put(monitor,w,1,5,"Route " .. tostring(train.route_id or "-").. "  Ziel " .. tostring(train.destination or "-"))
put(monitor,w,1,6,"Plan " .. tostring(train.service_plan or "-").. "  Halt " .. tostring(train.service_stop_index or "-"))
put(monitor,w,1,7,"Phase " .. tostring(train.phase or "-").. "  Laenge " .. tostring(train.length or "?"))
local trip=((ctx.state.fleet or{}).trips or{})[id]
if trip then put(monitor,w,1,9,"Fahrt " .. tostring(trip.state or "-")..(trip.uncertain and "  UNKLAR" or ""))end
if train.error or train.message then put(monitor,w,1,11,"! " .. tostring(train.error or train.message))end

local hits,row={},13
local level=ctx.level or "view"
local function button(label,action)
local allowed=permissions.check({nodes={{id="x",role="panel",permission=level}}},"x",action,{confirm=true})
if allowed then
put(monitor,w,1,row,"[" .. label .. "]")
hits[#hits+1]={x1=1,x2=#label+2,y=row,key="action",value=action,params={train_id=id}}
row=row+1
end
end
button("Halten","hold_train")

local fleet=ctx.state.fleet or{}
local pair=(fleet.train_pair or{})[id]
if pair and permissions.check({nodes={{id="x",role="panel",permission=level}}},"x","depot_run",{})then
for _,depot_id in ipairs(sorted_keys(fleet.depots))do
if fleet.depots[depot_id]==pair and row<h - 1 then
local label="In Depot " .. depot_id
put(monitor,w,1,row,"[" .. label .. "]")
hits[#hits+1]={x1=1,x2=#label+2,y=row,key="action",value="depot_run",params={pair_id=pair,train_id=id,depot=depot_id}}
row=row+1
end
end
end
button("NOTHALT","emergency_stop")
button("Freigeben (Bestaetigung)","release_train")
return hits
end

local function render_trip_assistant(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"FAHRTASSISTENT")
if not pages.allowed("trip_assistant",ctx.level or "view")then put(monitor,w,1,4,"Dafuer fehlt das Recht (operate).");return{}end
local trips=(ctx.state.fleet or{}).trips or{}
local ids=sorted_keys(trips)
if#ids==0 then put(monitor,w,1,4,"Keine Fahrten.")end
local hits,row={},4
for _,id in ipairs(ids)do
if row>=h - 1 then break end
local trip=trips[id]
put(monitor,w,1,row,id .. " " .. tostring(trip.state or "-").. " -> " .. tostring(trip.to or "-")..(trip.uncertain and " UNKLAR" or ""))
hits[#hits+1]={x1=1,x2=w,y=row,key="train",value=trip.train_id or id}
row=row+1
end
return hits
end

local function render_cargo(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"FRACHT")
if not pages.allowed("cargo",ctx.level or "view")then put(monitor,w,1,4,"Dafuer fehlt das Recht (operate).");return{}end
local orders=ctx.state.cargo or{}
local ids=sorted_keys(orders)
if#ids==0 then put(monitor,w,1,4,"Keine Frachtauftraege.")end
local row=4
for _,id in ipairs(ids)do
if row>=h - 1 then break end
local o=orders[id]
put(monitor,w,1,row,id .. " " .. tostring(o.state or "-").. " geliefert " .. tostring(o.delivered or 0).. " offen " .. tostring(o.open or 0).. " unklar " .. tostring(o.unresolved or 0))
row=row+1
end
return{}
end

local function render_faults(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"STOERUNGEN")
local list=ctx.faults or{}
if#list==0 then put(monitor,w,1,4,"Keine offenen Stoerungen.")end
local row=4
for _,item in ipairs(list)do
if row>=h - 1 then break end
local mark=item.state=="ACTIVE" and "!" or "~"
put(monitor,w,1,row,mark .. " " .. tostring(item.severity).. " " .. tostring(item.message))
if item.state~="ACTIVE" then put(monitor,w,1,row+1,"  gesehen von " .. tostring(item.acked_by or "?").. ", Ursache besteht");row=row+1 end
row=row+1
end
put(monitor,w,1,h - 1,"Quittieren = gelesen, nicht behoben.")
return{}
end



local EDIT_BUTTONS={
{"Takt-","headway_min",-1},{"Takt+","headway_min",1},{"Halt-","dwell_s",-5},{"Halt+","dwell_s",5},
{"Von-","window_from",-30},{"Von+","window_from",30},{"Bis-","window_to",-30},{"Bis+","window_to",30},
{"Abf-","departures",-5},{"Abf+","departures",5}
}

local function line_text(id,line)
local rhythm=line.headway_min and("Takt " .. line.headway_min .. " min")or((#(line.departures or{})>0)and(#line.departures .. " Abfahrten")or "-")
local window=line.window and(" " .. tostring(line.window.from).. "-" .. tostring(line.window.to))or ""
return id .. " v" .. tostring(line.version).. " " .. tostring(line.kind or "").. " " .. rhythm .. window
end

local function render_timetable(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"FAHRPLAN")
local fleet=ctx.state.fleet or{}
local lines=fleet.lines or{}
local hits,row={},4
local ids=sorted_keys(lines)
if#ids==0 then put(monitor,w,1,row,"Keine Linien gemeldet.");return hits end
local editing=ctx.editor and ctx.editor.line_id()
for _,id in ipairs(ids)do
if row>=h - 1 then break end
put(monitor,w,1,row,(id==(ctx.selection.line or editing)and ">" or " ").. line_text(id,lines[id]))
hits[#hits+1]={x1=1,x2=w,y=row,key="line",value=id}
row=row+1
end
local selected=ctx.selection.line or editing
local line=selected and lines[selected]
local admin=permissions.check({nodes={{id="x",role="panel",permission=ctx.level or "view"}}},"x","timetable_draft",{})
if not line or not admin or not ctx.editor or not ctx.editor.line_id()then
if line and not admin then put(monitor,w,1,row+1,"Aendern: Recht admin noetig.")end
return hits
end
local editor=ctx.editor
row=row+1
local x=1
for _,button in ipairs(EDIT_BUTTONS)do
local label="[" .. button[1] .. "]"
if x+#label - 1>w then x=1;row=row+1 end
if row<h - 3 then
put(monitor,w,x,row,label)
hits[#hits+1]={x1=x,x2=x+#label - 1,y=row,key="edit",params={cmd="adjust",field=button[2],delta=button[3]}}
end
x=x+#label+1
end
row=row+1
for _,text in ipairs(editor.changes())do
if row<h - 3 then put(monitor,w,1,row,"  " .. text);row=row+1 end
end
local problems=editor.validate()
if#problems>0 and row<h - 2 then put(monitor,w,1,row,"! " .. tostring(problems[1]));row=row+1 end
local conflict=editor.conflict(line.version)
local buttons,labels={},{}
if conflict then
put(monitor,w,1,row,"KONFLIKT: Linie ist jetzt v" .. tostring(line.version).. ", Entwurf auf v" .. tostring(editor.base_version()));row=row+1
buttons[#buttons+1]={"Neu laden",{cmd="reset"}}
buttons[#buttons+1]={"Stand uebernehmen",{cmd="rebase",version=line.version}}
else
if editor.dirty()and#problems==0 then
buttons[#buttons+1]={"Entwurf senden",nil,{action="timetable_draft",params={pair_id=line.pair_id,line=editor.draft(),base_version=editor.base_version()}}}
end
local result=editor.sent_request()and(fleet.results or{})[editor.sent_request()]
if result then
if result.ok then
put(monitor,w,1,row,"Entwurf v" .. tostring(result.version).. " angenommen.");row=row+1
buttons[#buttons+1]={"Veroeffentlichen",nil,{action="timetable_publish",params={pair_id=line.pair_id,line_id=selected,version=result.version,base_version=editor.base_version()}}}
else
put(monitor,w,1,row,"Abgelehnt: " .. tostring(result.reason));row=row+1
end
elseif editor.sent_request()then
put(monitor,w,1,row,"Entwurf gesendet, Antwort steht aus...");row=row+1
end
if editor.dirty()then buttons[#buttons+1]={"Verwerfen",{cmd="reset"}}end
end
x=1
for _,button in ipairs(buttons)do
local label="[" .. button[1] .. "]"
if x+#label - 1>w then x=1;row=row+1 end
if row<h then
put(monitor,w,x,row,label)
if button[3] then
hits[#hits+1]={x1=x,x2=x+#label - 1,y=row,key="action",value=button[3].action,params=button[3].params}
else
hits[#hits+1]={x1=x,x2=x+#label - 1,y=row,key="edit",params=button[2]}
end
end
x=x+#label+1
end
return hits
end


local REPLACE_STEP={
WAIT_NEW_COMPUTER={{"Schluessel ausgeben","replace_adopt",{}}},
WAIT_KEY_CHECK={{"Pruefsumme stimmt","replace_key",{matches=true}},{"stimmt NICHT","replace_key",{matches=false}}},
WAIT_BINDINGS={{"Signale pruefen","replace_bindings",{}}},
WAIT_TEST={{"Test bestanden","replace_finish",{test_ok=true}}}
}

local function render_maintenance(monitor,ctx)
local w,h=size(monitor)
header(monitor,ctx,"WARTUNG")
if not pages.allowed("maintenance",ctx.level or "view")then put(monitor,w,1,4,"Dafuer fehlt das Recht (admin).");return{}end
local diag=ctx.state.diagnostics or{}
local maintenance=diag.maintenance or{}
put(monitor,w,1,4,"Wartungssperre: " ..(maintenance.enabled and "AN" or "aus").. "  " .. tostring(maintenance.reason or ""))
local row=5
for _,lock in ipairs(diag.update_locks or{})do
if row>=h - 3 then break end
put(monitor,w,1,row,"Sperre " .. tostring(lock.node_id).. ": " .. tostring(lock.reason))
row=row+1
end
local hits={}
local replacements=ctx.state.replacements or{}
for _,id in ipairs(sorted_keys(replacements))do
local state=replacements[id]
if row>=h - 3 then break end
put(monitor,w,1,row,"Ersatz " .. id .. ": " .. tostring(state.state)..(state.fingerprint and("  Pruefsumme " .. state.fingerprint)or ""))
row=row+1
if state.missing and#state.missing>0 and row<h - 2 then put(monitor,w,1,row,"  fehlt: " .. table.concat(state.missing,","));row=row+1 end
local x=1
for _,step in ipairs(REPLACE_STEP[state.state] or{})do
local label="[" .. step[1] .. "]"
if row<h - 1 then
put(monitor,w,x,row,label)
local params={node_id=id}
for k,v in pairs(step[3])do params[k]=v end
hits[#hits+1]={x1=x,x2=x+#label - 1,y=row,key="action",value=step[2],params=params}
x=x+#label+1
end
end
row=row+1
end

local nodes=ctx.state.nodes or{}
local started=false
for _,id in ipairs(sorted_keys(nodes))do
if row>=h - 1 then break end
local node=nodes[id]
if node.role~="master" and not replacements[id] then
if not started then put(monitor,w,1,row,"Computer ersetzen:");row=row+1;started=true end
if row<h - 1 then
local label="[" .. id .. " " .. tostring(node.status or "").. "]"
put(monitor,w,1,row,label)
hits[#hits+1]={x1=1,x2=#label,y=row,key="action",value="replace_begin",params={node_id=id}}
row=row+1
end
end
end
return hits
end

local NATIVE={gleisbild=render_gleisbild,train_detail=render_train_detail,trip_assistant=render_trip_assistant,cargo=render_cargo,fault_center=render_faults,maintenance=render_maintenance,timetable=render_timetable}

function views.render(view,monitor,ctx)
if not views.VIEWS[view] then view="overview" end
if not pages.allowed(view,ctx.level or "view")then
header(monitor,ctx,string.upper(view))
local w=size(monitor)
put(monitor,w,1,4,"Dafuer fehlt das Recht (" .. pages.get(view).min .. ").")
views.footer(monitor,ctx)
return{}
end
local hits
if NATIVE[view] then
hits=NATIVE[view](monitor,ctx)
else
hits={}
local model=setmetatable({page=DELEGATE[view],display_name=ctx.label,_hits=hits},{__index=ctx.state})
renderer.render(monitor,model)
end
views.footer(monitor,ctx)
return hits or{}
end

return views
