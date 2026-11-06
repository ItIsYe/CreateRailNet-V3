# Messwerte vom echten Modpack

Gemessen mit `probe/crn_probe.lua` und `probe/crn_probe2.lua`. Umgebung: ComputerCraft 1.120.2, Minecraft 1.21.1, ein Computer mit Funkmodem (`left`), Kabelmodem mit Hub (`right`), Create_Station, Create_Signal und Create_TrainObserver. Das ist die Grundlage fuer die Pruefungen A01 bis A05 des Konzepts 1.1. Was nicht gemessen wurde, steht unten bei "Offen".

## Gesichert

| Nr | Messwert | Folge fuer das Konzept |
|---|---|---|
| M01 | Computerspeicher `fs.getCapacity` = 1 000 000 Byte | Die 1-MB-Grenze gilt. |
| M02 | `http` ist verfuegbar, `raw.githubusercontent.com` ist erreichbar | Installation per Download ist moeglich. |
| M03 | Station hat alle 16 Methoden des Konzepts, Signal alle 6, Beobachter beide | Keine Methode fehlt (A01). |
| M04 | `getTrainName()` und `hasSchedule()` werfen ohne Zug den Fehler `there is no train present` | Immer mit `pcall` aufrufen; "kein Zug" ist ein normaler Zustand. |
| M05 | Ereignisse tragen den Geraetenamen (`Create_Station_1`), nicht den Bahnhofsnamen (`Abstell 11`) | Zuordnung Geraet zu Bahnhof gehoert in die Gerätebindung. |
| M06 | Reihenfolge am Bahnhof: `train_imminent`, `train_passing` (Beobachter), `train_arrival`, `train_departure`, `train_passed` (Beobachter) | Ankuendigung etwa 3 bis 4 s vor Ankunft; Beobachter liegt vor dem Bahnhof. |
| M07 | `train_signal_state_change` liefert nur `RED` oder `GREEN` | Weitere Zustaende wurden nicht gesehen. |
| M08 | Das eigene `setForcedRed` loest dasselbe Ereignis aus wie ein natuerlicher Wechsel, innerhalb eines Ticks (0,05 s) | Ob ein Signal durch uns rot ist, nur ueber `isForcedRed()` pruefen, nie ueber das Ereignis. |
| M09 | `setForcedRed(true)` dann `false` stellt den Ausgangszustand her; `isForcedRed` und `getState` sind sofort richtig | Schreibweg und Rueckstellung funktionieren (A09). |
| M10 | `getSchedule()`: `{cyclic, entries=[{instruction={id="create:destination", data={text}}, conditions=[[{id, data}]]}]}`; `conditions` ist Liste von Gruppen aus Bedingungen; `create:delay` hat `value` und `time_unit` (1, vermutlich Sekunden) | Fahrplanmodell des Konzepts muss diese Form lesen und schreiben. |
| M11 | `getSchedule()` enthaelt keinen Fortschritt (aktueller Eintrag) | Das Ziel eines Zuges aus Ereignissen ableiten oder als unbekannt fuehren. |
| M12 | `setSchedule` mit dem unveraenderten Fahrplan eines haltenden Zuges: `ok`, danach identisch, Zug fuhr normal weiter | Der Schreibweg ueber den Bahnhof funktioniert. Aenderung des Inhalts ist nicht gemessen. |
| M13 | `canTrainReach(Name)` liefert `true, nil` oder `false, "no-target"`; `distanceTo(eigener Name)` liefert `0, nil` | Zwei Rueckgabewerte beachten. |
| M14 | Zugname ist nicht eindeutig: `Unnamed Train` ist der Standardname, zwei Zuege hatten verschiedene Fahrplaene | Zugregister nicht auf den Namen allein stuetzen; eindeutige Namen vor Betriebsfreigabe verlangen. |
| M15 | 40 Geraeteaufrufe (Signal ueber das Kabelmodem, Bahnhof) brauchen weniger als 5 ms Echtzeit und keinen Tick | Abfragekosten sind kein Engpass; 300 Signale abzufragen ist billig. |
| M16 | `isTrainEnroute()` ist `true`, sobald ein Zug zum Bahnhof unterwegs ist | Vorwarnung ohne Ereignis lesbar. |

