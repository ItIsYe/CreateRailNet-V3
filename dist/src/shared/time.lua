













local time={}


function time.now_ms()
return math.floor(os.clock()*1000)
end




function time.now_s()
if os.epoch then
return math.floor(os.epoch("utc")/1000)
end

return os.time and os.time()or math.floor(os.clock())
end

return time
