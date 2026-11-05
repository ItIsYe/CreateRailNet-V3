




local M={}

local FALLBACK={
[258]="tab",[257]="enter",[259]="backspace",[265]="up",[264]="down",[263]="left",[262]="right",
[266]="pageUp",[267]="pageDown",[256]="escape",
}

function M.name(code)
local keys_table=rawget(_G,"keys")
if keys_table and keys_table.getName then
local ok,name=pcall(keys_table.getName,code)
if ok and name then return name end
end
return FALLBACK[code]
end

return M
