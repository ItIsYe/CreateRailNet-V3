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
| E5 | Das Speicherlimit von 1 000 000 Byte je Computer ist fest (`computer_space_limit` wird nicht angehoben). Programm als verkleinerte Dateien (`dist/`), Master 709 380 Byte, Zustand und Update-Reserve gedeckelt (`src/shared/storage_budget.lua`) | Die frühere Entscheidung, das Budget anzuheben und 2 MB zu verlangen, ist zurückgenommen; Beleg: `test_installer_manifest.lua`, `test_storage_budget.lua`, `test_minify.lua` |
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
| P7 Fleet | Flottenpaare, virtuelle Zug-Nodes, Fahrplan, Fracht | **umgesetzt (offline)**, siehe unten |
| P8 Panel | Multi-Monitor, Gleisbildeditor, Rechte, Offline-Entwürfe | **umgesetzt (offline)**, siehe unten |
| P9 OTA/Wartung | Zustände Kap. 18, Wartungssperre, Betreiberbestätigung, Rollback | **umgesetzt (offline)**, siehe unten |
| P10 Integration | 112 Einzeltests + E2E, 300/400 Signale, Freigabestufen | **umgesetzt (offline)**, siehe unten |

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
| Platzbedarf des Masters | Programm 709 380 + Zustand 238 000 + Update-Reserve 40 000 innerhalb 1 000 000 Byte, Warnung im Doctor bei weniger als 40 KB Reserve | `test_installer_manifest.lua`, `test_storage_budget.lua`, `test_doctor.lua` |

Noch nicht Teil von P6: aktive Observer-Nodes (der Detektorpegel der Sensor-Nodes beweist "frei", `docs/PROOF.md`; Train-Observer mit Zugnamen sind in ATM10 8.1 nicht belegt), die Erstellung von
Bahnsteig-Kandidaten aus dem Netzplaner, die Einrichtung der Bahnhof- und Depot-Peripherie durch einen gefuehrten Assistenten (die Daten stehen im Plan), die Verwendung der Gleiswahl durch Fahrplaene (P7), die
Umstellung der Weichen ueber Nodes im Netz (Weichen bleiben am Master). Das alte Verhalten bleibt Standard.

## P7 Flotte

Einzelheiten `docs/FLEET.md`. Neue Rolle `fleet` (Flotten-Node), Konfiguration unter `cfg.fleet`.

| Konzept | Umsetzung | Test |
|---|---|---|
| 8.1 feste Paare, Reserve, Partnerausfall sperrt nur das Paar, Versionswiderspruch sperrt | `fleet/pairs.lua`, Dauerhaftigkeit ueber `replica` mit festem Fuehrer | `test_fleet_pairs.lua`, `test_fleet_node.lua` (D-03 bis D-05) |
| 8.2 Zugprofile, Zustimmung des Bedieners, ausgemusterte IDs nie wieder | `fleet/profile.lua` | `test_fleet_profile.lua` (D-01, D-02) |
| 8.3 sechs Prioritaetsklassen, FIFO, Anti-Starvation | `fleet/priority.lua` | `test_fleet_priority.lua` (D-09) |
| 8.4 / 9 Fahrplan: Entwurf, Veroeffentlichung, Takt, Zeitbasen, kein Nachholen, keine Doppelfahrt | `fleet/timetable.lua` | `test_fleet_timetable.lua` (D-06 bis D-08, D-10) |
| 24.1 Kette NEW_REQUEST bis COMPLETE, UNCERTAIN statt Raten, Storno am sicheren Halt | `fleet/trip.lua`, `fleet/engine.lua` | `test_fleet_trip.lua`, `test_fleet_engine.lua` (C-01, C-03, C-09) |
| 10 / 24.2 Fracht: nur nachgewiesene Mengen, Teilmengen, Abfahrtsregeln | `fleet/cargo_ledger.lua` | `test_fleet_cargo.lua` |
| 2.1 Fahrt nur nach Master-Bestaetigung, Schedule genau einmal | `fleet_node.lua`, `fleet_bridge.lua`, `station_node.lua` (`apply_schedule`) | `test_fleet_bridge.lua`, `test_station_apply_schedule.lua`, `test_fleet_e2e.lua` |
| Konfigurationspruefung | `validate.lua` | `test_fleet_config.lua` |

