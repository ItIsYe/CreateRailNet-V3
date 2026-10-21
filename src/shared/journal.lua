--[[
Purpose: Durable journal with monotone sequence numbers, checksums, commit markers and snapshots (Gesamtkonzept Kap. 5.2, 5.4, 15).
Public API: new(path, opts) -> journal. opts: fs, max_entries (2000), max_bytes (65536), state_fn (function -> state, makes the journal compact itself), now (function -> seconds).
  journal.open() -> status, info     status "fresh" | "ok" | "tail_repaired" | "corrupt" | "failed" ("failed": the files could not be written; "corrupt" locks the journal: nothing is appended until the operator deals with it)
  journal.append(kind, data) -> seq | nil, err        data is a table of plain values; the entry is on disk when this returns
  journal.commit(seq) -> ok, err                       marks every entry up to seq as committed (a marker entry of its own)
  journal.committed() / journal.last_seq() / journal.base_seq() / journal.snapshot_seq()
  journal.recovered() -> { state, snapshot_seq, entries = { { seq, kind, data } }, committed }  what is needed to rebuild: the last snapshot and everything after it
  journal.snapshot(state) -> ok, err                   writes state as the snapshot at last_seq, then starts a new journal file after it
  journal.entries_after(seq) -> list                   journal.status() -> { state, locked, failed, entries, bytes, last_seq, committed, last_error }
  journal.reopen() -> status                           after a write failure or a repair by the operator: read everything again
Notes: file format: first line "#CRNJ1<TAB>base_seq<TAB>crc", then one line per entry "seq<TAB>kind<TAB>json<TAB>crc" (crc: Adler-32 of everything before it on the line).
  Sequence numbers are contiguous; commit markers are entries of kind "commit" ({ upto = n }). A line that is damaged at the very end (a write that was interrupted)
  is cut off (tail_repaired); a damaged line followed by good lines means the file was damaged in the middle: the journal is "corrupt" and refuses appends, because
  a safety decision must not rest on a history with a hole (Kap. 5.2: incomplete journals and disk errors block new releases).
  A failed write (disk full, unwritable) makes the journal "failed": append refuses until reopen() finds the file intact. Compaction writes the snapshot first and rewrites the
  journal second; a crash between the two leaves old journal entries below the snapshot, which open() skips and then drops. The snapshot file is path .. ".snap" (safe_write, .prev kept).
  Everything is bounded: entries since the last snapshot are kept in memory, and past max_entries / max_bytes the journal compacts itself with state_fn; without it,
  or when compaction keeps failing, appends stop at four times max_bytes ("full") instead of growing without limit.
]]

local json = require("src.shared.json")
local checksum = require("src.shared.checksum")
local safe_write = require("src.shared.safe_write")

local journal = {}

local HEADER = "#CRNJ1"
local SNAPSHOT_VERSION = 1

local function crc_of(text) return checksum.hex(checksum.adler32(text)) end

