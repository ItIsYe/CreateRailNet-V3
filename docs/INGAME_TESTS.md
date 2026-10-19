# Spieltests (was sich offline nicht prüfen lässt)

Die Tests in `tests/` laufen ohne Minecraft. Sie beweisen die Logik (Reservierung, Stellwerk, Wiederanlauf, Updates, Netz), aber nicht, wie sich
Create und CC:Tweaked in der echten Welt verhalten. Diese Liste ist dafür da: einmal in einer **Testwelt oder auf einem abgesperrten Stück
Strecke** durchgehen, die Ergebnisse in die letzte Spalte schreiben. Wo etwas anders kommt als erwartet, steht in der Zeile, was das bedeutet.

Vorbereitung: Backup der Welt, ein kleines Netz (Master, 2 Signale, 2 Sensoren, 1 Weiche, 1 Zug, 1 Panel-Monitor), `scripts/setup.lua --check`
ohne Fehler, `docs/INGAME_SETUP.md` durchgearbeitet.

## 0. Installer (`docs/INSTALL.md`)

Der Installer ist offline gegen ein simuliertes GitHub getestet (inklusive Absturz bei jeder Dateioperation). Ob HTTP, Dateisystem und `require` im Spiel
genauso arbeiten, zeigt nur der Versuch. Auf einem **frischen** Computer, dann auf einem zweiten mit kleinem Speicher:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0a | `wget run https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<zweig>/installer --ref <zweig>` | Menü, Fortschritt, am Ende der Einrichtungs-Assistent | „HTTP ist nicht verfuegbar": `computercraft-server.toml` (http, Domain freigeben); anderer Fehler: Text notieren | |
| 0b | im Assistenten weitermachen (alles mit Enter) | läuft ohne „module not found" / „startup_template.lua is missing" durch, schreibt `startup.lua`, startet neu in die Rolle | „module not found": `require` löst Pfade aus `/scripts` anders auf als vermutet → melden, Wortlaut notieren | |
| 0c | `installer` (oder `installer --yes`) gleich noch einmal | lädt nur das Manifest, „Alle Dateien sind auf dem Stand …", Neustart in 2 s; dauert wenige Sekunden | lädt Dateien erneut: Größe/Prüfsumme weichen ab (Zeilenenden? `git config core.autocrlf`) → melden | |
| 0d | `fs.getFreeSpace("/")` vor und nach einer Master- und einer Node-Installation (Lua-Prompt) | Master ca. 550 KB, Node ca. 235-245 KB belegt, Standardspeicher (1 MB) reicht | reicht nicht: Meldung nennt, wie viel fehlt; `computer_space_limit` erhöhen | |
| 0e | Computer mit zu wenig Platz (`computer_space_limit` klein) | „Der Speicher dieses Computers reicht nicht …", Platte unverändert | Platte verändert: Abbruch-Zeitpunkt notieren | |
| 0f | Strom aus / Chunk entladen während „Dateien werden geladen" | beim nächsten Start „Installation unvollstaendig." und `installer --resume` läuft von selbst bis zum Neustart | Computer bleibt in der Shell: `installer --resume --role <rolle>` | |
| 0g | eigene Konfiguration (`configs/templates/network.full.example.json`) ändern, `installer` erneut | Datei bleibt unverändert; eine gelöschte `scripts/start_*.lua` kommt zurück | Datei überschrieben: melden (Seed-Liste im Manifest) | |
| 0h | `installer --role signal` auf einem Sensor-Computer | alte Sensor-Dateien weg, Assistent richtet die Signal-Rolle ein | | |
| 0i | direkt nach einem Push auf den Zweig installieren | evtl. „… checksum of …" und Wiederholung mit Wartezeit (CDN-Cache), dann Erfolg | dauerhaft Prüfsummenfehler: `lua scripts/manifest_sync.lua --check` im Repository | |

### 0.1 Einrichtungs-Assistent (`docs/INGAME_SETUP.md`)

