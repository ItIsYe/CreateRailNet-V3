# Messwerte vom echten Modpack

**Hinweis (Datenformat 4):** Create regelt Signale, Bloecke, Weichen und Kreuzungen vollstaendig; die Software schaltet und liest keine Signale mehr. Die Messwerte zu Signalen (M07 bis M09, M15 zum Teil, M17 bis M19, die Signal-Proben in M21 und M22) bleiben als Beobachtung des Modpacks stehen, sind fuer die Software aber nicht mehr noetig. Gebraucht werden: Bahnhof (M03 bis M06, M10 bis M14, M16, M20 bis M22: Fahrplaene und Freigabe per Abschnittsfahrplan) und Beobachter.

Gemessen mit `probe/crn_probe.lua` und `probe/crn_probe2.lua` (das zweite Messprogramm ist entfernt: es pruefte die Schreibwege von Signalen, die die Software nicht mehr steuert; die Ergebnisse bleiben hier stehen). Umgebung: ComputerCraft 1.120.2, Minecraft 1.21.1, ein Computer mit Funkmodem (`left`), Kabelmodem mit Hub (`right`), Create_Station, Create_Signal und Create_TrainObserver. Das ist die Grundlage fuer die Pruefungen A01 bis A05 des Konzepts 1.1. Was nicht gemessen wurde, steht unten bei "Offen".

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
| M14 | Zugname ist nicht eindeutig: `Unnamed Train` ist der Standardname, zwei Zuege hatten verschiedene Fahrplaene | Zugregister nicht auf den Namen allein stuetzen; eindeutige Namen vor Betriebsfreigabe verlangen. **Umsetzung:** Die Anmeldung weist `Unnamed Train`, einen Namen eines schon registrierten Zuges und einen Namen ab, den im Netz schon ein anderer Zug traegt (er steht an einem Gleis eines Bahnhofs, oder die Leitstelle hat ihn als fremden Zug gesehen); der Zug wird dann nicht umbenannt. Nicht erkennbar sind Zuege, die noch nie an einem Bahnhof des Netzes standen. |
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

Messung mit `crn_probe4` (Messprogramm entfernt, seit Create die Signale allein regelt): 180 s, zwei Signale (`Create_Signal_5`, `Create_Signal_34`), ein Zug "Zug 5" auf einem Rundkurs, **kein Beobachter angeschlossen**, Abfrage alle 0,2 s (die drei Aufrufe je Signal laufen nacheinander).

- Bei jeder Durchfahrt wechselt das Signal auf `RED` und `listBlockingTrainNames()` nennt den Zugnamen; beim Verlassen des Blocks wird es wieder `GREEN` und die Liste ist leer. **6 von 6 Durchfahrten** (4 an `Create_Signal_5`, 2 an `Create_Signal_34`).
- Der Name erscheint 0 bis 0,75 s nach dem Ereignis `train_signal_state_change` (RED) in der Liste und verschwindet gleichzeitig mit dem Ereignis GREEN (0 bis 0,2 s); feiner als der Abfrageabstand ist das nicht aufgeloest. Das Ereignis kommt 0,05 bis 0,15 s vor dem gelesenen `getState`.
- Die rote Zeit ist die Belegungszeit des Blocks hinter dem Signal: `Create_Signal_5` 7,0 / 7,4 / 7,2 / 7,2 s, `Create_Signal_34` 19,2 / 19,0 s. `Create_Signal_34` sah den Zug nur in jeder zweiten Runde (Abstand 85 s statt 42,5 s).
- Die Methodenliste des Signals hat sechs Eintraege (`getState`, `cycleSignalType`, `isForcedRed`, `setForcedRed`, `listBlockingTrainNames`, `getSignalType`), der Signaltyp ist `ENTRY_SIGNAL`.
- Folge: Der Zugname im Signal ist belegt, und das Verschwinden des Namens zeigt, dass der Block hinter dem Signal geraeumt ist. Der Vergleich mit einem Beobachter steht in M19.

## M19 Signal gegen Beobachter (vom Betreiber gemessen, zweiter Lauf von `crn_probe4`, Messprogramm entfernt)

