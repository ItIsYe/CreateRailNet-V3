--[[
Purpose: Grafisches Gleisbild (schematic track diagram).
Renders blocks as segments on the monitor, colored by state.
Each block in config can have a gleisbild_pos = {x, y, w, dir}
for its position on the diagram. Falls back to a list view if no positions defined.
]]

local ui_utils = require("src.master.ui.ui_utils")
local gleisbild = {}

-- Block state → character for the track segment
local TRACK_CHARS = {
  FREE       = "-",  -- free track
  RESERVED   = "R",  -- reserved for a train
  OCCUPIED   = "O",  -- occupied (train present)
  FAULT      = "!",  -- fault
}

-- Direction → track character variant
local DIR_CHARS = {
  horizontal = "-",
  vertical   = "|",
  curve_lt   = "/",
  curve_rb   = "\\",
  switch_l   = "<",
  switch_r   = ">",
}

function gleisbild.new(dispatcher, registry, interlocking_ref)
  local panel = {}
  local C = ui_utils.colors

  local function build_layout(overview, config_blocks)
    -- If blocks have gleisbild_pos defined, use them
    -- Otherwise auto-layout in a horizontal list
    local positioned = {}
    local has_positions = false

    if config_blocks then
      for _, bcfg in ipairs(config_blocks) do
        if bcfg.gleisbild_pos then
          positioned[bcfg.id] = bcfg.gleisbild_pos
          has_positions = true
        end
      end
    end

    return positioned, has_positions
  end

  function panel.draw(monitor)
    if not monitor then return end
    local u = ui_utils.new(monitor)
    local w, h = u.size()
    u.clear(C.black)
    u.header(1, "GLEISBILD", nil, w)

    local bdata = dispatcher and dispatcher.get_overview and dispatcher.get_overview() or {}
    local il_routes = interlocking_ref and interlocking_ref.list and interlocking_ref.list() or {}

    -- Count blocks by state for summary bar
    local free, res, occ, flt = 0, 0, 0, 0
    for _, b in pairs(bdata) do
      if b.state == "FREE" then free = free + 1
      elseif b.state == "RESERVED" then res = res + 1
      elseif b.state == "OCCUPIED" then occ = occ + 1
      else flt = flt + 1 end
    end

    -- Summary line
    u.fill_line(2, C.black, w)
    u.write_at(1,  2, "Frei:"  .. free, C.lime)
    u.write_at(9,  2, "Res:"   .. res,  C.yellow)
    u.write_at(17, 2, "Bes:"   .. occ,  C.orange)
    if flt > 0 then u.write_at(25, 2, "STOER:" .. flt, C.white, C.red) end

    -- Active Fahrstraßen
    local il_list = {}
    for id, rs in pairs(il_routes) do
      if rs.status ~= "VACANT" then table.insert(il_list, {id=id, rs=rs}) end
    end
    if #il_list > 0 then
      u.fill_line(3, C.black, w)
      u.write_at(1, 3, "Fahrstrassen: ", C.cyan)
      local fx = 15
      for _, il in ipairs(il_list) do
        local col = (il.rs.status == "SET" and C.lime) or (il.rs.status == "OCCUPIED" and C.orange) or C.yellow
        local label = tostring(il.id):sub(1,8) .. "=" .. tostring(il.rs.status):sub(1,4)
        if fx + #label < w then u.write_at(fx, 3, label, col); fx = fx + #label + 2 end
      end
    end

    -- ── Gleisbild rendering ────────────────────────────────────────
    -- Sort blocks for display
    local blocks = {}
    for id, b in pairs(bdata) do table.insert(blocks, {id=id, b=b}) end
    table.sort(blocks, function(a,x) return a.id < x.id end)

    -- Check if we have gleisbild positions in config
    local config_blocks = dispatcher and dispatcher.get_config_blocks and dispatcher.get_config_blocks()
    local positioned, has_positions = build_layout(bdata, config_blocks)

    if has_positions then
      -- Positioned rendering: draw each block at its configured coordinates
      local base_row = 4
      for _, entry in ipairs(blocks) do
        local pos = positioned[entry.id]
        if pos then
          local bx = (pos.x or 1)
          local by = (pos.y or 1) + base_row
          local bw = pos.w or 3
          if by <= h - 3 then
            local b = entry.b
            local state_col = (ui_utils.STATE_COLORS[b.state] or {fg=C.white}).fg
            local track_char = TRACK_CHARS[b.state] or "-"
            local dir_char = DIR_CHARS[pos.dir or "horizontal"] or track_char
            local segment = string.rep(dir_char, bw)
            -- Draw track segment
            u.write_at(bx, by, segment, state_col)
            -- Draw block ID below
            if by + 1 <= h - 3 then
              u.write_at(bx, by+1, tostring(entry.id):sub(1,bw), C.lightGray)
            end
            -- Show train if occupied
            local owner = (b.occupied_by or b.reserved_by or ""):sub(1, bw)
            if owner ~= "" and by + 2 <= h - 3 then
              u.write_at(bx, by+2, owner, C.yellow)
            end
          end
        end
      end
    else
      -- Auto-layout: horizontal list of blocks, 2 rows each
      -- Show up to (w-2)/6 blocks per row
      local col_w = 6
      local cols = math.max(1, math.floor((w) / col_w))
      local row = 4
      local col = 0
      for _, entry in ipairs(blocks) do
        if row > h - 3 then break end
        local b = entry.b
        local state_col = (ui_utils.STATE_COLORS[b.state] or {fg=C.white}).fg
        local track_char = TRACK_CHARS[b.state] or "-"
        local x = col * col_w + 1

        -- Track segment
        u.write_at(x, row, "[" .. track_char .. track_char .. track_char .. "]", state_col)
        -- Block ID
        u.write_at(x, row+1, tostring(entry.id):sub(1,col_w), C.lightGray)

        -- Interlocking route
        local il_r = b.interlocking_route
        if il_r then
          u.write_at(x, row+2, tostring(il_r):sub(1,col_w), C.cyan)
        end

        col = col + 1
        if col >= cols then col = 0; row = row + 3 end
      end

      if not has_positions then
        u.write_at(1, h-2, "Tipp: gleisbild_pos in Config fuer grafisches Stellwerk", C.lightGray)
      end
    end

    -- Nodes status strip
    local nodes = registry and registry.all and registry.all() or {}
    local n_down = 0
    for _, n in pairs(nodes) do if n.status ~= "ONLINE" then n_down = n_down + 1 end end
    local node_str = n_down > 0 and (n_down .. " Node(s) OFFLINE!") or "Alle Nodes online"
    local node_col = n_down > 0 and C.red or C.lime
    u.write_at(w - #node_str, h-1, node_str, node_col)

    u.footer(h, "Gleisbild | Rot=STOER Gelb=RES Orange=BES Gruen=FREI", w)
  end

  function panel.touch(x, y) end  -- future: click on block for details

  return panel
end

return gleisbild
