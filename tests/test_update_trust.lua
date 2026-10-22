--[[
Purpose: A signed update package from the master to a node, end to end: the key of the pair signs it, the node checks proof, role, protocol, schema and space, the offer must match the package and the staged files must match its SHA-256 (Pruefplan I-02, I-03, I-09).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local update_trust = require("src.shared.update_trust")
local update_package = require("src.shared.update_package")
local updater = require("src.shared.updater")
local keyring = require("src.shared.keyring")
local checksum = require("src.shared.checksum")
local net = require("src.shared.net")
local memfs = require("tests.harness.memfs")

local MASTER_KEY = string.rep("7a", 32)
local CONFIG = { nodes = { { id = "MASTER-1", role = "master" }, { id = "SIG-1", role = "signal" }, { id = "PANEL-1", role = "panel" } } }

local OLD = { ["src/shared/net.lua"] = "-- net v1\nreturn {}\n", ["crn_version.txt"] = "v1" }
local NEW = { ["src/shared/net.lua"] = "-- net v2\nreturn { fixed = true }\n", ["src/nodes/signal_node.lua"] = "-- signal v2\nreturn {}\n" }

local function trust()
  return { rev = 1, nodes = { ["SIG-1"] = { epoch = 1, status = "active", role = "signal" }, ["PANEL-1"] = { epoch = 1, status = "active", role = "panel" } } }
end

local function update_of(files)
  local manifest, map = {}, {}
  for path, body in pairs(files) do
    map[path] = { content = body, size = #body, adler = checksum.adler32(body) }
    manifest[#manifest + 1] = { path = path, size = #body, adler = map[path].adler }
  end
  table.sort(manifest, function(a, b) return a.path < b.path end)
  return { id = "u1", version = "v2", files = map, manifest = manifest }
end

local function world(opts)
  opts = opts or {}
  local master_ring = keyring.master({ id = "MASTER-1", master_key = MASTER_KEY, trust = trust(), masters = { "MASTER-1" } })
  local node_key = keyring.derive_node_key(MASTER_KEY, "SIG-1", 1)
  local node_ring = keyring.node({ id = "SIG-1", key = opts.wrong_key and string.rep("00", 32) or node_key, epoch = 1, masters = { "MASTER-1" } })
  local w = { fs = memfs.new(), events = {} }
  for path, body in pairs(OLD) do w.fs.set(path, body) end
  w.sign = update_trust.signer({ keyring = master_ring, my_id = "MASTER-1", config = CONFIG, protocol = net.PROTOCOL_REVISION })
  w.verify = update_trust.verifier({ keyring = node_ring, master_id = "MASTER-1", node_id = "SIG-1", role = "signal", protocol = net.PROTOCOL_REVISION,
    free_space = function() return opts.free or 1000000 end, require = opts.require })
  local network = { send_reliable = function(kind, dst, payload) w.events[#w.events + 1] = { kind = kind, payload = payload } end }
  w.updater = updater.new(network, "SIG-1", nil, { fs = w.fs, sources = { "MASTER-1" }, verify_package = w.verify, quiesce = function() return true end, reboot = function() end, sleep = function() end })
  function w.event(name)
    for i = #w.events, 1, -1 do if w.events[i].payload.type == name then return w.events[i].payload end end
  end
  function w.offer(update, package)
    return w.updater.offer({ update_id = update.id, version = update.version, files = update.manifest, package = package }, "MASTER-1")
  end
  return w
end

local function chunks(w, update, tamper)
  for path, file in pairs(update.files) do
    local body = tamper and tamper[path] or file.content
    assert(w.updater.chunk({ update_id = update.id, path = path, index = 1, total = 1, data = body }, "MASTER-1"))
  end
end

return {
  test_a_package_signed_with_the_key_of_the_pair_is_taken_and_applied = function()
    local w = world()
    local update = update_of(NEW)
    local package = w.sign("SIG-1", update)
    assert(package and package.roles[1] == "signal" and package.rollback_to == "previous")
    assert(w.offer(update, package) == true)
    assert(w.event("ota_need"))
    chunks(w, update)
    assert(w.updater.commit({ update_id = update.id }, "MASTER-1") == true)
    assert(w.fs.files["src/shared/net.lua"] == NEW["src/shared/net.lua"])
  end,

  test_a_package_made_for_another_computer_or_with_another_key_is_refused_before_a_file_is_asked_for = function()
    local w = world()
    local update = update_of(NEW)
    local for_panel = w.sign("PANEL-1", update)
    local ok, err = w.offer(update, for_panel)
    assert(ok == false and err:find("package refused", 1, true) and w.event("ota_need") == nil)
    local wrong = world({ wrong_key = true })
    local ok2, err2 = wrong.offer(update, wrong.sign("SIG-1", update))
    assert(ok2 == false and err2:find("bad_signature", 1, true))
  end,

  test_an_offer_without_a_package_is_refused_when_the_node_requires_one_and_taken_when_it_does_not = function()
    local strict = world({ require = true })
    local update = update_of(NEW)
    local ok, err = strict.offer(update, nil)
    assert(ok == false and err:find("no_package", 1, true) and strict.event("ota_need") == nil)
    local lax = world({ require = false })
    assert(lax.offer(update, nil) == true and lax.event("ota_need"))
  end,

  test_an_offer_with_more_or_other_files_than_the_package_covers_is_refused = function()
    local w = world()
    local update = update_of(NEW)
    local package = w.sign("SIG-1", update)
    local bigger = update_of({ ["src/shared/net.lua"] = NEW["src/shared/net.lua"], ["src/nodes/signal_node.lua"] = NEW["src/nodes/signal_node.lua"], ["src/shared/extra.lua"] = "-- sneaked in\n" })
    local ok, err = w.offer(bigger, package)
    assert(ok == false and err:find("not_covered", 1, true))
    local resized = update_of({ ["src/shared/net.lua"] = NEW["src/shared/net.lua"] .. "x", ["src/nodes/signal_node.lua"] = NEW["src/nodes/signal_node.lua"] })
    assert(w.offer(resized, package) == false)
  end,

  test_files_that_differ_from_the_signed_hashes_are_not_swapped_in = function()
    local w = world()
    local genuine = update_of(NEW)
    local package = w.sign("SIG-1", genuine)
    -- an offer whose list (path, size, Adler-32) fits the forged files, under the signed package of the genuine ones: only the SHA-256 of the package can tell
    local body = NEW["src/shared/net.lua"]
    local forged_files = { ["src/shared/net.lua"] = body:sub(1, -3) .. "X\n", ["src/nodes/signal_node.lua"] = NEW["src/nodes/signal_node.lua"] }
    assert(#forged_files["src/shared/net.lua"] == #body)
    local forged = update_of(forged_files)
    assert(w.offer(forged, package) == true, "the offer looks fine to the checks of the offer")
    chunks(w, forged)
    local ok, err = w.updater.commit({ update_id = forged.id }, "MASTER-1")
    assert(ok == false and err:find("bad_file", 1, true), tostring(err))
    assert(w.fs.files["src/shared/net.lua"] == OLD["src/shared/net.lua"], "nothing was swapped")
    assert(w.event("ota_result").success == false)
  end,

  test_a_node_without_room_does_not_start_and_a_wrong_role_or_protocol_is_refused = function()
    local update = update_of(NEW)
    local tight = world({ free = 100 })
    local ok, err = tight.offer(update, tight.sign("SIG-1", update))
    assert(ok == false and err:find("no_space", 1, true))
    local package = update_package.build({ { path = "src/shared/net.lua", content = NEW["src/shared/net.lua"] }, { path = "src/nodes/signal_node.lua", content = NEW["src/nodes/signal_node.lua"] } },
      { release = "v2", roles = { "depot" }, protocol = net.PROTOCOL_REVISION, schema = update_package.DATA_SCHEMA, rollback_to = "previous" }, keyring.derive_node_key(MASTER_KEY, "SIG-1", 1))
    local w = world()
    local ok2, err2 = w.offer(update, package)
    assert(ok2 == false and err2:find("wrong_role", 1, true))
    local future = update_package.build({ { path = "src/shared/net.lua", content = NEW["src/shared/net.lua"] }, { path = "src/nodes/signal_node.lua", content = NEW["src/nodes/signal_node.lua"] } },
      { release = "v9", roles = { "signal" }, protocol = net.PROTOCOL_REVISION, schema = update_package.DATA_SCHEMA + 1, migration = { steps = "journal" }, rollback_to = "previous" }, keyring.derive_node_key(MASTER_KEY, "SIG-1", 1))
    local ok3, err3 = w.offer(update, future)
    assert(ok3 == false and err3:find("migration_required", 1, true), "a schema change waits for a person")
  end,

  test_no_key_no_package_and_a_computer_of_no_role_gets_none = function()
    local no_key = update_trust.signer({ keyring = keyring.master({ id = "MASTER-1", master_key = nil, trust = { nodes = {} }, masters = { "MASTER-1" } }), my_id = "MASTER-1", config = CONFIG, protocol = 5 })
    assert(no_key("SIG-1", update_of(NEW)) == nil)
    local w = world()
    assert(w.sign("UNKNOWN", update_of(NEW)) == nil)
    local verifier = update_trust.verifier({ keyring = keyring.node({ id = "SIG-1", masters = { "MASTER-1" } }), master_id = "MASTER-1", node_id = "SIG-1", role = "signal", protocol = 5 })
    local ok, code = verifier({ format = 1 }, {})
    assert(ok == false and code == "no_key")
  end,

  test_the_config_check_knows_the_key_that_demands_packages = function()
    local validate = require("src.shared.validate")
    local function text(value)
      local _, errs = validate.validate_config({ v = 1, channel = 1, master_id = "M", nodes = { { id = "M", role = "master" } }, ota_require_package = value })
      return table.concat(errs or {}, "\n")
    end
    assert(not text(true):find("ota_require_package", 1, true) and not text(false):find("ota_require_package", 1, true))
    assert(text("yes"):find("ota_require_package", 1, true))
  end
}