Aufbau: `Create_Signal_34` liegt vor einem Bahnhof (`Create_Station_1`), `Create_TrainObserver_1` am Bahnhofseingang, `Create_Signal_5` hinter dem Bahnhof; zwei Zuege im Wechsel ("Zug 5" und "Unnamed Train"), 180 s, Abfrage alle 0,2 s, keine Sperre. Die Ereignisse des Bahnhofs (`train_imminent`, `train_arrival`, `train_departure`) wurden mitgeschrieben.

- **Name und Raeumung am Signal des Beobachterblocks (`Create_Signal_34`):** Der Zugname steht in `listBlockingTrainNames()`, sobald der Zug in den Block einfaehrt, und verschwindet gleichzeitig mit dem Ereignis GREEN. 5 von 5 Durchfahrten am Beobachter sind durch einen Namenszeitraum des Signals abgedeckt, die Namen werden richtig unterschieden ("Zug 5" und "Unnamed Train" an verschiedenen Bloecken zur gleichen Zeit ebenfalls).
- **Abstand zu `train_passed` am Beobachter (Condition 3):** Der Name verschwindet im Signal **0,45 bis 0,70 s nach** `train_passed` (vier Durchfahrten: 0,45 / 0,70 / 0,55 / 0,70 s; Abfrageabstand 0,2 s). Klein und gleichbleibend, solange der Beobachter am Ende des Blocks liegt.
- **Fruehere Ankuendigung:** Der Name erscheint im Signal 7,35 bis 7,45 s **vor** `train_passing` am Beobachter und 4,4 s vor `train_imminent` des Bahnhofs (drei Durchfahrten voll gemessen). Das Signal kuendigt den Zug also frueher an als der Beobachter.
- **Beobachter selbst:** `train_passing` kommt 0,8 s vor `train_arrival`; `train_passed` kommt erst rund 5,2 s **nach** `train_departure`, weil der ganze Zug am Beobachter vorbei muss.
- **Naechstes Signal (`Create_Signal_5`, anderer Block hinter dem Bahnhof):** ROT genau 2,0 s nach `train_departure`, Name 7,0 bis 7,4 s lang; GRUEN 4,1 bis 4,7 s nach `train_passed`. Das ist ein anderer Block und kein Vergleich zum Beobachter.
- **Verzoegerung des Namens nach dem ROT-Ereignis:** 0 bis 0,15 s, bei Zuegen, die nicht durch den Bahnhof fuhren, 0,60 bis 0,75 s (4 von 12 ROT-Ereignissen). Wer die Liste sofort beim Ereignis liest, kann sie leer finden; einmal nachfragen genuegt.
- **Nicht gemessen:** ein Zug, der vor einem erzwungen roten Signal wartet (steht er in der Liste, oder nur der Zug im Block?), ein echter Knoten mit mehreren Einfahrtssignalen vor demselben Block (zeigen alle den Zug im gemeinsamen Block?), zwei Zuege mit gleichem Namen (M14). Bis dahin bleibt der Beobachter am Knoten Pflicht.

## M20 Kein direkter Rueckweg zum selben Bahnhof (vom Betreiber beobachtet)

- Ein Zug, der an Bahnhof 10 steht, kann in Create nicht direkt wieder zu Bahnhof 10 geschickt werden: er muss erst zu einem anderen Bahnhof (11) und kann von dort wieder nach 10. In einem Fahrplan darf deshalb kein Bahnhof zweimal unmittelbar hintereinander stehen.
- Folge im Programm: `schedule.check` weist einen Fahrplan mit zwei gleichen aufeinanderfolgenden Eintraegen ab (bei einem umlaufenden Fahrplan auch letzter gegen ersten Eintrag); eine Vorlage mit gleichen Halten hintereinander wird nicht angelegt, auch wenn die Rueckfahrt zum Start (`return_to_start`) dasselbe Ziel ergibt (ein einziger Halt mit Rueckfahrt waere A, A); die Zielwahl nimmt nie das Gleis, von dem der Zug kommt (bei einer Bahnhofsgruppe das naechste Mitglied); Abstellen am Bahnhof, an dem der Zug steht, wird abgelehnt. Der erste Eintrag eines Auftragsfahrplans ist der eigene Bahnhof (Aufenthalt bis zur Freigabe), der zweite muss ein anderer sein.
- Nicht gemessen: was Create genau tut (Zug bleibt stehen, ueberspringt den Eintrag oder meldet nichts), und ob ein Haltefahrplan mit dem eigenen Bahnhof als einzigem Eintrag (H2, `docs/FREIGABE_PER_FAHRPLAN.md`) darunter faellt. Fuer den Haltefahrplan ist es geklaert: der Zug bleibt stehen (M21, Probe B).

