--[[
Purpose: The acceptance matrix of the concept (Kap. 20, 21): every case with its step, its criterion, the offline tests that prove the logic behind it, and the in-game status (all NOT_RUN until a person ran it).
Public API: returns { cases = list, risks = list, signoff = table }.
  case = { id, group, title, criterion, coverage, refs = { "tests/file.lua#fragment of a test name", ... }, status, evidence }
  coverage: "OFFLINE" (the logic is proven by the listed tests; the physical part still needs the game), "PARTIAL" (a part of it is proven offline), "GAME" (only the game can show it)
  status: NOT_RUN | PASS | FAIL | BLOCKED. PASS needs `evidence` with every field of Kap. 20 (see tests/acceptance/lib.lua). Nothing here is PASS: no case ran in the game.
Notes: refs are checked by tests/test_acceptance.lua: the file must exist and contain the fragment, so a renamed or deleted test breaks the matrix instead of silently leaving a claim behind.
]]

local function case(id, title, criterion, coverage, refs)
  return { id = id, group = id:sub(1, 3) == "E2E" and "E2E" or id:sub(1, 1), title = title, criterion = criterion, coverage = coverage, refs = refs or {}, status = "NOT_RUN" }
end

local O, P, G = "OFFLINE", "PARTIAL", "GAME"
local cases = {
  -- A: modpack and peripheral compatibility (10)
  case("A-01", "ATM10/NeoForge/Create/CC-Versionen fixieren", "Exakte Versionen aus der Welt dokumentiert", G),
  case("A-02", "Lokale Peripherals entdecken", "Echte Typen und Methoden korrekt erkannt", P, { "tests/test_station_apply_schedule.lua#create_station" }),
  case("A-03", "Wired Modems mit mehreren Geraeten", "Eindeutige stabile Adressierung, Ersatzerkennung", P, { "tests/test_panel_monitors.lua#vanished_or_was_replaced" }),
  case("A-04", "Train Station erkennt Zug", "Richtige Identitaet, kein Phantom-Zug", P, { "tests/test_fleet_engine.lua#train_must_really_be_at_the_station" }),
  case("A-05", "getSchedule/setSchedule", "Nachweisbare einmalige Aenderung am richtigen Zug", P, { "tests/test_station_apply_schedule.lua#repeated_call_with_the_same_command_id" }),
  case("A-06", "Physische Abfahrt/Ankunft", "Ereignisse und sichtbare Bewegung abgeglichen", G),
  case("A-07", "Signal-Methoden und Status", "Tatsaechlich verfuegbare Methoden dokumentiert", G),
  case("A-08", "Controllerverlust bei forced red", "Rueckfallverhalten physisch getestet; ungeschuetzte Fahrt verhindert", G),
  case("A-09", "Train Observer", "Ereignistypen, Zugnamen, Luecken abgeglichen", P, { "tests/test_dispatcher_proof.lua#an_observer_frees_a_block" }),
  case("A-10", "Chunk-Unload/Serverneustart", "Unbekannte Zeitraeume nicht als frei interpretiert", P, { "tests/test_occupancy.lua#restart_or_a_change_of_leadership_forgets_every_proof" }),
  -- B: track graph and hardware binding (10)
  case("B-01", "Vier Gleise, zwei pro Richtung", "Fahrtrichtung/Zuordnung korrekt", O, { "tests/test_safety_graph.lua#edges_follow_the_route_direction" }),
  case("B-02", "Sechs- und achtgleisige Erweiterung", "Alle Abzweige und Zusammenfuehrungen korrekt", O, { "tests/test_plan_builder.lua#three_platforms_make_a_ladder_of_two_switches" }),
  case("B-03", "Kreuzende Fahrstrassen", "Konfliktgruppen verhindern Gegengenehmigung", O, { "tests/test_safety_graph.lua#two_routes_that_need_one_switch_in_different_positions_conflict" }),
  case("B-04", "Unabhaengige Fahrstrassen", "Parallele Nutzung ohne falsche Sperre", O, { "tests/test_plan_builder_sim.lua#routes_that_share_nothing_may_run_at_the_same_time" }),
  case("B-05", "4/6/8 Signale an Multi-Signal-Node", "Jede Signal-ID steuert das richtige Signal", O, { "tests/test_signal_host.lua#", "tests/test_signal_node_world.lua#" }),
  case("B-06", "Modem-Vertauschung", "Abweichung entdeckt, keine automatische Umbindung", O, { "tests/test_signal_bindings.lua#", "tests/test_panel_monitors.lua#nothing_is_rebound" }),
  case("B-07", "Belegung ohne ausreichenden Nachweis", "UNKNOWN/sperrend, nicht automatisch frei", O, { "tests/test_occupancy.lua#every_block_starts_unknown", "tests/test_dispatcher_proof.lua#unknown_blocks_are_not_given" }),
  case("B-08", "Vollstaendige Zugschlussraeumung", "Freigabe erst nach belegter Raeumung", O, { "tests/test_dispatcher_proof.lua#tail_proves_it_free", "tests/test_dispatcher_proof.lua#train_whose_end_was_not_proven" }),
  case("B-09", "Topologieaenderung im Betrieb", "Nur betroffene Bereiche geprueft/gesperrt", O, { "tests/test_occupancy.lua#only_the_named_blocks_are_invalidated", "tests/test_safety_graph.lua#affected_blocks_of_a_topology_change" }),
  case("B-10", "Sicherer Wartepunkt langer Zug", "Physischer Halt und ausreichende Laenge nachgewiesen", P, { "tests/test_safety_graph.lua#length_of_the_train_must_fit_the_safe_stop" }),
  -- C: routes and train movement (12)
  case("C-01", "Manuelle Personenzugfahrt nach Bahnhof Sued", "Richtiger Zug/Ziel/gesicherter Weg", P, { "tests/test_fleet_e2e.lua#whole_trip_with_a_real_dispatcher", "tests/test_fleet_trip.lua#normal_way_goes_through_every_state" }),
  case("C-02", "Automatische Zugauswahl", "Nur genehmigter kompatibler Zug", P, { "tests/test_fleet_engine.lua#train_of_another_pair_is_never_taken", "tests/test_fleet_profile.lua#" }),
  case("C-03", "setSchedule vor/nach Freigabe", "Keine Uebergabe vor Dual-Commit", O, { "tests/test_fleet_engine.lua#no_signal_of_the_schedule_before_the_actuator_is_eligible", "tests/test_fleet_trip.lua#accepted_schedule_is_not_a_departure" }),
  case("C-04", "Zwei konfliktierende Fahrten", "Keine doppelte Konfliktfreigabe", O, { "tests/test_dual_commit.lua#two_trains_on_routes_that_share_a_block", "tests/test_plan_builder_sim.lua#opposite_trains_on_one_line_exclude_each_other" }),
  case("C-05", "Zwei unabhaengige Fahrten", "Gleichzeitige sichere Durchfuehrung", O, { "tests/test_plan_builder_sim.lua#routes_that_share_nothing_may_run_at_the_same_time" }),
  case("C-06", "Zielbahnsteige belegt", "Sicherer physischer Wartepunkt", P, { "tests/test_track_choice.lua#when_every_suitable_track_is_taken_the_train_waits_before_the_station", "tests/test_fleet_engine.lua#all_platforms_taken_the_trip_waits" }),
  case("C-07", "Richtungswechsel Endbahnhof", "Nur physisch erprobte Richtung", P, { "tests/test_track_choice.lua#length_direction_and_type_exclude_tracks" }),
  case("C-08", "Durchfahrten mehrerer Bahnhoefe", "Vollstaendiger Schutz bis Endpunkt", P, { "tests/test_dispatcher_proof.lua#route_that_does_not_end_at_a_proven_safe_stop" }),
  case("C-09", "Fahrtabbruch in Bewegung", "Naechster erreichbarer sicherer Stopp", P, { "tests/test_fleet_trip.lua#cancel_before_the_schedule_ends_the_trip" , "tests/test_fleet_engine.lua#cancelling_a_running_trip_waits_for_a_safe_stop" }),
  case("C-10", "Ueberlanger Zug/Bahnsteig", "Ungeeignete Zuweisung abgelehnt", O, { "tests/test_track_choice.lua#train_longer_than_every_track", "tests/test_dispatcher_proof.lua#train_that_is_longer_than_the_stop_is_refused" }),
  case("C-11", "Depot voll", "Sichere Alternative statt Zufahrtsblockade", O, { "tests/test_track_choice.lua#full_depot_leads_to_an_alternative_depot" }),
  case("C-12", "Deadlock", "Sichere Planung oder konservative Sperre", O, { "tests/test_deadlock.lua#two_trains_that_wait_for_each_other", "tests/test_dispatcher_proof.lua#standing_trains_that_wait_for_each_others_blocks" }),
  -- D: fleets, timetables and priority (10)
  case("D-01", "Unbekannten Zug registrieren", "Betreiberzustimmung erforderlich", O, { "tests/test_fleet_profile.lua#" }),
  case("D-02", "Doppelzuweisung desselben Zuges", "Maximal ein wirksamer Auftrag", O, { "tests/test_fleet_engine.lua#train_serves_one_trip_at_a_time" }),
  case("D-03", "Mehrere Flottenpaare", "Exklusive Zug-/Auftragszustaendigkeit", O, { "tests/test_fleet_pairs.lua#", "tests/test_fleet_engine.lua#train_of_another_pair_is_never_taken" }),
  case("D-04", "Fester Partner faellt aus", "Keine neue betroffene Automatik", O, { "tests/test_fleet_pairs.lua#", "tests/test_fleet_engine.lua#nothing_happens_when_the_pair_is_not_healthy" }),
  case("D-05", "Partner kehrt zurueck", "Dauerhafter Delta-/Snapshot-Abgleich", O, { "tests/test_fleet_node.lua#a_partner_that_restarts_is_in_step_again", "tests/test_fleet_pairs.lua#" }),
  case("D-06", "Echt-/Minecraft-Zeit", "Zeitbasen korrekt getrennt", O, { "tests/test_fleet_timetable.lua#" }),
  case("D-07", "Takt plus fixe Abfahrten", "Keine doppelte Fahrt-ID", O, { "tests/test_fleet_timetable.lua#", "tests/test_fleet_engine.lua#departure_the_timetable_hands_out_again" }),
  case("D-08", "Verpasste Starts nach Downtime", "Keine unkontrollierten Nachholfahrten", O, { "tests/test_fleet_timetable.lua#" }),
  case("D-09", "Alle sechs Prioritaetsklassen", "Richtige Reihenfolge und FIFO/Anti-Starvation", O, { "tests/test_fleet_priority.lua#" }),
  case("D-10", "Laufenden Fahrplan aendern", "Wechsel nur am sicheren programmierbaren Punkt", P, { "tests/test_fleet_timetable.lua#", "tests/test_fleet_admin.lua#publication_waits_for_the_partner" }),
  -- E: master, network and restart (12)
  case("E-01", "Fuehrenden Master abschalten", "Gueltige Neuwahl, keine alte Berechtigung", O, { "tests/test_election.lua#", "tests/test_ha_integration.lua#e10_a_command_of_an_old_epoch" }),
  case("E-02", "Standby-Master abschalten", "Keine neuen freigabewirksamen Dual-Commit-Operationen", O, { "tests/test_dual_commit.lua#e02_without_the_standby" }),
  case("E-03", "Schiedsrichter abschalten", "Fuehrung A+B moeglich, wenn beide bereit", O, { "tests/test_election.lua#" }),
  case("E-04", "A-B-Link trennen", "Keine neue Sicherheitsfreigabe", O, { "tests/test_election.lua#", "tests/test_replica.lua#" }),
  case("E-05", "Partition Master/Arbiter", "Maximal ein gueltiger Fuehrer, keine neue unbestaetigte Freigabe", O, { "tests/test_election.lua#", "tests/test_dual_commit.lua#leader_that_loses_its_majority" }),
  case("E-06", "Beide Master neu starten", "Journal/physischer Abgleich vor Freigabe", O, { "tests/test_dual_commit.lua#", "tests/test_dispatcher_proof.lua#restart_forgets_every_proof" }),
  case("E-07", "Ausfall im Prepare", "Kein halber Commit freigegeben", O, { "tests/test_dual_commit.lua#e07_" }),
  case("E-08", "Ausfall nach Commit vor Aktuation", "Reservierung erhalten, Ausgang rekonstruiert", O, { "tests/test_dual_commit.lua#e08_" }),
  case("E-09", "Ausfall waehrend Zugfahrt", "Keine Phantom-Stopp-/Raeumungsmeldung", P, { "tests/test_dispatcher_proof.lua#restored_train_is_uncertain_until_its_clearance_is_proven" }),
  case("E-10", "Alter Leader sendet Befehl", "Aktuatoren lehnen ab", O, { "tests/test_ha_integration.lua#e10_a_command_of_an_old_epoch_is_refused_at_the_actuator", "tests/test_fence.lua#" }),
  case("E-11", "Ausfall Signal-/Stationskommunikation", "Betroffene neue Aktionen gesperrt", P, { "tests/test_net_signals.lua#" }),
  case("E-12", "Lokaler Defekt, getrennte sichere Strecke", "Weiterbetrieb nur bei global gueltiger Freigabe", O, { "tests/test_op_state.lua#local_defect_closes_only_areas" }),
  -- F: identity, permissions and replay (10)
  case("F-01", "Unbekannter Rechner meldet sich", "Ohne physische Aufnahme keine Rechte", O, { "tests/test_auth.lua#f01_" }),
  case("F-02", "Fremde Node-ID nutzen", "Authentifizierung scheitert", O, { "tests/test_auth.lua#f02_" }),
  case("F-03", "Nachrichteninhalt manipulieren", "Integritaetskontrolle lehnt ab", O, { "tests/test_auth.lua#f03_" }),
  case("F-04", "Alte Befehle wiederholen", "Keine doppelte reale Ausfuehrung", O, { "tests/test_auth.lua#f04_" }),
  case("F-05", "Anzeige-Panel beantragt Fahrt", "Zustaendiger Empfaenger verweigert", O, { "tests/test_panel_permissions.lua#master_refuses_a_manual_control" }),
  case("F-06", "Betriebspanel aendert Admin-Konfig", "Zustaendiger Empfaenger verweigert", O, { "tests/test_panel_permissions.lua#view_reads_operate_asks_and_locks_admin_manages" }),
  case("F-07", "Alte Epoch nach Failover", "Befehle verweigert", O, { "tests/test_fence.lua#", "tests/test_ha_integration.lua#epoch_is_remembered_across_a_restart" }),
  case("F-08", "Widerrufener Schluessel", "Keine Authentifizierung nach Austausch", O, { "tests/test_auth.lua#f08_", "tests/test_replacement.lua#old_computer_loses_its_key" }),
  case("F-09", "Fremdcomputer an Wired-Peripheral-Netz", "Kein unautorisierter direkter Zugriff", P, { "tests/test_auth.lua#f09_" }),
  case("F-10", "Authentifizierungs-Spam/Ueberlast", "Begrenzte Verarbeitung, sicherer Fehlerbetrieb", O, { "tests/test_auth.lua#f10_" }),
  -- G: stations, depots and goods (12)
  case("G-01", "Mehrere Train Stations pro Bahnhof", "Eindeutige gleisgenaue Zuordnung", P, { "tests/test_station_apply_schedule.lua#schedule_goes_to_the_create_station_of_the_platform" }),
  case("G-02", "Alternatives Bahnhofsgleis", "Nur bestaetigte passende Einfahrt", O, { "tests/test_dispatcher_proof.lua#confirmed_alternative_is_used" }),
  case("G-03", "Zwei Zuege, ein Depotgleis", "Exklusive Belegung/Reservierung", O, { "tests/test_track_choice.lua#a_track_that_is_taken_or_unproven_gives_way" }),
  case("G-04", "Depot vollstaendig belegt", "Kein planmaessiger Zufahrtsstau", O, { "tests/test_track_choice.lua#when_all_depots_are_full", "tests/test_fleet_engine.lua#when_every_depot_is_full_the_train_waits" }),
  case("G-05", "Vollbeladungsregel", "Fracht tatsaechlich bestaetigt", O, { "tests/test_fleet_cargo.lua#departure_rules_full_partial_and_time", "tests/test_cargo_meter.lua#loading_chest_that_lost_items" }),
  case("G-06", "Mindestteilmenge", "Schwelle tatsaechlich bestaetigt", O, { "tests/test_fleet_cargo.lua#departure_rules_full_partial_and_time" }),
  case("G-07", "Zeitgesteuerte Abfahrt ohne Warenbeweis", "Unbekannte Ladung nicht gutgeschrieben", O, { "tests/test_fleet_cargo.lua#time_and_arrival_are_no_proof_of_goods" }),
  case("G-08", "Teilentladung", "Nur tatsaechlich nachgewiesene Menge geliefert", O, { "tests/test_fleet_cargo.lua#example_of_the_concept_700_loaded_650_arrived" }),
  case("G-09", "Doppelte Warenmeldung", "Keine doppelte Buchung", O, { "tests/test_fleet_cargo.lua#message_twice_never_makes_a_second_delivery" }),
  case("G-10", "Ladestellenausfall", "Kein fingierter Ladestatus", O, { "tests/test_fleet_cargo.lua#unloaded_goods_that_were_never_proven_loaded", "tests/test_cargo_meter.lua#gone_peripheral_or_nonsense_is_no_measurement", "tests/test_fleet_engine.lua#failed_one_books_nothing" }),
  case("G-11", "Abbruch mit bereits geladener Fracht", "Rest und Standort nachvollziehbar", P, { "tests/test_fleet_cargo.lua#closed_order_takes_no_more_reports" }),
  case("G-12", "Depotfahrt", "Geeignetes Abstellgleis und Masterfreigabe", O, { "tests/test_track_choice.lua#depot_a_free_compatible_track_is_given_first", "tests/test_fleet_engine.lua#depot_run_chooses_the_track" }),
  -- H: panel, track diagram and offline drafts (14)
  case("H-01", "Mehrere Monitore am Panel-PC", "Unterschiedliche Ansichten gleichzeitig", P, { "tests/test_panel_display.lua#two_monitors_show_two_different_views_at_the_same_time", "tests/test_panel_node_multi.lua#every_bound_monitor_shows_its_own_view" }),
  case("H-02", "Verknuepfte Monitorgruppe", "Gemeinsame Auswahl ohne extra Steuerung", O, { "tests/test_panel_monitors.lua#groups_share_a_selection_but_never_issue_a_command", "tests/test_panel_display.lua#group_shares_the_selection_and_an_independent_monitor_does_not" }),
  case("H-03", "Unabhaengiger Monitor", "Keine ungewollte Gruppenkopplung", O, { "tests/test_panel_monitors.lua#groups_share_a_selection_but_never_issue_a_command" }),
  case("H-04", "Verschiedene Monitorgroessen", "Bedienung, Zeichnung und Touch korrekt", P, { "tests/test_panel_display.lua#each_size_draws_inside_its_own_width" }),
  case("H-05", "Halbautomatisch erzeugtes Gleisbild", "Nur bestaetigte Topologieobjekte", O, { "tests/test_panel_diagram.lua#proposal_puts_every_block_of_the_graph" }),
  case("H-06", "Layout manuell bearbeiten", "Sicherheitsgraph bleibt unveraendert", O, { "tests/test_panel_diagram.lua#editor_moves_labels_and_cuts_out_but_never_touches_a_connection" }),
  case("H-07", "Layoutentwurf speichern", "Laufende Anzeige unveraendert", O, { "tests/test_panel_diagram.lua#active_layout_stays_until_it_is_confirmed" }),
  case("H-08", "Layoutversion ausdruecklich aktivieren", "Keine Aktivierung ohne Pruefung/Bestaetigung", O, { "tests/test_panel_diagram.lua#draft_that_disagrees_with_the_graph_cannot_be_published" }),
  case("H-09", "Offline Gleisbild/Fahrplan bearbeiten", "Entwurf lokal gespeichert", O, { "tests/test_panel_offline.lua#offline_drafts_are_edited" }),
  case("H-10", "Reconnect nach Offline-Aenderung", "Versionspruefung, Rechte und erneute Bestaetigung", O, { "tests/test_panel_offline.lua#the_way_back_checks_the_identity" }),
  case("H-11", "Master-Daten veraltet", "Kein Anzeige-Freibeweis", O, { "tests/test_panel_offline.lua#stale_data_is_labelled_and_never_a_proof", "tests/test_panel_fault_center.lua#old_values_are_labelled" }),
  case("H-12", "Gleichzeitige Bedienung zweier Panels", "Versionskonflikt erkannt, kein Doppelauftrag", O, { "tests/test_fleet_admin.lua#draft_made_on_an_old_version_is_a_conflict", "tests/test_panel_node_multi.lua#moved_line_is_a_conflict_that_a_person_resolves" }),
  case("H-13", "300+ Signalobjekte zeichnen", "Keine fehlerhaften Zustands-/ID-Verknuepfungen", P, { "tests/test_load_signals.lua#drawing_model_of_400_signals", "tests/test_panel_display.lua#track_diagram_draws_the_letter_of_what_is_proven" }),
  case("H-14", "Monitor im Betrieb entfernen", "Andere Anzeigen und Betrieb bleiben funktionsfaehig", O, { "tests/test_panel_monitors.lua#vanished_or_was_replaced", "tests/test_panel_display.lua#monitor_that_is_removed_or_breaks_does_not_stop_the_others" }),
  -- I: updates, maintenance, rollback (12)
  case("I-01", "Update automatisch vorbereiten", "Aktivierung verlangt ausdrueckliche Bestaetigung", O, { "tests/test_update_control.lua#prepared_update_is_not_activated_without_the_operator" }),
  case("I-02", "Unberechtigte Updateanforderung", "Empfangende Node lehnt ab", O, { "tests/test_update_package.lua#wrong_key_breaks_the_origin_proof", "tests/test_updater.lua#", "tests/test_update_trust.lua#offer_without_a_package_is_refused_when_the_node_requires_one" }),
  case("I-03", "Manipuliertes Paket", "Authentizitaet/Integritaet scheitert", O, { "tests/test_update_package.lua#file_that_differs_from_the_list_is_refused", "tests/test_update_trust.lua#files_that_differ_from_the_signed_hashes_are_not_swapped_in" }),
  case("I-04", "Update bei betroffener aktiver Fahrt", "Unzulaessiger Neustart verhindert", O, { "tests/test_update_control.lua#active_journey_that_depends_on_the_node" }),
  case("I-05", "Master-A/B einzeln aktualisieren", "Keine Freigabe ohne vorgeschriebene Bestaetigung", O, { "tests/test_update_control.lua#master_is_updated_as_standby" }),
  case("I-06", "Flottenpartner aktualisieren", "Kein Doppelauftrag, kein Partnerwechsel", O, { "tests/test_update_control.lua#fleet_partner_is_updated_one_at_a_time" }),
  case("I-07", "Neustart mitten in Slotwechsel", "Definierter gueltiger Slot oder sichere Sperre", P, { "tests/test_update_control.lua#restart_in_the_middle_of_the_slot_change", "tests/test_updater.lua#" }),
  case("I-08", "Fehler nach Update, Rollback", "Kein altes Sicherheitsjournal blind eingespielt", O, { "tests/test_update_control.lua#rollback_never_restores_old_reservations" }),
  case("I-09", "Inkompatible Schema-Migration", "Kein automatischer Betrieb", O, { "tests/test_update_package.lua#schema_change_is_never_applied_automatically" }),
  case("I-10", "Wartungssperre ueber Neustart", "Sperre bleibt wirksam", O, { "tests/test_op_state.lua#maintenance_lock_is_still_there_after_a_restart" }),
  case("I-11", "Signalcontroller tauschen", "Neue physische Zuordnung/Identitaet bestaetigt", O, { "tests/test_replacement.lua#every_signal_of_the_old_computer_must_be_bound_again", "tests/test_replacement_flow.lua#whole_replacement_goes_through_the_actions" }),
  case("I-12", "Panel-Node aktualisieren", "Andere Nodes unabhaengig funktionsfaehig", O, { "tests/test_update_control.lua#prepared_update_is_not_activated_without_the_operator" }),
  -- J: load, resources and long run (10)
  case("J-01", "300+ Signale aktiv", "Keine falschen Zuordnungen oder Fahrfreigaben", P, { "tests/test_load_signals.lua#300_signals" }),
  case("J-02", "400 Signale im Stresstest", "Queue-/Speichergrenzen eingehalten", P, { "tests/test_load_signals.lua#400_signals" }),
  case("J-03", "Gleichzeitige Fahrten", "Kein Konflikt bei Last", P, { "tests/test_load_signals.lua#many_trains" }),
  case("J-04", "Mehrmonitor-Panel unter Last", "Messbar bedienbar innerhalb freigegebener Grenzwerte", G),
  case("J-05", "Grosse Gleisbildaenderungen", "Keine unkontrollierte Komplettneuzeichnung", P, { "tests/test_load_signals.lua#large_layout_change" }),
  case("J-06", "Paketsturm/Verlust", "Kritische Ereignisse priorisiert; Verlust erkannt", P, { "tests/test_auth.lua#f10_", "tests/test_auth.lua#traffic_in_both_directions_over_a_bad_link" }),
  case("J-07", "Langer Dauerlauf", "Kein unbegrenzter Speicher-/Journalanstieg", P, { "tests/test_journal.lua#journal_compacts_itself_and_stays_bounded" }),
  case("J-08", "Voller Datentraeger", "Neue Freigabe scheitert sicher", O, { "tests/test_journal.lua#full_disk_stops_appends", "tests/test_dual_commit.lua#change_that_cannot_be_journaled_gives_no_movement" }),
  case("J-09", "Logrotation/Archivierung", "Begrenzt und konsistent", P, { "tests/test_journal.lua#journal_compacts_itself_and_stays_bounded" }),
  case("J-10", "Serverneustart unter Last", "Kein Doppelbefehl oder Phantom-Raeumungsnachweis", P, { "tests/test_fleet_engine.lua#restart_in_the_middle_does_not_make_a_second_trip", "tests/test_dispatcher_proof.lua#restart_forgets_every_proof" }),
  -- end to end (8)
  case("E2E-01", "Manuelle Personenfahrt nach Bahnhof Sued", "Ohne verfruehte Freigabe, Doppelausfuehrung oder unbestaetigte Blockraeumung", P, { "tests/test_fleet_e2e.lua#whole_trip_with_a_real_dispatcher" }),
  case("E2E-02", "Zwei konkurrierende Personenfahrten, Zielbahnhof belegt", "Halt an bestaetigter Warteposition, spaeter Freigabe, keine Deadlock-Kollision", P, { "tests/test_plan_builder_sim.lua#two_trains_for_one_platform_exclude_each_other_and_the_second_follows", "tests/test_deadlock.lua#" }),
  case("E2E-03", "Gueterzug mit Teilbeladung, Zeitfenster, Masterausfall, Teilentladung", "Nur nachgewiesene Menge buchen, offene Mengen erhalten", P, { "tests/test_fleet_cargo.lua#example_of_the_concept_700_loaded_650_arrived", "tests/test_fleet_engine.lua#freight_trip_leaves_only_when_the_cargo_rule_is_met", "tests/test_fleet_engine.lua#loading_point_that_measured_books_the_quantity" }),
  case("E2E-04", "Master A faellt nach Reservierungscommit vor bestaetigtem setSchedule aus", "Nach Wiederherstellung kein doppelter Fahrplan- oder Reservierungsbefehl", P, { "tests/test_fleet_engine.lua#restart_in_the_middle_does_not_make_a_second_trip", "tests/test_dual_commit.lua#e08_" }),
  case("E2E-05", "Panel offline, parallele Fahrplanaenderung, Entwurf, Reconnect", "Konfliktpruefung und bewusste Neuveroeffentlichung ohne unkontrollierte Fahrt", O, { "tests/test_panel_node_multi.lua#draft_goes_on_offline_but_is_not_sent_and_a_moved_line_is_a_conflict", "tests/test_fleet_admin.lua#draft_made_on_an_old_version_is_a_conflict", "tests/test_panel_offline.lua#draft_made_on_an_old_version_is_a_conflict", "tests/test_panel_offline.lua#wishes_made_offline_are_kept_for_the_eye" }),
  case("E2E-06", "Neue Signal-Node/Bahnhofseinmuendung im Betrieb", "Unabhaengige Bereiche nur bei globaler Bereitschaft aktiv; geaenderter Bereich gesperrt bis Abnahme", P, { "tests/test_occupancy.lua#only_the_named_blocks_are_invalidated", "tests/test_op_state.lua#local_defect_closes_only_areas" }),
  case("E2E-07", "Rollen-/Schluesselwechsel und Update einer Signal-Node", "Fremdcomputer ohne Peripheralzugriff; Update nach Bestaetigung; Recovery", P, { "tests/test_replacement.lua#", "tests/test_update_control.lua#a_failed_activation_locks_the_node" }),
  case("E2E-08", "Komplettneustart aller Computer mit mehreren Zuegen in der Welt", "Keine alte Befehlswiederholung; offene Reservierungen und unbekannte Teilstrecken geschuetzt", P, { "tests/test_e2e_offline.lua#e2e_08", "tests/test_dispatcher_proof.lua#restart_forgets_every_proof_but_keeps_the_reservations" }),
}

