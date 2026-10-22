--[[
Purpose: Writes the files of an installation: space check before anything is touched, verified download, atomic replace.
Public API: new(env) -> stage
  env: fs, safe_write, checksum, http (install/http client), compile(source, name) -> function | nil, err, sleep(seconds), yield()
  stage.free_space() -> bytes | nil (unknown) | math.huge (no limit)
  stage.check_capacity(planned_bytes, reclaimable_bytes) -> true | false, message
  stage.fetch(ref, path, entry) -> true | false, err      download, check size / Adler-32 / syntax, replace the file
  stage.read(path) -> body | nil
  stage.remove(path)
Notes: a file is written to <path>.tmp, read back, and moved over the old one (src/shared/safe_write.lua), so at every moment the
  old or the new version is complete. A download that does not match the manifest is repeated with a new URL (a CDN may still serve
  the old file for a few minutes after a push).
]]

local stage = {}

-- the installer ships the minified copies in dist/ (scripts/build_dist.lua); size and checksum in the manifest are those of dist/
stage.REMOTE_PREFIX = "dist/"

-- journal, version file and a little more than the files themselves: a check that passes barely is worth nothing
stage.SPACE_HEADROOM_BYTES = 12 * 1024
local FETCH_ATTEMPTS = 4
local FETCH_DELAY_S = 2

function stage.new(env)
  local fsys = env.fs
  local self = {}

  function self.free_space()
    if not (fsys and fsys.getFreeSpace) then return nil end
    local ok, value = pcall(fsys.getFreeSpace, "/")
    if not ok then return nil end
    if type(value) == "string" then
      if value:lower() == "unlimited" then return math.huge end
      value = tonumber(value)
    end
    if type(value) == "number" then return value < 0 and math.huge or value end
    return nil
  end

  -- planned: bytes to be written (including the temporary copy of the largest file); reclaimable: bytes of files that get replaced
  function self.check_capacity(planned_bytes, reclaimable_bytes)
    local free = self.free_space()
    if free == nil or free == math.huge then return true end
    local available = free + (reclaimable_bytes or 0)
    local needed = (planned_bytes or 0) + stage.SPACE_HEADROOM_BYTES
    if available >= needed then return true end
    local function kb(bytes) return math.ceil(bytes / 1000) end
    return false, string.format(
      "Der Speicher dieses Computers reicht nicht: gebraucht %d KB, frei %d KB (es fehlen %d KB). Nichts wurde veraendert. "
        .. "Abhilfe: Platz schaffen (Logs und Spuren loeschen, andere Dateien entfernen). Ein Computer fasst fest 1 MB.",
      kb(needed), kb(available), kb(needed - available))
  end

  function self.read(path)
    if not fsys.exists(path) then return nil end
    local fh = fsys.open(path, "r")
    if not fh then return nil end
    local body = fh.readAll()
    fh.close()
    return body
  end

  function self.remove(path)
    if fsys.exists(path) then pcall(fsys.delete, path) end
  end

  local function verify(path, body, entry)
    if #body ~= entry.size then return false, string.format("size of %s: got %d, expected %d", path, #body, entry.size) end
    local sum = env.checksum.adler32(body, env.yield)
    if sum ~= entry.adler then return false, string.format("checksum of %s: got %d, expected %d", path, sum, entry.adler) end
    if path:match("%.lua$") then
      local chunk, err = env.compile(body, path)
      if not chunk then return false, "syntax of " .. path .. ": " .. tostring(err) end
    end
    return true
  end

  function self.fetch(ref, path, entry)
    local last_err
    for attempt = 1, FETCH_ATTEMPTS do
      local body, err = env.http.download_file(ref, stage.REMOTE_PREFIX .. path)
      if not body then
        last_err = err
      else
        local ok, why = verify(path, body, entry)
        if ok then
          local written, write_err = env.safe_write.write(path, body, { fs = fsys, keep_backup = false })
          if written then return true end
          last_err = "write of " .. path .. " failed: " .. tostring(write_err)
        else
          last_err = why
        end
      end
      if attempt < FETCH_ATTEMPTS then env.sleep(FETCH_DELAY_S * attempt) end
    end
    return false, last_err
  end

  return self
end

return stage
