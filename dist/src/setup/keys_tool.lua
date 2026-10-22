










local keystore=require("src.shared.keystore")
local keyring=require("src.shared.keyring")
local safe_write=require("src.shared.safe_write")
local shared_args=require("src.shared.args")

local keys_tool={}

keys_tool.USAGE=table.concat({
"Schluesselverwaltung (scripts/keys.lua)",
"  init                       Master: Master-Schluessel erzeugen (einmal, am ersten Master)",
"  issue <ID> [--role r]      Master: Schluessel fuer einen Computer ausgeben (auf Diskette, sonst auf dem Bildschirm)",
"  revoke <ID>                Master: Schluessel eines Computers sperren",
"  list                       Master: alle ausgegebenen Schluessel",
"  export-master              Master: Master-Schluessel und Liste auf Diskette fuer den zweiten Master",
"  import-master              zweiter Master: Master-Schluessel und Liste von Diskette uebernehmen",
"  install --id <ID>          Computer: Schluessel von Diskette einrichten (oder --key <64 Zeichen> --epoch <Nummer>)",
"  status [--id <ID>]         zeigt, ob ein Schluessel eingerichtet ist (Pruefsumme, nie der Schluessel)"
},"\n")

local function yes(text)return text~=nil and text:lower():match("^%s*[jy]")~=nil end

local function grouped(key)
local parts={}
for i=1,#key,8 do parts[#parts+1]=key:sub(i,i+7)end
return table.concat(parts," ")
end

local function write_file(fsys,path,body)
return safe_write.write(path,body,{fs=fsys,keep_backup=false})
end

local function first_disk(env)
local mounts=keystore.drive_mounts(env.peripheral)
return mounts[1]
end

local function load_master_state(env,paths)
local master,merr=keystore.load_master(paths.master,{fs=env.fs})
if not master then return nil,nil,"Dieser Computer hat keinen Master-Schluessel (" .. tostring(merr).. "). Zuerst: keys init" end
local trust,terr=keystore.load_trust(paths.trust,{fs=env.fs})
if not trust then return nil,nil,"Die Liste der Schluessel ist beschaedigt (" .. tostring(terr).. "). Es wird nichts geaendert." end
return master,trust
end

local commands={}

function commands.init(args,env,paths)
local say=env.say
local existing=keystore.load_master(paths.master,{fs=env.fs})
if existing and not args.force then
say("Es gibt schon einen Master-Schluessel (Pruefsumme " .. keyring.fingerprint(existing.key).. ").")
say("Ein neuer Schluessel macht ALLE ausgegebenen Schluessel ungueltig. Nur mit --force und der Eingabe JA.")
return 1
end
if existing then
local answer=env.ask("Wirklich? Alle Computer brauchen danach neue Schluessel. Tippen Sie JA: ")
if answer~="JA" then say("Abgebrochen. Nichts wurde geaendert.");return 1 end
end
local typed=env.ask("Tippen Sie 20 beliebige Zeichen als Zufall fuer den Schluessel: ")or ""
local key=keystore.new_master_key(typed .. "|" .. tostring(env.entropy and env.entropy()or ""))
local ok,err=keystore.save_master({key=key},paths.master,{fs=env.fs})
if not ok then say("Der Schluessel konnte nicht gespeichert werden: " .. tostring(err));return 1 end
if existing then

local trust=keystore.load_trust(paths.trust,{fs=env.fs})or{rev=0,nodes={}}
for _,entry in pairs(trust.nodes)do entry.status="revoked" end
keystore.save_trust(trust,paths.trust,{fs=env.fs})
end
say("Master-Schluessel erzeugt. Pruefsumme: " .. keyring.fingerprint(key))
say("Der zweite Master bekommt ihn mit: keys export-master (hier) und keys import-master (dort).")
return 0
end

