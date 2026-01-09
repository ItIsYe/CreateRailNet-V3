--[[
Purpose: Validate network configuration with actionable errors.
Public API: validate_config(cfg) -> ok, errors.
]]

local validate = {}

local function add_error(errors, path, msg)
  table.insert(errors, string.format("%s: %s", path, msg))
end

function validate.validate_config(cfg)
  local errors = {}
  if type(cfg) ~= "table" then
    add_error(errors, "config", "must be an object")
    return false, errors
  end

  if cfg.v ~= 1 then
    add_error(errors, "v", "must be 1")
  end
  if type(cfg.channel) ~= "number" then
    add_error(errors, "channel", "must be a number")
  end
  if type(cfg.master_id) ~= "string" then
    add_error(errors, "master_id", "must be a string")
  end
  if type(cfg.blocks) ~= "table" then
    add_error(errors, "blocks", "must be an array")
  end
  if type(cfg.routes) ~= "table" then
    add_error(errors, "routes", "must be an array")
  end
  if type(cfg.nodes) ~= "table" then
    add_error(errors, "nodes", "must be an array")
  end

  for i, block in ipairs(cfg.blocks or {}) do
    local base = string.format("blocks[%d]", i)
    if type(block.id) ~= "string" then
      add_error(errors, base .. ".id", "must be a string")
    end
    if type(block.entry_signal) ~= "string" then
      add_error(errors, base .. ".entry_signal", "must be a string")
    end
    if type(block.exit_signal) ~= "string" then
      add_error(errors, base .. ".exit_signal", "must be a string")
    end
    if type(block.sensors) ~= "table" then
      add_error(errors, base .. ".sensors", "must be an array")
    end
    if type(block.switches) ~= "table" then
      add_error(errors, base .. ".switches", "must be an array")
    end
  end

  for i, route in ipairs(cfg.routes or {}) do
    local base = string.format("routes[%d]", i)
    if type(route.id) ~= "string" then
      add_error(errors, base .. ".id", "must be a string")
    end
    if type(route.blocks) ~= "table" then
      add_error(errors, base .. ".blocks", "must be an array")
    end
    if type(route.priority) ~= "number" then
      add_error(errors, base .. ".priority", "must be a number")
    end
  end

  for i, node in ipairs(cfg.nodes or {}) do
    local base = string.format("nodes[%d]", i)
    if type(node.id) ~= "string" then
      add_error(errors, base .. ".id", "must be a string")
    end
    if type(node.role) ~= "string" then
      add_error(errors, base .. ".role", "must be a string")
    end
  end

  return #errors == 0, errors
end

return validate
