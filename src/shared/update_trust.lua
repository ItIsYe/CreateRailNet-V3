--[[
Purpose: Signs update packages on the master and checks them on the node, with the key the two share (Gesamtkonzept Kap. 14, Pruefplan I-02, I-03).
Public API: signer({ keyring, my_id, config, protocol }) -> sign_package(node_id, update) -> package | nil
  verifier({ keyring, master_id, node_id, role, protocol, free_space () -> bytes, require (bool) }) -> verify_package(package, offer) -> true | false, code, detail
Notes: the key is the pair key of master and node (src/shared/keyring.lua): no key, no package. The node refuses an offer without a package when `require` is set (config `ota_require_package`, on by default when
  authentication is enforced); with `require` off an offer without a package is taken as before (nodes of an older master). A package that is there is always checked, whatever `require` says: a wrong
  proof is never a reason to continue. The package carries the SHA-256 of every file; the updater checks the staged files against it at the commit. The signer lists the role of the target computer from the plan.
]]

local update_package = require("src.shared.update_package")

local update_trust = {}

local MIN_FREE = 20000

function update_trust.signer(opts)
  return function(node_id, update)
    local keyring = opts.keyring
    if not keyring or not keyring.pair_key then return nil end
    local key = keyring.pair_key(opts.my_id, node_id)
    if not key then return nil end
    local role
    for _, node in ipairs((opts.config and opts.config.nodes) or {}) do if node.id == node_id then role = node.role end end
    if not role then return nil end
    local files = {}
    for _, item in ipairs(update.manifest) do files[#files + 1] = { path = item.path, content = update.files[item.path].content } end
    return update_package.build(files, { release = update.version, roles = { role }, protocol = opts.protocol, schema = update_package.DATA_SCHEMA, min_free_bytes = MIN_FREE, rollback_to = "previous" }, key)
  end
end

function update_trust.verifier(opts)
  return function(package, offer)
    if package == nil then
      if opts.require then return false, "no_package", "this computer takes only signed update packages" end
      return true
    end
    local key = opts.keyring and opts.keyring.pair_key and opts.keyring.pair_key(opts.master_id, opts.node_id)
    if not key then return false, "no_key", "this computer has no key to check the package with" end
    local ctx = { role = opts.role, protocol = opts.protocol, schema = update_package.DATA_SCHEMA }
    if opts.free_space then
      local ok, free = pcall(opts.free_space)
      if ok and type(free) == "number" then ctx.free_bytes = free end
    end
    return update_package.verify(package, key, ctx)
  end
end

return update_trust
