# Configuration Reference

All topology is declared in JSON, nothing is hard-coded. `lua scripts/check_configs.lua` (and the master at start) validate a file;
`validate.validate_config` names the path of every problem, for example `auto_clear_stable_s: must be a number >= 0`.

## Where the plan lives

Every computer has its own network plan, `configs/network.json` by default (the path stands in its `startup.lua`). The setup wizard creates it
(`docs/INGAME_SETUP.md`): on the master as a copy of an example or an empty plan that you extend, on every other computer as a **short plan**, which is
valid on its own and holds only this computer and the master:

```
{
  "v": 1,
  "channel": 777,
  "master_id": "MASTER-1",
  "nodes": [
    {"id": "MASTER-1", "role": "master"},
    {"id": "SIG-1", "role": "signal", "adapter": "peripheral", "peripheral": "Create_Signal_0"}
  ],
  "blocks": [],
  "routes": []
}
```

The master needs an entry in `nodes` for every computer, with the same fields. `scripts/setup.lua --check [file]` validates a plan on the computer.

A **station or depot** computer needs its `platforms` / `tracks` in its own plan. The master's plan is the source: put them in the entry of that computer there and let the computer fetch the plan
(`scripts/setup.lua --fetch-plan`, `docs/INGAME_SETUP.md`); the computer writes it to its own `configs/network.json` after a yes.

A computer that is not in the master's plan yet does not have to be typed in: it announces itself, waits on the master's page *Einrichtung* and is written
into the plan file when the operator accepts it (`docs/INGAME_SETUP.md`). The master then writes the plan in the format of the setup wizard (stable key
order, the old file stays as `<file>.prev`); a plan that is a bundled template (`configs/templates/...`) is never written to.

## Top-Level

| Key | Type | Default | Meaning |
|---|---|---|---|
| `v` | number | required | schema version, `1` |
| `channel` | number | required | modem channel of the network |
| `master_id` | string | required | node id of the master |
| `blocks` | array | required | block definitions |
| `routes` | array | required | route definitions |
| `nodes` | array | required | node definitions |
| `interlocking_routes` | array | none | adds flank protection / overlap to routes (see below) |
| `service_plans` | array | none | multi-stop journeys for trains |

### Tuning (all optional)

| Key | Default | Meaning |
|---|---|---|
| `heartbeat_timeout_s` | 6 | a node that is silent this long is DOWN and its blocks go FAULT. Raise to 15 on a laggy server |
| `sensor_guard_min_occupy_ms` | see `sensor_guard.lua` | shortest plausible stay on a detector; `0` switches the check off |
| `require_release` | `false` | `true`: after every start of the master no train starts a journey until the operator touches **[BETRIEB FREIGEBEN]** on the page *Einrichtung* (only possible when every signal / sensor / switch / station / depot computer of the plan is online and no block is in FAULT; `docs/OPERATIONS.md`). A restart takes the release back |
| `auto_clear_faults` | `true` | blocks that went FAULT because a node timed out clear themselves (`docs/OPERATIONS.md`); `false` = operator only |
| `auto_clear_stable_s` | 15 | how long every node of the cause has to be back before the block may clear |
| `auto_clear_max_age_s` | 10 | oldest detector report that still counts as "free" |
| `signal_refresh_per_s` | 2 | blocks per second whose signals are sent again (rolling refresh); `0` = off |
| `signal_red_on_stop` | `true` | the master puts every signal to RED when it stops (Ctrl+T, crash) |
| `startup_autoupgrade` | `true` | a node adds the OTA recovery to an older `startup.lua` by itself (`docs/OTA.md`) |
| `cmd_sources` | master only | extra sender ids a node accepts commands from |
| `ota_sources` | `["OTA-TOOL"]` | sender ids that may start an update (plus the master) |
| `log_forward` | `true` | `false` keeps a node's warnings to itself |
| `log_sink` | master | node id that receives the forwarded log |
| `trace_capacity` | 500 | dispatcher calls kept for replay (`scripts/replay_trace.lua`) |
| `state_file` | `state/master_state.json` | dispatcher snapshot (written with a `.prev` backup) |

## Block
```
{ "id": "B1",
  "entry_signal": "SIG-1",
  "exit_signal": "SIG-2",
  "sensors": ["SEN-1"],
  "switches": [{"id":"SW-1","position":"STRAIGHT"}],
  "gleisbild_pos": {"x": 4, "y": 2} }
```
A block without `sensors` works, but a timed-out block of that kind can only be cleared by the operator (nothing can show it free).
`gleisbild_pos` is optional and places the block on the gleisbild page.

## Route
```
{ "id": "R1", "from":"A", "to":"B", "blocks":["B1"], "priority":10 }
```
`blocks` are driven in this order. `conflict_group` / `conflict_groups` add exclusion groups on top of the automatic ones
(`block:<id>` per block, `opp:<from><->to` against the opposite direction; see `docs/DISPATCHER_SAFETY.md`).

## Interlocking routes (optional)

Every route is also a Fahrstrasse: its entry/exit signal, switch positions and the signals of its blocks are derived from the route
and its blocks. An entry with the id of a route only **adds** fields to it:

```
{ "id": "R1",
  "flank_protection": [{"switch_id": "SW-9", "position": "STRAIGHT"}],
  "overlap_block": "B-OVERRUN" }
```

- `flank_protection`: switches next to the route that are locked in the given position and set while the route is held.
- `overlap_block`: a block behind the exit signal (Durchrutschweg) that stays reserved for the train. A train that enters it
  turns the block FAULT.

An entry whose id is no route stands for itself and needs `entry_signal` and `blocks` (older configs).

## Node
```
{ "id":"SIG-1", "role":"signal" }
```
Roles: `master`, `signal`, `sensor`, `switch`, `station`, `depot`, `panel`, `train`. Hardware bindings (`adapter`, `peripheral`, `side`)
are described in `docs/CREATE_HARDWARE_ADAPTERS.md`; station, depot, train and panel keys in the respective documents.

The devices a computer talks and shows through are named in its own entry (the setup wizard writes them; both are optional):

| Key | Type | Meaning |
|---|---|---|
| `modem` | non-empty string | the modem to use, e.g. `modem_0` or `top`. Exactly this one is used: if it is missing the computer has no network (and says so) instead of picking another modem. Without the key the first modem found is used, which is a guess when there are several |
| `monitor` | non-empty string | the monitor of a master or panel, e.g. `monitor_0` or `left`. Real monitors are never called just `monitor`; a missing named monitor falls back to the first monitor found (logged), and the old name `monitor` still works for plans written before |

Both are checked by the validator (`<path>.modem: must be non-empty string`). A wrong shape in a plan (a number where a list is expected, a block entry that
is not an object) is reported with its path; it does not raise an error.
