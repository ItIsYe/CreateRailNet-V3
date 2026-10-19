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
Eine Einleitung gibt es nicht: die Tasten stehen am rechten Ende der Trennlinie unter jeder Kopfzeile.

| Taste | Wirkung |
|---|---|
| Enter | den Vorschlag in `[ ]` übernehmen |
| `?` | Hilfe zur aktuellen Frage (eigene Seite, danach geht es an derselben Stelle weiter) |
| `<` | einen Schritt zurück; auf der ersten Frage: fragt, ob die Einrichtung abgebrochen werden soll |
| Strg+T | bricht ab; vor dem Schreiben (Schritt „Prüfen") bleibt alles unverändert |

### Die Schritte

1. **Rolle**: Master, Signal, Melder, Weiche, Bahnhof, Depot, Zug oder Monitor (im Installer-Menü stehen dieselben Wörter). Vom Installer vorgegeben,
   wenn er den Assistenten startet.
2. **Netzplan**: der Netzplan ist die Datei, die dein ganzes Netz beschreibt (Computer, Blöcke, Routen). Jeder Computer hat seine eigene unter
   `configs/network.json`.
   - *Master*: vorhandenen Plan behalten, **ein Beispiel als Startpunkt kopieren**, einen **leeren Plan** anlegen (nur der Master) oder eine eigene Datei angeben.
     Den Plan baust du danach aus (`docs/config_reference.md`) und prüfst ihn mit `scripts/setup.lua --check`.
   - *Alle anderen*: einen **Kurzplan** anlegen (empfohlen; nur dieser Computer und der Master, gültig für sich allein) oder eine eigene Datei angeben
     (wird nur gelesen). Die Beispielpläne werden Nodes nicht angeboten: ihre Gerätenamen sind Platzhalter. Kanal und Master-ID werden nur beim Kurzplan gefragt.
3. **Name**: die ID des Computers. Steht im Netzplan schon ein Eintrag mit dieser Rolle, wählst du ihn aus einer Liste; sonst schlägt der Assistent die
   nächste freie ID vor (`SIG-1`, `SIG-2`, ...). Der Master nimmt die ID aus dem Plan.
4. **Hardware**: nur was nötig ist. Der Assistent sucht die angeschlossenen Geräte selbst (Modem, Create-Signal, Train Observer, Create-Bahnhof, Monitor).
   Hängt genau ein passendes Gerät am Computer, ist das **eine** Ja/Nein-Frage („Dieses Gerät verwenden?"), sonst eine Auswahl. Steht im Netzplan schon
   alles zu diesem Computer, entfällt der Schritt; fehlt nur das Gerät, weist er darauf hin.
   - **Modem**: kein Modem hält an („Trotzdem ohne Modem weitermachen?", Enter bricht ab). Bei **mehreren** Modems wählst du eins; der Name kommt als
     `modem` in den Plan und der Computer nimmt nie ein anderes. Mit einem einzigen wird es von selbst gefunden.
   - **Monitor** (Master, Monitor, Bahnhof, Depot, Zug): bei mehreren die Wahl, sonst wird der gefundene genommen (Feld `monitor` im Plan, nur wenn gewählt;
     beim Monitor-Computer immer).
   - Weiche: Seite des Redstone-Ausgangs, Stellung bei Signal, Signal umkehren. Signal und Melder: Create-Gerät am Computer oder Redstone an einer Seite.
5. **Prüfen**: eine Seite mit allem, was gleich geschrieben wird (Rolle, ID, Kanal, Master, Netzplan, Anschluss, Modem, Monitor) und der Angabe, welche
   Dateien neu entstehen. `J` schreibt, `N` lässt einen Schritt noch einmal machen, `A` bricht ab.

### Danach: Prüfung, Verbindungstest, Abschluss

Nach dem Schreiben sieht sich der Assistent **das Geschriebene** an (der Doktor, `docs/OPERATIONS.md`): Installation vollständig, `startup.lua`, Netzplan,
Eintrag dieses Computers, Modem, Geräte der Rolle, Monitor, freier Speicher, Dateistand. Ein Node fragt außerdem den **Master**, ob er ihn kennt
(bis zu 6 Sekunden). Ist alles grün, steht auf der Abschlussseite nur „Prüfung: Alles in Ordnung". Gibt es etwas Gelbes (Hinweis) oder Rotes (Fehler), kommen
zwei Seiten: die Liste und „was zu tun ist". **Rot und Enter startet nicht neu**: erst beheben, dann `reboot`.

Die Abschlussseite zeigt beim Master die nächsten Schritte. Bei einem Node steht dort entweder „Der Master kennt diesen Computer schon", oder die Zeile, die
im Netzplan des Masters unter `nodes` fehlt (zum Abschreiben, sie steht auch in der eigenen `configs/network.json`). Weil dann der Neustart die Seite
löschen würde, ist die Antwort auf „Jetzt neu starten?" in diesem Fall **Nein**, wenn du nur Enter drückst.

### Was geschrieben wird

| Datei | Wann | Hinweis |
|---|---|---|
| `startup.lua` | immer | Rolle, ID, Netzplan-Pfad; mit Wiederherstellung (`docs/OTA.md`); alte Fassung bleibt als `startup.lua.prev` |
| `configs/network.json` | Master: Beispiel kopiert / leer angelegt. Andere: Kurzplan. Nicht bei „behalten" oder „eigene Datei" | alte Datei bleibt als `network.json.prev`; vorher fragt der Assistent, ob er überschreiben darf |
| `crn_status.lua` | immer | das Prüfprotokoll: `KONFIGURIERT`, `GEPRUEFT` oder `PRUEFUNG_OFFEN`, mit Zeit, Dateistand, Zahl der Fehler und Hinweise |

Alles wird über eine temporäre Datei geschrieben, zurückgelesen und geprüft (`src/shared/safe_write.lua`). Ein erzeugter Netzplan muss die Prüfung des Masters
bestehen (`validate_config`), sonst wird nichts geschrieben. Ein vorhandener Netzplan mit Fehlern wird gezeigt und nur auf ausdrücklichen Wunsch übernommen.
**Der Assistent schaltet nie ein Signal oder eine Weiche**: er liest die Geräteliste und fragt den Master, mehr nicht.

### Ein Netz in der Praxis

1. **Master** zuerst: Beispiel kopieren (oder leer anlegen), danach `configs/network.json` ausbauen: Blöcke und Routen eintragen (`edit configs/network.json`),
   mit `scripts/setup.lua --check` prüfen, neu starten.
2. **Jeder andere Computer**: Installer, Rolle, Kurzplan (gleicher Kanal und Master-ID wie beim Master), Name, Hardware. Läuft der Master, meldet sich der
   Computer von selbst (siehe unten) und du bestätigst ihn dort. Läuft er noch nicht, zeigt der Assistent die Zeile für den Netzplan des Masters.
3. Jeder Computer gehört in `nodes` des Masters: Blöcke und Routen verweisen auf diese IDs.
4. **Bahnhof und Depot** brauchen ihre Bahnsteige und Gleise (`platforms`, `tracks` mit `sensor_id` und `block_id`). Ein Computer liest aber nur seinen eigenen
   Netzplan und prüft ihn beim Start vollständig; mit dem Kurzplan fehlen ihm diese Angaben (der Doktor sagt „Bahnhof ohne Bahnsteige"). Für diese Rollen
   den kompletten Plan des Masters auf den Computer kopieren und im Assistenten „Eigene Datei angeben" wählen (`docs/INSTALL.md`, Abschnitt „Konfiguration verteilen").

### Neue Computer am Master aufnehmen

Ein Computer, der noch nicht im Netzplan des Masters steht, meldet sich nach dem Start beim Master (Nachricht `pair_announce`, mit seinem Eintrag und dem
Prüfprotokoll). Der Master tut damit **nichts außer es anzuzeigen**: der Computer bekommt keine Befehle, keinen Block und keine Fahrt.

- Am Master erscheint eine gelbe Meldung „Neuer Computer wartet: SIG-3 (signal)" und die Statusseite wird gelb.
- Die Seite **EINRICHTUNG** (dritte Seite, nach Status und Meldungen) zeigt vier Zeilen: Netzplan hat Blöcke und Routen, Computer online, Selbsttest der Computer
  (was jeder über sich selbst herausgefunden hat, „lokal geprüft"; keine Freigabe der Strecke), neue Computer, die auf Annahme warten. Jede Zeile hat ein Wort (OK, OFFEN, FEHLER), nicht nur eine Farbe. Darunter die wartenden Computer.
- Zeile antippen wählt aus. **[ANNEHMEN]** fragt beim ersten Antippen („[SICHER?]") und schreibt beim zweiten den Eintrag in den Netzplan des Masters
  (`configs/network.json`, alte Fassung als `.prev`, vorher wird geprüft, dass der Plan mit dem Eintrag gültig bleibt). **[ABLEHNEN]** ignoriert die ID etwa 10 Minuten.
- Steht die ID schon mit anderer Rolle im Plan, ist die Zeile rot und kann nicht angenommen werden.
- Ein wartender Computer ist **kein Node**: der Master registriert ihn nicht, ignoriert seine Ereignisse (auch Bedienbefehle von etwas, das sich „Panel" nennt) und schickt ihm nichts.
  Erst der Eintrag im Netzplan macht ihn dazu.
- Nach dem Annehmen steht der Eintrag im Plan und der Computer ist ein Node. **Bloecke und Routen, die ihn benutzen, gelten nach einem Neustart des Masters** (der Dispatcher wird beim
  Start aus dem Plan gebaut); die Meldung auf dem Monitor sagt das.
- Der Computer erfährt das Ergebnis (`known` / `rejected`), schreibt es ins Log und fragt danach nur noch alle 10 Minuten.

Läuft der Master mit einer Vorlage aus `configs/templates/` statt mit einer eigenen `configs/network.json`, nimmt er niemanden auf (die Vorlagen bleiben unverändert):
erst mit `scripts/setup.lua` einen eigenen Netzplan anlegen.

### Netzplan und Computer prüfen

```
scripts/setup.lua --check              prüft configs/network.json
scripts/setup.lua --check <datei>      prüft eine andere Datei
scripts/setup.lua --doctor             prüft diesen Computer und sagt, was zu tun ist (fragt auch den Master)
```

`--check` ändert nichts. Es meldet „in Ordnung (5 Computer, 1 Block, 1 Route)" oder nennt jeden Fehler **auf Deutsch** mit seiner Stelle im Plan (zum Beispiel
`nodes[2] (SIG-2).role: unbekannte Rolle "x"`). `--doctor` ändert nur das Prüfprotokoll `crn_status.lua`. Der Master startet mit einem fehlerhaften Plan nicht.
`lua scripts/check_configs.lua` ist dagegen ein Entwicklungsskript für die Beispiele im Repository und liegt nicht auf den Spiel-Computern.

Neu einrichten: den Assistenten noch einmal starten. Auf einem bereits eingerichteten Computer fragt er zuerst, ob er neu einrichten soll
(Nein ändert nichts); die alten Antworten sind teils als Vorschlag da. Computer, die mit einer älteren Version eingerichtet wurden, laufen weiter: sie fügen
die fehlende OTA-Wiederherstellung ihrer `startup.lua` selbst hinzu, und die neuen Dateien erreichen sie mit `scripts/ota_push.lua --legacy`
(`docs/OTA.md`). Nach der ersten Einrichtung einer Welt einmal `docs/INGAME_TESTS.md` durcharbeiten.


## Von Hand starten

Der Assistent schreibt `startup.lua`, danach startet der Computer seine Rolle von selbst. Von Hand geht es mit dem passenden Starter (er liegt ab der
Installation auf dem Computer und wird nie überschrieben):

```lua
shell.run("scripts/start_master.lua")   -- start_train, start_panel, start_signal, start_sensor, start_switch, start_station, start_depot
```

## Werkzeuge

Auf dem Spiel-Computer sind `scripts/setup.lua --check`, `--doctor` und `peripherals` (CC:Tweaked) die Werkzeuge für Einrichtung und Fehlersuche. Die Programme in `src/tools/`
(Config-Check, System-Check, Peripheral Inspector, Debug-Events und andere) sind **Entwicklerwerkzeuge**: der Installer legt sie nicht auf Spiel-Computern ab.
Sie stehen in `docs/TOOLS.md`. Wer den Peripheral Inspector im Spiel braucht (etwa um die echten Methoden des Create-Bahnhofs zu sehen), kopiert die einzelne Datei
`src/tools/peripheral_inspector.lua` an denselben Pfad auf den Computer (zum Beispiel mit `wget` von GitHub); er benötigt nur Module, die der Installer ohnehin mitbringt.
Im Spiel ist das nicht getestet.

## Wichtige Config-Felder

- `channel`: gemeinsamer Funkkanal
- `master_id`: ID des Master-Computers
- `nodes`: alle Computer im Netz, je einer pro Eintrag mit seiner Rolle (neue Computer trägt der Master selbst ein, siehe oben)
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
