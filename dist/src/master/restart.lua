









local restart={}

function restart.build(opts)
local o=opts or{}
return function(operator)
local failed=0
if o.red~=false and o.dispatcher and o.dispatcher.shutdown_red then
local ok,count=pcall(o.dispatcher.shutdown_red)
if not ok then
failed=-1
if o.logger then o.logger.warn("signals to RED before the restart failed",{error=tostring(count)})end
elseif type(count)=="number" and count>0 then
failed=count
if o.logger then o.logger.warn("signals to RED before the restart: some did not answer",{failed=count})end
end
end
if o.logger then o.logger.info("master restarts",{by=operator})end
if not o.reboot then return false,"Dieser Computer kann nicht neu starten." end
o.reboot()
return true,"Neustart ..." ..(failed~=0 and " (nicht alle Signale haben ROT bestaetigt)" or "")
end
end

return restart
