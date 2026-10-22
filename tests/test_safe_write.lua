--[[
Purpose: safe_write tests on an in-memory filesystem that behaves like CC:Tweaked (move onto an existing file fails).
Public API: returns table of tests.
]]

pcall(dofile, "tests/harness/cc_bootstrap.lua")

local safe_write = require("src.shared.safe_write")

local function memfs()
  local f = { files = {}, fail = {} }
  f.exists = function(p) return f.files[p] ~= nil end
  f.open = function(p, mode)
    if mode == "r" then
      if f.files[p] == nil then return nil end
      return { readAll = function() return f.files[p] end, close = function() end }
    end
    if f.fail.open == p then return nil end
    local buf = {}
    return {
      write = function(s) buf[#buf + 1] = s end,
      close = function()
        local body = table.concat(buf)
        if f.fail.truncate then body = body:sub(1, f.fail.truncate) end
        f.files[p] = body
      end
    }
  end
  f.delete = function(p) f.files[p] = nil end
  f.move = function(src, dst)
    if f.fail.move_raise then error("crash during move", 0) end
    if f.fail.move_silent then return end
    if f.files[dst] ~= nil then error("Destination exists", 0) end
    f.files[dst] = f.files[src]
    f.files[src] = nil
  end
  f.makeDir = function() end
  return f
end

return {
  test_first_write_creates_file_without_leftovers = function()
    local fsys = memfs()
    assert(safe_write.write("state/a.json", "one", { fs = fsys }))
    assert(fsys.files["state/a.json"] == "one")
    assert(fsys.files["state/a.json.tmp"] == nil and fsys.files["state/a.json.prev"] == nil)
  end,

  test_overwrite_keeps_previous_generation = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys }))
    assert(safe_write.write("a", "two", { fs = fsys }))
    assert(fsys.files["a"] == "two")
    assert(fsys.files["a.prev"] == "one")
    assert(fsys.files["a.tmp"] == nil)
  end,

  test_keep_backup_false_leaves_no_prev = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys, keep_backup = false }))
    assert(safe_write.write("a", "two", { fs = fsys, keep_backup = false }))
    assert(fsys.files["a.prev"] == nil)
  end,

  test_verify_failure_keeps_old_file = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys }))
    fsys.fail.truncate = 1
    local ok, err = safe_write.write("a", "two-long", { fs = fsys })
    assert(ok == false and tostring(err):find("verify", 1, true))
    assert(fsys.files["a"] == "one")
    assert(fsys.files["a.tmp"] == nil)
  end,

  test_open_failure_returns_error_and_keeps_old_file = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys }))
    fsys.fail.open = "a.tmp"
    local ok, err = safe_write.write("a", "two", { fs = fsys })
    assert(ok == false and err)
    assert(fsys.files["a"] == "one")
  end,

  test_failed_move_rolls_back_to_previous_content = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys }))
    fsys.fail.move_silent = true
    local ok, err = safe_write.write("a", "two", { fs = fsys })
    assert(ok == false and tostring(err):find("move", 1, true))
    assert(fsys.files["a"] == "one", "reader must still find the previous complete file")
  end,

  test_crash_between_delete_and_move_is_recoverable_from_backup = function()
    local fsys = memfs()
    assert(safe_write.write("a", "one", { fs = fsys }))
    fsys.fail.move_raise = true
    local ok = pcall(safe_write.write, "a", "two", { fs = fsys })
    assert(ok == false)
    assert(fsys.files["a"] == nil)
    local body, source = safe_write.read_with_backup("a", { fs = fsys })
    assert(body == "one" and source == "backup")
  end,

  test_read_reports_missing = function()
    local fsys = memfs()
    local body, err = safe_write.read("nope", { fs = fsys })
    assert(body == nil and err == "missing")
    local b2, e2 = safe_write.read_with_backup("nope", { fs = fsys })
    assert(b2 == nil and e2 == "missing")
  end,

  test_non_string_body_is_rejected = function()
    local fsys = memfs()
    local ok, err = safe_write.write("a", { 1 }, { fs = fsys })
    assert(ok == false and err)
  end,

  test_default_filesystem_roundtrip = function()
    local path = "state/test_safe_write.txt"
    os.remove(path); os.remove(path .. ".prev"); os.remove(path .. ".tmp")
    assert(safe_write.write(path, "alpha"))
    assert(safe_write.write(path, "beta"))
    assert(safe_write.read(path) == "beta")
    assert(safe_write.read(safe_write.backup_path(path)) == "alpha")
    os.remove(path); os.remove(path .. ".prev"); os.remove(path .. ".tmp")
  end,

  test_the_old_generation_gives_way_when_the_new_copy_would_not_fit = function()
    local f = memfs()
    local capacity = 3000
    f.getFreeSpace = function()
      local used = 0
      for _, body in pairs(f.files) do used = used + math.max(#body, 500) end
      return math.max(0, capacity - used)
    end
    local old = string.rep("a", 1000)
    f.files["state/x.json"], f.files["state/x.json.prev"] = old, string.rep("b", 1000)
    -- free: 1000; a new copy of 900 bytes fits next to the current one only without .prev
    local new = string.rep("c", 900)
    assert(safe_write.write("state/x.json", new, { fs = f }))
    assert(f.files["state/x.json"] == new)
    assert(f.files["state/x.json.prev"] == old, "the previous generation is the one that was current")
    assert(f.files["state/x.json.tmp"] == nil)
  end,

  test_with_room_enough_both_generations_stay = function()
    local f = memfs()
    f.getFreeSpace = function() return 900000 end
    f.files["state/x.json"], f.files["state/x.json.prev"] = "one", "zero"
    assert(safe_write.write("state/x.json", "two", { fs = f }))
    assert(f.files["state/x.json.prev"] == "one")
  end,
}
