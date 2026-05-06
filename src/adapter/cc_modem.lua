--[[
Purpose: CC:Tweaked modem transport adapter compatible with shared net module.
Public API: new(opts), open(), send(channel,dst,msg), broadcast(channel,msg), poll(event).
]]

local cc_modem = {}

function cc_modem.new(opts)
  local options = opts or {}
  local peripheral_api = options.peripheral_api or _G.peripheral
  local modem = options.modem
  local reply_channel = options.reply_channel

  if not modem and peripheral_api and peripheral_api.find then
    local ok, found = pcall(peripheral_api.find, "modem")
    if ok then
      modem = found
    end
  end

  local self = { modem = modem, reply_channel = reply_channel or options.channel }

  function self.open(channel)
    if not self.modem then
      return false, "modem unavailable"
    end
    local ok, err = pcall(self.modem.open, channel)
    if not ok then
      return false, "modem open failed: " .. tostring(err)
    end
    return true
  end

  function self.send(channel, dst, msg)
    if not self.modem then
      return false, "modem unavailable"
    end
    local ok, err = pcall(self.modem.transmit, channel, self.reply_channel, msg)
    if not ok then
      return false, "modem transmit failed: " .. tostring(err)
    end
    return true
  end

  function self.broadcast(channel, msg)
    return self.send(channel, "broadcast", msg)
  end

  function self.poll(event)
    if type(event) ~= "table" or event[1] ~= "modem_message" then
      return nil
    end
    return event[5]
  end

  return self
end

return cc_modem
