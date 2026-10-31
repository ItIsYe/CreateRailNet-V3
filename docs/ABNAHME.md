# Abnahmematrix A01 bis A18

Jede Pruefung aus Konzept 17.2 mit dem automatischen Test (laeuft ohne Spiel, jede Aenderung) und dem Schritt im grossen Spieltest (`docs/GROSSER_TEST.md`), der sie am echten Modpack bestaetigt. Eine Zeile gilt erst als abgenommen, wenn der Spieltest-Schritt ein Ergebnis hat.

| Kennung | Pruefung | Automatischer Test | Spieltest |
|---|---|---|---|
| A01 | Modversionen und Methoden inventarisieren | tests/test_dev.lua, tests/test_stage8.lua (Schnittstellenabdruck) | 2.1, 3.4, 8.13 |
| A02 | Station mit und ohne Zug abfragen | tests/test_dev.lua | 2.1, 2.2 |
| A03 | Ankunft und Abfahrt beobachten | tests/test_dev.lua, tests/test_e2e_station.lua | 4.11, 4.12 |
| A04 | Fahrplan an haltendem Zug setzen | tests/test_e2e_station.lua, tests/test_station_role.lua | 4.8, 4.20 |
| A05 | Fahrplan bei bestehender Navigation pruefen | tests/test_station_role.lua (unklare Ausgangslage) | 4.16, 7.9 |
| A06 | Letzte Freigabebedingung | tests/test_domain.lua | 4.20 |
| A07 | Zwei Weizen-Tastendruecke | tests/test_e2e_station.lua | 4.13 |
| A08 | 639 und 640 Weizen | tests/test_domain.lua, tests/test_e2e_station.lua | 4.9, 4.10 |
| A09 | Signal rot erzwingen und aufheben | tests/test_stage6.lua | 6.3 |
| A10 | Computer stoppen, Modem abziehen | (nur im Spiel messbar) | 6.7 |
| A11 | T-Knoten mit langen Zuegen | tests/test_areas.lua, tests/test_stage6.lua | 6.10 |
| A12 | Vier und weitere Gleise | tests/test_stage5.lua | 5.3, 5.7 |
| A13 | Manuell gefahrenen Zug anmelden | tests/test_stage7.lua | 7.7, 7.8, 7.9 |
| A14 | Unbekannten Zug einfahren lassen | tests/test_stage7.lua, tests/test_e2e_station.lua | 7.12 |
| A15 | Zentrale waehrend eines Auftrags neu starten | tests/test_e2e_station.lua, tests/test_stage8.lua | 4.14, 8.2 |
| A16 | Chunkgrenze und Entladen | (nur im Spiel messbar) | 9.3, 9.4 |
| A17 | Computer ersetzen | tests/test_stage8.lua | 8.10, 8.11, 8.12 |
| A18 | Update des Modpacks | tests/test_stage8.lua, tests/test_installer.lua | 8.13, 8.14 |

Last (Konzept 16, Stufe 9): `tests/test_load.lua` mit 312 Signalen an 26 Computern und mit einem Node mit 450 Signalen (Berichte und Konfigurationssicherung in Teilen); im Spiel `docs/GROSSER_TEST.md` Abschnitt Stufe 9.
