--[[
Purpose: Remote over-the-air (OTA) update system for CreateRailNet nodes.
Allows the master to push new Lua source files to all connected nodes via modem.

Protocol:
  Master sends: { type="ota_update", files={{path, content}}, version, checksum }
  Node responds: { type="ota_result", node_id, success, errors }

Nodes apply updates atomically: all files written to temp paths, then renamed.
Nodes reboot automatically after a successful update.

Public API (updater module):
  new(network, node_id, logger) -> updater
  updater.apply(payload)        -> ok, errors

Public API (master_updater module):
  new(network, registry, logger) -> master_updater
  master_updater.push(files, opts) -> results
  master_updater.push_to(node_id, files, opts) -> ok, err
]]

local time = require("src.shared.time")

local updater = {}

-- Node-side: receive and apply an OTA update payload
function updater.new(network, node_id, logger)
  local self = {}

  -- Apply an OTA update payload from the master.
  -- payload.files = { {path=string, content=string}, ... }
  -- Writes atomically: temp file then rename. Reboots on success.
  function self.apply(payload)
    if type(payload) ~= "table" or type(payload.files) ~= "table" then
      return false, { "invalid payload: missing files table" }
    end

    local errors = {}
    local written = {}

    -- Phase 1: write all files to .ota_tmp paths
    for i, f in ipairs(payload.files) do
      if type(f.path) ~= "string" or type(f.content) ~= "string" then
        table.insert(errors, "entry " .. i .. ": missing path or content")
      else
        local tmp = f.path .. ".ota_tmp"
        local ok = false
        if fs and fs.open then
          -- Ensure parent directory exists
          local dir = f.path:match("^(.*)/[^/]+$")
          if dir and dir ~= "" and fs.makeDir then
            pcall(fs.makeDir, dir)
          end
          local fh = fs.open(tmp, "w")
          if fh then
            fh.write(f.content)
            fh.close()
            ok = true
          end
        elseif io and io.open then
          local fh = io.open(tmp, "w")
          if fh then
            fh:write(f.content)
            fh:close()
            ok = true
          end
        end
        if ok then
          table.insert(written, { src = tmp, dst = f.path })
        else
          table.insert(errors, "write failed: " .. f.path)
        end
      end
    end

    if #errors > 0 then
      -- Clean up temp files on failure
      for _, w in ipairs(written) do
        if fs and fs.delete then pcall(fs.delete, w.src) end
        if io then pcall(os.remove, w.src) end
      end
      return false, errors
    end

    -- Phase 2: atomic rename all temp files to final paths
    for _, w in ipairs(written) do
      if fs and fs.move then
        pcall(fs.delete, w.dst)
        fs.move(w.src, w.dst)
      elseif os and os.rename then
        os.rename(w.src, w.dst)
      end
    end

    if logger then
      logger.info("OTA update applied", {
        files = #payload.files,
        version = payload.version,
        node_id = node_id
      })
    end

    -- Notify master of success before rebooting
    if network then
      network.send("event", payload.src or "broadcast", {
        type = "ota_result",
        node_id = node_id,
        success = true,
        files = #payload.files,
        version = payload.version
      })
      -- Give the message time to send before reboot
      if os.sleep then os.sleep(0.5) end
    end

    -- Reboot to load new code
    if os.reboot then os.reboot() end
    return true, {}
  end

  return self
end

return updater
