





local adler=require("core.adler")

local M={}

local TEXT_SIZES={2400,1200,600,300,150}
local LIST_SIZES={12,6,3,2,1}


local function split_text(text,size)
local out={}
if#text==0 then return{""}end
local i=1
while i<=#text do
out[#out+1]=text:sub(i,i+size-1)
i=i+size
end
return out
end

local function split_list(items,per)
local out={}
if#items==0 then return{{}}end
local i=1
while i<=#items do
local part={}
for k=i,math.min(i+per-1,#items)do part[#part+1]=items[k]end
out[#out+1]=part
i=i+per
end
return out
end

local function build(pieces,make,limit,ser)
local payloads={}
for i,piece in ipairs(pieces)do
local payload=make(piece,i,#pieces)
local ok,text=pcall(ser.encode,payload)
if not ok then return nil,"nicht kodierbar"end
if#text>limit then return nil,"zu gross"end
payloads[i]=payload
end
return payloads
end


function M.parts_text(text,make,limit,ser)
local why
for _,size in ipairs(TEXT_SIZES)do
local payloads
payloads,why=build(split_text(text,size),make,limit,ser)
if payloads then return payloads end
if why~="zu gross"then return nil,why end
end
return nil,"Die Daten passen auch in kleinste Teile nicht in eine Nachricht."
end

function M.parts_list(items,make,limit,ser)
local why
for _,per in ipairs(LIST_SIZES)do
local payloads
payloads,why=build(split_list(items,per),make,limit,ser)
if payloads then return payloads end
if why~="zu gross"then return nil,why end
end
return nil,"Ein einzelnes Element passt nicht in eine Nachricht."
end


function M.fit(items,make,limit,ser)
local function fits(n)
local part={}
for i=1,n do part[i]=items[i]end
local ok,text=pcall(ser.encode,make(part))
if not ok then return nil,"nicht kodierbar"end
return#text<=limit
end
local all,why=fits(#items)
if all==nil then return nil,why end
if all then return items,false end
if#items==0 then return nil,"Die Antwort ist schon ohne Elemente zu gross."end
local one=fits(1)
if not one then return nil,"Ein einzelnes Element passt nicht in eine Nachricht."end
local lo,hi=1,#items-1
while lo<hi do
local mid=math.floor((lo+hi+1)/2)
if fits(mid)then lo=mid else hi=mid-1 end
end
local out={}
for i=1,lo do out[i]=items[i]end
return out,true
end


function M.new(opts)
opts=opts or{}
local c={}
local max_parts=opts.max_parts or 60
local max_items=opts.max_items or 400
local max_bytes=opts.max_bytes or 64000
local max_keys=opts.max_keys or 64
local ttl=opts.ttl or 120
local now=opts.now or function()return 0 end
local sets={}
local count=0

local function whole_number(v)return type(v)=="number"and v==math.floor(v)end

function c.drop(key)
if sets[key]then sets[key]=nil;count=count-1 end
end

local function oldest_key()
local pick,at
for key,s in pairs(sets)do if at==nil or s.t<at then pick,at=key,s.t end end
return pick
end


function c.add(key,set,index,total,data,sum)
if type(key)~="string"or#key==0 or#key>80 then return nil,"Schluessel ungueltig"end
if type(set)=="number"then set=string.format("%.14g",set)end
if type(set)~="string"or#set==0 or#set>40 then return nil,"Satzkennung ungueltig"end
if not whole_number(index)or not whole_number(total)or total<1 or total>max_parts or index<1 or index>total then
return nil,"Teilnummer ungueltig"
end
local kind=type(data)=="string"and"text"or(type(data)=="table"and"liste"or nil)
if not kind then return nil,"Daten ungueltig"end
if kind=="text"then
if sum~=nil and(type(sum)~="string"or#sum>16)then return nil,"Pruefsumme ungueltig"end
else
sum=nil
end
local t=now()
local s=sets[key]
if s and(s.set~=set or s.total~=total or s.kind~=kind or s.sum~=sum or t-s.t>ttl)then
c.drop(key)
s=nil
end
if not s then
if count>=max_keys then c.drop(oldest_key())end
s={set=set,total=total,kind=kind,sum=sum,parts={},n=0,size=0,t=t}
sets[key]=s
count=count+1
end
s.t=t
local weight=#data
if s.parts[index]==nil then
if s.size+weight>((kind=="text")and max_bytes or max_items)then
c.drop(key)
return nil,"Daten zu gross"
end
s.parts[index]=data
s.size=s.size+weight
s.n=s.n+1
end
if s.n<s.total then return nil,"offen"end
sets[key]=nil
count=count-1
if kind=="text"then
local pieces={}
for i=1,s.total do pieces[i]=s.parts[i]end
local text=table.concat(pieces)
if s.sum and adler.hex(text)~=s.sum then return nil,"Pruefsumme stimmt nicht"end
return text
end
local list={}
for i=1,s.total do
for _,item in ipairs(s.parts[i])do list[#list+1]=item end
end
return list
end

return c
end

return M
