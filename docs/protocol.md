# Network Protocol

## Message Format

All messages are JSON tables transmitted over a shared modem channel:

```
{
  v   = 1,                          -- protocol major version, must match
  pv  = 5,                          -- protocol revision (additive changes only; older nodes send none = 1)
  type = "register|heartbeat|cmd|event|ack|err|auth",
  id  = "<unique string>",          -- for dedup and ack matching
  src = "<node_id>",
  dst = "<node_id>|broadcast",
  ts  = <ms since epoch>,           -- time.now_ms()
  payload = { ... },
  -- revision 5, only with config.auth_mode monitor / enforce (docs/KEYS.md):
  ss = "<session>", sq = <n>, ke = <key epoch>, ch = "<challenge nonce>", at = "<mac, 32 hex>"
}
```

## Message Types

**register** — node announces itself on connect or reconnect.
Payload includes `role` and full node state (platforms, tracks, etc.).
Master replies with ack. Reliable delivery.

**heartbeat** — periodic liveness signal (every 2s by default).
Master updates `last_seen`. Fire-and-forget. Payload: `role`; a sensor adds `occupied` (boolean, what its detector shows now, absent while the
read fails) which the master uses to clear blocks after an outage (`docs/OPERATIONS.md`).

**cmd** — master sends a command to a node.
Always reliable (`send_reliable`). Node replies with ack or err.
Key commands: `depart_authorized`, `hold_position`, `set_aspect`, `set_position`, `ota_update`.

**event** — node sends an occurrence to the master.
Critical events use `send_reliable` (sensor enter/leave, arrived, request_departure, etc.).
Status-only events are fire-and-forget.

**ack** — acknowledgement. Payload: `{ ack_id = "<original msg id>", applied = true|nil }`.
Cancels the retry entry for that message. Without `applied` it means *delivered* (transport level, e.g. an OTA chunk that
was stored). With `applied = true` the receiver also did what the message asked: a node ran the command, the master handled the
event. `net.on_ack(ack_payload, original_message)` lets the sender tell the two apart.

**err** — command failed. Payload: `{ ref_id, error }`.

## Validation and who may send what

`net.receive` is fail-closed: a message with a wrong major version, an id/src/dst that is not a non-empty string of sane length,
an unknown `type`, a payload that is not a table, or a non-numeric `ts`/`pv` is `"invalid"` and dropped. The revision a peer
announced is kept (`net.peer_revision(id)`, at most 1024 peers) so newer features can be used only towards nodes that have them;
during a rolling OTA old and new nodes talk to each other, so changes to the envelope stay additive.

- **Commands to a node** are executed only when `src` is `master_id` or listed in `config.cmd_sources`; anything else gets an
  `err` ("source not allowed") and is logged once per sender and minute. OTA commands follow `config.ota_sources` instead
  (see `docs/OTA.md`), so the OTA tool can update but not steer.
- **The plan decides who is a node.** The master registers a computer, and handles its events, only when the plan lists its id with the
  role it announces. Any other computer (not in the plan, or in the plan with another role) is a pairing candidate and nothing else: it is
  not registered, its events are not handled, it gets no panel snapshot, and no alert is raised for it (a stranger must not be able to fill
  the alerts; one audit line per minute covers all of them). Only `pair_announce` and `pair_probe` are open to every computer. A plan
  without nodes admits nobody.
- **An event type belongs to one role**: `sensor` from a sensor (and only about itself, `payload.sensor_id == src`); `request_departure`,
  `arrived`, `train_status`, `schedule_applied`, `train_fault` from a train; `station_*`, `platform_status`, `train_arrived_station`,
  `train_left_station` from a station; `depot_*` from a depot; `manual_control` and `panel_request_snapshot` from a panel, and for manual
  control the panel must also be registered (it has been heard). Other events (log, update) come from any node of the plan. Rejected
  events of a computer of the plan are audited (`event_rejected`), raise a yellow alert, and are still acknowledged so the sender stops
  retrying.
