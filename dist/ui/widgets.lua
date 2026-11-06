





local palette=require("ui.palette")
local S=palette.SLOT

local W={}

local KIND_FG={text=S.text,dim=S.gedaempft,hell=S.hell,ok=S.ok,wait=S.wartend,attention=S.achtung,halt=S.halt,info=S.auswahl}
local KIND_BG={ok=S.ok,wait=S.wartend,attention=S.achtung,halt=S.halt,info=S.haupt,primary=S.haupt,secondary=S.trenner,danger=S.halt}

function W.label(v,x,y,text,kind,maxw)
v.canvas.text(x,y,text,KIND_FG[kind or"text"]or S.text,nil,maxw)
end

function W.badge(v,x,y,text,kind)
local label=" "..text.." "
local bg=KIND_BG[kind or"info"]or S.haupt
local fg=(kind=="wait")and S.hintergrund or S.hell
return v.canvas.text(x,y,label,fg,bg)
end


function W.fit(text,width)
text=tostring(text)
if#text<=width then return text end
local plain=text:gsub("%s*%b()%s*$","")
if#plain>0 and#plain<=width then return plain end
if width<=1 then return"~"end
local cut=text:sub(1,width-1)
if not text:sub(width,width):match("%s")then
local at=cut:find("%s[^%s]*$")
if at and at>width/2 then cut=cut:sub(1,at-1)end
end
return cut.."~"
end

function W.wrap(text,width)
local lines={}
for paragraph in(tostring(text).."\n"):gmatch("(.-)\n")do
local line=""
for word in paragraph:gmatch("%S+")do
while#word>width do
if line~=""then lines[#lines+1]=line;line=""end
lines[#lines+1]=word:sub(1,width)
word=word:sub(width+1)
end
if line==""then line=word
elseif#line+1+#word<=width then line=line.." "..word
else lines[#lines+1]=line;line=word end
end
lines[#lines+1]=line
end
while#lines>1 and lines[#lines]==""do lines[#lines]=nil end
return lines
end


function W.button(v,id,x,y,w,h,label,opts)
opts=opts or{}
local enabled=opts.enabled~=false
local kind=opts.kind or"primary"
local bg=enabled and(KIND_BG[kind]or S.haupt)or S.trenner
if v.focus_id==id and enabled then bg=S.auswahl end
v.canvas.fill(x,y,w,h,bg)
local fg=enabled and S.hell or S.gedaempft
local text=label
if#text>w-2 then text=text:sub(1,math.max(1,w-3)).."~"end
local tx=x+math.max(0,math.floor((w-#text)/2))
v.canvas.text(tx,y+math.floor((h-1)/2),text,fg,bg)
v.touch.add(id,x,y,w,h,{enabled=enabled,reason=opts.reason})
v.add_focus(id,enabled)
end


function W.list(v,id,rect,items,state,opts)
opts=opts or{}
local row_h=opts.row_h or(v.layout.mode=="gross"and 3 or 1)

local footer=(#items*row_h>rect.h)and 1 or 0
local per_page=math.max(1,math.floor((rect.h-footer)/row_h))
state.index=math.max(1,math.min(state.index or 1,math.max(1,#items)))
local page=math.floor((state.index-1)/per_page)
state.offset=page*per_page
local pages=math.max(1,math.ceil(#items/per_page))
v.lists[id]={state=state,per_page=per_page,count=#items}
v.list_order[#v.list_order+1]=id
v.canvas.fill(rect.x,rect.y,rect.w,rect.h,S.arbeit)
if#items==0 then

local lines=W.wrap(opts.empty or"(leer)",rect.w-2)
for i=1,math.min(#lines,math.max(1,rect.h-1))do
v.canvas.text(rect.x+1,rect.y+i-1,lines[i],S.gedaempft,S.arbeit,rect.w-2)
end
end
for row=1,per_page do
local i=state.offset+row
local item=items[i]
if not item then break end
local y=rect.y+(row-1)*row_h
local selected=(i==state.index)
local bg=selected and S.zeile or S.arbeit
v.canvas.fill(rect.x,y,rect.w,row_h,bg)
local mark=selected and"> "or"  "
local title_y=y+math.floor((row_h-1)/2)
local detail=item.detail
local room=rect.w-2
if detail and row_h==1 then

local dw=math.min(#detail,math.max(math.floor(room/2),rect.w-3-#item.text))
v.canvas.text(rect.x+room-dw+2,title_y,detail,KIND_FG[item.kind or"dim"]or S.gedaempft,bg,dw)
room=room-dw-1
v.canvas.text(rect.x,title_y,mark..item.text,selected and S.hell or S.text,bg,room+2)
elseif row_h>=3 and(#item.text>room or(detail and#detail>room))then

local tl=W.wrap(item.text,room)
local dl=detail and W.wrap(detail,room)or{}
local dn=#dl>0 and math.min(#dl,math.max(1,row_h-#tl))or 0
local tn=math.min(#tl,row_h-dn)
local function take(lines,n)
local out={}
for k=1,n do out[k]=lines[k]end
if#lines>n then out[n]=W.fit(table.concat(lines," ",n),room)end
return out
end
local y0=y+(row_h-tn-dn)
for k,line in ipairs(take(tl,tn))do
v.canvas.text(rect.x,y0+k-1,(k==1 and mark or"  ")..line,selected and S.hell or S.text,bg,rect.w)
end
for k,line in ipairs(take(dl,dn))do
v.canvas.text(rect.x+2,y0+tn+k-1,line,KIND_FG[item.kind or"dim"]or S.gedaempft,bg,rect.w-2)
end
else
v.canvas.text(rect.x,title_y,mark..item.text,selected and S.hell or S.text,bg,rect.w)
if detail and row_h>=2 then v.canvas.text(rect.x+2,title_y+1,detail,KIND_FG[item.kind or"dim"]or S.gedaempft,bg,rect.w-2)end
end
v.touch.add("sel:"..id..":"..i,rect.x,y,rect.w,row_h)
end
if footer==1 then
local fy=rect.y+rect.h-1
v.canvas.fill(rect.x,fy,rect.w,1,S.arbeit)
v.canvas.text(rect.x+2,fy,string.format("Seite %d/%d  (%d Eintraege)",page+1,pages,#items),S.gedaempft,S.arbeit,rect.w-4)
if pages>1 then
v.canvas.text(rect.x+rect.w-7,fy," < > ",S.hell,S.haupt)
v.touch.add("page:"..id..":prev",rect.x+rect.w-7,fy,3,1)
v.touch.add("page:"..id..":next",rect.x+rect.w-4,fy,3,1)
end
end
return math.min(per_page,math.max(0,#items-state.offset)),per_page
end


function W.field(v,id,x,y,w,label,state)
local focused=v.input_id==id
v.fields[id]=state
v.canvas.text(x,y,label,focused and S.hell or S.gedaempft,S.arbeit,math.max(w,#label))
local fy=y+1
v.canvas.fill(x,fy,w,1,focused and S.zeile or S.trenner)
local shown=tostring(state.value or"")
local room=w-2
if#shown>room then shown="~"..shown:sub(#shown-room+2)end
v.canvas.text(x+1,fy,shown..(focused and"_"or""),S.hell,focused and S.zeile or S.trenner,w-1)
v.touch.add("field:"..id,x,fy,w,1)
end

return W
