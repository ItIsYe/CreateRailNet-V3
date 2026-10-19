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
   Netzplan und prüft ihn beim Start vollständig; mit dem Kurzplan fehlen ihm diese Angaben (der Doktor sagt „Bahnhof ohne Bahnsteige"). Die holt sich der Computer
   beim Master (nächster Abschnitt): Bahnsteige im Netzplan des Masters eintragen, Master neu starten, auf dem Computer `scripts/setup.lua --fetch-plan`.

### Den Plan vom Master holen (Bahnhof und Depot)

Der Master schickt seinen Netzplan nur auf Nachfrage und nur an einen **Bahnhof oder ein Depot, das im Plan steht** (mit dieser Rolle). Wer ihn holt, bestimmt der Spieler am Computer:

1. Am Master: der Computer ist angenommen (Seite EINRICHTUNG), seine Bahnsteige bzw. Gleise stehen im Eintrag (`docs/config_reference.md`), der Master läuft mit diesem Plan.
2. Am Computer, während der Einrichtung: kennt der Master ihn und fehlen die Bahnsteige, fragt der Assistent „Den Plan jetzt vom Master holen?". Später jederzeit (auch wenn sich der Plan am Master geändert hat):
   `scripts/setup.lua --fetch-plan`.
3. Der Computer holt den Plan in Teilen (jedes Teil wird bei Verlust neu angefragt) und prüft ihn, **bevor** er etwas schreibt: Pruefsumme, gültiges Format, derselbe Kanal und Master, und dass
   der Plan diesen Computer mit seiner Rolle enthält. Hat der Plan am Master sich währenddessen geändert oder ist etwas beschädigt angekommen, holt er ihn von vorn.
4. Dann zeigt er, was kam (Computer, Blöcke, Routen, Bahnsteige), und schreibt erst nach deinem **Ja** nach `configs/network.json`. Die alte Datei bleibt als `.prev`; Modem und Monitor, die auf diesem Computer
   gewählt wurden, bleiben im Eintrag. Der neue Plan gilt ab dem nächsten Start des Computers (`reboot`).

Der Master liefert die Datei so, wie sie **jetzt auf seiner Platte** liegt, wenn sie gültig ist; das ist die Datei, die du bearbeitet hast (der laufende Master kennt neue Bloecke erst nach seinem Neustart).
Hat der Eintrag im Plan des Masters noch keine Bahnsteige oder Gleise, sagt der Computer das und schreibt nichts. Signal, Melder, Weiche, Zug und Monitor bekommen keinen Plan (sie brauchen ihn nicht).

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
- Nach dem Annehmen erscheint auf der Seite der Knopf **[MASTER NEU STARTEN]** (zwei Berührungen; die erste nennt, wie viele Blöcke gerade belegt sind; alle Signale gehen auf ROT, der Zustand wird gesichert,
  dann startet der Master neu und wartet auf die Bestätigung des Wiederanlaufs). Verlangt der Plan `require_release`, steht darunter **[BETRIEB FREIGEBEN]** (`docs/OPERATIONS.md`).
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
scripts/setup.lua --fetch-plan         Bahnhof/Depot: holt den Netzplan vom Master (schreibt erst nach einem Ja)
scripts/setup.lua --test               geführter Funktionstest: liest, schaltet nur nach einem Ja und stellt zurück
scripts/setup.lua --linktest           Funkstrecke zum Master: Antworten, Laufzeit, größte Nachricht, die durchkommt
scripts/setup.lua --export             schreibt crn_diag.txt für die Fehlersuche aus der Ferne
```

`--check` ändert nichts. Es meldet „in Ordnung (5 Computer, 1 Block, 1 Route)" oder nennt jeden Fehler **auf Deutsch** mit seiner Stelle im Plan (zum Beispiel
`nodes[2] (SIG-2).role: unbekannte Rolle "x"`). `--doctor` ändert nur das Prüfprotokoll `crn_status.lua`. Der Master startet mit einem fehlerhaften Plan nicht.
`lua scripts/check_configs.lua` ist dagegen ein Entwicklungsskript für die Beispiele im Repository und liegt nicht auf den Spiel-Computern.

### Funktionstest (`--test`)

`--doctor` liest nur. Ob das, was im Plan steht, auch **tut**, was es soll, prüft `scripts/setup.lua --test` auf dem Computer selbst. Der Test zeigt zuerst, was er vorhat
(`[liest]`, `[zeigt]`, `[SCHALTET]`), und fragt einmal, ob er starten soll. Dann:

- **Gelesen** wird ohne Rückfrage: das Modem (Kanal lässt sich öffnen), der Master (antwortet er, kennt er die ID; angemeldet wird dabei niemand), der Melder (6 Sekunden lang,
  mit demselben Aufruf wie im Betrieb), der Create-Bahnhof (Name wie im Plan).
- **Gezeigt** wird auf dem Monitor eine Zeile „CreateRailNet Funktionstest"; du bestätigst, dass du sie siehst.
- **Geschaltet** wird nur nach einem eigenen Ja für diese eine Aktion (Enter allein ist ein Nein): ein Signal wird 3 Sekunden freigegeben und danach wieder auf **ROT** gestellt, eine Weiche 3 Sekunden
  auf Abzweig und danach auf geradeaus. Der sichere Zustand wird auch hergestellt, wenn der Schritt davor fehlschlug oder du mit Strg+T abbrichst; lässt er sich nicht herstellen, steht „ACHTUNG ... von Hand pruefen" da.
  Es darf dabei kein Zug in der Nähe sein; ein Computer im Betrieb sollte vorher angehalten werden.

Am Ende steht ein Ergebnis (bestanden / fehlgeschlagen / übersprungen). In `crn_status.lua` (und damit beim Master als „Hardwaretest") landet **bestanden** nur, wenn jeder Schritt gemacht wurde und
bestanden hat; **fehlgeschlagen** wird immer festgehalten; fehlen Schritte (kein Ja), bleibt der Eintrag, wie er war. Der Test gibt nichts frei; ob der Betrieb läuft, entscheidet nur der Mensch am Master
(`require_release`, `docs/OPERATIONS.md`).

### Funkstrecke (`--linktest`)

Fragt den Master zehnmal und sagt: wie viele Fragen beantwortet wurden, wie viele davon sofort (beim ersten Versuch), die Laufzeit, und danach in Stufen von 256 bis 4000 Byte, wie groß eine Nachricht
sein darf, die **in beide Richtungen** durchkommt. Ein Teil des Netzplans (`--fetch-plan`) ist rund 3300 Byte groß; kommt das nicht durch, sagt der Test das, bevor der Plan-Abruf daran scheitert.
Antwortet der Master nicht, ist nach drei Fragen Schluss. Der Master sieht gewöhnliche Anfragen dieses Computers (steht er nicht im Plan, erscheint er wie bei `--doctor` als wartender Computer); geschaltet
oder geschrieben wird nichts. Auf dem Master selbst läuft der Test nicht.

### Diagnosedatei (`--export`)

Schreibt `crn_diag.txt` (höchstens 8000 Byte, nur ASCII): Version, Ergebnis der Prüfung mit den Hinweisen, der Eintrag dieses Computers im Netzplan, das Prüfprotokoll, die angeschlossenen Geräte mit den Namen,
wie das Spiel sie nennt, die Dateien mit Größe und der freie Platz. Der Netzplan selbst steht nicht drin, Passwörter gibt es nicht. Sie liest nur und fragt niemanden. Zum Weitergeben:
`pastebin put crn_diag.txt` (zeigt einen Code) oder die Datei aus dem Ordner des Computers kopieren. Das ist der erste Schritt, wenn sich jemand anderes einen Fehler ansehen soll.

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

Auf dem Spiel-Computer sind `scripts/setup.lua --check`, `--doctor`, `--test`, `--linktest`, `--export` und `peripherals` (CC:Tweaked) die Werkzeuge für Einrichtung und Fehlersuche. Die Programme in `src/tools/`
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
