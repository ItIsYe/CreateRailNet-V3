# Zwei Master und ein Schiedsrichter (Hochverfügbarkeit)

Nach dem Gesamtkonzept (Kap. 2, 5) führen **Master A und Master B** gemeinsam, und ein kleiner **Schiedsrichter** ist die dritte Stimme der Wahl. Dieses Paket (P3) liefert die
**Wahl** und die **Absperrung** alter Führungen. Der gemeinsame, dauerhafte Sicherheitszustand beider Master (Dual-Commit) folgt in Paket P4; bis dahin führt der gewählte Master
mit seinem eigenen Zustand, und ein Wechsel startet mit dem, was der neue Master selbst weiß.

## Aufbau im Netzplan

Im Netzplan des Masters (`configs/network.json`):

    "master_id": "MASTER-A",
    "masters":   ["MASTER-A", "MASTER-B"],
    "arbiter":   "ARBITER-1",
    "nodes": [ ... {"id": "MASTER-A", "role": "master"}, {"id": "MASTER-B", "role": "master"}, {"id": "ARBITER-1", "role": "arbiter"} ... ]

`master_id` ist der bevorzugte Master (A). Der Schiedsrichter ist ein **eigener Computer** der Rolle *Schiedsrichter* (Installer: Rolle 9, oder `scripts/start_arbiter.lua`), nur mit Modem,
ohne Geräte. Computer mit Kurzplan lernen `masters` und `arbiter` von ihrem Master (er schickt sie in seiner Antwort `pair_state`) und merken sie sich in `state/crn_ha.json`; bei
eingeschalteter Authentifizierung (`docs/KEYS.md`) glauben sie das nur einer signierten Antwort. Der zweite Master bekommt denselben Netzplan (Kopie) und wird mit `--id MASTER-B` gestartet.

## Wie die Wahl funktioniert

- Drei Stimmen: A, B und der Schiedsrichter; zwei bilden die Mehrheit. Wer führt, hat in seiner **Periode** (Zahl, die nur steigt) die Stimmen von zwei Computern.
- Wer lange nichts von einem Führenden hört (A nach 5 s, B nach 8 s), fragt zuerst **vorab** („würdest du mich wählen?“). Diese Frage ändert nichts. Nur bei einer Mehrheit steigt die Periode
  und es kommt zur Wahl. So kann ein Master, der vom Führenden getrennt ist, die Periode nicht hochtreiben und einen laufenden Führenden nicht stören.
- Jede Stimme wird **dauerhaft** gespeichert, bevor sie beantwortet wird (`state/election.json`); ein Computer, der neu startet, wählt in einer Periode nie zweimal. Ist die Datei unlesbar,
  nimmt der Computer an keiner Wahl teil und sendet keine Befehle.
- Wer führt, schickt jede Sekunde einen Takt und ist nur gültig, solange eine Mehrheit einen Takt bestätigt hat, den er vor höchstens 3 s gesendet hat (das **Pachtfenster**). Verliert er die
  Mehrheit, hört er von selbst auf. Die anderen warten länger, ehe sie wählen (Pacht plus 1 s Reserve): so führt zu jedem Zeitpunkt höchstens einer gültig.
- Eine Mehrheit der Stimmen ist **Führung, keine Freigabe**: jede Freigabe braucht weiterhin die dauerhafte Bestätigung beider Master (P4).

## Was ein Master tut, der nicht führt

Er nimmt Meldungen an und bestätigt sie (Heartbeats, Anmeldungen, Aufnahme neuer Computer, Plan-Abfragen), pflegt sein Register, **fasst aber den Dispatcher nicht an**: keine Reservierung, kein
Signal-Refresh, keine Zeitablauf-Entscheidung, keine Fahrplan-Befehle. Befehle an Nodes kann er nicht senden (`net.gate`); was ein Master als Führender in die Warteschlange gestellt hat und dann
verliert, wird nicht mehr wiederholt. Nodes melden an **beide** Master (Heartbeat, Anmeldung, Ereignisse), damit der zweite nach einem Wechsel sofort weiß, wer da ist.

## Absperrung an den Aktoren (Fencing)

