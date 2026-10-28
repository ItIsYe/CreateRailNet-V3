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

## Offen

- `setSchedule` mit geaendertem Inhalt (andere Ziele) und bei einem Zug ohne Namen.
- Monitor-Groessen und Farben, Create_DisplayLink: kein Geraet angeschlossen.
- Funkreichweite und Nachrichtenverlust zwischen Computern (Ender-Modem).
- Verhalten bei vielen Geraeten am Kabel (hier nur ein Signal, ein Bahnhof, ein Beobachter).