- **Heartbeats** of nodes of the plan that the master does not know (it restarted, nodes only register at their own start) register them
  (`node_adopted`); a heartbeat or register of a node that was DOWN is audited as `node_reconnect`.

## Pairing (revision 3)

Revision 3 adds a way for a computer to say "I am this entry of the plan" and for the master to answer where it stands. Everything is
additive: an older master ignores the new event, an older node never sends it, and the master sends `pair_state` only to peers that
announced revision 3 or newer (`net.peer_revision`).

| Message | Direction | Payload |
|---|---|---|
| `pair_announce` (event, reliable) | node -> master | `{ type, role, entry, setup }`: `entry` is the node's own entry of its plan (or none), `setup` is `{ state, fail, warn, version }` from its `crn_status.lua` record |
| `pair_probe` (event, reliable) | setup wizard -> master | same payload; sent by `scripts/setup.lua` for the link test. It registers nothing: a master that knows the computer answers `known`, otherwise the computer waits as a candidate like after an announcement |
| `pair_probe` filler | setup wizard (`--linktest`) | `pair_probe` may carry `pad` (a string of filler, only its size matters; it is not kept) and `echo = n` (1 .. 4000): the answer then carries `pad` of n bytes. This measures which message size passes the link in both directions. A master that does not know `echo` answers without `pad` (the tool reports that). Additive within revision 4 |
| `pair_state` (cmd) | master -> node | `{ cmd = "pair_state", state, detail, probe_id? }`; sent to a node when its state changes (unasked), answered with an ack. A `pair_probe` is a question and is answered **every time**, even with the same state as before; that answer carries `probe_id` (the id of the probe message), and the asking side ignores an answer that names another probe |

States: `known` (in the plan with this role), `pending` (waits for the operator), `conflict` (the id is in the plan with another role; `detail`
is the planned role), `rejected` / `muted` (the operator said no; ignored for 10 minutes), `full` (64 candidates already wait), `invalid`
(no sane id or role; no answer). A node starts announcing once the master has shown revision 3 (its first message carried `pv`); it announces every 20 s until the master answered,
every 300 s while it waits for the operator and every 600 s once it is known, so a master that restarted learns about it again.

Nothing is granted by announcing. What arrives is cut down before it is kept: a sane id, a role of ours, a small table of plain values
whose `id` and `role` are those of the sender, at most 64 candidates, forgotten after an hour without a sign. Only
`runtime.pair_decide("accept", id, operator)` (a deliberate two-touch on the master page *Einrichtung*) writes the entry into the plan file
(`safe_write`, the old file stays as `.prev`, refused for a template plan or a plan that does not validate before and after). Both
decisions are audited (`node_accepted`, `pair_rejected`, also `pair_candidate`, `pair_conflict`).

## The plan of the master (revision 4)

A station or depot computer reads its platforms / tracks from its own plan, and a plan is more than one modem message holds, so the setup wizard of that computer fetches it part by part. The computer asks, the master
answers; the master never sends a plan unasked. Additive again: an older master does not know `plan_get` and stays silent (the asker reports "no answer").

| Message | Direction | Payload |
|---|---|---|
| `plan_get` (event, reliable) | computer -> master | `{ type = "plan_get", role, index, version? }`: part `index` (1 = start of a transfer, reads the file again); `version` is the Adler-32 (8 hex characters) the asker began with, absent for part 1 |
| `plan_part` (cmd, plain) | master -> computer | `{ cmd = "plan_part", question = <id of the plan_get>, ok = true, index, total, version, size, data }` or `{ ok = false, state, reason }` |

