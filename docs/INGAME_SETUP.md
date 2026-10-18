# CreateRailNet-V3 Ingame Setup

## Installation

Der empfohlene Weg ist der Installer (`docs/INSTALL.md`): ein Befehl lädt die Dateien der Rolle von GitHub, prüft sie und startet den Assistenten.

```
wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/main/installer
```

## Erste Einrichtung (der Assistent)

Der Installer startet den Assistenten selbst. Liegen die Dateien schon auf dem Computer (von Hand kopiert), startest du ihn so:

```lua
shell.run("scripts/setup.lua")
```

(`scripts/setup.lua --role <rolle>` überspringt die Rollenfrage.) Der Assistent richtet **diesen einen Computer** ein. Er stellt pro Seite eine Frage,
die Kopfzeile zeigt, wo du bist (`Rolle  [Netzplan]  Name  Hardware  Pruefen`), und bis zur Zusammenfassung wird **nichts geschrieben**.

| Taste | Wirkung |
|---|---|
| Enter | den Vorschlag in `[ ]` übernehmen |
| `?` | Hilfe zur aktuellen Frage (eigene Seite, danach geht es an derselben Stelle weiter) |
| `<` | einen Schritt zurück; auf der ersten Frage: fragt, ob die Einrichtung abgebrochen werden soll |
| Strg+T | bricht ab; vor dem Schreiben (Schritt „Prüfen") bleibt alles unverändert |

### Die Schritte

1. **Rolle**: Master, Signal, Melder, Weiche, Bahnhof, Depot, Zug oder Monitor. Vom Installer vorgegeben, wenn er den Assistenten startet.
2. **Netzplan**: der Netzplan ist die Datei, die dein ganzes Netz beschreibt (Computer, Blöcke, Routen). Jeder Computer hat seine eigene Kopie unter
   `configs/network.json`.
   - *Master*: vorhandenen Plan behalten, **ein Beispiel als Startpunkt kopieren**, einen **leeren Plan** anlegen (nur der Master) oder eine eigene Datei angeben.
     Den Plan baust du danach aus (`docs/config_reference.md`) und prüfst ihn mit `scripts/setup.lua --check`.
   - *Alle anderen*: einen **Kurzplan** anlegen (empfohlen; nur dieser Computer und der Master, gültig für sich allein), ein Beispiel direkt verwenden
     (wird nur gelesen) oder eine eigene Datei angeben. Kanal und Master-ID werden nur beim Kurzplan gefragt.
3. **Name**: die ID des Computers. Steht im Netzplan schon ein Eintrag mit dieser Rolle, wählst du ihn aus einer Liste; sonst schlägt der Assistent die
   nächste freie ID vor (`SIG-1`, `SIG-2`, ...). Der Master nimmt die ID aus dem Plan.
4. **Hardware**: nur was nötig ist. Der Assistent sucht die angeschlossenen Geräte selbst (Modem, Create-Signal, Train Observer, Create-Bahnhof, Monitor)
   und lässt dich das richtige auswählen. Steht im Netzplan schon alles zu diesem Computer, entfällt der Schritt; fehlt nur das Gerät, weist er darauf hin.
   - Kein Modem: eine deutliche Warnung (der Computer kann nicht mit dem Netz sprechen), du darfst trotzdem weitermachen und das Modem später anbauen.
   - Weiche: Seite des Redstone-Ausgangs, Stellung bei Signal, Signal umkehren.
   - Signal und Melder: Create-Gerät am Computer oder Redstone an einer Seite.
5. **Prüfen**: eine Seite mit allem, was gleich geschrieben wird (Rolle, ID, Kanal, Master, Netzplan, Anschluss) und der Angabe, welche Dateien
   neu entstehen. `J` schreibt, `N` lässt einen Schritt noch einmal machen, `A` bricht ab.

Danach bekommst du eine **Abschlussseite**: beim Master die nächsten Schritte, bei allen anderen die Zeile für `nodes` im Netzplan des Masters
(zum Abschreiben), dann die Frage nach dem Neustart.

### Was geschrieben wird

| Datei | Wann | Hinweis |
|---|---|---|
| `startup.lua` | immer | Rolle, ID, Netzplan-Pfad; mit Wiederherstellung (`docs/OTA.md`); alte Fassung bleibt als `startup.lua.prev` |
| `configs/network.json` | Master: Beispiel kopiert / leer angelegt. Andere: Kurzplan. Nicht bei „behalten" oder „verwenden" | alte Datei bleibt als `network.json.prev`; vorher fragt der Assistent, ob er überschreiben darf |

Alles wird über eine temporäre Datei geschrieben, zurückgelesen und geprüft (`src/shared/safe_write.lua`). Ein erzeugter Netzplan muss die Prüfung des Masters
bestehen (`validate_config`), sonst wird nichts geschrieben. Ein vorhandener Netzplan mit Fehlern wird gezeigt und nur auf
ausdrücklichen Wunsch übernommen.

### Ein Netz in der Praxis

1. **Master** zuerst: Beispiel kopieren (oder leer anlegen), danach `configs/network.json` ausbauen: Blöcke, Routen, Computer eintragen, mit
   `scripts/setup.lua --check` prüfen.
2. **Jeder andere Computer**: Installer, Rolle, Kurzplan (gleicher Kanal und Master-ID wie beim Master), Name, Hardware. Am Ende zeigt der Assistent die
   Zeile für den Netzplan des Masters. Steht der Computer dort schon (Beispiel-Plan), wählst du ihn in Schritt 3 aus der Liste und trägst nichts nach.
3. Jeder Computer gehört in `nodes` des Masters: Blöcke und Routen verweisen auf diese IDs.

### Netzplan prüfen

```
scripts/setup.lua --check              prüft configs/network.json
scripts/setup.lua --check <datei>      prüft eine andere Datei
```

Das ändert nichts. Es meldet „in Ordnung (5 Computer, 1 Block, 1 Route)" oder nennt jeden Fehler mit seinem Pfad im Plan (zum Beispiel
`nodes[2].role: ...`). Der Master startet mit einem fehlerhaften Plan nicht. `lua scripts/check_configs.lua` ist dagegen ein Entwicklungsskript für die
Beispiele im Repository und liegt nicht auf den Spiel-Computern.

Neu einrichten: den Assistenten noch einmal starten. Auf einem bereits eingerichteten Computer fragt er zuerst, ob er neu einrichten soll
(Nein ändert nichts); die alten Antworten sind teils als Vorschlag da. Computer, die mit einer älteren Version eingerichtet wurden, laufen weiter: sie fügen
die fehlende OTA-Wiederherstellung ihrer `startup.lua` selbst hinzu, und die neuen Dateien erreichen sie mit `scripts/ota_push.lua --legacy`
(`docs/OTA.md`). Nach der ersten Einrichtung einer Welt einmal `docs/INGAME_TESTS.md` durcharbeiten.


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
