# Flotte: Zugpaare, Fahrplaene, Auftraege, Fracht (Gesamtkonzept Kap. 8 bis 10, 24)

Die Flotte besteht aus **festen Paaren** von Flotten-Nodes (Rolle `fleet`). Die erste Node eines Paares ist die aktive (sie entscheidet), die zweite haelt eine dauerhafte Kopie und tut sonst nichts. Es gibt
**keine Uebernahme**: faellt der Partner aus, sind neue automatische Auftraege dieses Paares gesperrt; andere Paare arbeiten weiter (Kap. 8.1). Ein ungerader Rest bleibt Reserve.

## Netzplan

```json
"fleet": {
  "pairs": [ { "id": "P1", "nodes": ["FLEET-A", "FLEET-B"], "trains": ["TRAIN-1"] } ],
  "train_profiles": [ { "immutable_id": "TRAIN-1", "create_name_ref": "Sued 1", "train_class": "PASSENGER", "length": 6, "permitted_directions": ["EAST", "WEST"], "line_permissions": ["L1"] } ],
  "lines": [ { "id": "L1", "kind": "PASSENGER", "time_base": "REAL", "window": {"from": "06:00", "to": "22:00"}, "departures": ["08:00"], "headway_min": null,
               "stops": [ {"station": "NORD"}, {"station": "SUED"} ], "routes": {"EAST": "R-NS"}, "origin": "NORD", "goal": "SUED", "direction": "EAST" } ],
  "platforms": { "SUED": [ { "id": "P1", "block": "BP1", "direction": "EAST", "length": 8, "confirmed": true, "preferred": 1 } ] },
  "stations": { "NORD": "STATION-N" } }
```

`scripts/setup.lua --check` prueft Paare, Profile, Linien und Bahnsteige. Die Flotten-Nodes brauchen den Partner und die Stations-Nodes in `cmd_sources`.

## Was wer tut

| Teil | Aufgabe | Datei |
|---|---|---|
| Profil | unveraenderliche Zug-ID, Create-Name, Laenge, Richtungen, Linienrechte; ein unbekannter Zug wird erkannt, aber nur mit Zustimmung des Bedieners angelegt; eine ausgemusterte ID wird archiviert und nie wieder vergeben | `src/fleet/profile.lua` |
| Prioritaet | sechs Klassen (Ersatz-Personenzug bis zusaetzlicher Gueterzug), FIFO, dokumentierte Alterung (hoechstens zwei Stufen), manuell ist keine hoehere Prioritaet | `src/fleet/priority.lua` |
| Fahrplan | Linien, feste Abfahrten und Takt, Echt- oder Minecraft-Zeit, Zeitzone, Betriebsfenster; Entwurf, Pruefung, Veroeffentlichung erst nach Bestaetigung beider Partner; keine Nachholfahrten nach einem Ausfall, kein Doppelstart nach Neustart oder Zeitspruenge | `src/fleet/timetable.lua` |
| Fahrt | Zustandskette NEW_REQUEST bis COMPLETE (Kap. 24.1), getrennte IDs fuer Auftrag, Fahrt, Fahrtabschnitt, Befehl; ein angenommener Fahrplan ist keine Abfahrt; unklarer Ausgang heisst UNCERTAIN und wird aus Beobachtungen rekonstruiert | `src/fleet/trip.lua` |
| Fracht | nur nachgewiesene Mengen zaehlen; Sendungen mit eigener ID; geliefert / offen / unklar getrennt (24.2); Zeit und Ankunft sind kein Warenbeweis | `src/fleet/cargo_ledger.lua` |
| Paare | feste Paare, Gesundheit, Versionsabgleich, Widerspruch sperrt, Neuzuordnung nur gefuehrt | `src/fleet/pairs.lua` |
| Ablauf | Auftraege aus dem Fahrplan, Zug und Bahnsteig waehlen, Fahrstrasse beim Master anfragen, genau einmal den Fahrplan uebergeben | `src/fleet/engine.lua` |
| Node | Dauerhaftigkeit ueber Journal und Kopie beim Partner; eine bindende Nachricht verlaesst die Node erst, wenn der Partner den Stand hat | `src/nodes/fleet_node.lua` |
| Master | Fahrstrassenanfrage wird Reservierung; Rueckmeldungen aus dem Zustand des Dispatchers (committed, eligible, Abfahrt, Position, Ankunft, Zugschlussnachweis) | `src/master/fleet_bridge.lua` |
| Bahnhof | `apply_schedule`: nur fuer einen Zug auf einem Gleis mit Create-Station, einmal je Befehls-ID | `src/nodes/station_node.lua` |

