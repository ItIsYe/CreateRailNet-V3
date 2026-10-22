# Updates, Wartung, Betriebszustaende (V3, Paket P9)

Der Ablauf auf dem Knoten (Angebot, Teile, Tausch, Probestart, Rueckfall) steht in `docs/OTA.md`. Hier stehen die Regeln davor und danach.

## Betriebszustaende (`src/domain/op_state.lua`)
INITIAL_SETUP, TEST_MODE, NORMAL, DEGRADED_GLOBAL (zweiter Master fehlt oder Commit unklar), DEGRADED_LOCAL (lokaler Defekt, betroffene Bereiche gesperrt), RECOVERY, MAINTENANCE, FAULT_LOCKED.
Der strengste gilt. Nur NORMAL erlaubt neue Fahrten; in DEGRADED_LOCAL nur in Bereichen, die nachweislich unabhaengig von der Stoerung sind und solange die globalen Voraussetzungen bestehen.
Das Panel bekommt `op_state` und `op_text` im Snapshot, die Sperren der Updates in `diagnostics.update_locks`.

## Ablauf eines Updates
1. Vorbereiten (automatisch erlaubt): Paket laden und pruefen (`src/shared/update_package.lua`: Herkunftsnachweis, Zielrolle, Protokoll, Datenschema, Migrationsplan, Platz fuer Stage und Sicherung, Rueckfallziel, Dateihashes). Eine Schemaaenderung wird nie automatisch eingespielt.
2. Freigabe eines kritischen Knotens (`update_release`): Bediener und Nachweis, dass der Knoten sicher steht (zum Beispiel Signal lokal ROT, Strecke frei).
3. Aktivierung (`ota_push` mit `confirm = true`): nur mit Bestaetigung des Betreibers; bei kritischen Knoten zusaetzlich Freigabe, keine aktive Fahrt, die vom Knoten abhaengt, nicht in RECOVERY oder FAULT_LOCKED.
   Ein Push ohne Zielknoten ist mit der Update-Steuerung nicht moeglich.
4. Reihenfolge: ein Master nur als Standby und vom fuehrenden Master aus (danach kontrollierter Fuehrungswechsel und der andere); der Schiedsrichter nur bei zwei gesunden Mastern; Flottenpartner einzeln, andere Paare bleiben unberuehrt; Panel und Zug-Knoten brauchen nur die Bestaetigung.
5. Fehler, Rueckfall, unbekannter Zustand, Neustart waehrend der Aktivierung: der Knoten ist gesperrt (`state/update_plan.json`, ausserhalb der Programmdateien). Die Bloecke, die vom Knoten abhaengen, gehen wie bei einem Knotenausfall auf FAULT; alte Reservierungen werden nie blind wiederhergestellt.
   Die Sperre hebt ein Bediener mit Nachweis auf (`update_unlock`).

## Wartungssperre
`state/maintenance.json`: die Sperre ueberlebt einen Neustart; eine unlesbare Datei laesst sie eingeschaltet. Updates laufen in der Wartung (ihre eigenen Pruefungen entscheiden).

## Austauschassistent (`src/master/replacement.lua`)
Alter Schluessel wird ungueltig, der neue Computer bekommt einen neuen Schluessel (Abgleich des Fingerabdrucks mit dem Bildschirm), jedes Signal des alten Computers muss am neuen von einer Person neu bestaetigt werden,
erst ein bestandener Test mit Quelle beendet die Haltung. Auf dem Panel: Wartungsseite (`docs/PANEL.md`). Der Schluessel geht nur auf eine Diskette, die Signale liest der Master aus dem Heartbeat des neuen Computers.

## Grenzen
Siehe `docs/V3_ZIEL.md` (P9): Programmslots dateiweise, Master-Update ueber den Installer. Spieltests 0ct bis 0cx.

## Signierte Pakete
Mit Schluesseln signiert der Master jedes Angebot fuer den Knoten (`src/shared/update_trust.lua`): Herkunftsnachweis mit dem Paarschluessel, Zielrolle, Protokoll, Datenschema, Platz, SHA-256 jeder Datei, Rueckfallziel. Der Knoten prueft das vor der ersten
Dateianforderung, die Dateien des Angebots muessen genau die des Pakets sein, und beim Commit werden die gespeicherten Dateien gegen die SHA-256 des Pakets geprueft. `ota_require_package` (Standard an bei `auth_mode = "enforce"`) verlangt ein Paket.
