--[[
Purpose: Kleine Pruefhilfen fuer die Tests (eq, ok, contains, raises). Wirft bei Fehlschlag einen Fehler mit lesbarem Text; der Testlaeufer faengt ihn ab.
]]

local M = {}

local function show(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function M.eq(actual, expected, message)
  if actual ~= expected then
    error((message or "eq") .. ": erwartet " .. show(expected) .. ", erhalten " .. show(actual), 2)
  end
end

function M.ok(value, message)
  if not value then error(message or "ok: Wert ist falsch", 2) end
end

function M.contains(text, part, message)
  if type(text) ~= "string" or not text:find(part, 1, true) then
    error((message or "contains") .. ": '" .. tostring(part) .. "' nicht gefunden in " .. show(text), 2)
  end
end

function M.not_contains(text, part, message)
  if type(text) == "string" and text:find(part, 1, true) then
    error((message or "not_contains") .. ": '" .. tostring(part) .. "' unerwartet gefunden", 2)
  end
end

function M.raises(fn, part, message)
  local ok, err = pcall(fn)
  if ok then error((message or "raises") .. ": es wurde kein Fehler geworfen", 2) end
  if part and not tostring(err):find(part, 1, true) then
    error((message or "raises") .. ": Fehler " .. show(tostring(err)) .. " enthaelt nicht '" .. part .. "'", 2)
  end
end

return M
