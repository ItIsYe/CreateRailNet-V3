--[[
Purpose: Finds the monitor of a computer. Real monitors are called monitor_0 (over a cable) or like the side they sit on, never just
  "monitor", so asking for the name "monitor" finds nothing in the game.
Public API: resolve(peripherals, name, scale) -> monitor | nil, note
  peripherals: the wrapper of src/adapter/peripherals.lua (wrap, list, get_type)
  name: the monitor the plan names (entry field "monitor"), or nil
  scale: the text scale the plan asks for (entry field "monitor_scale"), or nil to leave the monitor as it is
  valid_scale(scale) -> boolean   a number from 0.5 to 5 in steps of 0.5 (what CC:Tweaked's setTextScale takes)
Notes: a smaller text scale puts more characters on the same monitor (a 3 x 2 block monitor: about 29 x 19 characters at scale 1, about 58 x 24 at 0.5).
  A scale that is not valid, a monitor without setTextScale or a call that fails is not an error: the monitor is used as it is and `note` says what was wrong, for the log.
  order: the named monitor; the old default name "monitor" (plans and tests written before); the first monitor by type (names
  sorted, so it is the same one on every start). A named monitor that is missing does not stop the display: the first monitor is used
  and `note` says what was wrong, for the log.
]]

local monitors = {}

function monitors.valid_scale(scale)
  return type(scale) == "number" and scale >= 0.5 and scale <= 5 and scale * 2 == math.floor(scale * 2)
end

local function say(note, text)
  if note then return note .. "; " .. text end
  return text
end

-- the text scale of the plan, applied to the monitor that was found
local function scaled(found, note, scale)
  if not found or scale == nil then return found, note end
  if not monitors.valid_scale(scale) then
    return found, say(note, "monitor_scale " .. tostring(scale) .. " is not valid (0.5 to 5 in steps of 0.5), ignored")
  end
  if type(found.setTextScale) ~= "function" then return found, say(note, "monitor_scale: this monitor has no setTextScale") end
  local ok, err = pcall(found.setTextScale, scale)
  if not ok then return found, say(note, "monitor_scale " .. tostring(scale) .. " failed: " .. tostring(err)) end
  return found, note
end

function monitors.resolve(peripherals, name, scale)
  local found, note = monitors.find(peripherals, name)
  return scaled(found, note, scale)
end

function monitors.find(peripherals, name)
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
