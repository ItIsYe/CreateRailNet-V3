





local M = {}

local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

function M.compute(w, h)
if w >= 100 and h >= 40 then
return {
mode = "gross", w = w, h = h,
header = rect(1, 1, w, 3),
nav = rect(1, 4, 20, h - 3),
work = rect(22, 5, w - 22, h - 12),
hint = rect(22, h - 6, w - 22, 2),
actions = rect(22, h - 4, w - 22, 4),
nav_row_h = 3, action_row_h = 3,
}
end
if w >= 51 and h >= 19 then
return {
mode = "kompakt", w = w, h = h,
header = rect(1, 1, w, 1),
nav = rect(1, 2, w, 1),
work = rect(1, 4, w, h - 7),
hint = rect(1, h - 2, w, 1),
actions = rect(1, h - 1, w, 2),
nav_row_h = 1, action_row_h = 2,
}
end
return { mode = "status", w = w, h = h, work = rect(1, 1, w, h) }
end

return M
