









local signal_bindings=require("src.shared.signal_bindings")

local signal_tool={}

signal_tool.USAGE=table.concat({
"Signale dieses Computers binden (scripts/bind_signals.lua)",
"  list                 zeigt alle Signale dieses Computers und ihre Bindung",
"  check                vergleicht Bindungen, angeschlossene Geraete und Plan (aendert nichts)",
"  bind <ID>            ein neues Signal anschliessen und an <ID> binden (eines nach dem anderen)",
"  replace <ID>         ein ersetztes Geraet fuer <ID> neu binden",
"  unbind <ID>          Bindung loeschen"
},"\n")

local function yes(text)return text~=nil and text:lower():match("^%s*[jy]")~=nil end

local function expected_ids(env)
for _,node in ipairs((env.config and env.config.nodes)or{})do
if node.id==env.id and type(node.signals)=="table" then return node.signals end
end
return{}
end

local function present_devices(env)
local out={}
local ok,names=pcall(env.peripheral.getNames)
if not ok or type(names)~="table" then return out end
for _,name in ipairs(names)do
local okt,ptype=pcall(env.peripheral.getType,name)
out[name]=okt and ptype or "unknown"
end
return out
end

local function is_signal_type(ptype)return type(ptype)=="string" and ptype:lower():find("signal",1,true)~=nil end

local function signal_names(env)
local set={}
for name,ptype in pairs(present_devices(env))do if is_signal_type(ptype)then set[name]=ptype end end
return set
end

local function new_bindings(env)
local bindings=signal_bindings.new({fs=env.fs,node_id=env.id,now=env.now})
local state,err=bindings.load()
return bindings,state,err
end

local commands={}

function commands.list(_,env)
local bindings=new_bindings(env)
local say=env.say
local seen=present_devices(env)
local listed={}
for _,record in ipairs(bindings.list())do
listed[record.logical_id]=true
local usable=bindings.is_usable(record.logical_id,seen)
say(string.format("%-12s %-22s Gleis %-6s Richtung %-8s %s",record.logical_id,record.peripheral,tostring(record.track_id or "-"),tostring(record.direction or "-"),usable and "ok" or "NICHT BENUTZBAR"))
end
for _,id in ipairs(expected_ids(env))do
if not listed[id] then say(string.format("%-12s (noch nicht gebunden)",id))end
end
return 0
end

