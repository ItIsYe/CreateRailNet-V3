






local pages={}

local ORDER={
{id="overview",min="view",title="Uebersicht"},
{id="gleisbild",min="view",title="Gleisbild"},
{id="trains",min="view",title="Zuege"},
{id="train_detail",min="view",title="Zugdetail"},
{id="trip_assistant",min="operate",title="Fahrtassistent"},
{id="stations",min="view",title="Stationen"},
{id="depots",min="view",title="Depots"},
{id="timetable",min="view",title="Fahrplan"},
{id="cargo",min="operate",title="Fracht"},
{id="fault_center",min="view",title="Stoerungen"},
{id="nodes",min="view",title="Knoten"},
{id="maintenance",min="admin",title="Wartung"},
{id="audit",min="admin",title="Protokoll"}
}
local RANK={view=1,operate=2,admin=3}
local BY_ID={}
for _,page in ipairs(ORDER)do BY_ID[page.id]=page end

function pages.list()return ORDER end
function pages.get(id)return BY_ID[id] end

function pages.allowed(id,level)
local page=BY_ID[id]
return page~=nil and(RANK[level] or 1)>=RANK[page.min]
end

function pages.visible(level)
local out={}
for _,page in ipairs(ORDER)do
if pages.allowed(page.id,level)then out[#out+1]=page end
end
return out
end

function pages.freshness(age_s,opts)
if age_s==nil then return "none" end
local limit=(opts and opts.stale_after_s)or 10
if age_s>limit then return "stale" end
return "fresh"
end

local LABEL={fresh="aktuell",stale="veraltet",none="keine Daten"}
function pages.label(freshness)return LABEL[freshness] or LABEL.none end

return pages
