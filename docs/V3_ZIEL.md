# V3-Ziel: Gesamtkonzept 1.0 und der Stand dieses Repositories

Das Dokument „CreateRailNet V3 – Verbindliche Gesamtspezifikation“ (Konzeptstand 1.0, 21.10.2026) ist das Ziel. Diese Datei verfolgt, was davon umgesetzt ist,
wo es im Code liegt und was nur das Spiel zeigen kann. Sie wird mit jedem Paket (P1 bis P10, Kap. 19 des Konzepts) fortgeschrieben.

Die Sprache des Konzepts: **VERBINDLICH** (Sicherheitsinvariante), **ENTWURFSSTANDARD** (darf nach technischer Prüfung geändert werden), **NACHWEISPFLICHT** (nur das Spiel klärt es).
Eine Funktion ist erst dann „implementiert“, wenn Code, Tests, Migration, Logging und sichere Fehlerbehandlung da sind (Kap. 23). „Betriebsbereit“ ist ein Netzbereich erst nach
der physischen Abnahme (Kap. 20): das kann dieses Repository nicht herstellen, nur vorbereiten.

## Entscheidungen, die für die Umsetzung getroffen wurden

| # | Entscheidung | Grund |
|---|---|---|
| E1 | Umbau in Stufen im bestehenden Repository, der Dispatcher bleibt der Kern der Master-Logik; er bekommt Beweisstufen, Wartepunkte und eine Commit-Schranke | die Tests und das Verhalten des bisherigen Dispatchers sind das Sicherheitsnetz; ein zweiter Dispatcher daneben würde beides verdoppeln |
| E2 | Der **Schiedsrichter ist ein eigener CC-Computer** (Rolle `arbiter`), kein Nebenjob eines Nodes | Kap. 2: dritte Stimme, nur Wahldaten; ein Nebenjob würde Ausfälle koppeln |
| E3 | Schlüssel: ein Master-Schlüssel (beide Master), je Computer ein abgeleiteter Schlüssel mit Nummer; **Übergabe per Diskette oder Eingabe** am Gerät | Kap. 12.1 verlangt physisch bestätigte Erstregistrierung mit lokaler Schlüsselübergabe |
| E4 | Authentifizierung ist je Computer schaltbar (`auth_mode` off / monitor / enforce); `off` bleibt der Standard bis zur Einführung | bestehende Netze laufen weiter; der Betrieb nach dem Konzept verlangt `enforce` |
| E5 | Master-Speicherbudget **900 000 Byte** statt „etwa 740 000“ des Konzepts, mit Begründung in `docs/assumptions.md` | Authentifizierung (P1) und Masterwahl (P3) kosten zusammen etwa 100 KB; ein Master dieser Größe braucht `computer_space_limit` von 2 MB oder mehr; Rückweg: `computer_space_limit` anheben oder Planer/Setup-Werkzeuge auf die Panel-Rolle verlagern, Entscheidung in P10 mit Messwerten |
| E6 | Alles, was nur das Spiel zeigt (Mod-APIs, Create-Verhalten, Rechenzeit), steht in `docs/INGAME_TESTS.md` und bleibt **NOT_RUN**, bis es im Spiel gelaufen ist | Kap. 20: BLOCKED ist kein PASS; kein Offline-Test ersetzt einen Pflichtfall |

## Pakete (Kap. 19)

| Paket | Inhalt | Stand |
|---|---|---|
| P0 API-Labor | Mod-API-Matrix im Spiel | nur im Spiel möglich: `docs/INGAME_TESTS.md`, Werkzeuge `scripts/` (Peripheral-Inspektor, Schedule-Test) vorhanden |
| P1 Trust + Protokoll | Authentifizierung, Schlüssel, Sitzungen, Replay-Schutz, Framing | **umgesetzt (offline)**, siehe unten |
| P2 Persistenz | Journal mit Commit-Indizes, Snapshots, Testabstürze, Idempotenz | **umgesetzt (offline)**, siehe unten |
| P3 Master-Wahl | Master A/B, Schiedsrichter, Epoche, Fencing | **umgesetzt (offline)**, siehe unten |
| P4 Dual-Commit | Zustandsreplikation auf beide Master, Sperre für Freigaben bis zur Bestätigung | **umgesetzt (offline)**, siehe unten |
| P5 Graph + Reservierung | gerichteter Graph, Beweisstufen, Wartepunkte, Zugschlussnachweis | **umgesetzt (offline)**, siehe unten |
| P6 Hardware-Nodes | Multi-Signal, Bahnhof/Depot nach Kap. 6/7, Observer | **umgesetzt (offline)**, siehe unten |
| P7 Fleet | Flottenpaare, virtuelle Zug-Nodes, Fahrplan, Fracht | offen |
| P8 Panel | Multi-Monitor, Gleisbildeditor, Rechte, Offline-Entwürfe | offen |
| P9 OTA/Wartung | Zustände Kap. 18, Wartungssperre, Betreiberbestätigung, Rollback | offen |
| P10 Integration | 112 Einzeltests + E2E, 300/400 Signale, Freigabestufen | offen |

