# Belegungsnachweis, sichere Wartepunkte, Freigabe (Gesamtkonzept Kap. 3, 4, 5.2)

Der Master kennt zu jedem Block drei **Beweisstufen**: `FREE_PROVEN`, `OCCUPIED_PROVEN`, `UNKNOWN`. Reserviert und belegt sind davon unabhängig (Kap. 4.1): ein Block kann reserviert und
`FREE_PROVEN` sein. Ein Block gilt nur als frei, wenn er bewiesen frei ist (S-03).

## Was ein Nachweis ist

| Quelle | frei | belegt |
|---|---|---|
| Endsensor (`tail_sensors`) meldet "leave" | ja | – |
| frischer Detektorpegel aller Sensoren des Blocks ("frei", nicht älter als `auto_clear_max_age_s`) | ja | – |
| Beobachter (P6), Bahnhof | ja | ja |
| Einfahrtsensor ("enter") | – | ja |

**Kein Nachweis** (Kap. 3, verbotene Ersatznachweise): Signal steht auf Rot, kein Zug am Bahnhof, seit N Sekunden keine Meldung, Fahrplan wurde akzeptiert, geplante Zugposition, Computer antwortet
nicht, Beobachtermeldung fehlt, Neustart, Verbindungsabbruch, Wort des Bedieners. Sie dürfen sperren (der Block wird `UNKNOWN`), aber nie freigeben.

Ein Neustart des Masters und jeder Führungswechsel vergessen **alle** Nachweise (S-07). Eine Reparatur (`clear_fault`) oder ein Ende der Wartung beweist nichts: der Block braucht den Nachweis neu (S-10).
Der Nachweis wird nicht zum anderen Master repliziert (er würde ohnehin nach einem Wechsel nicht geglaubt), das Replikat enthält die Entscheidungen: Reservierungen, Züge, Warteschlange.

## Schalter

`occupancy_proof = "on"` (Standard `off`, siehe `docs/config_reference.md`). Mit `off` bleibt das alte Verhalten, die Beweisstufen werden trotzdem mitgeführt und angezeigt. **Ohne `on` erfüllt der Master S-03 nicht.**
Mit `on` gilt:

1. **Freigabe nur über bewiesen freie Blöcke.** Nach dem Start ist alles `UNKNOWN`; die Blöcke werden frei, sobald alle ihre Sensoren frisch "frei" melden (Aufgabe `prove_free`, alle 2 s) oder ein Beobachter es belegt.
   Ein Block ohne Sensor kann nie bewiesen werden (Warnung `no_tail_evidence` im Graphen, R-02): der Bereich bleibt von der Automatik ausgenommen.
2. **Die Fahrstraße endet an einem bewiesenen sicheren Wartepunkt** (`safe_stops`, `proven = true`) und der Zug passt (`length`). Es gibt keine Ersatzhalte unterwegs (S-08, 4.2). Ein Wartepunkt ohne Haltetest im Spiel
   (`proven = false`) zählt nicht.
3. **Das Ende des Zuges wird bewiesen.** Ein "leave" von einem Sensor, der kein Endsensor des Blocks ist, hebt den Block nicht auf. Wird eine Fahrstraße freigegeben, während der Zug noch auf einem Block steht, bleibt der
   Block belegt (`get_clearing()` nennt ihn), bis der Endsensor oder ein Beobachter die Räumung belegt (S-05).
4. **Verklemmungen werden gemeldet, nie erzwungen gelöst** (Kap. 4.4): stehende Züge, die auf Blöcke voneinander warten, stehen im Bericht `get_deadlocks()` mit dem Zyklus; keine Reservierung wird entzogen. Eine
   **bestätigte Alternative** (`alternatives`, `reachability_confirmed`) wird versucht, wenn der erste Weg nicht frei ist; Create muss diesen Weg nachweislich nehmen (R-03).

## Zustandsautomat einer Reservierung (Kap. 5.2)

`PROPOSED -> VALIDATED -> PREPARED_BOTH_DURABLE -> COMMITTED_BOTH_DURABLE -> ACTUATION_ELIGIBLE -> ACTUATED -> IN_PROGRESS -> CLEARANCE_PENDING -> RELEASED_PROVEN`, daneben `FAULT` und `UNCERTAIN`.
Kein Zustand wird übersprungen. Mit zwei Mastern gibt der Dispatcher ein Signal erst in `ACTUATION_ELIGIBLE` (der andere Master hält den Eintrag dauerhaft und hat ihn bestätigt); ein einzelner Master durchläuft die
Zwischenzustände sofort. `RELEASED_PROVEN` gilt erst, wenn jeder Block der Fahrstraße bewiesen frei ist; bis dahin steht die Reservierung in `CLEARANCE_PENDING`. Nach einem Neustart oder Wechsel sind Reservierungen,
die möglicherweise wirksam wurden, `UNCERTAIN` und werden nur über den Nachweis der Räumung beendet.

## Grenzen

- Der Graph (`src/domain/safety_graph.lua`) plant und prüft Konflikte; dass Create denselben Weg wählt, beweist er nicht (R-03). Deshalb endet jede Freigabe an einem Wartepunkt, den der Haltetest bestätigt hat.
- Beobachter-Nodes, die Blöcke aktiv abfragen, kommen mit P6; bis dahin beweisen nur Sensorpegel und Endsensoren.
- Haltetest, Zuglängen und die Räumung langer Züge sind nur im Spiel prüfbar (`docs/INGAME_TESTS.md`, Zeilen 0ca bis 0cd).
