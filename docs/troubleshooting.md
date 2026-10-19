# Troubleshooting

## Signals always RED

Signals default to RED when the master cannot confirm safety. This is by design.

Causes and fixes:
- **Node not registered**: The signal_node may not have connected. Check the modem channel and that `master_id` in config matches the master's actual node ID.
- **Block in FAULT**: Any FAULT block on a route forces all signals on that route red. Clear the fault by resolving the sensor state and re-registering the node.
- **Master in RECOVERY mode**: After a restart, the master enters recovery mode: new route requests, departures and manual actions are refused until an operator confirms recovery from the panel or via the `confirm_recovery` manual action. Free blocks are RED; a train that already held a reservation gets its signal back.
- **Maintenance mode active**: All departure signals are held red in maintenance mode.

## Block stuck in FAULT

A block enters FAULT when:
- A sensor sends `leave` without a prior `enter` (sequence error)
- A node times out while a block is reserved or occupied
- The signal hardware fails to respond (`setForcedRed` returns error)

A fault caused by a **node timeout** clears itself 15 s after the node is back, once its detectors report the track free (`docs/OPERATIONS.md`).
If it does not, one of the conditions is missing: the node is not up (status page), the block has no sensor, a detector reports occupied, or the
block faulted for another reason (garbage event, signal hardware).

Fix:
1. Check the sensor node is running and sending heartbeats
2. On the panel, navigate to Diagnostics to see the specific error
3. Use `manual_control` → `clear_fault` with the block_id once you have looked at the track (a block that belongs to a train on its way is refused: `release_train` first)
4. The master will re-evaluate on the next sensor event

## Train stuck in QUEUED

A train enters QUEUED when its requested route is blocked by:
- Another train occupying or reserving a block on the route
- An opposite-direction conflict on the same corridor
- The route is in a conflict group with an active route

The queue processes automatically when the blocking train clears. If a train is stuck indefinitely:
- Check Diagnostics for `blocked_by` info in the queue entry
- Verify the blocking train's sensor events are firing correctly
- Use `hold_train` + `authorize_train` manual actions to manually release and re-queue

## Node keeps timing out

Default timeout is 6 seconds. Node heartbeats fire every 2 seconds.

- **Wireless modem**: Range issues. Use wired modems where possible.
- **Wrong channel**: Node and master must use the same `channel` in config.
- **Server lag**: At low TPS, heartbeat intervals stretch. Consider increasing `heartbeat_timeout_s` in config (e.g. to 15 for laggy servers).

## A signal shows something else than the master wants

The master sends signals again at start, a few per second afterwards (`signal_refresh_per_s`) and when a signal node comes back, so a wrong
signal corrects itself within one round (blocks / 2 per second). If it does not: check the log page for "signals did not answer" (the
peripheral name in the hardware config does not match, or the computer is off) and the audit log for `node_timeout` of the signal node.

## Installer problems

See the table in `docs/INSTALL.md` ("Wenn etwas schiefgeht"). The short version: `HTTP ist nicht verfuegbar` means HTTP is off in the ComputerCraft config;
`Der Speicher dieses Computers reicht nicht` means nothing was changed and the computer needs more space; `Installation unvollstaendig.` at boot means an
interrupted installation, which `startup.lua` resumes by itself (`installer --resume`).

## Setup wizard

- **"Kein Modem an diesem Computer"**: the wizard warns and lets you go on. Without a modem the computer cannot reach the master; place one directly against the computer and start the wizard again, or
  just attach it later.
- **"Der Netzplan erwartet das Geraet ... nicht angeschlossen"**: the plan names a device (`peripheral`, `create_station`) the computer does not see.
  The name in the plan must match what `peripherals` lists, or the device is not connected yet.
- **The master does not start, naming a config error**: `scripts/setup.lua --check` lists every problem of `configs/network.json` with its path.
- **Wrong id or role**: run `scripts/setup.lua` again; an installed computer asks first whether to set up again, and offers its old answers.
- **The doctor shows `[FEHL]` or `[WARN]` lines**: `scripts/setup.lua --doctor` lists every point of this computer with what to do about it. The common ones:
  `Modem ... nicht gefunden` (the plan names a modem that is not attached: attach it or change the `modem` field of the entry), `Mehrere Modems, keines festgelegt` and
  `Mehrere Monitore, keiner festgelegt` (the first one is used; write its name into the entry as `modem` / `monitor`), `Kein Monitor` (the display stays empty),
  `Bahnhof ohne Bahnsteige` / `Depot ohne Gleise` (see below), `Speicher fast voll`.
- **A station or depot computer says "Bahnhof ohne Bahnsteige" / "Depot ohne Gleise"**: platforms and tracks are read from the computer's own plan, and a short plan has none.
  Copy the complete plan of the master to this computer (for example with a disk) and choose "Eigene Datei angeben" in the wizard. There is no distribution of the plan yet.
- **The computer does not show up on the master's page *Einrichtung***: the computer needs a modem on the same channel as the master, the master must run (a master from
  before revision 3 ignores the announcement; update it with the installer), and the link test of the wizard says which of these it is ("Master antwortet nicht" / "kennt die ID noch nicht").
  A rejected id is ignored for 10 minutes; a computer that stood on the page for an hour without a sign is forgotten and announces itself again.
- **[ANNEHMEN] answers with an error**: the master refuses to write when its plan is a bundled template (`configs/templates/...`), does not parse, or would be invalid with the new
  entry. Create an own plan with `scripts/setup.lua` and check it with `--check`; nothing is changed in the refused case.
- **The master page shows a computer in red**: its id is in the plan with another role. Two computers with the same id, or a changed role; fix one side and let the computer announce itself again.
- **A page is cut off or shows odd characters**: the wizard assumes a 51 x 19 terminal and plain ASCII. A smaller terminal wraps lines but needs more
  pages; report the size (`term.getSize()`) if a page does not fit.

## OTA update not applying

- Verify the master is running and nodes are registered before pushing
- Check Diagnostics for `ota_failed` audit entries
- The node must have write access to its disk (CC:Tweaked default: yes)
- After OTA, nodes reboot. If the node comes back on the old version, the new code did not reach its main loop and the node rolled itself back (`docs/OTA.md`), or the disk was full — check the log page
- A node from before the verified update does not answer the normal push: use `ota_push.lua --legacy --node ID` once

## Panel shows stale data

The panel node requests a full snapshot on connect. If data looks stale:
- Verify the panel_node is registered (appears in Overview → Nodes)
- Touch the right edge to cycle pages and force a redraw request
- Restart the panel_node to trigger a fresh snapshot request

## Fail-Safe behaviour

If the master is uncertain (missing nodes, recovery mode, maintenance), it forces signals RED. This is intentional. The system never grants permission when unsure.