`state` of a failure: `refused` (reason `not_in_plan` / `conflict` / `role` / `unavailable`: only a station or depot that the plan lists with that role gets the plan; everybody else gets this small answer and nothing is kept for them),
`changed` (the plan on the master's disk is no longer the one the asker began with: start again), `error` (reason in German: file missing, empty, too big, not valid). The master reads the plan **file** as it lies on its disk and hands
it out only when it parses and validates; part 1 reads it again, later parts come from the one cached text (60 s). A part is 3000 bytes of the text; `version` is the Adler-32 of the whole text. `plan_part` is not sent reliably: the
asker asks again for a part that did not arrive (three times, then it gives up).

The asker checks everything before it uses it: sender is the master, `question` is the id of its own request, `index`/`total`/`size`/`version`/`data` are sane (at most 60 parts, 200000 bytes, parts of at most 8192 bytes), `total`,
`size` and `version` stay the same in every part, size and Adler-32 of the assembled text match, the text is a valid plan, channel and master id are those of this computer, and the plan lists this computer with its role. A plan
that changed or arrived damaged is fetched again (twice at most). Whether to write it is the player's decision (`docs/INGAME_SETUP.md`).

## Authentication (revision 5)

With `auth_mode` `monitor` or `enforce` every message carries `ss` (the session of the sender, new at every boot), `sq` (a count per sender, receiver and session), `ke` (the
key epoch, in messages between a master and a computer), `ch` (the nonce the receiver handed out) and `at`: HMAC-SHA-256, cut to 16 bytes, over the canonical form (`src/shared/canon.lua`) of
`crn1`, `src`, `dst`, `type`, `id`, `pv`, `ts`, `ss`, `sq`, `ke`, `ch` and `payload`. A message between a master and a computer is signed with that computer's key (the masters derive it from the master key,
the id and the epoch of the trust list); two masters use a key for that pair. Nothing else is accepted as authenticated: `msg.authenticated` is set by the receiving net after the check and always overwritten.

**Sessions.** A receiver that does not know the session of a sender (it restarted, or the sender did) does not process the message. It answers with `type = "auth"`, payload `{ kind = "challenge", for_ss, nonce, ss }`,
signed like any message. The sender takes the nonce, repeats everything that waits for that receiver with `ch = nonce`, and answers with a challenge of its own (without `ss`, so it does not go on) so the
answers to its first message are not lost either. An old recording has no valid nonce. At most one challenge goes out per sender and 250 ms.

**Replay window.** `sq` is accepted when it is new inside a window of 256 below the highest seen; one seen already is `"duplicate"` (retries whose acknowledgement got lost are answered again, nothing is carried out twice);
one older than the window is refused (`auth_failed`, `replay`). `net.receive` returns `"auth_failed", reason` for a message that is refused (`unsigned`, `bad_mac`, `no_key`, `unknown_peer`, `revoked`, `stale_key`, `replay`, `overload`,
`bad_field`, `broadcast`), `"challenge"` / `"auth"` for the handshake.

**Open messages.** Without a MAC only `event` of type `pair_announce`, `pair_probe`, `plan_get` and `cmd` `pair_state`, `plan_part` are accepted (a computer that is not part of the net yet must be able to say so; the
answers are checked by what they carry). A broadcast is never accepted as authenticated.

**Load limit.** At most 400 MAC checks per second for all senders together, and 5 per second for a sender that failed ten checks in the last ten seconds.

## Two masters and the arbiter (high availability)

The election between master A, master B and the arbiter is carried by plain `cmd` messages with `cmd = "election"`, `kind` (`pre_vote_request`, `pre_vote_reply`, `vote_request`, `vote_reply`, `lead_beat`,
`lead_ack`) and the fields of `src/domain/election.lua`; they are sent without retry (the election repeats itself). Only the computers named in `config.masters` and `config.arbiter` are heard.
A command of a master to any other computer carries `election_epoch` (the term of its leadership), `election_leader` (its id) and `election_proof` (the voters that elected it). The receiver refuses
a lower epoch than the highest it has seen (`state/crn_epoch.json`) and, in a plan with two masters, a command without an epoch. `pair_state` may carry `masters` and `arbiter`: the topology a
computer with a short plan learns from its master. Details: `docs/HA.md`.

