






local checksum={}

local MOD=65521
local BLOCK=4096

function checksum.adler32(text,tick)
local a,b=1,0
local length=#text
local position=1
while position<=length do
local last=position+BLOCK - 1
if last>length then last=length end
local bytes={string.byte(text,position,last)}
for i=1,#bytes do
a=a+bytes[i]
b=b+a
end

a=a%MOD
b=b%MOD
position=last+1
if tick and(position - 1)%(BLOCK*2)==0 then tick()end
end
return b*65536+a
end

function checksum.hex(value)
return string.format("%08x",value)
end

return checksum
