












local require_scan={}

local function strip_comments(text)
text=text:gsub("%-%-%[(=*)%[.-%]%1%]","")
text=text:gsub("%-%-[^\n]*","")
return text
end

function require_scan.modules(body)
local found,list={},{}
local function add(name)if not found[name] then found[name]=true;list[#list+1]=name end end
local text=strip_comments(tostring(body or ""))
for name in text:gmatch("require%s*%(%s*[\"']([%w_%.%-]+)[\"']%s*%)")do add(name)end
for name in text:gmatch("require%s*,%s*[\"']([%w_%.%-]+)[\"']")do add(name)end
for name in text:gmatch("require%s+[\"']([%w_%.%-]+)[\"']")do add(name)end
table.sort(list)
return list
end

function require_scan.module_path(name)
return(tostring(name):gsub("%.","/")).. ".lua"
end

function require_scan.closure(entries,read_body)
local seen,paths={},{}
local problems={missing={},external={}}
local reported={}

local function visit(path,label)
if seen[path] then return end
local body=read_body(path)
if not body then
if not reported[label] then reported[label]=true;problems.missing[#problems.missing+1]=label end
return
end
seen[path]=true
paths[#paths+1]=path
for _,name in ipairs(require_scan.modules(body))do
if name:sub(1,4)=="src." then
visit(require_scan.module_path(name),name)
elseif name:sub(1,3)~="cc." and not reported[name] then
reported[name]=true
problems.external[#problems.external+1]=name
end
end
end

for _,entry in ipairs(entries or{})do
if entry:find("/",1,true)or entry:match("%.lua$")then visit(entry,entry)
else visit(require_scan.module_path(entry),entry)end
end
table.sort(paths)
table.sort(problems.missing)
table.sort(problems.external)
return paths,problems
end

return require_scan
