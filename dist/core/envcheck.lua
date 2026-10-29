--[[
Purpose: Schnittstellenpruefung nach einem Modpack-Update (Konzept 14.1, A18): aus dem Host (CC-Version) und den Methodenlisten der vorhandenen Create-Geraete wird ein Abdruck gebildet und gespeichert. Weicht er beim naechsten Start vom gespeicherten ab, bleibt die Automatik angehalten, bis der Bediener die Pruefung bestanden hat.
API: envcheck.signature(scan, host) -> Text; envcheck.check(store, path, scan, host) -> status ("erstmals" | "gleich" | "geaendert"), alt, neu; envcheck.accept(store, path, scan, host) -> ok
Notes: Es zaehlen nur Art und Methoden der Create-Geraete (Bahnhof, Signal, Beobachter) und der Host-Text; Namen der Geraete und andere Peripherals aendern den Abdruck nicht. "geaendert" ueberschreibt den gespeicherten Abdruck nicht - das geschieht erst mit accept nach bestandener Pruefung.
]]

local adler = require("core.adler")

local M = {}

local KINDS = { "station", "signal", "observer" }

function M.signature(scan, host)
  local parts = { "host=" .. tostring(host or "?") }
  for _, kind in ipairs(KINDS) do
    local names
    for _, d in ipairs(scan) do
      if d.kind == kind then
        local list = {}
        for m in pairs(d.methods or {}) do list[#list + 1] = m end
        table.sort(list)
        local joined = table.concat(list, ",")
        -- mehrere Geraete derselben Art: der kleinste gemeinsame Satz zaehlt (fehlt irgendwo eine Methode, aendert sich der Abdruck)
        if names == nil or #joined < #names then names = joined end
      end
    end
    if names then parts[#parts + 1] = kind .. "=" .. adler.hex(names) end
  end
  return table.concat(parts, ";")
end

function M.check(store, path, scan, host)
  local current = M.signature(scan, host)
  local saved = store.load(path)
  if not saved or type(saved.signature) ~= "string" then
    store.save(path, { signature = current })
    return "erstmals", nil, current
  end
  if saved.signature == current then return "gleich", saved.signature, current end
  return "geaendert", saved.signature, current
end

function M.accept(store, path, scan, host)
  return store.save(path, { signature = M.signature(scan, host) })
end

return M