**State replication between the masters (dual commit).** The leader sends the standby the change of its dispatcher state as `cmd` messages with `cmd = "repl"` and `kind`:
`entry` (`idx`, `term`, `prev_idx`, `prev_term`, `delta`), `ack` / `nack` (the standby holds the entry durably / lacks the one before), `commit` (`idx`), `ping`, `sync` (a full copy of the state when the
standby is too far behind) and `part` (a body over 2800 bytes is split; each part carries a checksum of the whole). Only the other master is heard. A command that gives movement (route, departure, schedule,
a signal that is not red) is sent to a node only after the standby has acknowledged the entry it depends on; it then carries `command_id = "<idx>.<n>"`, and a node carries a command with the same
`election_epoch` and `command_id` out once, whatever the message id. A restrictive command (red, stop) never waits. Details: `docs/HA.md`.

## Reliability

`send_reliable` adds the message to a pending table. `tick()` retries with exponential backoff:
- Base interval: 200ms
- Max interval: 5000ms
- Max retries: 5

After 5 failed retries, `on_drop` fires and the node is marked potentially down.

Message ids are `<node>.<boot nonce>.<n>`. Every computer counts from 1 after a boot, so bare numbers collide between nodes
and between two boots of one node. Deduplication keys on `src/id` with a 30s TTL.

A duplicate means the sender never saw our answer (the ack got lost). The receiver answers again without redoing the work:
a node repeats the ack, or the err for a command that failed (it remembers the outcome of recent commands for 30s); the master
acks duplicate `event` and `register` messages again. Duplicate heartbeats and acks get no answer.

## Event Types (node → master)

| Event type | Sender | Reliable |
|---|---|---|
| `sensor` (enter/leave) | sensor_node | ✅ |
| `request_departure` | train_node | ✅ |
| `arrived` | train_node | ✅ |
| `schedule_applied` | train_node | ✅ |
| `train_status` | train_node | ❌ heartbeat |
| `train_arrived_station` | station_node | ✅ |
| `train_left_station` | station_node | ✅ |
| `station_ready_departure` | station_node | ✅ |
| `depot_train_arrived` | depot_node | ✅ |
| `depot_train_left` | depot_node | ✅ |
| `depot_train_ready` | depot_node | ✅ |
| `depot_request_dispatch` | depot_node | ✅ |
| `manual_control` | panel_node | ✅ |
| `ota_result` | any node | ❌ best-effort |
| `pair_announce` | any node | ✅ (revision 3) |
| `pair_probe` | setup wizard | ✅ (revision 3) |
| `plan_get` | setup wizard (station / depot) | ✅ (revision 4) |

## OTA Update Protocol

See `docs/OTA.md` for the full procedure. All commands are reliable `cmd` messages from the master or the OTA tool
(`OTA-TOOL`); nodes accept them only from `master_id` and `config.ota_sources`.

| Message | Direction | Payload |
|---|---|---|
| `ota_offer` | to node | `{ update_id, version, files = [{path, size, adler}] }` |
| `ota_need` (event) | from node | `{ update_id, need = [paths], reason? }` only files that differ |
| `ota_chunk` | to node | `{ update_id, path, index, total, data }` |
| `ota_commit` | to node | `{ update_id }` quiesce, swap, reboot |
| `ota_abort` | to node | `{ update_id }` |
| `ota_result` (event) | from node | `{ update_id, node_id, success, version, files, errors, up_to_date }` |
| `ota_confirmed` (event) | from node | `{ node_id, version }` after the first good boot of the new code |
| `ota_update` | to node | single-message form `{ files = [{path, content, adler?}], version, update_id? }`. New nodes apply it through the same safe path; nodes from before the verified update understand only this (`ota_push.lua --legacy`) and answer `ota_result` without `update_id`, to `broadcast` |