local risks = {
  { id = "R-01", title = "Signal setForcedRed verliert CC-Bindung", cases = { "A-08" }, release = "Physischer Test und fail-safe Streckenbau; sonst Automatikbereich sperren" },
  { id = "R-02", title = "Kein Zugschlussnachweis fuer alle Bloecke", cases = { "B-08" }, release = "Selektive Sensor-/Stations-/Signalnachweise oder Bereich nicht automatisch frei geben" },
  { id = "R-03", title = "Create faehrt moeglicherweise andere Route als Softwaregraph", cases = { "C-01", "G-02" }, release = "Reachability-/Fahrplan-/physische Routentests; bei Unklarheit keine Freigabe" },
  { id = "R-04", title = "CC-Peripherals ueber fremden Rechner direkt erreichbar", cases = { "F-09" }, release = "Steuer-Peripherien abkoppeln/segmentieren; Test F-09" },
  { id = "R-05", title = "Pure-Lua-Kryptografie, Schluessel und Bootvertrauen", cases = { "F-01", "F-08" }, release = "Benchmarks (scripts/auth_bench.lua), Testvektoren, manuelle Erstregistrierung" },
  { id = "R-06", title = "Master-Fencing im partitionierten Netz", cases = { "E-01", "E-02", "E-03", "E-04", "E-05", "E-06", "E-07", "E-08", "E-09", "E-10" }, release = "Formales Protokoll + Fehlertests E-01..E-10; fail-closed wenn nicht beweisbar" },
  { id = "R-07", title = "Zwei-Master-Durable-Commit sperrt Betrieb bei Einzelmasterausfall", cases = { "E-02" }, release = "Bewusste Verfuegbarkeitsbegrenzung; keine stillschweigende Lockerung" },
  { id = "R-08", title = "CC-Speicher/CPU/Monitore unter 400-Signallast", cases = { "J-01", "J-02", "J-04", "H-13" }, release = "Leistungsmessung, Delta-Updates, bounded work, ggf. zusaetzliche Nodes" },
  { id = "R-09", title = "Onboard CC und Cargo-Inventare nicht garantiert verfuegbar", cases = { "G-05", "G-07", "G-10" }, release = "Virtuelle Zug-Nodes, unabhaengige Ladestellenbelege; manuelle Bestaetigung erlaubt" },
  { id = "R-10", title = "Event-Verlust/Restart/Chunk-Unload", cases = { "A-10", "E-09", "J-10" }, release = "Dauerhafte Journale, Versions-/Evidenzluecken erkennen und konservativ sperren" },
  { id = "R-11", title = "Veraltete Repository-Modelle", cases = {}, release = "V3-Arbeitspakete ersetzen inkompatible Altannahmen (docs/V3_ZIEL.md)" },
  { id = "R-12", title = "Mod-/Serverversion kann Verhalten aendern", cases = { "A-01" }, release = "Exakte Modpack-Version fixieren; neuer Build braucht gezielte Regressionstests" },
}

-- who has to decide on the release at all (Kap. 20.2, G5): empty until a person fills it in
local signoff = { load_reserve = nil, release_decision = nil, responsible = nil }

return { cases = cases, risks = risks, signoff = signoff }