Der Assistent ist offline mit einem simulierten Computer getestet (jede Rolle, alle Plan-Wege, zurück, Hilfe, Abbruch, Bildschirm 51 x 19, nur ASCII).
Wie die Seiten auf einem **echten** Terminal aussehen, zeigt nur der Versuch. Auf einem frischen Computer je Rolle, dazu einmal auf einem
Computer ohne Modem und einmal auf einem Pocket-/Mini-Terminal, falls ihr eins benutzt:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0j | `scripts/setup.lua` auf dem Master: Beispiel kopieren, alles mit Enter | jede Seite passt ohne Scrollen auf den Bildschirm, keine Sonderzeichen/Kästchen, Kopfzeile zeigt den Schritt | Seite läuft über oder Zeichen kaputt: Bildschirmgröße (`term.getSize()`) und Seite notieren | |
| 0k | `?` auf jeder Frage, danach Enter | Hilfe auf eigener Seite, danach dieselbe Frage wieder, nichts doppelt | Frage fehlt oder erscheint zweimal: Frage notieren | |
| 0l | `<` mehrfach, auch auf der ersten Frage | geht Schritt für Schritt zurück, Antworten bleiben als Vorschlag, auf der ersten Frage kommt „Einrichtung abbrechen?" | | |
| 0m | Signal-Computer mit Create-Signal: Kurzplan | Gerät wird erkannt (Name aus der Liste), Zusammenfassung nennt „Create_Signal_0 (gefunden)", Abschlussseite zeigt die Zeile für den Netzplan des Masters | Gerät nicht erkannt: Typ mit `peripheral.getType` notieren (Erkennung in `src/setup/hardware.lua`) | |
| 0n | die Zeile von Hand in `nodes` des Masters eintragen (der Weg ohne Pairing), `scripts/setup.lua --check` | „in Ordnung" | Fehlerliste: Pfad und Text notieren | |
| 0o | Computer ohne Modem | deutliche Warnung, Weitermachen möglich, Zusammenfassung nennt „Modem FEHLT" | | |
| 0p | Assistent bis zur Zusammenfassung, dann `A` | „Abgebrochen. Es wurde nichts geaendert.", kein `startup.lua`, keine `configs/network.json` | Datei angelegt: melden | |
| 0q | Strg+T mitten in einer Frage | Shell, nichts geschrieben | | |
| 0r | Assistent auf einem schon eingerichteten Computer | fragt zuerst „Neu einrichten?"; Nein ändert nichts | | |

### 0.2 Prüfung, Geräte-Bindung und Aufnahme am Master (`docs/INGAME_SETUP.md`)