function commands.issue(args,env,paths)
local say=env.say
local id=args._extra and args._extra[2]
if not id then say("Fuer welchen Computer? keys issue <ID>");return 1 end
local master,trust,problem=load_master_state(env,paths)
if not master then say(problem);return 1 end
local record,err=keystore.issue(trust,master.key,id,args.role,env.now and env.now()or 0)
if not record then say(err);return 1 end
local saved,save_err=keystore.save_trust(trust,paths.trust,{fs=env.fs})
if not saved then say("Die Liste konnte nicht gespeichert werden: " .. tostring(save_err));return 1 end
say("Schluessel fuer " .. id .. " ausgegeben (Nummer " .. record.epoch .. ", Pruefsumme " .. keyring.fingerprint(record.key).. ").")
local mount=not args["no-disk"] and first_disk(env)
if mount then
local path=mount .. "/crn_key_" .. id .. ".json"
local ok,werr=write_file(env.fs,path,keystore.node_body(record))
if not ok then say("Die Diskette ist nicht beschreibbar: " .. tostring(werr));return 1 end
say("Geschrieben nach " .. path .. ". Diskette in das Laufwerk des Computers legen und dort: keys install --id " .. id)
else
say("Kein Laufwerk gefunden (oder --no-disk): der Schluessel steht hier. Er ist geheim, nur an diesem Bildschirm ablesen.")
say("  Schluessel: " .. grouped(record.key))
say("  Nummer:     " .. record.epoch)
say("Auf dem Computer: keys install --id " .. id .. " --key <Schluessel ohne Leerzeichen> --epoch " .. record.epoch)
end
say("Ein Master, der laeuft, uebernimmt die Liste innerhalb weniger Sekunden.")
return 0
end

function commands.revoke(args,env,paths)
local say=env.say
local id=args._extra and args._extra[2]
if not id then say("Welchen Computer? keys revoke <ID>");return 1 end
local master,trust,problem=load_master_state(env,paths)
if not master then say(problem);return 1 end
local ok,err=keystore.revoke(trust,id)
if not ok then say(err);return 1 end
local saved,save_err=keystore.save_trust(trust,paths.trust,{fs=env.fs})
if not saved then say("Die Liste konnte nicht gespeichert werden: " .. tostring(save_err));return 1 end
say("Der Schluessel von " .. id .. " ist gesperrt. Der Computer wird nicht mehr gehoert. Neuer Schluessel: keys issue " .. id)
return 0
end

