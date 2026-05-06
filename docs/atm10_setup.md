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

## Signalsteuerung
Primär über Adapter mit Peripheral-Methoden; Fallback kann Redstone sein.

## Sensoren
Nutze Detector/Peripheral; fallback ist Redstone-Input.

## Weichen
Je nach Setup per Peripheral oder Redstone.

## Bekannte Limitierungen
`setAspect`, `isOccupied`, `setPosition` sind in ATM10 nicht garantiert und müssen ingame geprüft werden.

## Debug-Schritte
- Node registriert sich nicht: Modem-Kanal/ID prüfen.
- Signal bleibt rot: Adapter-Methoden prüfen.
- Sensor meldet nichts: Methoden/Redstone-State prüfen.
- Block FAULT: Timeout oder inkonsistentes Enter/Leave prüfen.