## M21 Erster Lauf von `crn_alles` (vom Betreiber gemessen, 2026-11-06)

Aufbau: ein Bahnhof "Abstell 11" (`Create_Station_1`) mit Zug "Unnamed Train" (Fahrplan zyklisch: Abstell 11, 5 s; Abstell 10, 5 s), `Create_Signal_34` vor dem Bahnhof, `Create_Signal_5` dahinter, ein Beobachter am Bahnhofseingang, zwei Zuege im Wechsel ("Zug 5", "Unnamed Train").

**Abfahrt ueber die Station (`crn_probe3`, Proben A bis C; Annahmen H1 bis H3 aus `docs/FREIGABE_PER_FAHRPLAN.md`):**
- A: `setSchedule` mit geaendertem Inhalt (Fahrplan plus 1 s Wartezeit): ok, gelesen genau wie geschrieben; die Rueckstellung auf den urspruenglichen Fahrplan war nach jeder Probe "IDENTISCH". H1 bestaetigt.
- B: Haltefahrplan (ein Eintrag am eigenen Bahnhof, 1 s, nicht zyklisch): nach 20 s steht der Zug noch da, `hasSchedule` ist `true`, der Fahrplan bleibt unveraendert lesbar. H2 bestaetigt. Ein Fahrplan, dessen einziger Eintrag der eigene Bahnhof ist, ist also unproblematisch (M20): der Zug bleibt stehen.
- C: `create:powered` ohne Strom wird angenommen, der Zug haelt mindestens 15 s. H3 bestaetigt.
- D (Abfahrt per Fahrplan, H4 und H5): **nicht gemessen**. Das Hauptprogramm hatte den eigenen Bahnhof als Ziel gewaehlt, weil beim Planen noch kein Zug am Bahnhof stand (Fehler, behoben: das Ziel kommt jetzt aus dem Fahrplan des Zuges, hier "Abstell 10").

**Signal bei erzwungenem Rot (`crn_probe4 --sperre`, Messprogramm entfernt, 150 s, `Create_Signal_5` gesperrt):**
- `setForcedRed(true)`: Ereignis nach 0,05 s, `getState` RED nach 0,2 s; die Rueckstellung klappte.
- Der erste Zug, der nach der Sperre vom Bahnhof abfuhr (+53,7 s), blieb vor dem Signal stehen: danach 96 s lang kein Ereignis, kein `train_passed`, `Create_Signal_34` blieb ROT (Block besetzt).
- **Ein wartender Zug steht nicht in `listBlockingTrainNames` des gesperrten Signals:** die Liste blieb von +41,2 s bis zum Ende leer, obwohl der Zug dort wartete. Sie nennt nur Zuege im Block hinter dem Signal. Ob das Signal davor (`Create_Signal_34`, Block des Bahnhofs) den wartenden Zug nennt, ist nicht aufgezeichnet (in S2 war nur das gesperrte Signal gewaehlt; seit dem Fix beobachtet S2 alle Signale).
- Trotz Sperre erschienen zweimal Zugnamen im Signal (+13,4 s bis +20,6 s "Zug 5"; +35,2 s bis +41,2 s "Unnamed Train"); diese Zuege kamen nicht ueber den Bahnhof (kein `train_departure` davor), vermutlich aus der anderen Richtung. Nicht weiter untersucht.

