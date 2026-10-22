# Abnahme-Matrix (Kap. 20, 21)

Erzeugt von `lua5.4 scripts/acceptance_report.lua --write` aus `tests/acceptance/matrix.lua`; nicht von Hand bearbeiten.

Stand: 120 Faelle, davon NOT_RUN 120, PASS 0, FAIL 0, BLOCKED 0.
Offline belegt (Logik): 72, teilweise: 42, nur im Spiel: 6. **Offline belegt heisst nicht bestanden:** jeder Fall braucht den Lauf im Spiel mit Nachweis.
Erreichte Freigabestufe: **NONE** (G1 not reached: 10 case(s) not PASS (A-01=NOT_RUN, A-02=NOT_RUN, A-03=NOT_RUN, A-04=NOT_RUN, A-05=NOT_RUN, ...)).

## Freigabestufen

- G1 Lab: 10 Faelle (A-01, A-02, A-03, A-04, A-05, A-06, ...)
- G2 Safety: 29 Faelle (B-06, B-07, B-08, C-03, C-04, E-01, ...)
- G3 Pilot: 21 Faelle (B-01, B-02, B-03, B-04, B-05, B-09, ...)
- G4 Integration: 52 Faelle (D-01, D-02, D-03, D-04, D-05, D-06, ...)
- G5 Production: 8 Faelle (J-02, J-04, J-05, J-06, J-07, J-08, ...)
- G5 verlangt zusaetzlich: dokumentierte Lastreserve, ausdrueckliche Freigabe, eine verantwortliche Person; kein FAIL/BLOCKED in den Master-/Vertrauensfaellen (E, F).

## Faelle