## P1: was umgesetzt ist

| Anforderung (Konzept) | Wo | Test |
|---|---|---|
| Kap. 12.1: keine Identität aus Computer-ID/Absenderangabe | `src/shared/auth.lua`, `keyring.lua`, `net.lua` | `tests/test_auth.lua` (F-01, F-02) |
| Kap. 12.1: physisch bestätigte Erstregistrierung, lokale Schlüsselübergabe | `src/setup/keys_tool.lua`, `scripts/keys.lua`, `docs/KEYS.md` | `tests/test_keys_tool.lua` |
| Kap. 12.1: Defekte Nodes: alte Identität sperren, neuer Schlüssel | `keystore.revoke/issue`, Schlüsselnummer, Liste `state/crn_trust.json` | `test_keystore.lua`, `test_auth.lua` (F-08) |
| Kap. 12.1 Entwurfsstandard: MAC-gesicherte Nachrichten, HMAC-SHA-256 | `src/shared/sha256.lua` (FIPS/RFC-Vektoren, vier Bit-Backends) | `tests/test_sha256.lua` |
| Kap. 12.1: Pure-Lua-Kryptografie nur mit Benchmark | `scripts/auth_bench.lua`, `src/setup/auth_bench.lua` | `test_auth_setup.lua`, im Spiel 0bj |
| Kap. 12.2: authentication_tag, sequence, session_id, message_id | Umschlag `at`, `sq`, `ss`, `ch`, `ke` (Protokoll Revision 5) | `test_auth.lua`, `docs/protocol.md` |
| Kap. 12.2: Größen validieren, bevor teure Kryptografie läuft | `fields_sane` vor Prüfbudget vor MAC | `test_auth.lua` (F-10) |
| Kap. 12.2: Replay-Schutz, authentifizierte neue Sitzungen nach Neustart | Sitzung mit Aufforderung, Fenster von 256 | `test_auth.lua` (F-04) |
| Kap. 12.2: begrenzte Verarbeitung, sicherer Fehlerbetrieb unter Überlast | Prüfbudget 400/s, Sperrfrist je Absender | `test_auth.lua` (F-10) |
| Kap. 12.1: Schlüssel nie im Klartext-Log | Schlüssel erscheinen nur in `keys.lua issue` ohne Laufwerk, sonst nur Prüfsummen | `test_keys_tool.lua` |
| Kap. 12.1: Sicherheitsnetze trennen und im Spiel testen (F-09) | **nur Spiel**: `docs/INGAME_TESTS.md` 0bk | NOT_RUN |

Noch nicht Teil von P1: Nachrichten zwischen zwei Nodes (Kap. 12.3, kommt mit P7 über Tickets der Master), Rollenrechte je Befehl an den Empfängern (Kap. 11.4/F-05/F-06, P8),
`election_epoch` / `reservation_commit_proof` in Masterbefehlen (P3/P4), Quittierung von Prüffehlern im Panel (P8).

## P2: was umgesetzt ist

| Anforderung (Konzept) | Wo | Test |
|---|---|---|
| Kap. 5.2: monoton geordnete Sequenzen, unveränderliche Einträge, Prüfsummen, explizite Commit-Indizes, Snapshots | `src/shared/journal.lua`, `docs/JOURNAL.md` | `tests/test_journal.lua` |
| Kap. 5.2/5.4: Journalbeschädigung, Lücken, Diskfehler sperren betroffene Freigaben | Zustände `corrupt` (gesperrt) und `failed`, `writable` | `test_journal.lua` |
| Kap. 20 E-06/E-07 (Absturz in jedem Schritt): Journal bleibt ein Präfix des Geschriebenen, bestätigte Einträge bleiben | Absturz an jeder Dateioperation | `test_journal.lua` (ein Absturz an jeder Operation) |
| Kap. 12.2: dauerhafte Befehls-ID, deterministische Idempotenz, sichere Behandlung unklarer Vorzustände | `src/shared/idempotency.lua`, Einbindung in `common_node` | `test_idempotency.lua`, `test_node_ledger.lua` |
| Kap. 7.3: Fahrplanübergabe genau einmal, unklarer Ausgang: nicht blind wiederholen | `uncertain` bei Neustart zwischen Eintrag und Aktion | `test_node_ledger.lua` |
| Kap. 15/16, J-07/J-08/J-09: Journal-/Speichergrenzen, Plattenvoll, Rotation | `max_entries`, `max_bytes`, vier-fache Obergrenze, Selbstverdichtung | `test_journal.lua` |

