--[[
Purpose: Resolve node hardware configuration for adapters.
Public API: new(config) -> resolver with node(id), target(id), adapter(id), side(id), value(id, key). Entries added to config.nodes later are found.

Node config fields:
  adapter    "peripheral" (default) | "redstone"
  peripheral  peripheral name for adapter="peripheral" (e.g. "Create_Signal_0")
  side        redstone side for adapter="redstone" (e.g. "left", "top", "right")
  invert      boolean, for redstone switches: invert the output signal
  active_position  for redstone switches: which position = active signal ("DIVERGING" default)

Create mod specific notes:
  Signals:  use adapter="peripheral", peripheral="Create_Signal_0"
            Only setForcedRed(bool) is available in vanilla Create.
  Sensors:  use adapter="peripheral", peripheral="Create_TrainObserver_0"
            isTrainPassing() and getPassingTrainName() available.
  Switches: MUST use adapter="redstone", side="left" (etc.)
            Vanilla Create track switches have NO CC:Tweaked peripheral.
  Station:  not a hardware node; configured directly in train/route nodes.
]]

local hardware_config = {}

function hardware_config.new(config)
  -- Follows the plan: the master appends the entry of a computer it accepts to config.nodes while it runs, and that entry has to be found
  -- (the index is built again when the number of entries changed).
  local by_id, indexed = {}, -1
  local function index()
    local nodes = config and config.nodes
    if type(nodes) ~= "table" then return by_id end
    if #nodes ~= indexed then
      by_id, indexed = {}, #nodes
      for _, node in ipairs(nodes) do
        if type(node) == "table" and node.id then by_id[node.id] = node end
      end
    end
    return by_id
  end

  local self = {}

  function self.node(id)
    return index()[id] or { id = id }
  end

  function self.adapter(id)
    local node = self.node(id)
    return node.adapter or "peripheral"
  end

  function self.target(id)
    local node = self.node(id)
    return node.peripheral or node.target or id
  end

  function self.side(id)
    local node = self.node(id)
    return node.side
  end

  function self.value(id, key)
    local node = self.node(id)
    return node[key]
  end

  return self
end

return hardware_config
