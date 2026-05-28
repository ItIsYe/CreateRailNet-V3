--[[
Purpose: Shared state model for external panel nodes.
Public API: new(config, panel_id) -> state with update, set_page, next_page, snapshot.
]]

local panel_state = {}

local DEFAULT_PAGES = { "overview", "trains", "stations", "depots", "service_plans", "diagnostics" }

local function copy_table(src)
  local dst = {}
  for k, v in pairs(src or {}) do
    if type(v) == "table" then dst[k] = copy_table(v) else dst[k] = v end
  end
  return dst
end

local function find_panel_config(config, panel_id)
  for _, node in ipairs((config and config.nodes) or {}) do
    if node.id == panel_id then return node end
  end
  return { id = panel_id, role = "panel" }
end

function panel_state.new(config, panel_id)
  local panel_cfg = find_panel_config(config, panel_id)
  local pages = panel_cfg.pages or DEFAULT_PAGES
  local state = {
    panel_id = panel_id,
    display_name = panel_cfg.display_name or panel_id,
    pages = pages,
    page_index = 1,
    page = pages[1] or "overview",
    master_state = "UNKNOWN",
    last_update = 0,
    overview = {},
    trains = {},
    stations = {},
    depots = {},
    service_plans = {},
    diagnostics = {}
  }

  local self = {}

  function self.update(payload)
    if type(payload) ~= "table" then return end
    state.master_state = payload.master_state or "ONLINE"
    state.last_update = os.clock()
    if payload.overview then state.overview = copy_table(payload.overview) end
    if payload.trains then state.trains = copy_table(payload.trains) end
    if payload.stations then state.stations = copy_table(payload.stations) end
    if payload.depots then state.depots = copy_table(payload.depots) end
    if payload.service_plans then state.service_plans = copy_table(payload.service_plans) end
    if payload.diagnostics then state.diagnostics = copy_table(payload.diagnostics) end
  end

  function self.set_page(page)
    for i, candidate in ipairs(state.pages) do
      if candidate == page then state.page_index = i; state.page = page; return true end
    end
    return false
  end

  function self.next_page()
    if #state.pages == 0 then return nil end
    state.page_index = state.page_index + 1
    if state.page_index > #state.pages then state.page_index = 1 end
    state.page = state.pages[state.page_index]
    return state.page
  end

  function self.previous_page()
    if #state.pages == 0 then return nil end
    state.page_index = state.page_index - 1
    if state.page_index < 1 then state.page_index = #state.pages end
    state.page = state.pages[state.page_index]
    return state.page
  end

  function self.snapshot()
    return state
  end

  return self
end

return panel_state
