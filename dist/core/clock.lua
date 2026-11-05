





local M={}

function M.new(opts)
local c={}
local saved=opts.store.load(opts.path)
local base=(saved and tonumber(saved.t))or 0
local boots=((saved and tonumber(saved.boots))or 0)+1
local resumed=saved~=nil
local boot_raw=opts.raw()

function c.now()return base+(opts.raw()-boot_raw)end
function c.boot_id()return boots end
function c.resumed()return resumed end

function c.save()
return opts.store.save(opts.path,{t=c.now(),boots=boots})
end

c.save()
return c
end

return M
