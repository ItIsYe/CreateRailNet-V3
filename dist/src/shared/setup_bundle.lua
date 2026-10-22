










local setup_bundle={}

local unpack_fn=table.unpack or unpack

setup_bundle.MARKER="src/setup/wizard.lua"
setup_bundle.RECORD="crn_install.lua"

local function read(fsys,path)
if not(fsys and fsys.exists and fsys.exists(path))then return nil end
local fh=fsys.open(path,"r")
if not fh then return nil end
local body=fh.readAll()
fh.close()
return body
end

function setup_bundle.present(fsys)
return fsys~=nil and fsys.exists~=nil and fsys.exists(setup_bundle.MARKER)==true
end

function setup_bundle.recorded_ref(fsys)
local body=read(fsys,setup_bundle.RECORD)
return body and body:match('ref%s*=%s*"([^"\n]+)"')or nil
end

local function installer_args(env,flag)
local list={"installer",flag,"--yes"}
local ref=env.ref or setup_bundle.recorded_ref(env.fs)
if ref then list[#list+1]="--ref";list[#list+1]=ref end
return list
end

local function call_installer(env,flag)
if not(env.shell and env.shell.run)then return nil,"keine Shell" end
if not(env.fs and env.fs.exists and env.fs.exists("installer"))then
return nil,"Der Installer liegt nicht auf diesem Computer. Neu laden: wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<ref>/installer " .. flag
end
local list=installer_args(env,flag)
local ok=env.shell.run(unpack_fn(list))
if not ok then return nil,"installer " .. flag .. " ist fehlgeschlagen" end
return true
end

function setup_bundle.slim(env)
if not setup_bundle.present(env.fs)then return true end
return call_installer(env,"--slim")
end

function setup_bundle.run(main,args,env)
local say=env.say or print
if not setup_bundle.present(env.fs)then
say("Die Einrichtungs-Dateien sind auf diesem Computer nicht abgelegt (Platz). Sie werden geladen ...")
local fetched,err=call_installer(env,"--setup")
if not fetched or not setup_bundle.present(env.fs)then
return nil,"Die Einrichtungs-Dateien konnten nicht geladen werden: " .. tostring(err or "Dateien fehlen nach dem Laden")
end
end
local list={main}
for _,arg in ipairs(args or{})do list[#list+1]=arg end
local ok=env.shell.run(unpack_fn(list))
local slimmed,slim_err=setup_bundle.slim(env)
if not slimmed then say("Hinweis: die Einrichtungs-Dateien konnten nicht wieder entfernt werden (" .. tostring(slim_err).. "): installer --slim")end
if not ok then return nil,"failed" end
return true
end

return setup_bundle