Doctor, Verbindungstest, Pairing und die Master-Seite „Einrichtung" sind offline gegen simulierte Computer und ein simuliertes Netz getestet (Zustände, Grenzen,
böswillige Eingaben, Absturz beim Schreiben des Plans). Was nur das Spiel zeigt: wie echte Peripherie heißt, wie sich Modems verhalten und wie die Seite auf einem
echten Monitor aussieht. Master mit Netzplan und mindestens zwei weitere Computer (einer davon noch nicht im Plan), alle mit Modem:

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 0s | `scripts/setup.lua --doctor` auf einem eingerichteten Computer | eine Zeile je Punkt (`[ OK ]`), Modem und Monitor mit dem Namen, den `peripherals` bzw. `peripheral.getNames()` im Spiel liefert | Name weicht ab oder Gerät fehlt in der Liste: Typ mit `peripheral.getType(name)` und Wortlaut notieren (Erkennung in `src/setup/hardware.lua`, `src/adapter/monitors.lua`) | |
| 0t | Master mit Monitor an der Seite und einem zweiten Monitor am Kabel; Feld `monitor` im Eintrag auf den zweiten setzen, Master neu starten | Anzeige erscheint auf dem genannten Monitor; ein falscher Name zeigt auf dem ersten Monitor an und steht einmal im Log | Anzeige bleibt leer: Namen aus `peripheral.getNames()` und Log notieren | |
| 0u | Computer mit zwei Modems (Funk und Kabel); Assistent wählt eines, danach das gewählte abbauen | Doctor: `Modem ... nicht gefunden`; der Computer funkt **nicht** über das andere Modem | er funkt über das andere: melden (`src/adapter/cc_modem.lua`) | |
| 0v | neuer Computer (nicht im Plan), Assistent bis zum Verbindungstest, Master läuft | Doctor/Verbindungstest: `[WARN] Master kennt <id> noch nicht`; nach spätestens 20 s steht der Computer auf der Master-Seite *Einrichtung*, gelbe Meldung „Neuer Computer wartet" | nichts erscheint: gleicher Kanal? Master schon auf diesem Stand (Revision 3)? Wortlaut des Tests notieren | |
| 0w | auf der Master-Seite die Zeile antippen, **[ANNEHMEN]** zweimal | beim ersten Tippen wird der Knopf zu `[SICHER?]` (gilt 8 s), beim zweiten „... ist im Netzplan eingetragen"; `configs/network.json` enthält den Eintrag, `configs/network.json.prev` die alte Fassung; der Computer loggt `pairing: known` | Eintrag fehlt oder Datei beschädigt: beide Dateien aufheben und melden | |
| 0x | zweiten neuen Computer **[ABLEHNEN]** | verschwindet, meldet sich 10 Minuten lang nicht erneut auf der Seite | taucht sofort wieder auf: melden | |
| 0y | Computer mit einer ID, die im Plan mit anderer Rolle steht | Zeile in Rot, **[ANNEHMEN]** wird verweigert mit Hinweis | | |
| 0z | Master mit mitgelieferter Vorlage (`configs/templates/...`) als Plan, Computer annehmen | Ablehnung mit dem Hinweis, einen eigenen Plan anzulegen; nichts verändert | Datei verändert: melden | |
| 0aa | Seite *Einrichtung* auf Monitoren verschiedener Größe (2x1, 3x2, 4x3), Liste mit mehr Computern als Zeilen | alle Zeilen und beide Knöpfe erreichbar, nichts läuft über den Rand, Wörter OK / OFFEN / FEHLER auch auf einem Schwarzweiß-Monitor lesbar | Layout kaputt: Größe und Foto/Beschreibung notieren | |
| 0ab | Station-Computer mit Kurzplan: `--doctor` | Hinweis „Bahnhof ohne Bahnsteige" mit dem Weg (vollständigen Plan kopieren); nach dem Kopieren und „Eigene Datei angeben" verschwindet er | | |
| 0ac | Installer auf einem echten Terminal und auf einem Pocket-Computer | der Fortschritt ist **eine** Zeile, die sich überschreibt; Zeilen umbrechen an Wortgrenzen; Fehler rot, Hinweise gelb | Zeilen springen oder doppeln sich: Terminalgröße und Verhalten notieren (`install/ui.lua`) | |
| 0ad | `print(string.char(228, 246, 252, 223))` am Terminal und auf einem Monitor | zeigt ä ö ü ß, dann könnten Texte später Umlaute bekommen (derzeit steht alles in ASCII: ae oe ue ss) | andere Zeichen: ASCII beibehalten | |

## 1. Was macht ein Create-Signal, wenn sein Computer ausfällt? (offene Frage Nr. 1)

Das ist die wichtigste Frage: die Software setzt Signale neu (Start, rollend, Reconnect) und schaltet beim Stoppen des Masters alle auf ROT, aber sie
kann nicht wissen, ob der Zustand im Spiel erhalten bleibt.