function commands.list(args,env,paths)
local say=env.say
local master,trust,problem=load_master_state(env,paths)
if not master then say(problem);return 1 end
local ids={}
for id in pairs(trust.nodes)do ids[#ids+1]=id end
table.sort(ids)
say("Master-Schluessel, Pruefsumme " .. keyring.fingerprint(master.key).. "; Liste Stand " .. tostring(trust.rev))
if#ids==0 then say("Noch kein Computer hat einen Schluessel.")end
for _,id in ipairs(ids)do
local entry=trust.nodes[id]
say(string.format("  %-24s Nummer %d  %-8s %s",id,entry.epoch,entry.status=="active" and "aktiv" or "GESPERRT",entry.role or ""))
end
return 0
end

function commands.export_master(args,env,paths)
local say=env.say
local master,trust,problem=load_master_state(env,paths)
if not master then say(problem);return 1 end
local mount=first_disk(env)
if not mount then say("Kein Laufwerk mit Diskette gefunden.");return 1 end
local ok,err=write_file(env.fs,mount .. "/crn_master_key.json",require("src.shared.json").encode({v=1,key=master.key}))
if ok then ok,err=write_file(env.fs,mount .. "/crn_trust.json",require("src.shared.json").encode(trust))end
if not ok then say("Die Diskette ist nicht beschreibbar: " .. tostring(err));return 1 end
say("Master-Schluessel und Liste liegen auf der Diskette (Pruefsumme " .. keyring.fingerprint(master.key).. ").")
say("Nach dem Uebernehmen auf dem zweiten Master die Dateien von der Diskette loeschen: sie ist so geheim wie der Schluessel.")
return 0
end

function commands.import_master(args,env,paths)
local say=env.say
local mount=first_disk(env)
if not mount then say("Kein Laufwerk mit Diskette gefunden.");return 1 end
local master_path,trust_path=mount .. "/crn_master_key.json",mount .. "/crn_trust.json"
local master,merr=keystore.load_master(master_path,{fs=env.fs})
if not master then say("Auf der Diskette ist kein gueltiger Master-Schluessel (" .. tostring(merr).. ").");return 1 end
local trust,terr=keystore.load_trust(trust_path,{fs=env.fs})
if not trust then say("Auf der Diskette ist keine gueltige Liste (" .. tostring(terr).. ").");return 1 end
say("Gefunden: Master-Schluessel mit Pruefsumme " .. keyring.fingerprint(master.key).. ", " ..(function()local n=0 for _ in pairs(trust.nodes)do n=n+1 end return n end)().. " Computer in der Liste.")
local existing=keystore.load_master(paths.master,{fs=env.fs})
if existing and existing.key~=master.key then
say("Dieser Computer hat schon einen anderen Master-Schluessel (Pruefsumme " .. keyring.fingerprint(existing.key).. "). Nichts wurde geaendert.")
return 1
end
if not yes(env.ask("Stimmt die Pruefsumme mit der am ersten Master ueberein? (j/n) "))then say("Abgebrochen. Nichts wurde geaendert.");return 1 end
local ok,err=keystore.save_master(master,paths.master,{fs=env.fs})
if ok then ok,err=keystore.save_trust(trust,paths.trust,{fs=env.fs})end
if not ok then say("Speichern fehlgeschlagen: " .. tostring(err));return 1 end
say("Uebernommen.")
return 0
end

function commands.install(args,env,paths)
local say=env.say
local id=args.id
if not id then say("Fuer welchen Computer? keys install --id <ID>");return 1 end
local record,why
local source
if args.key then
local key=args.key:gsub("%s",""):lower()
local epoch=tonumber(args.epoch)
if not keyring.valid_key(key)then say("Der Schluessel muss aus 64 Zeichen 0-9 a-f bestehen.");return 1 end
if not epoch or epoch<1 or epoch~=math.floor(epoch)then say("--epoch fehlt oder ist keine ganze Zahl.");return 1 end
record={id=id,key=key,epoch=epoch}
source="Eingabe"
else
local files=keystore.find_disk_files(env.fs,env.peripheral,id)
if#files==0 then say("Keine Schluesseldatei fuer " .. id .. " auf einer Diskette gefunden.");return 1 end
for _,path in ipairs(files)do
local body=safe_write.read(path,{fs=env.fs})
record,why=keystore.parse_node_body(body,id)
if record then source=path;break end
say(path .. ": " .. tostring(why))
end
if not record then return 1 end
end
say("Schluessel fuer " .. id .. ": Nummer " .. record.epoch .. ", Pruefsumme " .. keyring.fingerprint(record.key).. " (Quelle: " .. source .. ").")
say("Diese Pruefsumme muss mit der Meldung am Master uebereinstimmen.")
if not yes(env.ask("Schluessel einrichten? (j/n) "))then say("Abgebrochen. Nichts wurde geaendert.");return 1 end
local ok,err=keystore.save_node(record,paths.node,{fs=env.fs})
if not ok then say("Speichern fehlgeschlagen: " .. tostring(err));return 1 end
say("Eingerichtet. Der Computer braucht einen Neustart (Strg+R halten).")
if source~="Eingabe" and yes(env.ask("Die Schluesseldatei von der Diskette loeschen? (j/n) "))then
if env.fs.delete then env.fs.delete(source);say("Geloescht.")end
end
return 0
end

function commands.status(args,env,paths)
local say=env.say
local record,err=keystore.load_node(paths.node,{fs=env.fs})
if record then
say("Schluessel dieses Computers: " .. record.id .. ", Nummer " .. record.epoch .. ", Pruefsumme " .. keyring.fingerprint(record.key))
if args.id and args.id~=record.id then say("ACHTUNG: gehoert zu " .. record.id .. ", nicht zu " .. args.id .. ".")end
else
say("Kein Schluessel eingerichtet (" .. tostring(err).. ").")
end
local master=keystore.load_master(paths.master,{fs=env.fs})
if master then say("Dieser Computer ist ein Master mit Master-Schluessel, Pruefsumme " .. keyring.fingerprint(master.key).. ".")end
local mode=env.config and env.config.auth_mode or "off"
say("Modus (auth_mode): " .. tostring(mode))
return 0
end

local COMMAND_NAMES={init="init",issue="issue",revoke="revoke",list="list",["export-master"]="export_master",["import-master"]="import_master",install="install",status="status"}

function keys_tool.run(argv,env)
local ok,args=pcall(shared_args.parse,argv or{},{id={},role={},key={},epoch={},force={boolean=true},["no-disk"]={boolean=true}})
if not ok then env.say(tostring(args));return 1 end
local name=args._extra and args._extra[1]
local command=name and COMMAND_NAMES[name]
if not command then
env.say(keys_tool.USAGE)
return name and 1 or 0
end
local paths={
node=env.paths and env.paths.node or keystore.NODE_PATH,
master=env.paths and env.paths.master or keystore.MASTER_PATH,
trust=env.paths and env.paths.trust or keystore.TRUST_PATH
}
return commands[command](args,env,paths)
end

return keys_tool