local function split_lines(text)
  local lines, position = {}, 1
  while position <= #text do
    local newline = text:find("\n", position, true)
    if newline then
      lines[#lines + 1] = { text = text:sub(position, newline - 1), complete = true }
      position = newline + 1
    else
      lines[#lines + 1] = { text = text:sub(position), complete = false }
      position = #text + 1
    end
  end
  return lines
end

local function parse_header(line)
  local base, crc = line:match("^" .. HEADER .. "\t(%d+)\t(%x%x%x%x%x%x%x%x)$")
  if not base then return nil end
  if crc_of(HEADER .. "\t" .. base) ~= crc then return nil end
  return tonumber(base)
end

local function parse_entry(line)
  local seq, kind, body, crc = line:match("^(%d+)\t([%w_%.%-]+)\t(.*)\t(%x%x%x%x%x%x%x%x)$")
  if not seq then return nil end
  if crc_of(seq .. "\t" .. kind .. "\t" .. body) ~= crc then return nil end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" then return nil end
  return { seq = tonumber(seq), kind = kind, data = data }
end

local function encode_entry(seq, kind, data)
  local ok, body = pcall(json.encode, data or {})
  if not ok then return nil, "entry cannot be written: " .. tostring(body) end
  if body:find("[\t\r\n]") then return nil, "entry contains a control character" end
  if type(kind) ~= "string" or not kind:match("^[%w_%.%-]+$") then return nil, "bad entry kind" end
  local head = seq .. "\t" .. kind .. "\t" .. body
  return head .. "\t" .. crc_of(head) .. "\n"
end

local function header_line(base)
  local head = HEADER .. "\t" .. base
  return head .. "\t" .. crc_of(head) .. "\n"
end

function journal.new(path, opts)
  opts = opts or {}
  local fsys = opts.fs or _G.fs
  local max_entries = opts.max_entries or 2000
  local max_bytes = opts.max_bytes or 65536
  local now = opts.now or function() return os.time and os.time() or 0 end
  local snap_path = path .. ".snap"
  local io_opts = { fs = opts.fs }

  local self = {}
  local entries = {}      -- entries after the snapshot, in order
  local base, snapshot_seq, snapshot_state = 0, 0, nil
  local last, committed = 0, 0
  local bytes = 0
  local state, locked, failed, last_error = "closed", false, false, nil
  local full = false

  local function fail(err)
    failed = true
    last_error = tostring(err)
    return nil, last_error
  end

  local function read_snapshot()
    local body, source = safe_write.read_with_backup(snap_path, io_opts)
    if not body then return nil, nil end
    local ok, decoded = pcall(json.decode, body)
    if ok and type(decoded) == "table" and decoded.v == SNAPSHOT_VERSION and type(decoded.seq) == "number" then return decoded, source end
    -- the primary snapshot is damaged: the previous one may still be good
    local prev = safe_write.read(safe_write.backup_path(snap_path), io_opts)
    if prev then
      ok, decoded = pcall(json.decode, prev)
      if ok and type(decoded) == "table" and decoded.v == SNAPSHOT_VERSION and type(decoded.seq) == "number" then return decoded, "backup" end
    end
    return nil, "damaged"
  end

  local function rewrite_journal(base_seq, kept)
    local parts = { header_line(base_seq) }
    for _, entry in ipairs(kept) do
      local line = encode_entry(entry.seq, entry.kind, entry.data)
      parts[#parts + 1] = line
    end
    local text = table.concat(parts)
    local ok, err = safe_write.write(path, text, { fs = opts.fs, keep_backup = false })
    if not ok then return nil, err end
    return #text
  end

  function self.open()
    entries, base, snapshot_seq, snapshot_state, last, committed, bytes = {}, 0, 0, nil, 0, 0, 0
    locked, failed, last_error, full = false, false, nil, false
    local info = {}

    local snap, snap_source = read_snapshot()
    if snap_source == "damaged" then
      locked, state = true, "corrupt"
      info.reason = "snapshot unreadable"
      return state, info
    end
    if snap then
      snapshot_seq, snapshot_state, committed = snap.seq, snap.state, tonumber(snap.committed) or snap.seq
      last = snap.seq
      info.snapshot_from = snap_source
    end

    local text = safe_write.read(path, io_opts)
    if not text then
      -- nothing journalled after the snapshot (or nothing at all)
      base = snapshot_seq
      local size, err = rewrite_journal(base, {})
      if not size then fail(err); state = "failed"; info.reason = last_error; return state, info end
      bytes = size
      state = snap and "ok" or "fresh"
      return state, info
    end

    local lines = split_lines(text)
    local file_base = lines[1] and lines[1].complete and parse_header(lines[1].text)
    if not file_base then
      locked, state = true, "corrupt"
      info.reason = "journal header unreadable"
      return state, info
    end
    base = file_base
    if snapshot_seq > 0 and base > snapshot_seq then
      -- the journal starts after a snapshot we do not have (the newer snapshot is gone): history has a hole
      locked, state = true, "corrupt"
      info.reason = "journal starts after the snapshot"
      return state, info
    end

    local expected = base + 1
    local kept, good_lines = {}, 1
    local damaged_at = nil
    for index = 2, #lines do
      local line = lines[index]
      local entry = line.complete and parse_entry(line.text) or nil
      if entry and entry.seq == expected then
        expected = expected + 1
        good_lines = index
        if entry.seq > snapshot_seq then kept[#kept + 1] = entry end
        if entry.kind == "commit" and type(entry.data.upto) == "number" and entry.data.upto > committed then committed = entry.data.upto end
      else
        damaged_at = index
        break
      end
    end

    if damaged_at then
      if damaged_at ~= #lines then
        locked, state = true, "corrupt"
        info.reason = "damaged line " .. damaged_at .. " of " .. #lines .. " is followed by more"
        return state, info
      end
      state = "tail_repaired"
      info.cut = lines[damaged_at].text:sub(1, 40)
    else
      state = "ok"
    end

    last = math.max(snapshot_seq, expected - 1)
    entries = kept
    local needs_rewrite = damaged_at ~= nil or base < snapshot_seq
    if needs_rewrite then
      -- cut the torn tail / finish a compaction that was interrupted after the snapshot was written
      local size, err = rewrite_journal(math.max(base, snapshot_seq), kept)
      if not size then fail(err); state = "failed"; info.reason = last_error; return state, info end
      base = math.max(base, snapshot_seq)
      bytes = size
      if state == "ok" then info.finished_compaction = true end
    else
      bytes = #text
    end
    return state, info
  end

  function self.reopen() return self.open() end

  local function write_line(line)
    if locked then return nil, "journal is locked (" .. state .. ")" end
    if failed then return nil, "journal is failed: " .. tostring(last_error) end
    if bytes + #line > max_bytes * 4 then full = true; return nil, "journal is full" end
    local ok, handle = pcall(fsys.open, path, "a")
    if not ok or not handle then return fail(ok and "cannot open journal" or handle) end
    local wrote, err = pcall(function() handle.write(line); handle.close() end)
    if not wrote then return fail(err) end
    bytes = bytes + #line
    return true
  end

  local function maybe_compact()
    if not opts.state_fn then return end
    if #entries < max_entries and bytes < max_bytes then return end
    local ok, current = pcall(opts.state_fn)
    if ok and type(current) == "table" then self.snapshot(current) end
  end

  function self.append(kind, data)
    local seq = last + 1
    local line, err = encode_entry(seq, kind, data)
    if not line then return nil, err end
    local ok, werr = write_line(line)
    if not ok then return nil, werr end
    last = seq
    entries[#entries + 1] = { seq = seq, kind = kind, data = data or {} }
    maybe_compact()
    return seq
  end

  function self.commit(seq)
    if type(seq) ~= "number" or seq > last then return nil, "cannot commit what was never appended" end
    if seq <= committed then return true end
    local marker, err = self.append("commit", { upto = seq })
    if not marker then return nil, err end
    committed = seq
    return true
  end

  function self.snapshot(new_state)
    if locked then return nil, "journal is locked (" .. state .. ")" end
    local body = json.encode({ v = SNAPSHOT_VERSION, seq = last, committed = committed, saved_at = now(), state = new_state })
    local ok, err = safe_write.write(snap_path, body, io_opts)
    if not ok then return fail(err) end
    local size, rerr = rewrite_journal(last, {})
    if not size then return fail(rerr) end
    snapshot_seq, snapshot_state, base, bytes, entries = last, new_state, last, size, {}
    failed, full = false, false
    return true
  end

  function self.committed() return committed end
  function self.last_seq() return last end
  function self.base_seq() return base end
  function self.snapshot_seq() return snapshot_seq end

  function self.recovered()
    local copy = {}
    for i, entry in ipairs(entries) do copy[i] = entry end
    return { state = snapshot_state, snapshot_seq = snapshot_seq, entries = copy, committed = committed }
  end

  function self.entries_after(seq)
    local out = {}
    for _, entry in ipairs(entries) do if entry.seq > seq then out[#out + 1] = entry end end
    return out
  end

  function self.status()
    return { state = state, locked = locked, failed = failed, entries = #entries, bytes = bytes, last_seq = last, committed = committed, last_error = last_error,
      writable = not locked and not failed and not full }
  end

  return self
end

return journal
