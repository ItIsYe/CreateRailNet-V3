





local M={}

local MOD=65521
local BLOCK=256

function M.sum(text)
local a,b=1,0
local n=#text
local i=1
while i<=n do
local j=i+BLOCK-1
if j>n then j=n end
local bytes={string.byte(text,i,j)}
for k=1,#bytes do
a=a+bytes[k]
b=b+a
end
a=a%MOD
b=b%MOD
i=j+1
end
return b*65536+a
end

function M.hex(text)
return string.format("%08x",M.sum(text))
end

return M