Noch nicht Teil von P7: der Fahrplaneditor am Bildschirm (P8), Lade- und Entladestellen, die Mengen melden, Depotfahrten und Umlaufrouten im Ablauf, Gueter-Teilmengenregeln pro Linie (die Regeln stehen im Ledger),
die Uebernahme von Zugpositionen aus Create selbst. Alles, was Create tatsaechlich tut, bleibt Spieltest (0ci bis 0cm).

## P8 Panel

Einzelheiten `docs/PANEL.md`. Code unter `src/panel/`, Anbindung in `src/nodes/panel_node.lua` und `src/master/runtime.lua`.

| Konzept | Umsetzung | Test |
|---|---|---|
| 11.4 Rechte view/operate/admin, Pruefung am Master, kritische Aktionen mit Bestaetigung | `panel/permissions.lua`, Pruefung in `master/runtime.lua` (`panel_denied` im Audit), Zwei-Tipp-Bestaetigung in `panel_node.lua` | `test_panel_permissions.lua`, `test_node_apps.lua` |
| 11.1 mehrere Monitore, feste logische IDs, Erkennung per Grossanzeige, Ersatz, Gruppen teilen nur Zug/Station/Abschnitt | `panel/monitor_registry.lua` | `test_panel_monitors.lua` |
| 11.3 Gleisbild aus dem Graphen vorgeschlagen, Entwurf -> Vorschau -> bestaetigte Veroeffentlichung, Rueckgabe nur bei gleicher Topologie, Uebernahme bei Aenderung, Ebenen getrennt | `panel/diagram.lua` | `test_panel_diagram.lua` |
| 11.5 Offline: Entwuerfe ja, Befehle/Veroeffentlichung nein, alte Wuensche verfallen, Rueckkehr mit Pruefung und neuer Bestaetigung | `panel/offline.lua`, `panel_node.lua` | `test_panel_offline.lua`, `test_node_apps.lua` |
| 11.2 Stoerungszentrale (Quittung loescht keine Ursache, S-11), Seitentabelle mit Mindestrecht und Frischemarke | `panel/fault_center.lua`, `panel/pages.lua` | `test_panel_fault_center.lua` |

Nachtrag (Verdrahtungsrunde, siehe unten): `panel_node.lua` zeichnet jeden gebundenen Monitor mit eigener Ansicht (`panel/multi_display.lua`, `panel/views.lua`), das Binden macht `scripts/bind_monitors.lua`,
das Gleisbild kommt vom Master (`panel/topology_sync.lua`), die Stoerungszentrale folgt den Meldungen des Masters, der Fahrplaneditor arbeitet am Bildschirm. Wie die Monitore im Spiel aussehen und reagieren, bleibt Spieltest (0cn bis 0cs, 0db bis 0dh).

## P9 OTA und Wartung

Einzelheiten `docs/UPDATE.md`. Der verifizierte Ablauf (Angebot, Teile, Tausch, Probestart, Rueckfall) bestand schon in `updater.lua`/`ota_recovery.lua`; P9 setzt die Regeln des Konzepts darum.

| Konzept | Umsetzung | Test |
|---|---|---|
| 18 Betriebszustaende und was sie erlauben | `domain/op_state.lua`, im Panel-Snapshot (`op_state`, `op_text`) | `test_op_state.lua`, `test_release.lua` |
| 14 Paket: Herkunftsnachweis, Rolle, Protokoll, Schema, Migration, Platz, Rueckfallziel, Dateihashes | `shared/update_package.lua`, Haken `verify_package` im Updater | `test_update_package.lua`, `test_updater.lua` (I-02, I-03, I-09) |
| 14 Aktivierung nur mit Betreiberbestaetigung; kritische Knoten mit Freigabe und ohne abhaengige Fahrt | `master/update_control.lua`, `manual_control` (`ota_push`, `update_release`, `update_unlock`) | `test_update_control.lua` (I-01, I-04, I-05, I-12) |
| 14 Reihenfolge: Standby-Master vom fuehrenden aus, Schiedsrichter nur bei zwei gesunden Mastern, Flottenpartner einzeln | `update_control.check` | `test_update_control.lua` (I-05, I-06) |
| 14 Neustart mitten im Slotwechsel, Wartungssperre ueber Neustart, Fehler -> Sperre, kein blindes Zurueckspielen | `update_control.load/finish`, `domain/maintenance.lua` (Datei), `on_lock` -> Knoten-Timeout im Dispatcher | `test_update_control.lua`, `test_op_state.lua` (I-07, I-08, I-10) |
| 14 Ersatzhardware: neue Identitaet, neue Zuordnung, Test | `master/replacement.lua` | `test_replacement.lua` (I-11) |

