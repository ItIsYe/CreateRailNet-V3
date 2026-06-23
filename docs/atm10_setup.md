# ATM10 Setup Guide

## Zielumgebung
- Minecraft 1.21.x
- All the Mods 10 (ATM10)
- CC:Tweaked
- Create

## Hardware-Grundsetup
- 1 Master-Computer
- 1 Node-Computer pro Signal/Sensor/Weiche
- Wired Modems empfohlen
- Wireless nur optional

## Peripheral-Inspektion
```lua
print(textutils.serialize(peripheral.getNames()))
local name = peripheral.getNames()[1]
print(textutils.serialize(peripheral.getMethods(name)))
```

## Adapter-Modi
Jeder Node kann optional über Felder in `nodes[]` an echte Hardware gebunden werden:

```json
{"id":"SIG-1","role":"signal","adapter":"redstone","side":"right"}
```

Unterstützte Modi:
- `adapter` fehlt oder ist `peripheral`: nutzt die Create/Addon-Peripheral-Methoden.
- `adapter` ist `redstone`: nutzt CC:Tweaked Redstone-I/O über `side`.

## Signalsteuerung
Create Signale verwenden `setForcedRed(bool)` — nicht `setAspect`. Der Adapter setzt `setForcedRed(true)` für ROT und `setForcedRed(false)` für GRÜN.

Alternativ Redstone-Fallback:
```json
{"id":"SIG-1","role":"signal","adapter":"redstone","side":"right"}
```

Dabei gilt:
- `GREEN` oder `YELLOW` setzt den Redstone-Ausgang auf `true`.
- `RED` setzt den Redstone-Ausgang auf `false`.

## Sensoren
Create Train Observer verwendet `isTrainPassing()` — nicht `isOccupied()`. Der Adapter prüft `isTrainPassing()` primär, `isOccupied()` als Fallback für andere Mods.

Alternativ Redstone-Fallback:
```json
{"id":"SEN-1","role":"sensor","adapter":"redstone","side":"front"}
```

Dabei wird `redstone.getInput(side)` als Belegtmeldung gelesen.

## Weichen
**Vanilla Create Track Switches haben KEIN CC:Tweaked Peripheral.** Weichen müssen immer über Redstone gesteuert werden:

Redstone (einzige Option für vanilla Create):
```json
{"id":"SW-1","role":"switch","adapter":"redstone","side":"back","active_position":"DIVERGING"}
```

Dabei wird der Redstone-Ausgang aktiv, wenn die gewünschte Position der `active_position` entspricht. Optional kann `invert=true` gesetzt werden.

## Beispiel
Siehe:

```text
configs/templates/network.redstone.example.json
```

## Bekannte Limitierungen
`setAspect` und `isOccupied` existieren nicht in vanilla Create — der Adapter fällt automatisch auf `setForcedRed`/`isTrainPassing` zurück. `setPosition` existiert nicht als CC-Peripheral für Create-Weichen — ausschließlich Redstone verwenden. Redstone-Adapter sind zuverlässiger und empfohlen.

## Debug-Schritte
- Node registriert sich nicht: Modem-Kanal/ID prüfen.
- Signal bleibt rot: Adapter-Modus, `side` und Redstone-Verkabelung prüfen.
- Sensor meldet nichts: `redstone.getInput(side)` oder Peripheral-Methoden prüfen.
- Weiche stellt falsch: `active_position` und `invert` prüfen.
- Block FAULT: Timeout oder inkonsistentes Enter/Leave prüfen.

## Remote Updates (OTA)

Alle Computer im Netzwerk können remote aktualisiert werden:

```lua
-- Auf dem Master-Computer ausführen:
shell.run("scripts/ota_push.lua")

-- Spezifischen Node aktualisieren:
shell.run("scripts/ota_push.lua", "--node", "TRAIN-1")

-- Mit Versionstag:
shell.run("scripts/ota_push.lua", "--version", "v2.1")
```

Oder über das Panel: Manual-Seite → `OTA Push All` antippen.

Jeder Node empfängt die neuen Dateien, schreibt sie atomar und startet automatisch neu.