Noch nicht Teil von P2: das Journal der Reservierungen des Masters (P4), Dual-Commit mit dem zweiten Master (P3/P4), Statusanzeige der Journale im Panel (P8).

## P3: was umgesetzt ist

| Anforderung (Konzept) | Wo | Test |
|---|---|---|
| Kap. 2/5.1: Master A, Master B, Schiedsrichter als dritte Stimme, 2 von 3 | `src/domain/election.lua`, `src/nodes/arbiter_node.lua`, Rolle `arbiter` | `tests/test_election.lua` |
| S-01: nur der gültig gewählte aktive Master erteilt Befehle | Gate im Net (`src/shared/ha.lua`), Standby fasst den Dispatcher nicht an | `test_ha_integration.lua`, `test_master_standby.lua` |
| S-02: Wahlmehrheit ersetzt nicht die Bestätigung beider Master | Dokumentiert, Dual-Commit folgt in P4 | `docs/HA.md` |
| S-09: alte Master-Epochen werden abgewiesen | `src/shared/fence.lua` am Aktor, dauerhaft | `test_fence.lua`, `test_ha_integration.lua` (E-10) |
| 5.1: Führungsperiode, Term-Nachweis in Masterbefehlen | `election_epoch`, `election_leader`, `election_proof` | `test_ha_integration.lua` |
| 5.3: Ausfallmatrix (A, B, Schiedsrichter, A-B-Link, Partition, Quorumverlust, Neustart) | Wahl mit Vorab-Frage, Pacht, dauerhafte Stimme | `test_election.lua` (E-01 bis E-05 und 40 Zufallsläufe: nie zwei Führende gleichzeitig) |
| 8.1/2: Nodes sprechen mit beiden Mastern | Spiegel im Net, Topologie vom Master gelernt | `test_ha_integration.lua`, `test_fence.lua` |

Noch nicht Teil von P3: der gemeinsame dauerhafte Zustand beider Master und die Bestätigung beider (P4), die Erkennung der Ist-Lage nach dem Wechsel (P4/P5), die Anzeige des Führungszustands im Panel
(P8). Die Pacht beruht auf der Uhr der Computer (`docs/HA.md`, Annahmen): ob das auf dem Zielserver unter Last hält, zeigt nur Spieltest 0bx.

## P4 Dual-Commit

Entscheidung: es wird der **Zustand** des Dispatchers repliziert (Differenzen, `state_delta`), nicht die Folge der Operationen; ein Eintrag ist erst mit der dauerhaften Quittung des zweiten Masters bestätigt.

| Konzept | Umsetzung | Test |
|---|---|---|
| 5.2 / S-02 / S-03: Freigabe nur nach Bestätigung beider | `replica.lua`, Sperre `barrier.lua`, Adapter `guarded_adapters.lua`, Verdrahtung `ha_wiring.lua` | `test_dual_commit.lua` |
| E-02: zweiter Master aus, nichts wird freigegeben | Reservierung bleibt, Signal rot, Warteschlange begrenzt | `test_e02_...`, `test_the_waiting_queue_is_bounded_...` |
| E-07: auf beiden vorbereitet, auf keinem bestätigt, Wechsel | Beförderung schneidet den unbestätigten Rest, `recovery.required` | `test_e07_...` |
| E-08: bestätigt, Signal nicht gesetzt, Wechsel | der neue Führende setzt die Signale neu | `test_e08_...` |
| Absturz an jeder Dateioperation von Führendem und Standby | Journal mit Prüfsummen, `rcommit`-Einträge | `test_replica.lua` |
| Wiederholung beim Node | `command_id` je Epoche im Befehlsjournal | `test_node_ledger.lua` |

Noch nicht Teil von P4: die Bestätigung des Betreibers im Panel (P8), die Prüfung der Ist-Lage nach dem Wechsel gegen die Sensoren (P5), das Stellen der Signale über Signal-Nodes im Netz statt über die Peripherie
des Masters (P6). Der Platzbedarf des Masters ist auf 900000 Bytes gewachsen (Konzept: etwa 740000); die Entscheidung fällt in P10.

## P5 Graph + Reservierung

Schalter `occupancy_proof` (Standard aus), Einzelheiten `docs/PROOF.md`.