| ID | Pruefschritt | Bestehenskriterium | Offline | Tests | Spiel |
|---|---|---|---|---|---|
| A-01 | ATM10/NeoForge/Create/CC-Versionen fixieren | Exakte Versionen aus der Welt dokumentiert | GAME | - | NOT_RUN |
| A-02 | Lokale Peripherals entdecken | Echte Typen und Methoden korrekt erkannt | PARTIAL | test_station_apply_schedule.lua | NOT_RUN |
| A-03 | Wired Modems mit mehreren Geraeten | Eindeutige stabile Adressierung, Ersatzerkennung | PARTIAL | test_panel_monitors.lua | NOT_RUN |
| A-04 | Train Station erkennt Zug | Richtige Identitaet, kein Phantom-Zug | PARTIAL | test_fleet_engine.lua | NOT_RUN |
| A-05 | getSchedule/setSchedule | Nachweisbare einmalige Aenderung am richtigen Zug | PARTIAL | test_station_apply_schedule.lua | NOT_RUN |
| A-06 | Physische Abfahrt/Ankunft | Ereignisse und sichtbare Bewegung abgeglichen | GAME | - | NOT_RUN |
| A-07 | Signal-Methoden und Status | Tatsaechlich verfuegbare Methoden dokumentiert | GAME | - | NOT_RUN |
| A-08 | Controllerverlust bei forced red | Rueckfallverhalten physisch getestet; ungeschuetzte Fahrt verhindert | GAME | - | NOT_RUN |
| A-09 | Train Observer | Ereignistypen, Zugnamen, Luecken abgeglichen | PARTIAL | test_dispatcher_proof.lua | NOT_RUN |
| A-10 | Chunk-Unload/Serverneustart | Unbekannte Zeitraeume nicht als frei interpretiert | PARTIAL | test_occupancy.lua | NOT_RUN |
| B-01 | Vier Gleise, zwei pro Richtung | Fahrtrichtung/Zuordnung korrekt | OFFLINE | test_safety_graph.lua | NOT_RUN |
| B-02 | Sechs- und achtgleisige Erweiterung | Alle Abzweige und Zusammenfuehrungen korrekt | OFFLINE | test_plan_builder.lua | NOT_RUN |
| B-03 | Kreuzende Fahrstrassen | Konfliktgruppen verhindern Gegengenehmigung | OFFLINE | test_safety_graph.lua | NOT_RUN |
| B-04 | Unabhaengige Fahrstrassen | Parallele Nutzung ohne falsche Sperre | OFFLINE | test_plan_builder_sim.lua | NOT_RUN |
| B-05 | 4/6/8 Signale an Multi-Signal-Node | Jede Signal-ID steuert das richtige Signal | OFFLINE | test_signal_host.lua, test_signal_node_world.lua | NOT_RUN |
| B-06 | Modem-Vertauschung | Abweichung entdeckt, keine automatische Umbindung | OFFLINE | test_signal_bindings.lua, test_panel_monitors.lua | NOT_RUN |
| B-07 | Belegung ohne ausreichenden Nachweis | UNKNOWN/sperrend, nicht automatisch frei | OFFLINE | test_occupancy.lua, test_dispatcher_proof.lua | NOT_RUN |
| B-08 | Vollstaendige Zugschlussraeumung | Freigabe erst nach belegter Raeumung | OFFLINE | test_dispatcher_proof.lua, test_dispatcher_proof.lua | NOT_RUN |
| B-09 | Topologieaenderung im Betrieb | Nur betroffene Bereiche geprueft/gesperrt | OFFLINE | test_occupancy.lua, test_safety_graph.lua | NOT_RUN |
| B-10 | Sicherer Wartepunkt langer Zug | Physischer Halt und ausreichende Laenge nachgewiesen | PARTIAL | test_safety_graph.lua | NOT_RUN |
| C-01 | Manuelle Personenzugfahrt nach Bahnhof Sued | Richtiger Zug/Ziel/gesicherter Weg | PARTIAL | test_fleet_e2e.lua, test_fleet_trip.lua | NOT_RUN |
| C-02 | Automatische Zugauswahl | Nur genehmigter kompatibler Zug | PARTIAL | test_fleet_engine.lua, test_fleet_profile.lua | NOT_RUN |
| C-03 | setSchedule vor/nach Freigabe | Keine Uebergabe vor Dual-Commit | OFFLINE | test_fleet_engine.lua, test_fleet_trip.lua | NOT_RUN |
| C-04 | Zwei konfliktierende Fahrten | Keine doppelte Konfliktfreigabe | OFFLINE | test_dual_commit.lua, test_plan_builder_sim.lua | NOT_RUN |
| C-05 | Zwei unabhaengige Fahrten | Gleichzeitige sichere Durchfuehrung | OFFLINE | test_plan_builder_sim.lua | NOT_RUN |
| C-06 | Zielbahnsteige belegt | Sicherer physischer Wartepunkt | PARTIAL | test_track_choice.lua, test_fleet_engine.lua | NOT_RUN |
| C-07 | Richtungswechsel Endbahnhof | Nur physisch erprobte Richtung | PARTIAL | test_track_choice.lua | NOT_RUN |
| C-08 | Durchfahrten mehrerer Bahnhoefe | Vollstaendiger Schutz bis Endpunkt | PARTIAL | test_dispatcher_proof.lua | NOT_RUN |
| C-09 | Fahrtabbruch in Bewegung | Naechster erreichbarer sicherer Stopp | PARTIAL | test_fleet_trip.lua, test_fleet_engine.lua | NOT_RUN |
| C-10 | Ueberlanger Zug/Bahnsteig | Ungeeignete Zuweisung abgelehnt | OFFLINE | test_track_choice.lua, test_dispatcher_proof.lua | NOT_RUN |
| C-11 | Depot voll | Sichere Alternative statt Zufahrtsblockade | OFFLINE | test_track_choice.lua | NOT_RUN |
| C-12 | Deadlock | Sichere Planung oder konservative Sperre | OFFLINE | test_deadlock.lua, test_dispatcher_proof.lua | NOT_RUN |
| D-01 | Unbekannten Zug registrieren | Betreiberzustimmung erforderlich | OFFLINE | test_fleet_profile.lua | NOT_RUN |
| D-02 | Doppelzuweisung desselben Zuges | Maximal ein wirksamer Auftrag | OFFLINE | test_fleet_engine.lua | NOT_RUN |
| D-03 | Mehrere Flottenpaare | Exklusive Zug-/Auftragszustaendigkeit | OFFLINE | test_fleet_pairs.lua, test_fleet_engine.lua | NOT_RUN |
| D-04 | Fester Partner faellt aus | Keine neue betroffene Automatik | OFFLINE | test_fleet_pairs.lua, test_fleet_engine.lua | NOT_RUN |
| D-05 | Partner kehrt zurueck | Dauerhafter Delta-/Snapshot-Abgleich | OFFLINE | test_fleet_node.lua, test_fleet_pairs.lua | NOT_RUN |
| D-06 | Echt-/Minecraft-Zeit | Zeitbasen korrekt getrennt | OFFLINE | test_fleet_timetable.lua | NOT_RUN |
| D-07 | Takt plus fixe Abfahrten | Keine doppelte Fahrt-ID | OFFLINE | test_fleet_timetable.lua, test_fleet_engine.lua | NOT_RUN |
| D-08 | Verpasste Starts nach Downtime | Keine unkontrollierten Nachholfahrten | OFFLINE | test_fleet_timetable.lua | NOT_RUN |
| D-09 | Alle sechs Prioritaetsklassen | Richtige Reihenfolge und FIFO/Anti-Starvation | OFFLINE | test_fleet_priority.lua | NOT_RUN |
| D-10 | Laufenden Fahrplan aendern | Wechsel nur am sicheren programmierbaren Punkt | PARTIAL | test_fleet_timetable.lua | NOT_RUN |
| E-01 | Fuehrenden Master abschalten | Gueltige Neuwahl, keine alte Berechtigung | OFFLINE | test_election.lua, test_ha_integration.lua | NOT_RUN |
| E-02 | Standby-Master abschalten | Keine neuen freigabewirksamen Dual-Commit-Operationen | OFFLINE | test_dual_commit.lua | NOT_RUN |
| E-03 | Schiedsrichter abschalten | Fuehrung A+B moeglich, wenn beide bereit | OFFLINE | test_election.lua | NOT_RUN |
| E-04 | A-B-Link trennen | Keine neue Sicherheitsfreigabe | OFFLINE | test_election.lua, test_replica.lua | NOT_RUN |
| E-05 | Partition Master/Arbiter | Maximal ein gueltiger Fuehrer, keine neue unbestaetigte Freigabe | OFFLINE | test_election.lua, test_dual_commit.lua | NOT_RUN |
| E-06 | Beide Master neu starten | Journal/physischer Abgleich vor Freigabe | OFFLINE | test_dual_commit.lua, test_dispatcher_proof.lua | NOT_RUN |
| E-07 | Ausfall im Prepare | Kein halber Commit freigegeben | OFFLINE | test_dual_commit.lua | NOT_RUN |
| E-08 | Ausfall nach Commit vor Aktuation | Reservierung erhalten, Ausgang rekonstruiert | OFFLINE | test_dual_commit.lua | NOT_RUN |
| E-09 | Ausfall waehrend Zugfahrt | Keine Phantom-Stopp-/Raeumungsmeldung | PARTIAL | test_dispatcher_proof.lua | NOT_RUN |
| E-10 | Alter Leader sendet Befehl | Aktuatoren lehnen ab | OFFLINE | test_ha_integration.lua, test_fence.lua | NOT_RUN |
| E-11 | Ausfall Signal-/Stationskommunikation | Betroffene neue Aktionen gesperrt | PARTIAL | test_net_signals.lua | NOT_RUN |
| E-12 | Lokaler Defekt, getrennte sichere Strecke | Weiterbetrieb nur bei global gueltiger Freigabe | OFFLINE | test_op_state.lua | NOT_RUN |
| F-01 | Unbekannter Rechner meldet sich | Ohne physische Aufnahme keine Rechte | OFFLINE | test_auth.lua | NOT_RUN |
| F-02 | Fremde Node-ID nutzen | Authentifizierung scheitert | OFFLINE | test_auth.lua | NOT_RUN |
| F-03 | Nachrichteninhalt manipulieren | Integritaetskontrolle lehnt ab | OFFLINE | test_auth.lua | NOT_RUN |
| F-04 | Alte Befehle wiederholen | Keine doppelte reale Ausfuehrung | OFFLINE | test_auth.lua | NOT_RUN |
| F-05 | Anzeige-Panel beantragt Fahrt | Zustaendiger Empfaenger verweigert | OFFLINE | test_panel_permissions.lua | NOT_RUN |
| F-06 | Betriebspanel aendert Admin-Konfig | Zustaendiger Empfaenger verweigert | OFFLINE | test_panel_permissions.lua | NOT_RUN |
| F-07 | Alte Epoch nach Failover | Befehle verweigert | OFFLINE | test_fence.lua, test_ha_integration.lua | NOT_RUN |
| F-08 | Widerrufener Schluessel | Keine Authentifizierung nach Austausch | OFFLINE | test_auth.lua, test_replacement.lua | NOT_RUN |
| F-09 | Fremdcomputer an Wired-Peripheral-Netz | Kein unautorisierter direkter Zugriff | PARTIAL | test_auth.lua | NOT_RUN |
| F-10 | Authentifizierungs-Spam/Ueberlast | Begrenzte Verarbeitung, sicherer Fehlerbetrieb | OFFLINE | test_auth.lua | NOT_RUN |
| G-01 | Mehrere Train Stations pro Bahnhof | Eindeutige gleisgenaue Zuordnung | PARTIAL | test_station_apply_schedule.lua | NOT_RUN |
| G-02 | Alternatives Bahnhofsgleis | Nur bestaetigte passende Einfahrt | OFFLINE | test_dispatcher_proof.lua | NOT_RUN |
| G-03 | Zwei Zuege, ein Depotgleis | Exklusive Belegung/Reservierung | OFFLINE | test_track_choice.lua | NOT_RUN |
| G-04 | Depot vollstaendig belegt | Kein planmaessiger Zufahrtsstau | OFFLINE | test_track_choice.lua | NOT_RUN |
| G-05 | Vollbeladungsregel | Fracht tatsaechlich bestaetigt | OFFLINE | test_fleet_cargo.lua | NOT_RUN |
| G-06 | Mindestteilmenge | Schwelle tatsaechlich bestaetigt | OFFLINE | test_fleet_cargo.lua | NOT_RUN |
| G-07 | Zeitgesteuerte Abfahrt ohne Warenbeweis | Unbekannte Ladung nicht gutgeschrieben | OFFLINE | test_fleet_cargo.lua | NOT_RUN |
| G-08 | Teilentladung | Nur tatsaechlich nachgewiesene Menge geliefert | OFFLINE | test_fleet_cargo.lua | NOT_RUN |
| G-09 | Doppelte Warenmeldung | Keine doppelte Buchung | OFFLINE | test_fleet_cargo.lua | NOT_RUN |
| G-10 | Ladestellenausfall | Kein fingierter Ladestatus | PARTIAL | test_fleet_cargo.lua | NOT_RUN |
| G-11 | Abbruch mit bereits geladener Fracht | Rest und Standort nachvollziehbar | PARTIAL | test_fleet_cargo.lua | NOT_RUN |
| G-12 | Depotfahrt | Geeignetes Abstellgleis und Masterfreigabe | PARTIAL | test_track_choice.lua | NOT_RUN |
| H-01 | Mehrere Monitore am Panel-PC | Unterschiedliche Ansichten gleichzeitig | PARTIAL | test_panel_monitors.lua | NOT_RUN |
| H-02 | Verknuepfte Monitorgruppe | Gemeinsame Auswahl ohne extra Steuerung | OFFLINE | test_panel_monitors.lua | NOT_RUN |
| H-03 | Unabhaengiger Monitor | Keine ungewollte Gruppenkopplung | OFFLINE | test_panel_monitors.lua | NOT_RUN |
| H-04 | Verschiedene Monitorgroessen | Bedienung, Zeichnung und Touch korrekt | GAME | - | NOT_RUN |
| H-05 | Halbautomatisch erzeugtes Gleisbild | Nur bestaetigte Topologieobjekte | OFFLINE | test_panel_diagram.lua | NOT_RUN |
| H-06 | Layout manuell bearbeiten | Sicherheitsgraph bleibt unveraendert | OFFLINE | test_panel_diagram.lua | NOT_RUN |
| H-07 | Layoutentwurf speichern | Laufende Anzeige unveraendert | OFFLINE | test_panel_diagram.lua | NOT_RUN |
| H-08 | Layoutversion ausdruecklich aktivieren | Keine Aktivierung ohne Pruefung/Bestaetigung | OFFLINE | test_panel_diagram.lua | NOT_RUN |
| H-09 | Offline Gleisbild/Fahrplan bearbeiten | Entwurf lokal gespeichert | OFFLINE | test_panel_offline.lua | NOT_RUN |
| H-10 | Reconnect nach Offline-Aenderung | Versionspruefung, Rechte und erneute Bestaetigung | OFFLINE | test_panel_offline.lua | NOT_RUN |
| H-11 | Master-Daten veraltet | Kein Anzeige-Freibeweis | OFFLINE | test_panel_offline.lua, test_panel_fault_center.lua | NOT_RUN |
| H-12 | Gleichzeitige Bedienung zweier Panels | Versionskonflikt erkannt, kein Doppelauftrag | PARTIAL | test_fleet_engine.lua | NOT_RUN |
| H-13 | 300+ Signalobjekte zeichnen | Keine fehlerhaften Zustands-/ID-Verknuepfungen | PARTIAL | test_load_signals.lua | NOT_RUN |
| H-14 | Monitor im Betrieb entfernen | Andere Anzeigen und Betrieb bleiben funktionsfaehig | PARTIAL | test_panel_monitors.lua | NOT_RUN |
| I-01 | Update automatisch vorbereiten | Aktivierung verlangt ausdrueckliche Bestaetigung | OFFLINE | test_update_control.lua | NOT_RUN |
| I-02 | Unberechtigte Updateanforderung | Empfangende Node lehnt ab | OFFLINE | test_update_package.lua, test_updater.lua | NOT_RUN |
| I-03 | Manipuliertes Paket | Authentizitaet/Integritaet scheitert | OFFLINE | test_update_package.lua | NOT_RUN |
| I-04 | Update bei betroffener aktiver Fahrt | Unzulaessiger Neustart verhindert | OFFLINE | test_update_control.lua | NOT_RUN |
| I-05 | Master-A/B einzeln aktualisieren | Keine Freigabe ohne vorgeschriebene Bestaetigung | OFFLINE | test_update_control.lua | NOT_RUN |
| I-06 | Flottenpartner aktualisieren | Kein Doppelauftrag, kein Partnerwechsel | OFFLINE | test_update_control.lua | NOT_RUN |
| I-07 | Neustart mitten in Slotwechsel | Definierter gueltiger Slot oder sichere Sperre | PARTIAL | test_update_control.lua, test_updater.lua | NOT_RUN |
| I-08 | Fehler nach Update, Rollback | Kein altes Sicherheitsjournal blind eingespielt | OFFLINE | test_update_control.lua | NOT_RUN |
| I-09 | Inkompatible Schema-Migration | Kein automatischer Betrieb | OFFLINE | test_update_package.lua | NOT_RUN |
| I-10 | Wartungssperre ueber Neustart | Sperre bleibt wirksam | OFFLINE | test_op_state.lua | NOT_RUN |
| I-11 | Signalcontroller tauschen | Neue physische Zuordnung/Identitaet bestaetigt | OFFLINE | test_replacement.lua | NOT_RUN |
| I-12 | Panel-Node aktualisieren | Andere Nodes unabhaengig funktionsfaehig | OFFLINE | test_update_control.lua | NOT_RUN |
| J-01 | 300+ Signale aktiv | Keine falschen Zuordnungen oder Fahrfreigaben | PARTIAL | test_load_signals.lua | NOT_RUN |
| J-02 | 400 Signale im Stresstest | Queue-/Speichergrenzen eingehalten | PARTIAL | test_load_signals.lua | NOT_RUN |
| J-03 | Gleichzeitige Fahrten | Kein Konflikt bei Last | PARTIAL | test_load_signals.lua | NOT_RUN |
| J-04 | Mehrmonitor-Panel unter Last | Messbar bedienbar innerhalb freigegebener Grenzwerte | GAME | - | NOT_RUN |
| J-05 | Grosse Gleisbildaenderungen | Keine unkontrollierte Komplettneuzeichnung | PARTIAL | test_load_signals.lua | NOT_RUN |
| J-06 | Paketsturm/Verlust | Kritische Ereignisse priorisiert; Verlust erkannt | PARTIAL | test_auth.lua, test_auth.lua | NOT_RUN |
| J-07 | Langer Dauerlauf | Kein unbegrenzter Speicher-/Journalanstieg | PARTIAL | test_journal.lua | NOT_RUN |
| J-08 | Voller Datentraeger | Neue Freigabe scheitert sicher | OFFLINE | test_journal.lua, test_dual_commit.lua | NOT_RUN |
| J-09 | Logrotation/Archivierung | Begrenzt und konsistent | PARTIAL | test_journal.lua | NOT_RUN |
| J-10 | Serverneustart unter Last | Kein Doppelbefehl oder Phantom-Raeumungsnachweis | PARTIAL | test_fleet_engine.lua, test_dispatcher_proof.lua | NOT_RUN |
| E2E-01 | Manuelle Personenfahrt nach Bahnhof Sued | Ohne verfruehte Freigabe, Doppelausfuehrung oder unbestaetigte Blockraeumung | PARTIAL | test_fleet_e2e.lua | NOT_RUN |
| E2E-02 | Zwei konkurrierende Personenfahrten, Zielbahnhof belegt | Halt an bestaetigter Warteposition, spaeter Freigabe, keine Deadlock-Kollision | PARTIAL | test_plan_builder_sim.lua, test_deadlock.lua | NOT_RUN |
| E2E-03 | Gueterzug mit Teilbeladung, Zeitfenster, Masterausfall, Teilentladung | Nur nachgewiesene Menge buchen, offene Mengen erhalten | PARTIAL | test_fleet_cargo.lua, test_fleet_engine.lua | NOT_RUN |
| E2E-04 | Master A faellt nach Reservierungscommit vor bestaetigtem setSchedule aus | Nach Wiederherstellung kein doppelter Fahrplan- oder Reservierungsbefehl | PARTIAL | test_fleet_engine.lua, test_dual_commit.lua | NOT_RUN |
| E2E-05 | Panel offline, parallele Fahrplanaenderung, Entwurf, Reconnect | Konfliktpruefung und bewusste Neuveroeffentlichung ohne unkontrollierte Fahrt | PARTIAL | test_panel_offline.lua, test_panel_offline.lua | NOT_RUN |
| E2E-06 | Neue Signal-Node/Bahnhofseinmuendung im Betrieb | Unabhaengige Bereiche nur bei globaler Bereitschaft aktiv; geaenderter Bereich gesperrt bis Abnahme | PARTIAL | test_occupancy.lua, test_op_state.lua | NOT_RUN |
| E2E-07 | Rollen-/Schluesselwechsel und Update einer Signal-Node | Fremdcomputer ohne Peripheralzugriff; Update nach Bestaetigung; Recovery | PARTIAL | test_replacement.lua, test_update_control.lua | NOT_RUN |
| E2E-08 | Komplettneustart aller Computer mit mehreren Zuegen in der Welt | Keine alte Befehlswiederholung; offene Reservierungen und unbekannte Teilstrecken geschuetzt | PARTIAL | test_e2e_offline.lua, test_dispatcher_proof.lua | NOT_RUN |

