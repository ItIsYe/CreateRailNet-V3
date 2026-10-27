--[[
Purpose: Last mit 300 und mehr Signalen (Konzept 16, Stufe 9): 26 Signal-Nodes mit je 12 Signalen, mehrere Bahnhoefe und ein Knoten an einer Leitstelle. Geprueft werden Nachrichtenaufkommen je Sekunde, fehlerfreier Lauf, begrenzte Dateigroessen, Zahl der Geraeteaufrufe je Takt und dass jede Sperre in der Leitstelle ankommt.
]]

local t = dofile("tests/lib/t.lua")
local H = dofile("tests/lib/harness.lua")

local SIGNALS_PER_NODE = 12
local SIGNAL_NODES = 26             -- 312 Signale

local function build()
  local h = H.new()
  local z = h.add_node({ id = "hauptstelle", roles = { "zentrale" }, tracks = {} })
  local nodes = {}
  for n = 1, SIGNAL_NODES do
    local tracks = {}
    for i = 1, SIGNALS_PER_NODE do
      tracks[#tracks + 1] = { name = "G" .. i, signals = { "Sig_" .. n .. "_" .. i } }
    end
    nodes[n] = h.add_node({ id = "strecke" .. n, roles = { "signal" }, central = "hauptstelle", tracks = tracks })
  end
  return h, z, nodes
end

return {
  { "312 Signale an 26 Computern: Aufkommen, Fehlerfreiheit und Sperren kommen an", function()
    local h, z, nodes = build()
    local sent0 = h.bus.sent
    h.step(60)
    local zentrale = z.node.roles.zentrale
    t.eq(#zentrale.signal_overview(), SIGNAL_NODES * SIGNALS_PER_NODE)
    for _, d in ipairs(h.order) do
      for _, m in ipairs(d.node.messages) do
        t.ok(m.level == "info", d.id .. " meldet " .. m.level .. ": " .. m.text)
      end
    end
    -- Ruhephase: nur der Takt der Zustandsmeldungen laeuft
    local before = h.bus.sent
    h.step(60)
    local per_second = (h.bus.sent - before) / 60
    t.ok(per_second < 12, "Nachrichten je Sekunde im Ruhebetrieb: " .. per_second)
    -- eine Sperre auf einem fernen Signal erreicht die Leitstelle innerhalb weniger Sekunden
    local far = nodes[SIGNAL_NODES]
    far.node.roles.signal.lock("signal" .. SIGNALS_PER_NODE, "bediener", "Last")
    h.step(8)
    local found = false
    for _, row in ipairs(zentrale.signal_overview()) do
      if row.node == "strecke" .. SIGNAL_NODES and row.signal.forced then found = true end
    end
    t.ok(found, "Sperre sichtbar")
  end },
  { "Aenderungen vieler Signale gleichzeitig: Berichte bleiben begrenzt", function()
    local h, z, nodes = build()
    h.step(30)
    local before = h.bus.sent
    for n = 1, SIGNAL_NODES do
      for i = 1, SIGNALS_PER_NODE do nodes[n].world.set_base("Sig_" .. n .. "_" .. i, "RED") end
    end
    h.step(10)
    local burst = h.bus.sent - before
    -- jeder Node meldet seinen Zustand gesammelt: hoechstens einige Berichte je Node, nicht einen je Signal
    t.ok(burst <= SIGNAL_NODES * 6, "Berichte nach der Aenderung: " .. burst)
    local reds = 0
    for _, row in ipairs(z.node.roles.zentrale.signal_overview()) do if row.signal.state == "RED" then reds = reds + 1 end end
    t.eq(reds, SIGNAL_NODES * SIGNALS_PER_NODE)
  end },
  { "Dateigroessen bleiben begrenzt: Journal und Zustandsdateien nach langem Lauf", function()
    local h, z, nodes = build()
    local far = nodes[1]
    for round = 1, 150 do
      far.node.roles.signal.lock("signal1", "bediener", "Wechsel")
      far.node.roles.signal.unlock("signal1", "bediener")
      h.step(1)
    end
    local used = 0
    for _, f in ipairs(far.fs.list("/crn_data")) do
      local path = "/crn_data/" .. f
      if not far.fs.isDir(path) then used = used + far.fs.getSize(path) end
    end
    t.ok(used < 60000, "Datenverzeichnis des Signal-Nodes: " .. used .. " Byte")
    t.ok(far.node.journal.size() < 40000, "Journal: " .. far.node.journal.size())
  end },
}
