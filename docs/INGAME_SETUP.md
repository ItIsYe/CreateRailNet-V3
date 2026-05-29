# CreateRailNet-V3 Ingame Setup

## Ziel

Diese Datei beschreibt den einfachen Start in CC:Tweaked / ATM10.

## Minimaler Ablauf

1. Repository-Dateien auf die Computer kopieren.
2. Auf jedem Computer eine Rolle wählen.
3. Eine passende Startdatei aus `scripts/` als `startup.lua` kopieren oder direkt ausführen.
4. `configs/templates/network.full.example.json` an deine Welt anpassen.
5. Config prüfen, bevor du echte Hardware schaltest.

## Starter

### Master

```lua
shell.run("scripts/start_master.lua")
```

### Train

```lua
shell.run("scripts/start_train.lua")
```

### Panel

```lua
shell.run("scripts/start_panel.lua")
```

### Signal

```lua
shell.run("scripts/start_signal.lua")
```

### Sensor

```lua
shell.run("scripts/start_sensor.lua")
```

### Switch

```lua
shell.run("scripts/start_switch.lua")
```

### Station

```lua
shell.run("scripts/start_station.lua")
```

### Depot

```lua
shell.run("scripts/start_depot.lua")
```

## Config Check

Vor dem Ingame-Test:

```lua
local check = require("src.tools.config_check")
check.run("configs/templates/network.full.example.json")
```

Das prüft Struktur, Rollen, Routen, Service-Pläne, Stops und Referenzen.

## Dry-Run System Check

Ohne reale Hardware zu schalten:

```lua
local sys = require("src.tools.system_check")
sys.run("configs/templates/network.full.example.json")
```

Der Check baut Domain-Modelle auf und testet einen Dispatcher-Reservierungspfad mit Fake-Adaptern.

## Peripheral Inspector

Zum Prüfen von Methoden und Seiten:

```lua
local insp = require("src.tools.peripheral_inspector")
insp.run()
```

Oder für eine Seite:

```lua
local insp = require("src.tools.peripheral_inspector")
insp.run({ side = "left" })
```

Das ist besonders wichtig für Create Train Schedule, weil die echten Methoden im Modpack/Peripheral sichtbar gemacht werden müssen.

## Debug Events

Sichere Testevents an den Master senden:

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "sensor", sensor_id = "SEN-AB", action = "enter" })
```

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "train_depart", train_id = "TRAIN-1", from = "ST-A", to = "ST-B" })
```

```lua
local dbg = require("src.tools.debug_events")
dbg.run({ kind = "train_arrived", train_id = "TRAIN-1", station = "ST-B" })
```

## Wichtige Config-Felder

- `channel`: gemeinsamer Funkkanal
- `master_id`: ID des Master-Computers
- `nodes`: alle Rollen im Netz
- `blocks`: reale Gleisabschnitte
- `routes`: fahrbare Routen über Blöcke
- `service_plans`: Umläufe/Fahrpläne für Trains

## Manual Panel

Panel Actions werden in der Panel-Node definiert:

```json
"manual_actions": [
  {"label": "Hold TRAIN-1", "action": "hold_train", "train_id": "TRAIN-1"},
  {"label": "Signal AB Green", "action": "set_signal", "signal_id": "SIG-AB-IN", "aspect": "GREEN"}
]
```

Auf der `manual`-Seite wird die Zeile angetippt und als `manual_control` an den Master gesendet.
