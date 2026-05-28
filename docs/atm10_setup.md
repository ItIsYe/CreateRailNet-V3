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
Primär über Adapter mit Peripheral-Methode `setAspect(aspect)`.

Redstone-Fallback:
```json
{"id":"SIG-1","role":"signal","adapter":"redstone","side":"right"}
```

Dabei gilt:
- `GREEN` oder `YELLOW` setzt den Redstone-Ausgang auf `true`.
- `RED` setzt den Redstone-Ausgang auf `false`.

## Sensoren
Primär über Peripheral-Methode `isOccupied()`.

Redstone-Fallback:
```json
{"id":"SEN-1","role":"sensor","adapter":"redstone","side":"front"}
```

Dabei wird `redstone.getInput(side)` als Belegtmeldung gelesen.

## Weichen
Primär über Peripheral-Methode `setPosition(position)`.

Redstone-Fallback:
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
`setAspect`, `isOccupied`, `setPosition` sind in ATM10 nicht garantiert und müssen ingame geprüft werden. Redstone-Fallback ist einfacher, aber kann je nach Verkabelung nur binäre Zustände abbilden.

## Debug-Schritte
- Node registriert sich nicht: Modem-Kanal/ID prüfen.
- Signal bleibt rot: Adapter-Modus, `side` und Redstone-Verkabelung prüfen.
- Sensor meldet nichts: `redstone.getInput(side)` oder Peripheral-Methoden prüfen.
- Weiche stellt falsch: `active_position` und `invert` prüfen.
- Block FAULT: Timeout oder inkonsistentes Enter/Leave prüfen.
