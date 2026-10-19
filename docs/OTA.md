# Over-the-air updates

How new code reaches the nodes, what is checked on the way, and what happens when something goes wrong.

## Operator procedure

1. Run `lua scripts/ota_push.lua [--node ID] [--version TEXT] [--wait SECONDS]` on a computer that has the source files and a modem
   on the network channel. Without `--node` it broadcasts an offer and updates every node that answers. The master panel
   (`manual_control` action `ota_push`) does the same for registered nodes.
2. Watch the status lines: `QUEUED, OFFERED, SENDING, COMMITTING, DONE, CONFIRMED`, or `FAILED` / `UNCONFIRMED`.
3. `CONFIRMED` means the node swapped its files, rebooted and its new code reached the main loop.

A node answers the sender with `ota_result` right before it reboots and with `ota_confirmed` (to the master) after the first good
boot. `DONE` therefore means "swapped, reboot pending", not "running".

## Rolling out step by step

`scripts/ota_push.lua` takes the targets from the plan, so a new version can go to one computer first:

    lua scripts/ota_push.lua --role signal --limit 1 --dry-run     whom would this reach? (nothing is sent, no modem is opened)
    lua scripts/ota_push.lua --role signal --limit 1                the first signal computer (sorted by id)
    lua scripts/ota_push.lua --role signal                          every signal computer
    lua scripts/ota_push.lua                                        every computer that answers on the channel

The master is never a target (it is installed, not pushed). A wrong role, a role nobody has in the plan, or a bad `--limit` stops the tool before anything is sent; `--node` is combined with nothing else.
Wait for `CONFIRMED` of the first computer (and look at it in the game) before the next step.

## Nodes that run the old code (first distribution)

Two ways. A computer with HTTP simply runs the installer (`docs/INSTALL.md`); it replaces what differs, adds the recovery to `startup.lua` and restarts.
For nodes that have no HTTP or that you want to update from the master:

Nodes set up before the verified update cannot talk the new protocol (offer / need / chunk / commit) and have no rollback. They understand one
thing: a single `ota_update` message with all files. `lua scripts/ota_push.lua --legacy [--node ID]` sends exactly that, one message per node
(every non-master node of the config without `--node`), limited to the files a node needs to boot (found by following the `require`s of the role
entry points, about a third of the runtime, so the old node has room for the temporary copies it writes). The node answers `ota_result`,
reboots into the new code, and counts as `CONFIRMED` when its heartbeat shows protocol revision 2 (seen by the master; the tool itself stops at `DONE`).

**Do one node first** (`--legacy --node X`), watch it come back, then do the rest: the old updater cannot roll back, a node whose new code
does not start has to be repaired by hand. From then on `ota_push.lua` without `--legacy` is enough (it sends the rest of the files and later
changes). The master computer is updated by running `installer` on it (`docs/INSTALL.md`) and restarting.

## startup.lua of older nodes

Updates never replace `startup.lua` (it holds role, id and config), so a node set up by an older `setup.lua` has no OTA recovery. Every node
and the master therefore check their own `startup.lua` at start: if it is the layout `setup.lua` writes (or the old repository file) and the
recovery block is missing, it is inserted in front of the line that picks the entry point, the old file is kept as `startup.lua.prev`, and the
change is active from the next boot. A `startup.lua` that does not look like that is left alone and the log says so; add the block by hand:

```lua
local ok_recovery, recovery = pcall(require, "src.shared.ota_recovery")
if ok_recovery then
  local ran, action, detail = pcall(recovery.recover)
  if ran and action ~= "none" then print("OTA recovery: " .. tostring(action) .. " " .. tostring(detail or "")) end
end
```

`lua scripts/upgrade_startup.lua` does the same by hand and prints what happened; `startup_autoupgrade = false` switches the automatic check off.

## What a node does

| Step | Check |
|---|---|
| offer | sender is the master or in `config.ota_sources` (default `OTA-TOOL`); every path is under `src/`, `scripts/` or `configs/templates/`, ends in `.lua` or `.json`, has no `..`; sizes and Adler-32 are plausible; no earlier update is waiting for confirmation |
| need | only files whose size or Adler-32 differ are requested, so a rollout moves what changed |
| chunk | pieces may arrive in any order and twice; the finished file must match size and Adler-32 or it is dropped and requested again; staged as `<path>.ota_new` |
| commit | all requested files staged, then `handlers.on_quiesce` (signal nodes set their signal to RED; failing quiesce aborts the update before any live file is touched) |
| swap | journal `ota_journal.txt` first; per file: backup `<path>.ota_bak`, delete, move; `crn_version.txt` is swapped in the same transaction; journal then switches to `trial` |
| reboot | `startup.lua` runs `src/shared/ota_recovery.lua` before anything else is loaded |

`startup.lua` is never replaced remotely: it holds the role, id and config of each computer (see above for how older ones get the recovery).

## Recovery

`ota_recovery.recover` runs at every start and decides from the journal:

- `applying`: the computer died during the swap. Every file is restored from its backup (a backup is only trusted when size and
  Adler-32 match the journal), files the update added are removed.
- `trial`, first boot: the new code runs; the journal remembers that this boot happened.
- `trial`, second boot without confirmation: the new code never reached its main loop (crash on start, power loss, chunk unload).
  The previous version is restored.
- Interrupted staging (`ota_stage.txt`): staged files are removed.

The new code confirms in `common_node.start` and in the master runtime start (`ota_recovery.confirm`), which deletes backups and
journal. A computer that restarts within seconds of an update for an unrelated reason is rolled back to the previous version; run the
update again.

`tests/test_updater.lua` kills the computer at every single filesystem operation of a commit and checks that the files are all old or
all new afterwards.

## Scaling

The sender offers a manifest (about 60 bytes per file) and sends only what differs. Per node at most `window` (4) chunks of
`chunk_size` (8192 bytes) are in flight, and only `max_parallel` (4) nodes are served at the same time; the rest wait in `QUEUED`.
A node that does not answer the offer fails alone after `offer_retries` x `offer_timeout_ms`, a stalled transfer after
`stall_timeout_ms`; the others continue. While a node transfers, swaps or reboots (and for `reboot_grace_ms` afterwards) the master
does not run its heartbeat timeout on it, so an update does not turn the blocks around that node into FAULT blocks.

## Limits and open points

- Adler-32 catches damaged or truncated transfers and writes. It is not a signature: anyone who can send on the channel under an
  accepted sender id can update nodes. Keep `ota_sources` short.
- What a Create signal shows while its computer reboots is not verified in game. The quiesce step puts the signal to RED before the
  swap; whether that survives the reboot depends on Create.
- The master computer itself is not updated by this mechanism; run `installer` on it and restart.