function commands.check(_,env)
local bindings,state,err=new_bindings(env)
local say=env.say
if state=="corrupt" then say("Die Bindungsdatei ist beschaedigt (" .. tostring(err).. "). Es ist kein Signal benutzbar.")return 1 end
local report=bindings.verify(present_devices(env))
local topology=bindings.compare_topology(expected_ids(env))
local problems=0
for _,id in ipairs(topology.unbound)do problems=problems+1;say("Signal " .. id .. ": der Master erwartet es, es ist nicht gebunden.")end
for _,id in ipairs(topology.unknown)do problems=problems+1;say("Signal " .. id .. ": gebunden, aber der Master kennt es nicht (wird nicht benutzt).")end
local ids={}
for id in pairs(report.missing)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do problems=problems+1;say("Signal " .. id .. ": Geraet " .. report.missing[id] .. " fehlt.")end
ids={}
for id in pairs(report.type_changed)do ids[#ids+1]=id end
table.sort(ids)
for _,id in ipairs(ids)do problems=problems+1;say("Signal " .. id .. ": Geraetetyp ist jetzt " .. tostring(report.type_changed[id].found).. " statt " .. tostring(report.type_changed[id].expected).. ".")end
for _,name in ipairs(report.unbound)do problems=problems+1;say("Geraet " .. name .. " ist neu und an kein Signal gebunden (bind oder replace verwenden).")end
if problems==0 then say("Alle Signale sind in Ordnung.")return 0 end
say("Es wird nichts automatisch umgebunden. Behebung: bind / replace / unbind.")
return 1
end

local function known_here(env,id)
for _,expected in ipairs(expected_ids(env))do if expected==id then return true end end
return false
end

local function bind_flow(env,id,replacing)
local say,ask=env.say,env.ask
if not id or id=="" then say("Signal-ID fehlt.")return 1 end
if not known_here(env,id)then say("Der Master kennt das Signal " .. id .. " fuer diesen Computer nicht. Zuerst den Netzplan (nodes[].signals) pruefen.")return 1 end
local bindings,state,err=new_bindings(env)
if state=="corrupt" then say("Die Bindungsdatei ist beschaedigt (" .. tostring(err).. "). Es wird nichts geaendert.")return 1 end
local existing=bindings.get(id)
if existing and not replacing then say("Signal " .. id .. " ist schon an " .. existing.peripheral .. " gebunden. Zum Ersetzen: replace " .. id)return 1 end
if replacing and not existing then say("Signal " .. id .. " ist nicht gebunden. Zuerst: bind " .. id)return 1 end

local before=signal_names(env)
say("Alle Geraete dieses Signals trennen bis auf die schon gebundenen. Jetzt genau das Modem des Signals " .. id .. " anschliessen.")
ask("Wenn das Modem angeschlossen ist: Enter ")
local after=signal_names(env)
local fresh={}
for name in pairs(after)do if not before[name] then fresh[#fresh+1]=name end end
table.sort(fresh)
if#fresh==0 then say("Es ist kein neues Signal-Geraet erschienen. Nichts wurde gebunden.")return 1 end
if#fresh>1 then say("Es sind " ..#fresh .. " neue Geraete erschienen (" .. table.concat(fresh,", ").. "). Es muss genau ein Geraet neu sein, sonst sind sie nicht zu unterscheiden. Nichts wurde gebunden.")return 1 end
local name=fresh[1]
say("Neues Geraet: " .. name .. " (" .. tostring(after[name]).. ").")

local okw,device=pcall(env.peripheral.wrap,name)
if not okw or not device or not device.setForcedRed then say("Das Geraet " .. name .. " kann nicht auf Rot gestellt werden. Nichts wurde gebunden.")return 1 end
local okc,callerr=pcall(device.setForcedRed,true)
if not okc then say("Rot stellen ist fehlgeschlagen: " .. tostring(callerr).. ". Nichts wurde gebunden.")return 1 end
if not yes(ask("Ist jetzt das Signal " .. id .. " rot (das richtige Signal)? (j/n) "))then
say("Signal " .. id .. " nicht gebunden.")
return 1
end
local meta={
confirmed=true,ptype=after[name],
track_id=ask("Gleis (z.B. T3): "),direction=ask("Richtung (z.B. OST): "),
signal_type=ask("Signalart (z.B. Einfahrt): "),position=ask("Ort/Position (z.B. km 4): ")
}
for _,key in ipairs({"track_id","direction","signal_type","position"})do if meta[key]=="" then meta[key]=nil end end
local ok,bind_err
if replacing then ok,bind_err=bindings.replace(id,name,meta)else ok,bind_err=bindings.bind(id,name,meta)end
if not ok then say("Nicht gebunden: " .. tostring(bind_err))return 1 end
say("Signal " .. id .. " ist an " .. name .. " gebunden.")
return 0
end

function commands.bind(args,env)return bind_flow(env,args[1],false)end
function commands.replace(args,env)return bind_flow(env,args[1],true)end

function commands.unbind(args,env)
local id=args[1]
local bindings,state=new_bindings(env)
if state=="corrupt" then env.say("Die Bindungsdatei ist beschaedigt. Es wird nichts geaendert.")return 1 end
if not id or not bindings.get(id)then env.say("Signal " .. tostring(id).. " ist nicht gebunden.")return 1 end
if env.ask("Bindung von " .. id .. " wirklich loeschen? Zum Bestaetigen JA schreiben: ")~="JA" then env.say("Nichts geloescht.")return 1 end
local ok,err=bindings.unbind(id)
if not ok then env.say("Nicht geloescht: " .. tostring(err))return 1 end
env.say("Bindung von " .. id .. " geloescht.")
return 0
end

function signal_tool.run(argv,env)
local command=argv and argv[1]
if not command then env.say(signal_tool.USAGE)return 0 end
local handler=commands[command]
if not handler then env.say("Unbekannter Befehl: " .. tostring(command))env.say(signal_tool.USAGE)return 1 end
local rest={}
for i=2,#argv do rest[#rest+1]=argv[i] end
return handler(rest,env)
end

return signal_tool