## Nachrichten

Flotte -> Master (Event): `fleet_route`, `fleet_release`, `fleet_hold`, `fleet_reconstruct`, `fleet_complete`. Master -> beide Flotten-Nodes (Event `fleet_event` mit `ev`): `route_committed`, `route_eligible`, `route_refused`,
`departure_observed`, `position`, `arrival_observed`, `tail_clear`, `station_train`, `reconstruction`; ausserdem `fleet_blocks` (frei reservierbare Bloecke). Flotte -> Bahnhof (cmd): `apply_schedule`; die Antwort
`ack` mit `applied` ist die Quittung des Aufrufs, **nicht** die Beobachtung der Abfahrt. Zwischen den Partnern: `fleet_pair` (Version und Pruefsumme) und `repl` (Zustandsabgleich, wie bei den Mastern).

## Grenzen

- Ob Create den Zug nach `setSchedule` wirklich so faehrt, zeigen nur die Spieltests 0ci bis 0cm.

## Bedienung vom Panel, Ladestellen und Depotfahrten
- **Panel -> Flotte:** der Master leitet Befehle des Panels an den aktiven Knoten des Paars weiter (cmd `fleet_admin`, Antwort als Ereignis `fleet_admin_result`): `timetable_draft` (neuer Entwurf, laeuft noch nicht), `timetable_publish` (gegen die Basisversion, nur bei gesundem Paar und wenn der Partner den Entwurf dauerhaft hat), `trip_cancel`, `cargo_report`, `depot_run`.
  Der aktive Knoten meldet alle 5 s `fleet_status` (Linien, Fahrten, Fracht, Depots, Zuege) an den Master, der es den Panels im Snapshot gibt (`fleet`, `cargo`).
- **Ladestellen:** ein Bahnsteig mit `cargo = { inventory, item, kind }` misst das Inventar neben dem Gleis, wenn der Zug ankommt und wenn er abfaehrt (zwei gleiche Lesungen hintereinander), und meldet die Differenz an die Knoten in `cargo_report_to`
  (`cargo_measure`, Qualitaet AUTO_INVENTORY). Die Flotte bucht sie auf die Fahrt des Zuges. Eine Lesung, die nicht geht, bucht nichts und haelt die Fahrt mit dem Grund; Menge null bucht nichts. Eine Kontrolle durch eine Person (`cargo_report`, MANUAL_AUTH)
  gilt nur fuer Namen aus `fleet.cargo_checkers` und nur, wenn der Auftrag diese Qualitaet zulaesst.
- **Depotfahrten:** `fleet.depots = { DEP1 = { tracks = { { id, block, length, confirmed, preferred, routes = { <Station> = <Route> } } } } }`. Die Gleiswahl ist die von `src/domain/track_choice.lua`: bevorzugtes Depot und Gleis, sonst das naechste passende;
  voll -> anderes Depot -> genehmigter Umlauf (`fleet.depot_circuit`) -> der Zug wartet vor dem Bahnhof und es wird gemeldet. Die Fahrt laeuft durch dieselbe Kette (beide Master, Zeitplan genau einmal). Der Zug muss an einem Bahnhof gesehen worden sein.
