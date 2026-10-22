









local terminal=require("src.setup.terminal")

local bauliste={}

bauliste.PATH="crn_bauliste.txt"
bauliste.WIDTH=50

local GROUPS={
{role="master",title="Master"},
{role="panel",title="Panel"},
{role="train",title="Zuege"},
{role="station",title="Bahnhoefe"},
{role="depot",title="Depots"},
{role="signal",title="Signale"},
{role="sensor",title="Melder"},
{role="switch",title="Weichen"},
}

function bauliste.render(plan,meta,l)
local out={}
local function add(text,indent)
for _,line in ipairs(terminal.wrap((indent or "").. text,bauliste.WIDTH))do out[#out+1]=line end
end
local function blank()out[#out+1]="" end
local stats=meta.stats

add("CreateRailNet Bauliste" ..((l.name and l.name~="")and(": " .. l.name)or ""))
add(string.rep("=",40))
add(stats.stations .. " Bahnhoefe, " .. stats.depots .. " Depots, " .. stats.trains .. " Zuege, Kanal " .. tostring(plan.channel).. ", Master " .. plan.master_id)
blank()

add("1. Das braucht ihr")
add("Computer gesamt: " .. stats.computers,"   ")
add("Modems: " .. stats.computers .. " (eins an jedem Computer)","   ")
local counted={}
for _,node in ipairs(plan.nodes)do counted[node.role]=(counted[node.role] or 0)+1 end
add("Master: 1 (mit Monitor)","   ")
if counted.panel then add("Panel: " .. counted.panel .. " (mit Monitor)","   ")end
if counted.train then add("Zuege: " .. counted.train .. " (Bordcomputer)","   ")end
add("Bahnhoefe und Depots: " ..((counted.station or 0)+(counted.depot or 0)).. " (je am Create-Bahnhofsblock)","   ")
add("Signale (Create): " .. stats.signals,"   ")
add("Melder (Train Observer): " .. stats.sensors,"   ")
add("Weichen: " .. stats.switches .. " (Redstone)","   ")
add("Bloecke: " .. stats.blocks .. "   Routen: " .. stats.routes,"   ")
blank()

add("2. Create-Bahnhoefe: Namen genau so")
add("Der Name am Create-Bahnhofsblock muss genau so heissen, sonst findet der Zug sein Ziel nicht.")
for _,item in ipairs(meta.create_names)do add(item.id .. '  "' .. item.name .. '"',"   ")end
blank()

add("3. Reihenfolge")
add("1. Master mit Monitor aufstellen; dort scripts/setup.lua --layout ausfuehren (so entstand dieser Plan), Master neu starten.","")
add("2. Strecke Block fuer Block: Signale und Melder, je Block zwei Signale und ein Melder (Liste unten).","")
add("3. Weichen an den Bahnhoefen und Depots.","")
add("4. Bahnhoefe und Depots (Create-Bahnhofsblock, Namen wie oben).","")
add("5. Zuege (Bordcomputer) zuletzt.","")
add("6. Pruefen: an jedem Computer scripts/setup.lua --doctor, am Master die Seite EINRICHTUNG, dann scripts/setup.lua --test.","")
blank()

add("4. So wird jeder Computer eingerichtet")
add("1. Computer aufstellen, Modem und das Geraet daran.","")
add("2. wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer","")
add("   (fuer ein ganzes Netz besser mit einem Tag, siehe docs/RELEASE.md), die Rolle waehlen wie in der Liste.","")
add("3. Im Assistenten: Netzplan \"Kurzplan\", die ID GENAU wie in der Liste.","")
add("4. Bahnhof und Depot: am Ende \"Den Plan jetzt vom Master holen?\" mit Ja (oder scripts/setup.lua --fetch-plan).","")
add("Der Master kennt die ID schon aus diesem Plan: es muss nichts angenommen werden.","")
blank()

add("5. Alle Computer")
local by_role={}
for _,item in ipairs(meta.computers)do
by_role[item.role]=by_role[item.role] or{}
table.insert(by_role[item.role],item)
end
for _,group in ipairs(GROUPS)do
local list=by_role[group.role]
if list and#list>0 then
blank()
add("-- " .. group.title .. " (" ..#list .. ") --")
for _,item in ipairs(list)do
add(item.id .. "  " .. item.role)
add(item.what,"   ")
if item.where~="" then add(item.where,"   ")end
end
end
end

blank()
add("6. Gut zu wissen")
for _,note in ipairs(meta.notes)do add("- " .. note)end
return table.concat(out,"\n").. "\n"
end

return bauliste
