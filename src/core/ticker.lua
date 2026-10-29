--[[
Purpose: Wiederkehrende und einmalige Aufgaben nach Betriebszeit. Die Schleife ruft poll() bei jedem Ereignis und nach jedem Timer auf; ein verlorener Timer verzoegert nur, er verpasst nichts. Nach einer Verspaetung wird die Aufgabe einmal ausgefuehrt, nicht mehrfach nachgeholt.
API: ticker.new(clock) -> k; k.every(name, seconds, fn); k.after(name, seconds, fn); k.cancel(name); k.poll() -> Anzahl; k.next_delay() -> Sekunden oder nil; k.errors() -> Liste
Notes: Ein Fehler in einer Aufgabe stoppt weder die anderen noch die Schleife; er wird gemerkt (errors) und die Aufgabe laeuft zum naechsten Termin wieder. Auf CC:Tweaked gehen Ereignisse verloren, wenn 256 in der Warteschlange liegen (auch Timer): nie auf genau einen Timer warten.
]]

local M = {}

function M.new(clock)
  local k = {}
  local tasks = {}
  local errs = {}

  function k.every(name, seconds, fn)
    tasks[name] = { seconds = seconds, fn = fn, due = clock.now() + seconds, repeating = true }
  end

  function k.after(name, seconds, fn)
    tasks[name] = { seconds = seconds, fn = fn, due = clock.now() + seconds, repeating = false }
  end

  function k.cancel(name) tasks[name] = nil end

  function k.poll()
    local now = clock.now()
    local due = {}
    for name, task in pairs(tasks) do
      if task.due <= now then due[#due + 1] = name end
    end
    table.sort(due, function(a, b)
      if tasks[a].due ~= tasks[b].due then return tasks[a].due < tasks[b].due end
      return a < b
    end)
    local ran = 0
    for _, name in ipairs(due) do
      local task = tasks[name]
      if task then
        if task.repeating then task.due = now + task.seconds else tasks[name] = nil end
        local ok, err = pcall(task.fn)
        ran = ran + 1
        if not ok then
          errs[#errs + 1] = { name = name, error = tostring(err), time = now }
          if #errs > 20 then table.remove(errs, 1) end
        end
      end
    end
    return ran
  end

  function k.next_delay()
    local best
    for _, task in pairs(tasks) do
      if not best or task.due < best then best = task.due end
    end
    if not best then return nil end
    return math.max(0, best - clock.now())
  end

  function k.errors() return errs end

  return k
end

return M