Abweichungen und Grenzen: Die "A/B-Programmslots" sind auf ComputerCraft dateiweise ausgefuehrt (Stage `.ota_new`, Sicherung `.ota_bak`, Journal, Probestart), der kleine verifizierte Bootloader ist der Wiederherstellungsblock in `startup.lua`.
Nachtrag: Der Austauschassistent haengt in `manual_control` (`replace_*`) und hat seine Knoepfe auf der Wartungsseite des Panels; `verify_package` wird aus der Knotenkonfiguration verdrahtet (`shared/update_trust.lua`, signierte Pakete,
`ota_require_package`). Der Master wird weiter durch den Installer aktualisiert (nicht ueber OTA).
Was Create und die Welt beim Neustart eines Signal-Computers tun, bleibt Spieltest (0ct bis 0cx).

## P10 Integration und Abnahme

Die Abnahme ist ein Spielthema; offline lassen sich Vollstaendigkeit, Nachweisfuehrung und die Logik hinter den Faellen pruefen.

| Konzept | Umsetzung | Test |
|---|---|---|
| Kap. 20: 112 Faelle A-01 bis J-10 und E2E-01 bis E2E-08 mit Pruefschritt, Kriterium, Offline-Beleg und Spielstatus | `tests/acceptance/matrix.lua` (Daten), `docs/ABNAHME.md` (erzeugt) | `test_acceptance.lua` (Zahlen je Gruppe, jeder genannte Test existiert) |
| Kap. 20: Zustaende NOT_RUN/PASS/FAIL/BLOCKED, PASS nur mit allen Nachweisfeldern, BLOCKED ist kein PASS | `tests/acceptance/lib.lua` | `test_acceptance.lua` |
| Kap. 20.2: Freigabestufen G1 bis G5; G5 nur mit Lastreserve, Freigabeentscheidung, verantwortlicher Person und ohne FAIL/BLOCKED in Master-/Vertrauensfaellen | `lib.stage`, `scripts/acceptance_report.lua --stage` | `test_acceptance.lua` |
| Kap. 21: Risiko-Register R-01 bis R-12 mit Freigabebedingung und zugehoerigen Faellen | `matrix.risks`, `docs/ABNAHME.md` | `test_acceptance.lua` |
| Kap. 16 / J-01, J-02, J-03, J-05, H-13: 300 und 400 Signale, viele Zuege, kleine Deltas, getrennte Zustaende im Gleisbild (Zaehlungen, keine Zeiten) | `tests/test_load_signals.lua` | `test_load_signals.lua` |
| E2E-08: nach Komplettneustart bleiben Reservierungen, kein alter Befehl wird wiederholt, nichts gilt als frei | `tests/test_e2e_offline.lua`; **Fund:** `dispatcher.restore` hat im Beweismodus alte Gruen-Signale wiederholt, jetzt bleiben die Bloecke ROT | `test_e2e_offline.lua` |

Funde dieses Pakets: (1) `active_conflicts` wurde im Delta als Ganzes ersetzt und war bei 40 laufenden Zuegen die Haelfte des Deltas, jetzt Eintrag fuer Eintrag (`state_delta`). (2) Der Wiederanlauf hat im Beweismodus Gruen wiederholt (siehe oben).

Stand der Abnahme: **kein Fall ist PASS, es wurde kein Fall im Spiel gelaufen; erreichte Stufe: keine.** Die Matrix zeigt je Fall, was offline belegt ist; das ersetzt keinen Spiellauf. Nicht offline pruefbar: Zeiten und Latenzen unter Serverlast,
TPS, Speicher, Verhalten von Create und CC:Tweaked, die Dauerlaeufe (2 h Mischbetrieb, danach 8 h, Kap. 20.1, vorher Obergrenzen festlegen) und alles unter "Spiel" in `docs/ABNAHME.md`.
Die Verdrahtungen aus P8/P9 (Mehrmonitor-Zeichnen, Bindewerkzeug, Austauschassistent, `verify_package`) sowie Fahrplaneditor, Ladestellen, Depotfahrten und Master-AUX sind in der Verdrahtungsrunde geschlossen worden (naechster Abschnitt).

## Verdrahtungsrunde (nach P10)

Alles, was in P8 bis P10 als "noch nicht angeschlossen" stand, ist code-seitig fertig. Offline getestet; wie es im Spiel aussieht und sich anfuehlt, zeigen die Spieltests 0db bis 0dh.