**Signal gegen Beobachter (150 s ohne Sperre, zweiter Beleg zu M19):**
- `Create_Signal_34` (Block des Beobachters): der Name verschwindet 0,6 s ("Zug 5") und 0,8 s ("Unnamed Train") nach `train_passed`; mit M19 sind es sechs von sechs Durchfahrten zwischen 0,45 und 0,8 s. Der Name erscheint 7,25 bis 7,5 s vor `train_passing` am Beobachter.
- `Create_Signal_5` (naechster Block hinter dem Bahnhof): ROT 2,0 s nach `train_departure`, der Name verschwindet 4,1 bis 4,8 s nach `train_passed`. Die Zeilen "38 s VOR train_passed" im Rohbericht sind ein Auswertungsfehler des Messprogramms (erster Namenszeitraum gegen erstes `train_passed`); die Paarung je Durchfahrt ist behoben.

## M22 Zweiter Lauf von `crn_alles` (vom Betreiber gemessen, 2026-11-06, 21:13 UTC)

Gleicher Aufbau wie M21. Rohbericht: `tests/fixtures/crn_alles_lauf2.txt`.

**Abfahrt per Fahrplan (Probe D, Annahmen H4 und H5):**
- Fahrplan mit drei Eintraegen (eigener Bahnhof "Abstell 11" mit 1 s Wartezeit, Ziel "Abstell 10", wieder "Abstell 11") per `setSchedule` an einen Zug, der schon am Bahnhof steht: der Zug faehrt los, `train_departure` kommt **1,2 s** nach `setSchedule`. **H4 bestaetigt, H5 = 1,2 s.** Der erste Eintrag am eigenen Bahnhof ist unproblematisch, solange der zweite ein anderer Bahnhof ist (M20).
- `canTrainReach("Abstell 10")` war `true`, `distanceTo` 661,4.
- Die gemeldete "Rueckkehr nach 21,0 s" ist **nicht belastbar**: es war die Ankunft eines anderen Zuges ("Zug 5"), der Pruefzug war noch unterwegs. Das Messprogramm zaehlte jede Ankunft am Bahnhof; seit dem Fix zaehlen nur Ereignisse des Pruefzuges, andere Zuege werden gemeldet und ignoriert.

**Signal bei erzwungenem Rot, jetzt mit beiden Signalen beobachtet (S2, 150 s, `Create_Signal_5` gesperrt):**
- **Das Signal davor (`Create_Signal_34`, Block mit Bahnhof und Beobachter) nennt den wartenden Zug durchgehend:** "Zug 5" stand von +0,0 s bis zum Ende der Messung in der Liste und das Signal blieb ROT. Der Zug fuhr bei +11,45 s vom Bahnhof ab, blieb vor dem gesperrten Signal stehen und wartete rund 138 s; kein weiteres Ereignis, kein `train_passed`.
- Das gesperrte Signal selbst nannte ihn nicht (Liste leer, ausser +33,4 s bis +39,4 s "Unnamed Train": ein Zug, der den Block hinter dem Signal ohne Bahnhof durchfuhr, vermutlich aus der anderen Richtung).
- Folge: Die Liste eines Signals nennt die Zuege im Block **hinter** ihm, ein wartender Zug steht in der Liste des Signals davor (also des Signals, das den Block bewacht, in dem er wartet).

**Signal gegen Beobachter (S1, 150 s ohne Sperre, dritter Beleg zu M19 und M21):**
- `Create_Signal_34` (Block des Beobachters): der Name verschwindet 0,8 / 0,8 s ("Unnamed Train") und 0,6 s ("Zug 5") nach `train_passed`; mit M19 und M21 sind es neun von neun Durchfahrten zwischen 0,45 und 0,8 s. Er erscheint 7,2 bis 7,5 s vor `train_passing`.
- `Create_Signal_5` (Block hinter dem Bahnhof): 4,8 / 4,8 / 4,1 s nach `train_passed`.

**Folgen:**
- Freigabe ueber den Fahrplan (`docs/FREIGABE_PER_FAHRPLAN.md`): H1 bis H5 sind im Spiel bestaetigt. Die Abfahrt kommt rund 1,2 s nach dem Setzen, wenn der erste Eintrag am eigenen Bahnhof nur eine kurze Wartezeit hat.
- Knoten: Fuer die **Raeumung** reicht das Verschwinden des Namens im Einfahrtssignal (neun von neun, 0,45 bis 0,8 s nach `train_passed`), sofern der Bereich hinter dem Signal der Kreuzungsblock ist; das ist an einem echten Knoten noch zu pruefen. Fuer die **Ankuendigung** nennt das Einfahrtssignal wartende Zuege nicht; sie kommt vom Beobachter an der Einfahrt oder vom Signal davor.

