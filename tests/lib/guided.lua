--[[
Purpose: Gemeinsamer Aufbau fuer Tests der gefuehrten Einrichtung: Leitstelle mit einem Bereich, ein leerer Computer mit Signalen, Ablauf bis zum Bildschirm "Signale zuordnen".
API: guided.setup{ pattern, tracks, signals, ends } -> h, z, d, v, netz; guided.screen(d)
]]

local H = dofile("tests/lib/harness.lua")

local G = {}

function G.setup(opts)
  opts = opts or {}
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local netz = z.node.roles.zentrale.netz
  netz.add_area({ name = "West-Ost", ends = opts.ends or { "Westbahnhof", "Ostbahnhof" }, count = opts.tracks or 2, pattern = opts.pattern or "gegenlaeufig" })
  local d = h.add_blank({ id = "neu" })
  for i = 1, opts.signals or 2 do d.world.add_signal("Create_Signal_" .. i) end
  h.step(1)
  local v = d.view()
  v.set_page("einrichtung")
  d.tap(v, "act:start")
  d.tap(v, "sel:modus:2"); d.tap(v, "act:weiter")
  h.step(5); d.node.render()
  d.tap(v, "sel:netzwahl:1"); d.tap(v, "act:weiter")
  d.tap(v, "sel:rollen:5"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  d.tap(v, "sel:bereich:1")
  h.step(3); d.node.render()
  d.tap(v, "act:weiter"); d.tap(v, "act:weiter")
  h.step(3); d.node.render()
  return h, z, d, v, netz
end

function G.screen(d) return d.node.setup.session().screen end

return G