| # | Versuch | Erwartet | Wenn anders | Ergebnis |
|---|---|---|---|---|
| 1a | Signal auf GRÜN stellen (`setForcedRed(false)`), Computer mit `shutdown` ausschalten | Signal bleibt GRÜN (Zustand liegt im Signal-Block) | springt auf ROT: gut, fail-safe; springt auf GRÜN/anderen Zustand: siehe 1d | |
| 1b | Signal auf ROT stellen, Computer ausschalten | bleibt ROT | wird GRÜN: **gefährlich** → Signale nur mit zusätzlichem Redstone-Latch/Hardware-Rückfallebene betreiben und melden | |
| 1c | Computer neu starten (`reboot`) | Signal behält Zustand, Signal-Node setzt beim Start ROT, Master schickt GRÜN nach (Log-Seite zeigt es) | Signal bleibt dauerhaft ROT: Master-Log und `node_reconnect` im Audit prüfen | |
| 1d | Chunk entladen (weit weglaufen, Computer + Signal im selben Chunk), nach 1-2 Minuten zurückkehren | Zustand wie vor dem Entladen, Node meldet sich neu (`node_reconnect`) | Zustand verloren: Dauer notieren, `signal_refresh_per_s` ggf. erhöhen | |
| 1e | Master mit Ctrl+T beenden | alle Signale gehen auf ROT, Züge halten vor den Signalen | Signal bleibt GRÜN: Peripheral-Name in der Hardware-Config prüfen; `signal_red_on_stop` | |
| 1f | Master hart beenden (Chunk entladen / Server-Neustart) | Signale bleiben im letzten Zustand (hier hilft die Software nicht) | – | |

Trage das Ergebnis in `docs/assumptions.md` unter „Not verified in the game" ein und passe `signal_red_on_stop` an, falls 1e/1f zeigen, dass es nichts nützt.

## 2. Master-Neustart

1. Zug wartet vor rotem Signal mit Fahrerlaubnis (Signal GRÜN), Master mit Ctrl+T beenden und neu starten.
2. Erwartet: Master meldet RECOVERY (Statusseite rot) und lehnt neue Anforderungen ab, bis im Panel `confirm_recovery` ausgelöst wird. Freie Blöcke
   haben ROT, der wartende Zug bekommt sein GRÜN zurück, die Weichen des fahrenden Zuges bleiben gesperrt (ein zweiter Zug, der dieselbe Weiche
   anders braucht, wartet), nichts wird doppelt vergeben. Nach der Bestätigung läuft alles normal weiter.
3. Wenn nicht: `state/master_state.json` und `.prev` ansehen, Trace-Datei (Abschnitt 8) an mich geben.

## 3. Node-Ausfall und Selbstheilung

| # | Versuch | Erwartet | Ergebnis |
|---|---|---|---|
| 3a | Sensor-Computer ausschalten (oder Chunk entladen), > 6 s warten | Block FAULT, Alerts-Seite rot, Audit `node_timeout` genau **einmal** | |
| 3b | Sensor wieder einschalten, Detektor frei | nach ca. 15-20 s Block wieder FREI, Audit `fault_auto_cleared`, Alert grün | |
| 3c | wie 3a, aber Zug steht beim Wiedereinschalten auf dem Detektor | Block bleibt FAULT, solange der Detektor „belegt" meldet; nach Abfahrt Selbstheilung | |
| 3d | wie 3a, Zug fährt währenddessen durch den Block und weiter | nach 3b ist der Zug-Eintrag weg, Strecke frei; kommt der Zug in den **nächsten** Block, entscheidet dessen Sensor | |
| 3e | wie 3a, aber ein zweiter Zug wartet in der Warteschlange | nach der Heilung wird er automatisch abgefertigt | |
| 3f | `auto_clear_faults = false` setzen und 3a/3b wiederholen | Block bleibt FAULT, `manual_control clear_fault` räumt ihn | |
| 3g | Signal-Computer ausschalten und wieder an | Block heilt erst, wenn auch die Sensoren „frei" melden; Signal bekommt vom Master seinen Zustand zurück | |

## 4. Stellwerk (Fahrstraßen)