## Aus dem Quelltext von CC:Tweaked (nicht im Spiel gemessen)

Quelle: `Config.java`, `ServerMonitor.rebuild`, `MonitorBlockEntity` (Repository cc-tweaked/cc-tweaked). Am echten Monitor mit `probe/crn_probe.lua` gegenpruefen.

| Nr | Wert | Folge fuer die Oberflaeche |
|---|---|---|
| Q01 | Terminal von Computer und Advanced Computer: 51x19 (Vorgabe der Spielkonfiguration, einstellbar von 1 bis 255). Pocket Computer 26x20, Turtle 39x13. | Der PC selbst zeigt immer die kompakte Ansicht (51x19). Pocket und Turtle sind kleiner und zeigen nur die Statusansicht. |
| Q02 | Monitor: Breite = Runden((Bloecke - 0,3125) / (Textgroesse x 6 / 64)), Hoehe = Runden((Bloecke - 0,3125) / (Textgroesse x 9 / 64)). Vorgabe der Textgroesse ist 1,0; das Programm stellt sie nie um. | Textgroesse 0,5: 1x1 = 15x10, 3x3 = 57x38, 5x4 = 100x52, 7x5 = 143x67. Textgroesse 1,0: 1x1 = 7x5, 3x3 = 29x19, 6x3 = 61x19, 7x5 = 71x33, 10x6 = 103x40. |
| Q03 | Das grosse Layout (ab 100x40) braucht bei Textgroesse 0,5 mindestens 5 Bloecke Breite und 4 Hoehe, bei der Vorgabe 1,0 mindestens 10x6. Die kompakte Ansicht (ab 51x19) braucht bei 1,0 mindestens 6x3 (5x3 ergibt 50x19 und damit nur die Statusansicht). | Die bisherige Angabe "mindestens 7x5 Bloecke" war kein Mindestwert; 7x5 bei Textgroesse 1,0 ergibt nur 71x33 (kompakt). |
| Q04 | Eingaben: der PC-Bildschirm liefert Mausklick und Tastatur, ein Monitor nur Beruehrung (`monitor_touch`), keine Tastatur, kein Scrollen. | Text eingeben geht nur am PC; Listen am Monitor brauchen die Blaetter-Tasten auf dem Bildschirm. |

## Offen

- `setSchedule` bei einem Zug ohne Namen. (Mit geaendertem Inhalt ist es bestaetigt, H1 bis H5; die Freigabe per Abschnittsfahrplan ist umgesetzt, `docs/FREIGABE_PER_FAHRPLAN.md`.)
- Mengenbedingung (`create:item_threshold`) im ersten Eintrag eines Abschnittsfahrplans bei einem stehenden Zug, und die Restwartezeit: Spieltest 4.9 bis 4.11 in `docs/GROSSER_TEST.md`.
- Monitor-Groessen und Farben, Create_DisplayLink: kein Geraet angeschlossen (die Groessen stehen als Rechnung aus dem Quelltext unter Q02, gemessen ist noch nichts).
- Alle Messungen zur Abfahrt am Bahnhof laufen mit `probe/crn_alles.lua` in einem Lauf (Spieltest 3.97). Die Rueckkehr des Pruefzuges in Probe D ist mit dem behobenen Messprogramm noch nicht belegt (fuer die Freigabe nicht noetig).
- ~~Signal statt Beobachter am Knoten~~ (Spieltest 3.96): entfaellt, weil Create Signale und Kreuzungen allein regelt und die Software keinen Knoten mehr steuert. Gleiche Zugnamen (M14) weist die Anmeldung ab (Spieltest 4.20).
- Funkreichweite und Nachrichtenverlust zwischen Computern (Ender-Modem).
- Verhalten bei vielen Geraeten am Kabel (hier nur ein Signal, ein Bahnhof, ein Beobachter).
