# Troubleshooting

## Signals always RED

Signals default to RED when the master cannot confirm safety. This is by design.

Causes and fixes:
- **Node not registered**: The signal_node may not have connected. Check the modem channel and that `master_id` in config matches the master's actual node ID.
- **Block in FAULT**: Any FAULT block on a route forces all signals on that route red. Clear the fault by resolving the sensor state and re-registering the node.
- **Master in RECOVERY mode**: After a restart, the master enters recovery mode and holds all signals red until an operator confirms recovery from the panel or via `confirm_recovery` manual action.
- **Maintenance mode active**: All departure signals are held red in maintenance mode.

## Block stuck in FAULT

A block enters FAULT when:
- A sensor sends `leave` without a prior `enter` (sequence error)
- A node times out while a block is reserved or occupied
- The signal hardware fails to respond (`setForcedRed` returns error)

Fix:
1. Check the sensor node is running and sending heartbeats
2. On the panel, navigate to Diagnostics to see the specific error
3. Use `manual_control` → `clear_fault` with the block_id to release (if implemented), or restart the affected sensor_node
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

## OTA update not applying

- Verify the master is running and nodes are registered before pushing
- Check Diagnostics for `ota_failed` audit entries
- The node must have write access to its disk (CC:Tweaked default: yes)
- After OTA, nodes reboot. If the node comes back on the old version, the `crn_version.txt` write may have failed — check disk space

## Panel shows stale data

The panel node requests a full snapshot on connect. If data looks stale:
- Verify the panel_node is registered (appears in Overview → Nodes)
- Touch the right edge to cycle pages and force a redraw request
- Restart the panel_node to trigger a fresh snapshot request

## Fail-Safe behaviour

If the master is uncertain (missing nodes, recovery mode, maintenance), it forces signals RED. This is intentional. The system never grants permission when unsure.