## Zeit

- `os.clock` laeuft 10 s, die Echtzeit (`os.epoch("utc")`) 18,3 s. Verhaeltnis 1,83 in beiden Laeufen (zuvor 1,85). Das passt zu etwa 11 Ticks pro Sekunde auf dem Server. Das ist eine Vermutung; `tps` auf dem Server bestaetigt sie.
- `os.epoch("ingame")` lieferte keine Veraenderung. Nicht verwenden.
- Folge: Alle Zeitueberwachungen (Timeouts, Haltezeiten, Heartbeats) in Spielzeit (`os.clock`) rechnen und mit langsamer Spielzeit testen.

## M17 Ausfallwirkung am Signal (A10, vom Betreiber gemessen)

- Sobald das Modem direkt am Signal entfernt wird, faellt das Signal in seinen Ausgangszustand zurueck (zusaetzliche Software-Sperre ist weg). Ob der Computer dabei laeuft oder angehalten ist, spielt keine Rolle; allein das Modem am Signal zaehlt.
- Folge: Eine Software-Sperre (`setForcedRed`) ist nur so haltbar wie diese eine Modemverbindung. Sie ist kein Notstopp. Der Signal-Node meldet ein verschwundenes Geraet als "nicht verfuegbar" (Leitstelle: Stoerung), und kommt das Signal zurueck, wird eine eigene Sperre durch den Abgleich schuetzend neu gesetzt.
- Folge fuer den Knoten: Faellt ein Einfahrtssignal aus (Modem weg), ist die Einfahrt nicht mehr zusaetzlich gesperrt. Das ist eine Stoerung des Bereichs und wird angezeigt, nicht still hingenommen.

## M18 Signal bei Zugdurchfahrt (vom Betreiber gemessen, ohne Beobachter)

Messung mit `probe/crn_probe4.lua`: 180 s, zwei Signale (`Create_Signal_5`, `Create_Signal_34`), ein Zug "Zug 5" auf einem Rundkurs, **kein Beobachter angeschlossen**, Abfrage alle 0,2 s (die drei Aufrufe je Signal laufen nacheinander).

- Bei jeder Durchfahrt wechselt das Signal auf `RED` und `listBlockingTrainNames()` nennt den Zugnamen; beim Verlassen des Blocks wird es wieder `GREEN` und die Liste ist leer. **6 von 6 Durchfahrten** (4 an `Create_Signal_5`, 2 an `Create_Signal_34`).
- Der Name erscheint 0 bis 0,75 s nach dem Ereignis `train_signal_state_change` (RED) in der Liste und verschwindet gleichzeitig mit dem Ereignis GREEN (0 bis 0,2 s); feiner als der Abfrageabstand ist das nicht aufgeloest. Das Ereignis kommt 0,05 bis 0,15 s vor dem gelesenen `getState`.
- Die rote Zeit ist die Belegungszeit des Blocks hinter dem Signal: `Create_Signal_5` 7,0 / 7,4 / 7,2 / 7,2 s, `Create_Signal_34` 19,2 / 19,0 s. `Create_Signal_34` sah den Zug nur in jeder zweiten Runde (Abstand 85 s statt 42,5 s).
- Die Methodenliste des Signals hat sechs Eintraege (`getState`, `cycleSignalType`, `isForcedRed`, `setForcedRed`, `listBlockingTrainNames`, `getSignalType`), der Signaltyp ist `ENTRY_SIGNAL`.
- Folge: Der Zugname im Signal ist belegt, und das Verschwinden des Namens zeigt, dass der Block hinter dem Signal geraeumt ist. **Nicht gemessen:** Abstand zu `train_passed` an einem Beobachter (keiner angeschlossen), Verhalten bei einem Zug, der vor einem erzwungen roten Signal wartet (`--sperre`), mehrere Zuege gleichzeitig, Zuege mit gleichem Namen (M14: Namen sind nicht eindeutig). Bis dahin bleibt der Beobachter am Knoten Pflicht.

