--[[
Purpose: Overview panel — live block map, train positions, node health.
Like a real railway control centre: blocks colored by state, trains named.
]]

local ui_utils = require("src.master.ui.ui_utils")
local overview = {}

function overview.new(dispatcher, registry)
  local panel = {}

  local function sorted_pairs(t, key_fn)
    local list = {}
    for k, v in pairs(t or {}) do table.insert(list, { k=k, v=v }) end
    table.sort(list, function(a,b) return (key_fn and key_fn(a) or a.k) < (key_fn and key_fn(b) or b.k) end)
    return list
  end

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    local C = ui_utils.colors

    u.clear(C.black)

    -- ── Header ─────────────────────────────────────────────────────
    u.header(1, "NETWORK OVERVIEW", nil, w)

    -- ── Block map ──────────────────────────────────────────────────
    local row = 3
    local bdata = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    local blocks = sorted_pairs(bdata)

    u.write_at(1, row, "STRECKENBLOECKE", C.cyan)
    row = row + 1

    local col_w = math.floor(w / 2) - 1
    local left_row, right_row = row, row
    for i, entry in ipairs(blocks) do
      local b = entry.v
      local target_row, target_col
      if i % 2 == 1 then
        target_row = left_row; target_col = 1
        left_row = left_row + 1
      else
        target_row = right_row; target_col = w - col_w + 1
        right_row = right_row + 1
      end
      if target_row > h - 6 then break end

      -- Block badge
      u.state_badge(target_col, target_row, b.state)
      -- Block ID
      local bid = tostring(entry.k):sub(1, col_w - 6)
      u.write_at(target_col + 5, target_row, bid, C.white)
      -- Owner (train) if occupied/reserved
      local owner = b.occupied_by or b.reserved_by or ""
      if owner ~= "" then
        local ow = tostring(owner):sub(1, col_w - #bid - 6)
        u.write_at(target_col + 5 + #bid + 1, target_row, ow, C.yellow)
      end
    end

    row = math.max(left_row, right_row) + 1
    if row > h - 5 then row = h - 5 end

    -- ── Node health summary ────────────────────────────────────────
    u.separator(row, w); row = row + 1
    local nodes = registry and registry.all and registry.all() or {}
    local up, down_n, total = 0, 0, 0
    local roles = {}
    for _, n in pairs(nodes) do
      total = total + 1
      if n.status == "ONLINE" then up = up + 1 else down_n = down_n + 1 end
      roles[n.role or "?"] = (roles[n.role or "?"] or 0) + 1
    end
    u.write_at(1, row, "NODES ", C.cyan)
    u.write_at(7, row, string.format("Online: %d", up), C.lime)
    if down_n > 0 then
      u.write_at(20, row, string.format("Offline: %d", down_n), C.red)
    end
    u.write_at(w - 8, row, string.format("Total:%d", total), C.lightGray)
    row = row + 1

    -- Role breakdown
    local role_parts = {}
    local role_order = {"master","train","station","depot","signal","sensor","switch","panel"}
    for _, r in ipairs(role_order) do
      if roles[r] then
        table.insert(role_parts, roles[r] .. "×" .. r:sub(1,3))
      end
    end
    local role_str = table.concat(role_parts, "  ")
    u.write_at(1, row, role_str:sub(1, w), C.lightGray)

    -- ── Footer ────────────────────────────────────────────────────
    u.footer(h, "< Vor  |  Zurueck >  Seiten antippen", w)
  end

  function panel.touch(x, y) end

  return panel
end

return overview
