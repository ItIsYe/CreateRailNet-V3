--[[
Purpose: Finds the monitor of a computer. Real monitors are called monitor_0 (over a cable) or like the side they sit on, never just
  "monitor", so asking for the name "monitor" finds nothing in the game.
Public API: resolve(peripherals, name) -> monitor | nil, note
  peripherals: the wrapper of src/adapter/peripherals.lua (wrap, list, get_type)
  name: the monitor the plan names (entry field "monitor"), or nil
Notes: order: the named monitor; the old default name "monitor" (plans and tests written before); the first monitor by type (names
  sorted, so it is the same one on every start). A named monitor that is missing does not stop the display: the first monitor is used
  and `note` says what was wrong, for the log.
]]

local monitors = {}

function monitors.resolve(peripherals, name)
  if not (peripherals and peripherals.wrap) then return nil, "no peripheral access" end
  local note = nil
  if type(name) == "string" and name ~= "" then
    local wanted = peripherals.wrap(name)
    if wanted then return wanted end
    note = "monitor '" .. name .. "' not found"
  end
  if name ~= "monitor" then
    local legacy = peripherals.wrap("monitor")
    if legacy then return legacy, note end
  end
  if peripherals.list and peripherals.get_type then
    local ok, names = pcall(peripherals.list)
    if ok and type(names) == "table" then
      local sorted = {}
      for _, candidate in ipairs(names) do sorted[#sorted + 1] = tostring(candidate) end
      table.sort(sorted)
      for _, candidate in ipairs(sorted) do
        if peripherals.get_type(candidate) == "monitor" then
          local found = peripherals.wrap(candidate)
          if found then return found, note end
        end
      end
    end
  end
  return nil, note or "no monitor found"
end

return monitors
