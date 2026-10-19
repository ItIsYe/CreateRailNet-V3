--[[
Purpose: The installation itself: pick the role, fetch the manifest of one ref, replace only what differs, finish with the setup wizard.
Public API: returns function(deps) -> result table { role, ref, id, installed, unchanged, removed, needs_setup }
  deps: ref, args { role, yes, resume }, http, plan, stage, ui, journal, checksum, safe_write, startup_template,
        env { fs, shell, sleep, reboot, now }
Order (nothing is touched before the space check passes):
  1 existing startup.lua / install record -> role   2 manifest of the ref   3 compare with the disk   4 space check, copy of the installer itself
  5 journal INSTALLING   6 download + verify + replace every differing file (largest first)   7 remove files of the old version
  8 version file + install record   9 journal removed = finished   10 setup wizard (new computer) or reboot (update)
A crash or an error between 5 and 9 leaves the journal: startup.lua then runs `installer --resume` instead of the role, and the
next run continues where the disk is (files that already match are skipped).
]]

return function(deps)
  local fsys = deps.env.fs
  local ui, plan, stage, journal = deps.ui, deps.plan, deps.stage, deps.journal
  local args = deps.args or {}
  local ref = deps.ref
  local unattended = args.yes == true or args.resume == true

  local RECORD = "crn_install.lua"
  local VERSION_FILE = "crn_version.txt"

  local result = { installed = 0, unchanged = 0, removed = 0, needs_setup = false }

  ui.info("Ref: " .. ref)

  -- 1. what is on this computer already -------------------------------------------------------------------------
  local startup_text = stage.read("startup.lua")
  local existing = startup_text and deps.startup_template.parse(startup_text) or nil

  local function read_table(path)
    local body = stage.read(path)
    if not body then return nil end
    local value = plan.load_data(body, path)
    if type(value) == "table" then return value end
    return nil
  end
  local old_record = read_table(RECORD)

  local known_roles = {}
  for _, role in ipairs(plan.ROLES) do known_roles[role.key] = true end

  local role = args.role
  if role and not known_roles[role] then error("Unbekannte Rolle: " .. tostring(role), 0) end
  if not role and existing and known_roles[existing.role] then
    ui.info("Vorhandene Rolle: " .. existing.role .. " (" .. existing.id .. ")")
    if unattended or ui.confirm("Rolle '" .. existing.role .. "' behalten?", true) then role = existing.role end
  end
  if not role then
    if unattended then error("Die Rolle dieses Computers ist unbekannt: mit --role <rolle> angeben.", 0) end
    role = ui.select_role(plan.ROLES)
    if not role then error("Ungueltige Rolle.", 0) end
  end
  result.role, result.ref = role, ref
  local role_label = role
  for _, entry in ipairs(plan.ROLES) do if entry.key == role then role_label = entry.label end end
  ui.header("Installiere: " .. role_label)

  -- 2. manifest of exactly this ref -------------------------------------------------------------------------------
  local body, dl_err = deps.http.download_file(ref, "install/manifest.lua")
  if not body then error("Manifest: " .. tostring(dl_err), 0) end
  local manifest, parse_err = plan.parse_manifest(body)
  if not manifest then error("Manifest: " .. tostring(parse_err), 0) end
  local valid, valid_err = plan.validate(manifest)
  if not valid then error("Manifest ungueltig: " .. tostring(valid_err), 0) end
  local files, files_err = plan.files_for_role(manifest, role)
  if not files then error(files_err, 0) end
  result.id = manifest.id
  ui.info("Stand " .. manifest.id .. ", " .. (function() local n = 0; for _ in pairs(files) do n = n + 1 end; return n end)() .. " Dateien fuer diese Rolle")

  -- 3. what differs ---------------------------------------------------------------------------------------------
  local todo, unchanged = plan.diff(files, stage.read, function(text) return deps.checksum.adler32(text, deps.env.yield) end, function(path) return fsys.exists(path) end)
  result.unchanged = unchanged

  local obsolete = {}
  for _, path in ipairs(old_record and old_record.files or {}) do
    if not files[path] and type(path) == "string" and fsys.exists(path) then obsolete[#obsolete + 1] = path end
  end

  -- 4. does it fit? (before anything is changed) ----------------------------------------------------------------
  local planned, reclaimable, largest = 0, 0, 0
  for _, path in ipairs(todo) do
    planned = planned + files[path].size
    if files[path].size > largest then largest = files[path].size end
    local current = stage.read(path)
    if current then reclaimable = reclaimable + #current end
  end
  for _, path in ipairs(obsolete) do
    local current = stage.read(path)
    if current then reclaimable = reclaimable + #current end
  end
  -- the installer keeps a copy of itself (installer): an interrupted installation is resumed from startup.lua without typing the URL
  local own_copy = deps.http.download_file(ref, "installer")
  if own_copy and own_copy:sub(1, 4) == "--[[" and stage.read("installer") ~= own_copy then
    planned = planned + #own_copy
  else
    if not own_copy then ui.warn("Der Installer konnte sich selbst nicht ablegen (kein Problem fuer diese Installation).") end
    own_copy = nil
  end
  local fits, fit_err = stage.check_capacity(planned + largest, reclaimable)
  if not fits then error(fit_err, 0) end
  if own_copy then
    local saved, save_err = deps.safe_write.write("installer", own_copy, { fs = fsys, keep_backup = false })
    if not saved then error("installer konnte nicht abgelegt werden: " .. tostring(save_err), 0) end
  end

  -- 5. - 7. install ---------------------------------------------------------------------------------------------
  if #todo > 0 then
    local ok_journal, journal_err = journal.write("INSTALLING", { ref = ref, role = role, id = manifest.id, files = todo })
    if not ok_journal then error("Installationsjournal konnte nicht geschrieben werden: " .. tostring(journal_err), 0) end
    ui.info(#todo .. " Dateien werden geladen (" .. unchanged .. " unveraendert)")
    for i, path in ipairs(todo) do
      local ok, err = stage.fetch(ref, path, files[path])
      if not ok then
        ui.progress_done()
        error("Installation abgebrochen bei " .. path .. ": " .. tostring(err) .. " -- 'installer --resume' setzt fort.", 0)
      end
      ui.progress(i, #todo, path)
    end
    ui.progress_done()
    result.installed = #todo
  else
    ui.ok("Alle Dateien sind auf dem Stand " .. manifest.id)
  end
  for _, path in ipairs(obsolete) do
    stage.remove(path)
    result.removed = result.removed + 1
  end
  for path in pairs(files) do stage.remove(path .. ".tmp") end

  -- 8. version and record ---------------------------------------------------------------------------------------
  local installed_paths = {}
  for path, entry in pairs(files) do if not entry.seed then installed_paths[#installed_paths + 1] = path end end
  table.sort(installed_paths)
  local record_lines = {
    "return {\n",
    "  role = " .. string.format("%q", role) .. ",\n",
    "  ref = " .. string.format("%q", ref) .. ",\n",
    "  id = " .. string.format("%q", manifest.id) .. ",\n",
    "  files = {\n",
  }
  for _, path in ipairs(installed_paths) do record_lines[#record_lines + 1] = "    " .. string.format("%q", path) .. ",\n" end
  record_lines[#record_lines + 1] = "  },\n}\n"
  local wrote_record, record_err = deps.safe_write.write(RECORD, table.concat(record_lines), { fs = fsys, keep_backup = false })
  if not wrote_record then error("Installationsprotokoll konnte nicht geschrieben werden: " .. tostring(record_err), 0) end
  local wrote_version, version_err = deps.safe_write.write(VERSION_FILE, ref .. "-" .. manifest.id, { fs = fsys, keep_backup = false })
  if not wrote_version then error("Versionsdatei konnte nicht geschrieben werden: " .. tostring(version_err), 0) end

  -- 9. finished ---------------------------------------------------------------------------------------------------
  journal.clear()
  ui.ok("Fertig: " .. role_label .. ". " .. result.installed .. " geladen, " .. result.unchanged .. " unveraendert, " .. result.removed .. " entfernt.")

  -- 10. a new computer gets the setup wizard, an installed one is upgraded and restarted ----------------------------
  if not existing or existing.role ~= role then
    result.needs_setup = true
    return result
  end
  local upgraded, status = deps.startup_template.upgrade(startup_text)
  if upgraded and status == "upgraded" then
    local ok_start, start_err = deps.safe_write.write("startup.lua", upgraded, { fs = fsys })
    if ok_start then ui.info("startup.lua hat jetzt die Wiederherstellung (alte Fassung: startup.lua.prev)")
    else ui.warn("startup.lua konnte nicht erweitert werden: " .. tostring(start_err)) end
  elseif not upgraded then
    ui.warn("startup.lua unveraendert: " .. tostring(status))
  end
  return result
end
