












local window_buffer={}

function window_buffer.new(monitor,opts)
local options=opts or{}
local api=options.window
if api==nil then api=_G.window end
local self={}
local win,width,height=nil,nil,nil

local function monitor_size()
if not(monitor and monitor.getSize)then return nil end
local ok,w,h=pcall(monitor.getSize)
if ok and w and h then return w,h end
return nil
end

function self.buffered()
return win~=nil
end

function self.begin()
if not(api and api.create)then return monitor end
local w,h=monitor_size()
if not w then return monitor end
if not win or w~=width or h~=height then
local ok,created=pcall(api.create,monitor,1,1,w,h,false)
if not ok or not created then win=nil;return monitor end
win,width,height=created,w,h
end
return win
end

function self.finish()
if not win then return false end

local ok=pcall(function()win.setVisible(true);win.setVisible(false)end)
return ok
end

function self.abort()
if win then pcall(win.setVisible,false)end
end

return self
end

return window_buffer
