--[[
Purpose: CC:Tweaked modem transport adapter compatible with shared net module.
Public API: new(opts), for_node(cfg, node_id, opts), and the methods that net and the nodes call with a colon (modem:open(channel),
  modem:send(channel, dst, msg), modem:broadcast(channel, msg), modem:poll(event)). They are methods: defined with a dot they would take the
  adapter itself for the channel, and a real modem refuses that (tests/test_cc_modem.lua uses a modem that checks its arguments).
  opts.modem_name: use exactly this modem (entry field "modem"); a missing one is not replaced by another, the modem stays unavailable
Notes: without a name a wireless modem is preferred (the net runs over radio; a wired modem next to it carries a monitor), otherwise the first modem is used. With several modems of the same kind that is a guess, so the setup wizard writes the name into the plan.
]]

local cc_modem = {}

function cc_modem.new(opts)
  local options = opts or {}
  local peripheral_api = options.peripheral_api or _G.peripheral
  local modem = options.modem
  local reply_channel = options.reply_channel

  if not modem and type(options.modem_name) == "string" and options.modem_name ~= "" then
    if peripheral_api and peripheral_api.wrap then
      local ok, wrapped = pcall(peripheral_api.wrap, options.modem_name)
      if ok then modem = wrapped end
    end
  elseif not modem and peripheral_api then
    -- a wireless modem first: with a wired and a wireless modem on one computer "the first modem" may be the cable one, which does not reach the other computers
    if peripheral_api.getNames and peripheral_api.getType and peripheral_api.call and peripheral_api.wrap then
      local ok_names, names = pcall(peripheral_api.getNames)
      if ok_names and type(names) == "table" then
        table.sort(names)
        for _, name in ipairs(names) do
          local ok_type, kind = pcall(peripheral_api.getType, name)
          if ok_type and kind == "modem" then
            local ok_wireless, wireless = pcall(peripheral_api.call, name, "isWireless")
            if ok_wireless and wireless == true then
              local ok_wrap, wrapped = pcall(peripheral_api.wrap, name)
              if ok_wrap and wrapped then modem = wrapped; break end
            end
          end
        end
      end
    end
    if not modem and peripheral_api.find then
      local ok, found = pcall(peripheral_api.find, "modem")
      if ok then
        modem = found
      end
    end
  end

  local self = { modem = modem, reply_channel = reply_channel or options.channel, modem_name = options.modem_name }

  function self:open(channel)
    if not self.modem then
      return false, "modem unavailable"
    end
    local ok, err = pcall(self.modem.open, channel)
    if not ok then
      return false, "modem open failed: " .. tostring(err)
    end
    return true
  end

  function self:send(channel, dst, msg)
    if not self.modem then
      return false, "modem unavailable"
    end
    local ok, err = pcall(self.modem.transmit, channel, self.reply_channel, msg)
    if not ok then
      return false, "modem transmit failed: " .. tostring(err)
    end
    return true
  end

  function self:broadcast(channel, msg)
    return self:send(channel, "broadcast", msg)
  end

  function self:poll(event)
    if type(event) ~= "table" or event[1] ~= "modem_message" then
      return nil
    end
    return event[5]
  end

  return self
end

-- the modem of a computer as its plan entry names it (field "modem"); the channel comes from the plan
function cc_modem.for_node(cfg, node_id, opts)
  local o = {}
  for key, value in pairs(opts or {}) do o[key] = value end
  o.channel = o.channel or (cfg and cfg.channel)
  for _, node in ipairs((cfg and cfg.nodes) or {}) do
    if node.id == node_id and type(node.modem) == "string" and node.modem ~= "" then o.modem_name = node.modem end
  end
  return cc_modem.new(o)
end

return cc_modem