| Konzept | Umsetzung | Test |
|---|---|---|
| 4.1 gerichteter Graph, stabile IDs, Topologieversion | `safety_graph.lua` | `test_safety_graph.lua` (B-01 bis B-04, B-09) |
| 4.1 FREE_PROVEN / OCCUPIED_PROVEN / UNKNOWN, Quelle, Zeitpunkt | `occupancy.lua` | `test_occupancy.lua` (B-07) |
| Kap. 3 verbotene Ersatznachweise | nur Endsensor, Detektorpegel, Beobachter, Bahnhof beweisen "frei" | `test_occupancy.lua` |
| S-03 / S-07 / S-10 | UNKNOWN nach Neustart, Wechsel, Reparatur | `test_dispatcher_proof.lua` |
| 4.2 / 4.3 / S-08 Fahrstraße endet an bewiesenem Wartepunkt, Zuglänge | `route_end`, `request_route(..., { length })` | `test_dispatcher_proof.lua` (C-06, C-10) |
| S-05 / B-08 Freigabe erst nach Zugschlussnachweis | Endsensor, Block bleibt belegt, `get_clearing()` | `test_dispatcher_proof.lua` |
| 4.4 Deadlock melden, nicht erzwingen; bestätigte Umfahrung | `deadlock.lua`, `alternatives` | `test_deadlock.lua`, `test_dispatcher_proof.lua` (C-12) |
| 5.2 Zustandsautomat der Reservierung | `reservation_phase.lua`, Verbindung mit dem Dual-Commit | `test_reservation_phase.lua`, `test_dual_commit.lua` |

Noch nicht Teil von P5: Beobachter-Nodes und die aktive Abfrage nach einem Wechsel (P6), die Räumungsprüfung bei Topologieänderung im Betrieb über die Anzeige (P8), die Erzeugung von Wartepunkt-Kandidaten
aus dem Netzplaner (`safe_stops` werden von Hand eingetragen). Das alte Verhalten bleibt Standard (`occupancy_proof = off`); die Wirkung auf das echte Netz zeigen nur die Spieltests 0ca bis 0cd.

## P6 Hardware-Nodes

Einzelheiten `docs/SIGNAL_NODES.md`. Schalter `signal_transport` (Standard `local`).

| Konzept | Umsetzung | Test |
|---|---|---|
| Kap. 6: logical_signal_id -> Peripherie, lokal dauerhaft, mit Bestaetigung | `signal_bindings.lua`, `bind_signals.lua` (`signal_tool.lua`) | `test_signal_bindings.lua`, `test_signal_tool.lua` (B-05) |
| Kap. 6: keine automatische Umbindung nach Start, Modemaenderung, Hardwaretausch | `verify`, `is_usable`, nur gemeldet | `test_signal_bindings.lua`, `test_signal_host.lua` (B-06) |
| Kap. 6: 4, 6, 8 Signale an einer Node, Abgleich mit der Master-Topologie | `signal_host.lua`, `signal_node.lua`, `compare_topology` | `test_signal_host.lua`, `test_signal_node_world.lua` |
| Kap. 2.1: Empfang, Anwendung, physische Wirkung getrennt; Epoche und Befehls-ID | `net_signals.lua` (Befehl ueber das Netz), `err` beendet die Wiederholung (`net.lua`) | `test_net_signals.lua`, `test_signal_node_world.lua` |
| Signalausfall nimmt die Bloecke ausser Betrieb | `dispatcher.signal_failed`, Heartbeat `signals` | `test_net_signals.lua`, `test_signal_node_world.lua` |
| Kap. 7.1 / 7.2: Gleiswahl, Alternativen, volles Depot nie als Blockade | `track_choice.lua` | `test_track_choice.lua` (C-06, C-10, C-11) |
| Platzbedarf des Masters | Budget 1 000 000 Bytes, `computer_space_limit` 2 000 000 noetig, Warnung im Doctor | `test_installer_manifest.lua`, `test_doctor.lua` |

Noch nicht Teil von P6: aktive Observer-Nodes (der Detektorpegel der Sensor-Nodes beweist "frei", `docs/PROOF.md`; Train-Observer mit Zugnamen sind in ATM10 8.1 nicht belegt), die Erstellung von
Bahnsteig-Kandidaten aus dem Netzplaner, die Einrichtung der Bahnhof- und Depot-Peripherie durch einen gefuehrten Assistenten (die Daten stehen im Plan), die Verwendung der Gleiswahl durch Fahrplaene (P7), die
Umstellung der Weichen ueber Nodes im Netz (Weichen bleiben am Master). Das alte Verhalten bleibt Standard.

## Abdeckung der Ingame-Abnahmefälle (Kap. 20)

Die Fälle A-01 bis J-10 und E2E-01 bis E2E-08 werden in P10 einzeln auf Tests und Spielzeilen abgebildet. Bis dahin gilt: kein Fall ist PASS, solange er nicht im Spiel gelaufen ist.
Offline belegbar sind Fehlerfälle der Logik (Authentifizierung F-01 bis F-04, F-08, F-10; später E-01 bis E-12 im Simulator).