## Aus dem Quelltext von CC:Tweaked (nicht im Spiel gemessen)

Quelle: `Config.java`, `ServerMonitor.rebuild`, `MonitorBlockEntity` (Repository cc-tweaked/cc-tweaked). Am echten Monitor mit `probe/crn_probe.lua` gegenpruefen.

| Nr | Wert | Folge fuer die Oberflaeche |
|---|---|---|
| Q01 | Terminal von Computer und Advanced Computer: 51x19 (Vorgabe der Spielkonfiguration, einstellbar von 1 bis 255). Pocket Computer 26x20, Turtle 39x13. | Der PC selbst zeigt immer die kompakte Ansicht (51x19). Pocket und Turtle sind kleiner und zeigen nur die Statusansicht. |
| Q02 | Monitor: Breite = Runden((Bloecke - 0,3125) / (Textgroesse x 6 / 64)), Hoehe = Runden((Bloecke - 0,3125) / (Textgroesse x 9 / 64)). Vorgabe der Textgroesse ist 1,0; das Programm stellt sie nie um. | Textgroesse 0,5: 1x1 = 15x10, 3x3 = 57x38, 5x4 = 100x52, 7x5 = 143x67. Textgroesse 1,0: 1x1 = 7x5, 3x3 = 29x19, 6x3 = 61x19, 7x5 = 71x33, 10x6 = 103x40. |
| Q03 | Das grosse Layout (ab 100x40) braucht bei Textgroesse 0,5 mindestens 5 Bloecke Breite und 4 Hoehe, bei der Vorgabe 1,0 mindestens 10x6. Die kompakte Ansicht (ab 51x19) braucht bei 1,0 mindestens 6x3 (5x3 ergibt 50x19 und damit nur die Statusansicht). | Die bisherige Angabe "mindestens 7x5 Bloecke" war kein Mindestwert; 7x5 bei Textgroesse 1,0 ergibt nur 71x33 (kompakt). |
| Q04 | Eingaben: der PC-Bildschirm liefert Mausklick und Tastatur, ein Monitor nur Beruehrung (`monitor_touch`), keine Tastatur, kein Scrollen. | Text eingeben geht nur am PC; Listen am Monitor brauchen die Blaetter-Tasten auf dem Bildschirm. |

## Offen

- `setSchedule` mit geaendertem Inhalt (andere Ziele) und bei einem Zug ohne Namen. Wird mit `probe/crn_probe3.lua` gemessen (Haltefahrplan, `create:powered`, Abfahrt per Fahrplan); Hintergrund und Annahmen H1 bis H5 in `docs/FREIGABE_PER_FAHRPLAN.md`.
- Monitor-Groessen und Farben, Create_DisplayLink: kein Geraet angeschlossen (die Groessen stehen als Rechnung aus dem Quelltext unter Q02, gemessen ist noch nichts).
- Signal und Beobachter im Vergleich (Spieltest 3.96, `probe/crn_probe4.lua`): Abstand zwischen dem Verschwinden des Zugnamens im Signal und `train_passed` am Ausfahrtsbeobachter, Verhalten bei wartendem Zug vor erzwungen rotem Signal (`--sperre`), mehrere Zuege und gleiche Zugnamen. Davon haengt ab, ob ein Knoten die Raeumung auch ohne Beobachter nachweisen koennte (Teilergebnis: M18).
- Funkreichweite und Nachrichtenverlust zwischen Computern (Ender-Modem).
- Verhalten bei vielen Geraeten am Kabel (hier nur ein Signal, ein Bahnhof, ein Beobachter).