## Risiko-Register

| ID | Risiko | Faelle | Freigabebedingung |
|---|---|---|---|
| R-01 | Signal setForcedRed verliert CC-Bindung | A-08 | Physischer Test und fail-safe Streckenbau; sonst Automatikbereich sperren |
| R-02 | Kein Zugschlussnachweis fuer alle Bloecke | B-08 | Selektive Sensor-/Stations-/Signalnachweise oder Bereich nicht automatisch frei geben |
| R-03 | Create faehrt moeglicherweise andere Route als Softwaregraph | C-01, G-02 | Reachability-/Fahrplan-/physische Routentests; bei Unklarheit keine Freigabe |
| R-04 | CC-Peripherals ueber fremden Rechner direkt erreichbar | F-09 | Steuer-Peripherien abkoppeln/segmentieren; Test F-09 |
| R-05 | Pure-Lua-Kryptografie, Schluessel und Bootvertrauen | F-01, F-08 | Benchmarks (scripts/auth_bench.lua), Testvektoren, manuelle Erstregistrierung |
| R-06 | Master-Fencing im partitionierten Netz | E-01, E-02, E-03, E-04, E-05, E-06, E-07, E-08, E-09, E-10 | Formales Protokoll + Fehlertests E-01..E-10; fail-closed wenn nicht beweisbar |
| R-07 | Zwei-Master-Durable-Commit sperrt Betrieb bei Einzelmasterausfall | E-02 | Bewusste Verfuegbarkeitsbegrenzung; keine stillschweigende Lockerung |
| R-08 | CC-Speicher/CPU/Monitore unter 400-Signallast | J-01, J-02, J-04, H-13 | Leistungsmessung, Delta-Updates, bounded work, ggf. zusaetzliche Nodes |
| R-09 | Onboard CC und Cargo-Inventare nicht garantiert verfuegbar | G-05, G-07, G-10 | Virtuelle Zug-Nodes, unabhaengige Ladestellenbelege; manuelle Bestaetigung erlaubt |
| R-10 | Event-Verlust/Restart/Chunk-Unload | A-10, E-09, J-10 | Dauerhafte Journale, Versions-/Evidenzluecken erkennen und konservativ sperren |
| R-11 | Veraltete Repository-Modelle | - | V3-Arbeitspakete ersetzen inkompatible Altannahmen (docs/V3_ZIEL.md) |
| R-12 | Mod-/Serverversion kann Verhalten aendern | A-01 | Exakte Modpack-Version fixieren; neuer Build braucht gezielte Regressionstests |
