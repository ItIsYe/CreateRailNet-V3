--[[
Purpose: The installation journal. While it exists, an installation is unfinished: startup.lua does not start the role but resumes it.
Public API: new(env) -> journal
  env: fs, safe_write
  journal.write(state, data) -> true | false, err    state "PREPARED" | "INSTALLING"; data: ref, role, id, files
  journal.read() -> table | nil
  journal.clear()                                      installation finished (removes the journal and its backup copies)
Notes: lives next to startup.lua, outside of everything the installer replaces. Written with src/shared/safe_write.lua (backup copy),
  so a crash while writing it leaves a readable journal; startup.lua only asks whether a file with this name exists.
]]

local journal = {}

journal.PATH = "crn_install_journal.lua"

function journal.new(env)
  local fsys = env.fs
  local self = {}

  function self.write(state, data)
    local d = data or {}
    local lines = {
      "return {\n",
      "  state = " .. string.format("%q", state) .. ",\n",
      "  ref = " .. string.format("%q", tostring(d.ref)) .. ",\n",
      "  role = " .. string.format("%q", tostring(d.role)) .. ",\n",
      "  id = " .. string.format("%q", tostring(d.id)) .. ",\n",
      "  files = {\n",
    }
    for _, path in ipairs(d.files or {}) do lines[#lines + 1] = "    " .. string.format("%q", path) .. ",\n" end
    lines[#lines + 1] = "  },\n}\n"
    return env.safe_write.write(journal.PATH, table.concat(lines), { fs = fsys })
  end

  function self.read()
    local body = env.safe_write.read_with_backup(journal.PATH, { fs = fsys })
    if not body then return nil end
    local chunk, result
    if setfenv then
      chunk = (loadstring or load)(body, "=journal")
      if chunk then setfenv(chunk, {}) end
    else
      chunk = load(body, "=journal", "t", {})
    end
    if not chunk then return nil end
    local ok
    ok, result = pcall(chunk)
    if ok and type(result) == "table" then return result end
    return nil
  end

  function self.clear()
    for _, path in ipairs({ journal.PATH, journal.PATH .. ".prev", journal.PATH .. ".tmp" }) do
      if fsys.exists(path) then pcall(fsys.delete, path) end
    end
  end

  return self
end

return journal
