






local json=require("src.shared.json")
local safe_write=require("src.shared.safe_write")

local election_store={}

election_store.DEFAULT_PATH="state/election.json"

function election_store.new(path,opts)
local self={}
local file=path or election_store.DEFAULT_PATH
local io_opts={fs=opts and opts.fs}

function self.load()
local body,err=safe_write.read_with_backup(file,io_opts)
if not body then
if err=="missing" then return nil end
return nil,err
end
local ok,decoded=pcall(json.decode,body)
if not ok or type(decoded)~="table" or type(decoded.term)~="number" then return nil,"election state is not readable" end
return{term=decoded.term,voted_for=type(decoded.voted_for)=="string" and decoded.voted_for or nil}
end

function self.save(term,voted_for)
return safe_write.write(file,json.encode({v=1,term=term,voted_for=voted_for}),io_opts)
end

return self
end

return election_store
