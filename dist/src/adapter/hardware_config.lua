




















local hardware_config={}

function hardware_config.new(config)


local by_id,indexed={},-1
local function index()
local nodes=config and config.nodes
if type(nodes)~="table" then return by_id end
if#nodes~=indexed then
by_id,indexed={},#nodes
for _,node in ipairs(nodes)do
if type(node)=="table" and node.id then by_id[node.id]=node end
end
end
return by_id
end

local self={}

function self.node(id)
return index()[id] or{id=id}
end

function self.adapter(id)
local node=self.node(id)
return node.adapter or "peripheral"
end

function self.target(id)
local node=self.node(id)
return node.peripheral or node.target or id
end

function self.side(id)
local node=self.node(id)
return node.side
end

function self.value(id,key)
local node=self.node(id)
return node[key]
end

return self
end

return hardware_config