1. Strecke mit Weiche: Zug anfordern → Gleisbild zeigt die Fahrstraße (`SET` grün), beim Einfahren `OCCU`, dann `DISS`, am Ende weg.
2. Zweiter Zug auf eine Fahrstraße, die dieselbe Weiche anders braucht → bleibt in der Warteschlange (`diag`: Grund), fährt nach dem ersten.
3. Gegenrichtung auf demselben Abschnitt → Warteschlange mit `opposite direction conflict`.
4. Optional: `flank_protection` in `interlocking_routes` für eine Nachbarweiche → wird gestellt (physisch!) und gesperrt, solange die Fahrstraße steht.
5. Optional: `overlap_block` hinter dem Ausfahrsignal → bleibt reserviert; Zug über das Halt-Signal hinaus → Block FAULT mit Alert.
6. Manuell `set_signal ... GREEN` ohne aktive Fahrstraße → Ablehnung mit „SICHERHEIT"; mit aktiver Fahrstraße → akzeptiert.

## 5. Updates (OTA)

| # | Versuch | Erwartet | Ergebnis |
|---|---|---|---|
| 5a | `lua scripts/ota_push.lua --node TESTNODE` | `QUEUED → … → DONE → CONFIRMED`, Node läuft mit neuer Version (`crn_version.txt`) | |
| 5b | Datei mit Syntaxfehler pushen (nur auf TESTNODE!) | Node startet nicht richtig, beim zweiten Boot ohne Bestätigung Rückfall auf die alte Version (`OTA recovery: …` beim Start) | |
| 5c | Computer während `COMMITTING` ausschalten / Chunk entladen | beim nächsten Start Rückfall oder vollständiges Update, nie ein Mischzustand | |
| 5d | Signal-Node updaten, während ein Zug wartet | Signal geht vor dem Tausch auf ROT, der Master schickt es nach dem Neustart wieder | |
| 5e | Node mit **altem** Stand: `lua scripts/ota_push.lua --legacy --node X` | Node meldet sich mit neuem Code (Status `CONFIRMED` im Master, `DONE` im Tool); danach normales `ota_push.lua` ohne `--legacy` | |
| 5f | Alten `startup.lua` auf dem Node lassen, einmal starten | Log „startup.lua got the OTA recovery block", `startup.lua.prev` vorhanden, nach dem nächsten Neustart ist die Wiederherstellung aktiv | |
| 5g | `fs.getFreeSpace("/")` vor und nach einem vollständigen Update auf einem kleinen Computer | genug Platz (der Legacy-Weg schreibt temporär doppelt: ca. 170 KB × 2) | |

## 6. Oberfläche

- Alle Seiten auf jeder verwendeten Monitorgröße durchblättern (linke/rechte Kante): kein Flackern, Texte nicht abgeschnitten, Touch-Zonen treffen.
- Statusseite: Lampe zeigt Rot bei Sensor-/Signal-/Weichen-Ausfall, Gelb bei einem anderen Node, Grün sonst; Alert antippen quittiert ihn.
- Logseite: Warnungen der Nodes erscheinen (z.B. defekter Sensor an einer Station).

## 7. Last und Größe

Das Netz darf wachsen; die Software begrenzt Listen, Retries und Logs. Prüfen, wenn es soweit ist:

- TPS und Rechner-Auslastung des Masters mit 10 / 30 / 60 Nodes (Heartbeats alle 2 s je Node); `diag`-Seite, Log „tick job failed".
- Ein OTA-Rollout an alle Nodes: `max_parallel` (4) Nodes gleichzeitig, der Rest wartet; keine Node-Timeouts während des Rollouts.
- Mehrere Züge gleichzeitig auf einer Strecke mit Weichen: keine Blockade, Warteschlange baut sich wieder ab.

## 8. Fehler festhalten

Wenn etwas Unerwartetes passiert ist (Block FAULT ohne erkennbaren Grund, Zug steht, falsches Signal): die Datei `traces/fault_1.json` (wird bei einem
Block-Fault selbst geschrieben) oder `trace_dump` im Panel auslösen, mit der Config auf einen PC kopieren und

    lua scripts/replay_trace.lua traces/fault_1.json configs/network.json

ausführen. Die Ausgabe zeigt, ob der Dispatcher dasselbe getan hätte und welche Sicherheitsregel gebrochen wurde. Trace + Config + Beschreibung
reichen, um den Fehler offline nachzustellen und als Test festzuhalten.
