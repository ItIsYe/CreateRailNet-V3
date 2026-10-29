--[[
Purpose: Betriebsuhr in Spielzeit (Ergaenzung E1): laeuft nur, solange der Computer an ist, und setzt nach einem Neustart beim gespeicherten Stand fort. Es gibt keinen Nachholen von verpassten Terminen. Ausserdem zaehlt sie die Starts (Boot-Kennung fuer eindeutige Nachrichten-IDs).
API: clock.new{raw, store, path} -> c; c.now() -> Sekunden; c.save(); c.boot_id(); c.resumed() -> true, wenn ein Stand geladen wurde
Notes: raw ist os.clock (Spielzeit des Computers, beginnt bei jedem Start neu); die Echtzeit (os.epoch) wird nicht verwendet, weil der Server langsamer als 20 Ticks/s laufen kann (Messwert: etwa 1,83 Echtsekunden je Spielsekunde).
]]

local M = {}

function M.new(opts)
  local c = {}
  local saved = opts.store.load(opts.path)
  local base = (saved and tonumber(saved.t)) or 0
  local boots = ((saved and tonumber(saved.boots)) or 0) + 1
  local resumed = saved ~= nil
  local boot_raw = opts.raw()

  function c.now() return base + (opts.raw() - boot_raw) end
  function c.boot_id() return boots end
  function c.resumed() return resumed end

  function c.save()
    return opts.store.save(opts.path, { t = c.now(), boots = boots })
  end

  c.save()
  return c
end

return M