| Bereich | Umsetzung | Test |
|---|---|---|
| Mehrere Monitore je Panel, eigene Ansicht je Monitor, Gruppen teilen nur Zug/Station/Abschnitt, Monitor weg stoppt die anderen nicht | `panel/views.lua`, `panel/multi_display.lua`, `panel_node.lua` | `test_panel_display.lua`, `test_panel_node_multi.lua` |
| Monitore binden (grosse Nummer, Bestaetigung, Ersatz, Gruppen) | `setup/monitor_tool.lua`, `scripts/bind_monitors.lua` | `test_monitor_tool.lua` |
| Gleisbild aus der Topologie des Masters, nur wenn es die ist, die der Master faehrt | `panel/topology_sync.lua`, `plan_get` fuer die Rolle panel | `test_panel_topology.lua`, `test_panel_node_multi.lua` |
| Stoerungszentrale folgt dem Master; Quittieren loescht keine Ursache | `panel/fault_center.sync`, `faults` im Snapshot | `test_panel_fault_center.lua`, `test_release.lua` |
| Austauschassistent (Schluessel nur auf Diskette, Pruefsumme, Signale vom Heartbeat, Test) | `master/replacement_setup.lua`, `manual_control` `replace_*`, Wartungsseite | `test_replacement_setup.lua`, `test_replacement_flow.lua` |
| Signierte Update-Pakete, Pruefung am Knoten, SHA-256 beim Commit | `shared/update_trust.lua`, `updater.lua`, `ota_manager.lua`, `ota_require_package` | `test_update_trust.lua` |
| Fahrplaneditor am Bildschirm (Entwurf, Vorschau, Veroeffentlichung gegen die Basisversion, Konflikt, Offline-Entwurf) | `panel/timetable_editor.lua`, `fleet_admin` im Flottenknoten, `fleet_status` zum Master | `test_panel_timetable_editor.lua`, `test_fleet_admin.lua`, `test_panel_node_multi.lua` |
| Ladestellen melden nachgewiesene Mengen (Inventar vorher/nachher, Fehlmessung bucht nichts), manuelle Kontrolle nur durch Berechtigte | `domain/cargo_meter.lua`, `station_node.lua` (`platform.cargo`), `engine.cargo_measure`, `cargo_report` | `test_cargo_meter.lua`, `test_fleet_engine.lua`, `test_node_apps.lua`, `test_fleet_admin.lua` |
| Depotfahrten (Gleiswahl, volles Depot -> anderes Depot -> Umlauf -> Halt und Meldung) im Ablauf der Flotte | `engine.request_depot`, `fleet.depots`, `destination_name` fuer Depots, Knopf im Zugdetail | `test_fleet_engine.lua`, `test_station_apply_schedule.lua`, `test_fleet_admin.lua` |
| Master-AUX: reduzierte, unabhaengige Fehlersicht auf eigenem Monitor | `master/aux_display.lua`, `aux_monitor` | `test_aux_display.lua`, `test_master_app.lua` |

Funde dieser Runde: (1) Ein neu gestarteter Flottenpartner wurde als "widerspruechlich" gesperrt, weil die Pruefsumme des Zustands von der Reihenfolge der Tabellenschluessel abhing (jetzt kanonischer Text, `shared/canon.lua`).
(2) Die Entwurfsanzeige des Fahrplaneditors hielt einen unveraenderten Entwurf fuer veraendert, aus demselben Grund. (3) Ein Fehler in einer Ansicht wurde als "Monitor fehlt" gemeldet; der Text des Fehlers wird jetzt mitgeliefert.

Weiterhin nur im Spiel pruefbar: das Aussehen und Ansprechen der Monitore, ob ein Inventar neben dem Gleis so zu lesen ist wie angenommen (Create-Verlader, Kisten, Faesser), und alles aus `docs/ABNAHME.md`.

## Abdeckung der Ingame-Abnahmefälle (Kap. 20)

Die Fälle A-01 bis J-10 und E2E-01 bis E2E-08 werden in P10 einzeln auf Tests und Spielzeilen abgebildet. Bis dahin gilt: kein Fall ist PASS, solange er nicht im Spiel gelaufen ist.
Offline belegbar sind Fehlerfälle der Logik (Authentifizierung F-01 bis F-04, F-08, F-10; später E-01 bis E-12 im Simulator).
