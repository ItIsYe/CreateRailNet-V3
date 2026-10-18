--[[
Purpose: Terminal output and questions of the installer.
Public API: new(env) -> ui
  env: print(text), write(text), read() -> line
  ui.header(title), ui.info(text), ui.warn(text), ui.error(text), ui.ok(text), ui.progress(done, total, label)
  ui.select_role(roles) -> key | nil        numbered menu
  ui.confirm(question, default_yes) -> boolean
]]

local ui_module = {}

function ui_module.new(env)
  local self = {}
  local function say(text) pcall(env.print, tostring(text)) end

  function self.header(title) say(""); say("=== " .. tostring(title) .. " ==="); say("") end
  function self.info(text) say("[INFO] " .. tostring(text)) end
  function self.warn(text) say("[WARN] " .. tostring(text)) end
  function self.error(text) say("[ERR ] " .. tostring(text)) end
  function self.ok(text) say("[ OK ] " .. tostring(text)) end

  function self.progress(done, total, label)
    local percent = total > 0 and math.floor(done / total * 100) or 100
    say(string.format("  [%3d%%] %d/%d %s", percent, done, total, tostring(label or "")))
  end

  function self.select_role(roles)
    say("")
    for i, role in ipairs(roles) do say(string.format("  %d) %-8s %s", i, role.label, role.text)) end
    say("")
    pcall(env.write, "Rolle dieses Computers [1-" .. #roles .. "]: ")
    local choice = tonumber(env.read() or "")
    if choice and roles[choice] then return roles[choice].key end
    return nil
  end

  function self.confirm(question, default_yes)
    local hint = default_yes and "[J/n]" or "[j/N]"
    while true do
      pcall(env.write, question .. " " .. hint .. ": ")
      local answer = tostring(env.read() or ""):lower()
      if answer == "" then return default_yes == true end
      if answer == "j" or answer == "ja" or answer == "y" or answer == "yes" then return true end
      if answer == "n" or answer == "nein" or answer == "no" then return false end
      say("Bitte j oder n eingeben.")
    end
  end

  return self
end

return ui_module