Jeder Befehl eines Masters an einen Node trägt `election_epoch` (die Periode), `election_leader` (seine ID) und `election_proof` (die Computer, die ihn gewählt haben). Der Node merkt sich die
höchste Periode, die er von einem Master gesehen hat (`state/crn_epoch.json`), und lehnt Befehle mit niedrigerer Periode ab („fenced: old_epoch“): ein früherer Führender kann nach einem Wechsel
nichts mehr stellen, auch wenn er sich noch für den Führenden hält. In einem Plan mit zwei Mastern ohne Periode ist ein Befehl eines Masters abgelehnt („no_epoch“). Den Beweis der Mehrheit
können die Nodes nicht prüfen (sie haben nur Schlüssel für die Master); den prüfen der andere Master und der Schiedsrichter, indem sie ihre Stimme geben.

## Bestätigung beider Master (Dual-Commit, P4)

Der Führende schreibt jede Änderung des Dispatcher-Zustands (Reservierungen, Züge, Weichen, Fahrplan) als Eintrag in sein Journal (`master_journal_file`) und schickt ihn dem anderen Master. Der legt ihn
ebenfalls dauerhaft ab und quittiert; erst dann gilt der Eintrag als **bestätigt**. Was Bewegung freigibt (Route, Abfahrt, Fahrplan, Signal nicht-rot, Weichenstellung davor) geht erst nach der
Bestätigung des Eintrags hinaus, von dem es abhängt, und zwar in der Reihenfolge, in der es entstand (die Weiche vor dem grünen Signal). **Rot und Halt warten nie.** Fällt der zweite Master aus,
bleibt der Führende am Leben, reserviert weiter, gibt aber nichts Neues frei; die Warteschlange ist begrenzt und das Panel zeigt Länge und Alter. Verliert der Führende die Führung, wird alles
Wartende verworfen und nie nachgeholt.

Bei einem Wechsel schneidet der neue Führende alles ab, was nicht bestätigt war (E-07), stellt den bestätigten Zustand wieder her, setzt die Signale einer bestätigten, aber nicht ausgeführten
Reservierung neu (E-08) und verlangt eine Bestätigung des Betreibers, ehe wieder Routen vergeben werden (`recovery.required`). Die Aktoren sperren den alten Führenden über die Epoche (Fencing); ein Befehl
trägt `command_id`, und ein Node führt ihn je Epoche nur einmal aus. Tests: `tests/test_replica.lua`, `tests/test_dual_commit.lua`.

## Was passiert wann (Ausfallmatrix, Kap. 5.3)

| Fehler | Führung | Neue Freigaben | Bestehende Fahrt |
|---|---|---|---|
| A fällt aus, B und Schiedsrichter da | B führt nach etwa 10 bis 20 s | erst mit der Bestätigung beider (P4) | bleibt; B übernimmt ohne Doppelbefehl |
| B fällt aus | A führt weiter (A + Schiedsrichter) | ohne zweiten Master keine Bestätigung beider (P4) | unverändert |
| Schiedsrichter fällt aus | A führt weiter (A + B) | wie bisher | unverändert |
| A–B-Verbindung getrennt | der Schiedsrichter entscheidet: A führt weiter | wie bisher | unverändert |
| A getrennt von allen | A hört nach 3 s auf zu führen, B (mit Schiedsrichter) übernimmt | über B | A sendet nichts mehr |
| A und B aus, nur Schiedsrichter | keine Führung | nein | Create bewegt sich weiter, nichts wird gestoppt |
| alle neu gestartet | Perioden bleiben, die Wahl läuft neu | nach der Wahl | Ist-Lage zählt (P4/P5) |

## Annahmen und Grenzen

- Die Pacht rechnet mit der Uhr jedes Computers (`os.clock`). Alle Computer eines Servers sehen denselben Takt, bei Serverlast laufen alle gleich langsam. Die Reserve von 1 s deckt
  Nachrichtenlaufzeit und kleine Unterschiede ab; ob das bei starkem Lag reicht, zeigt nur der Dauertest (`docs/INGAME_TESTS.md`).
- Zeit allein reicht nicht für die Führung (Kap. 2.1): die Periode und das Absperren am Aktor sind die zweite Sicherung.
- Der Schiedsrichter speichert nur seine Periode und seine Stimme, keinen Zustand der Bahn und keine zweite Kopie der Reservierungen.
