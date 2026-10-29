# Grosser Test

Der Test findet statt, wenn alle Stufen gebaut sind (Plan: `docs/STUFENPLAN.md`). Jede Stufe traegt hier ihre Schritte ein; du fuehrst sie im Spiel aus und schreibst das Ergebnis in die letzte Spalte. Gebaut ist jeweils nur, was auch ausserhalb des Spiels getestet ist; ob es im Spiel funktioniert, zeigt erst dieser Test.

Installation fuer den ganzen Test: `wget https://raw.githubusercontent.com/ItIsYe/CreateRailNet-V3/<ZWEIG>/installer.lua installer.lua`, dann `installer` (Dialog). `<ZWEIG>` steht am Ende in der Pull-Request-Beschreibung.

## Stufe 1: Kern (Uhr, Speichern, Journal, Funk)

Zwei Computer mit Funkmodem (Ender-Modem) an beliebiger Rolle, die Rolle spielt hier keine Rolle.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 1.1 | Computer A: `crn/app/main selftest` | Alle Zeilen "ok", am Ende "Alle lokalen Pruefungen bestanden."; `Uhr laeuft in Spielzeit` zeigt etwa 3,5 s | |
| 1.2 | Computer B: `crn/app/main selftest listen zentrale-1` | "Antwortet als 'zentrale-1' ..." und die Funkmodem-Zeile | |
| 1.3 | Computer A: `crn/app/main selftest ping bahnhof-1 zentrale-1` | "5 von 5 Antworten", Laufzeit in Spielsekunden je Ping; B zeigt fuenf "Ping von bahnhof-1" | |
| 1.4 | Computer B mit Strg+T beenden, A erneut pingen | "keine Antwort" fuenfmal, "0 von 5 Antworten" | |
| 1.5 | Computer A waehrend `selftest` (beim Warten) ausschalten und neu starten, dann `crn/app/main selftest` | Test laeuft wieder sauber durch (keine Reste aus dem Abbruch) | |
| 1.6 | `ls /crn_data` | Kein Rest von `selftest` | |

## Stufe 2: Geraete (Bahnhof, Signal, Beobachter)

Ein Computer mit Create-Geraeten am Kabelmodem (mindestens ein Bahnhof, ein Signal und ein Beobachter, wie bei dir). Waehrend der Pruefung duerfen Zuege fahren.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 2.1 | `crn/app/main selftest geraete` | Liste aller Geraete mit Typen; fuer jeden Bahnhof, jedes Signal und jeden Beobachter "ok" bei Methoden und "lesbar"; am Ende "Alle Geraetepruefungen bestanden." Ein Bahnhof ohne Zug zeigt "kein Zug", nicht "FEHLER" | |
| 2.2 | Zug am Bahnhof halten lassen, dann `crn/app/main selftest geraete` | Bei diesem Bahnhof steht "Zug <Name>" | |
| 2.3 | `crn/app/main selftest geraete schreiben` mit einem Signal ohne Zug im Abschnitt | "Sperre setzen und zuruecklesen" und "Sperre aufheben und zuruecklesen" je "ok"; danach ist das Signal wie vorher (Sichtpruefung) | |
| 2.4 | Dasselbe, waehrend ein Zug vor dem Signal wartet (Signal rot) | Beide Zeilen "ok"; nach dem Aufheben bleibt das Signal rot, solange der Zug den Abschnitt belegt (nur die zusaetzliche Sperre ist weg) | |
| 2.5 | Ein Signal vom Kabelmodem trennen, `selftest geraete` | Es fehlt in der Liste; kein Absturz des Programms | |

## Stufe 3: Oberflaeche und Assistent

Ein Computer ohne Einrichtung (alte `/crn_data` mit `delete /crn_data` entfernen), Advanced Computer, Funkmodem; moeglichst ein Monitor am Kabelmodem (Advanced Monitor, mindestens 7x5 Bloecke fuer das grosse Layout bei Textgroesse 0,5; kleinere zeigen die kompakte Ansicht). Start mit `crn/app/main` (oder Neustart).

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 3.1 | Start ohne Einrichtung | Seite "Einrichtung", Betriebszustand "Einrichtung", Kopfzeile "CRN - noch nicht eingerichtet" | |
| 3.2 | Assistent: Schritt 1 ohne Netzname auf "Weiter" | Hinweis "Der Netzname fehlt."; mit Namen geht es weiter | |
| 3.3 | Schritt 2: ohne Rolle auf "Weiter"; dann Rolle Leitstelle waehlen oder (Netz beitreten) Passagierbahnhof | Hinweis; danach Eingabe des Namens (nur Buchstaben, Ziffern, Leerzeichen, - und _) | |
| 3.4 | Schritt 3 (Geraete) | Alle Create-Geraete mit Typ; Funk- und Kabelmodem getrennt genannt (z.B. "Funk: left   Kabel: right"); Antippen setzt "[x]" | |
| 3.5 | Schritt 4 (Gleise): Gleis anlegen, Bahnhof, Signal, Beobachter und Ausgang zuordnen, "Kopieren" | Ein Geraet laesst sich nur einem Gleis geben, ein Ausgang nur einmal; die Kopie hat keine Geraete | |
| 3.6 | Schritt 5 (Test): "Alle lesenden", dann ein schaltender Test | Vor dem Schalten erscheint ein Bildschirm mit Geraet und Wirkung; nach "Vorbereitung erledigt: starten" "ok"; Signal/Ausgang sind danach wie vorher | |
| 3.7 | Schritt 6, "Speichern und aktivieren" | Zustand "Bereit"; nach einem Neustart (`reboot`) startet der Node mit derselben Einrichtung | |
| 3.8 | Schritt 6 ohne alle Pruefungen | Knopf heisst "Als Entwurf speichern", Zustand "Entwurf", Hinweis in den Meldungen | |
| 3.9 | Monitor: berühren der Reiter, Einrichtung dort bedienen, waehrend der Terminal eine andere Seite zeigt | Jede Ansicht hat ihre eigene Seite; bearbeitet die eine die Einrichtung, zeigt die andere "Einrichtung wird bearbeitet." | |
| 3.10 | Monitor verkleinern/vergroessern (Skalierung ueber `monitor.setTextScale` von Hand) oder anderen Monitor nehmen | Layout wechselt zwischen gross (ab 100x40), kompakt (ab 51x19) und Statusansicht; Eingaben bleiben | |
| 3.11 | Ein Create-Geraet im Betrieb abziehen und anschliessen | Meldungen "Geraet entfernt" und "Geraet angeschlossen" | |
| 3.12 | Seite "Geraete" und "Meldungen", Meldung quittieren | Quittiert aendert nur die Meldung | |

## Stufe 4: Erster Bahnhof (Zugregister, Fahrtauftrag, Freigabe)

Aufbau (drei Computer, alle mit Funkmodem, alle mit `installer` auf die gleiche Version gebracht und eingerichtet wie in Stufe 3):

- **Leitstelle** `hauptstelle`, Rolle "Leitstelle" (zentrale). Kein Create-Geraet noetig.
- **Weizenhof** `weizenhof`, Rollen "Gueterbahnhof" und "Anmeldung". Ein Gleis mit dem Create-Bahnhof "Weizenhof"; als Freigabeausgang eine Redstone-Seite (oder Relay), die **hinter** dem Bahnhof ein Redstone-Signal auf die Bahnhofsbedingung gibt. Im Assistenten (Schritt 3 "Geraete") diesen Bahnhof auch als Anmeldestation waehlen. Der Create-Fahrplan jedes Zuges, den du dort laufen laesst, endet pro Aufenthalt mit "Redstone-Signal an" (das setzt die Software selbst).
- **Zentrallager** `lager`, Rolle "Gueterbahnhof", ein Gleis mit dem Create-Bahnhof "Zentrallager", ebenfalls mit Freigabeausgang.
- Ein Zug, der noch **"Unnamed Train"** heisst, steht am Weizenhof. Zwischen beiden Bahnhoefen liegt Gleis, auf dem der Zug fahren kann.
- Uhrzeit-/Wartezeiten sind Betriebszeit (E1); alle Zeitangaben unten in Spielsekunden.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 4.1 | Alle drei Computer starten (`crn/app/main`) | Nach spaetestens 30 s zeigt die Leitstelle auf "Netz" beide Bahnhoefe als erreichbar mit je einem Gleis und dem Bahnhofsnamen | |
| 4.2 | Weizenhof, Seite "Gleise" | Gleis, Bahnhofsname, "Zug: Unnamed Train", Ausgang "aus" | |
| 4.3 | **Vor der Anmeldung**, Zug heisst noch "Unnamed Train": in Create am stehenden Zug einen Fahrplan mit einer Mengenbedingung anlegen (Ziel Weizenhof, Bedingung "Gegenstaende ... Weizen ... Menge 7"; die Zahl 7 nur dort verwenden). Leitstelle, Seite "Vorlagen", "Muster": Bahnhof `Weizenhof`, Zahl `7`, "Fahrplan lesen" | "Muster gespeichert (Feld data.threshold)". Bei einer Zahl, die mehrfach vorkommt (z.B. 0), kommt "kommt mehrfach vor"; ohne Mengenbedingung "keine Mengenbedingung" | |
| 4.4 | Weizenhof, Seite "Anmeldung", "Zug anmelden": Kennung `GZ-001`, Create-Zugname `GZ-001`, Anzeigename frei, Laenge, Fracht, Bedarfsbetrieb, "Anmelden" | "Angemeldet: GZ-001". Der Zug heisst in Create jetzt `GZ-001` und steht mit einem Warteauftrag (zyklisch, Ziel "Weizenhof", der Probefahrplan aus 4.3 ist ersetzt) am Gleis. Leitstelle, Seite "Zuege": GZ-001 "gesteuert", am Bahnhof Weizenhof | |
| 4.5 | Dieselbe Anmeldung mit dem Namen "Unnamed Train" mit einem anderen Zug versuchen | "Abgelehnt: Der Standardname ..." | |
| 4.6 | Leitstelle, "Vorlagen", "Neue Vorlage": Kennung `weizen`, Titel `Weizen liefern`, Zug `GZ-001`, Halte `Weizenhof:5:640; Zentrallager:3`, "Speichern" | Vorlage steht in der Liste | |
| 4.7 | Weizenhof, Seite "Fahrten" (nach spaetestens 10 s) | Taste "Weizen liefern", Zustand "bereit" | |
| 4.8 | Taste druecken (genau einmal) | Auftrag laeuft: "angefordert" -> "wird geprueft" -> "Fahrplan uebergeben" -> "Abfahrt freigegeben (noch nicht bestaetigt)". In Create hat der Zug jetzt den Auftragsfahrplan (Weizenhof mit Delay, Menge, Redstone; Zentrallager; Weizenhof). Der Freigabeausgang am Weizenhof ist **an** | |
| 4.9 | Die Menge im Zug (Weizen) unter 640 lassen und 40 s warten | Der Zug faehrt **nicht**; Auftrag bleibt "Abfahrt freigegeben (noch nicht bestaetigt)" (Create prueft die Menge vor dem Redstone-Signal) | |
| 4.10 | 640 oder mehr Weizen in den Zug laden | Abfahrt; Auftrag "unterwegs"; der Ausgang am Weizenhof geht **aus** | |
| 4.11 | Ankunft Zentrallager | Auftrag "am Ziel", Freigabe am Zentrallager (nach 3 s Mindestaufenthalt), Ausgang dort an, nach Abfahrt aus | |
| 4.12 | Rueckkehr zum Weizenhof | Auftrag "abgeschlossen"; Zug wartet wieder mit dem Warteauftrag; beide Ausgaenge aus | |
| 4.13 | Taste zweimal kurz hintereinander druecken, waehrend kein Auftrag laeuft | Genau ein Auftrag; die zweite Rueckmeldung zeigt "Auftrag A-n laeuft" | |
| 4.14 | Nach 4.8 (vor der Abfahrt) die Leitstelle neu starten (`reboot`) | Nach dem Start: derselbe Auftrag, Zustand bleibt; kein neuer Auftrag, kein erneutes Freigeben (Ausgang bleibt an); die Fahrt wird zu Ende gefuehrt | |
| 4.15 | Nach 4.8 den Computer Weizenhof neu starten | Ausgang bleibt an, danach wird die Abfahrt normal gemeldet | |
| 4.16 | Nach 4.8 den Zug von Hand abfahren lassen (Create-Eingriff), bevor die Menge erreicht ist, oder die Menge vorab erreichen und das Signal selbst setzen | Leitstelle: Auftrag "KLAERUNG erforderlich" mit Grund; es wird nichts als Erfolg gewertet | |
| 4.17 | Am Weizenhof den Freigabeausgang von Hand einschalten (Redstone) und Taste druecken | Auftrag "wartet": "Der Freigabeausgang am Start ist eingeschaltet." Nach dem Ausschalten laeuft er nach spaetestens 30 s weiter | |
| 4.18 | Funkmodem der Leitstelle waehrend 4.8 fuer 20 s entfernen und wieder anschliessen | Die Fahrt laeuft nach dem Wiederanschluss weiter; hoechstens ein Auftrag, keine doppelte Freigabe | |
| 4.19 | Seite "Gleise" am Weizenhof, "Ausgang aus" (zweimal tippen) | Nur nach Bestaetigung wird der Ausgang ausgeschaltet; Hinweis, dass ein Zug dann ohne Freigabe stehen bleibt | |
| 4.20 | Messprogramm `crn_probe` oder Create-Fahrplananzeige: bei 4.4 und 4.8 den Zugfahrplan ansehen | Pro Eintrag eine Bedingungsgruppe, die letzte Bedingung ist "Redstone-Signal an"; keine Alternative, die die Freigabe umgeht | |

Hinweis fuer den Test: Bei 4.9/4.10 hatte die Messung (M12) bisher nur die Zeit-Bedingung gezeigt; ob `create:powered` mit leerem Datenfeld in Create akzeptiert wird und ob Mengenbedingung + Redstone in einer Gruppe in dieser Reihenfolge arbeiten, ist genau das, was dieser Test klaeren soll. Bitte bei Abweichung den Fahrplan (4.20) und die Meldungen der Leitstelle schicken.

## Stufe 5: Zweiter Bahnhof, mehrere Gleise, Linien und Takt, Tafel

Aufbau: wie Stufe 4, dazu ein **Personen-/Hauptbahnhof mit drei Haltegleisen** (`hbf`, Rolle "Passagierbahnhof"; drei Create-Bahnhoefe "Hbf Gleis 1" bis "Hbf Gleis 3", jedes Gleis mit eigenem Freigabeausgang und - falls bekannt - der Gleislaenge in Wagen im Assistenten). Beide Zuege (`GZ-001`, ein zweiter angemeldeter Zug) stehen auf Gleisen des Hauptbahnhofs. Das Gleisnetz verbindet alle Gleise mit dem Zentrallager. Fuer die Anmeldung weiterer Zuege am Hauptbahnhof muss dort eine Anmeldestation gewaehlt sein (Rolle "Anmeldung").

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 5.1 | Leitstelle, Seite "Bahnhoefe", "Neu": Name `Hauptbahnhof`, Gleise `Hbf Gleis 1; Hbf Gleis 2; Hbf Gleis 3` (das bevorzugte zuerst), "Speichern" | Der Bahnhof steht in der Liste mit den drei Gleisen. Ein Gleis in zwei Bahnhoefen wird abgelehnt ("gehoert schon zum Bahnhof ...") | |
| 5.2 | Seite "Vorlagen", "Neu": Kennung `pendel`, Zug `GZ-001`, Halte `Hauptbahnhof:0; Zentrallager:20`, "Speichern" | Vorlage steht in der Liste (Bahnhofsgruppen und einzelne Bahnhoefe sind als Halte erlaubt) | |
| 5.3 | "Anfordern" mit dem Zug auf **Gleis 2** | Im Fahrplan des Zuges steht Start "Hbf Gleis 2", Ziel "Zentrallager", danach das **bevorzugte freie Gleis** des Hauptbahnhofs (Gleis 1). Die Fahrt laeuft bis "abgeschlossen"; der Zug wartet danach auf Gleis 1 mit dem Warteauftrag | |
| 5.4 | Dasselbe, waehrend ein anderer Zug auf Gleis 1 steht | Rueckfahrt zu Gleis 2 (oder 3), nie auf das belegte Gleis; im Auftrag steht kein Fehler | |
| 5.5 | Seite "Bahnhoefe", Eintrag waehlen, "Sperre" (sperrt das erste Gleis) und eine Fahrt anfordern | Das gesperrte Gleis wird nicht zugewiesen; "Sperre" nochmal hebt die Sperre auf. Ein Zug, der schon auf dem gesperrten Gleis steht, bleibt unberuehrt | |
| 5.6 | Bei der Laenge: ein Gleis kuerzer als der Zug (im Assistenten Gleislaenge eintragen) | Dieses Gleis wird als Ziel uebersprungen ("zu kurz") | |
| 5.7 | Alle Gleise des Hauptbahnhofs belegen oder sperren und eine Fahrt anfordern | Auftrag "wartet" mit Begruendung je Gleis; sobald eins frei ist, geht es von selbst weiter (spaetestens nach 10 s) | |
| 5.8 | Zwei Zuege mit je einer Vorlage zum selben Zielbahnhof anfordern (gleiche Sekunde) | Beide Fahrten kommen zustande; der zweite Zug wartet, bis das Ziel frei ist ("dem Auftrag A-n zugewiesen"), danach faehrt er | |
| 5.9 | Vorlage waehlen, "Prio" (bevorzugt) und zwei Fahrten konkurrieren | Die bevorzugte bekommt das Zielgleis zuerst; ein normaler Auftrag, der schon laenger als 2 Minuten wartet, wird nicht dauernd verdraengt | |
| 5.10 | Seite "Linien", "Neu": Kennung `pendel`, Titel `Pendel`, Vorlage `pendel`, Zuege `GZ-001; GZ-002`, Takt `120`, "Speichern" | Erster Termin nach 120 s; die Liste zeigt "naechster Termin in ... s" | |
| 5.11 | 10 Minuten laufen lassen | Jeder Termin erzeugt genau einen Auftrag (Seite "Auftraege": Quelle Linie); die beiden Zuege wechseln sich ab; ist kein Zug bereit, steht "Termin ausgelassen: kein Zug bereit am Start" und der Zaehler "ausgelassen" steigt, ohne dass Fahrten nachgeholt werden | |
| 5.12 | "Ein/Aus" bei der Linie | Ausgeschaltet entstehen keine neuen Termine; laufende Fahrten bleiben | |
| 5.13 | Leitstelle waehrend einer Linienfahrt neu starten | Die Fahrt laeuft weiter; nach dem Start kommt kein Schwall an Terminen, sondern hoechstens einer, falls einer faellig war | |
| 5.14 | Seite "Tafel" auf der Leitstelle und auf den Bahnhofs-Nodes | Zwei getrennte Zeilen je Linie: **Plan** (naechster Termin in ... s) und **Ist** (Zug, Zustand, Halt k/n) | |
| 5.15 | Zug bei einer Linienfahrt auf ein anderes Gleis des Ziels umleiten (Create-Eingriff) | Ankunft "an unerwarteter Station" -> Auftrag "KLAERUNG erforderlich", kein stiller Erfolg | |

Zu 5.x: Die Fahrzeit der Linien wird in dieser Stufe nicht geschaetzt; die Tafel zeigt deshalb nur den Plan-Termin der Abfahrt und den gemeldeten Ist-Stand, keine geschaetzte Ankunftszeit.

## Stufe 6: Signal-Node und Knotenpunkt

**Wichtig vorab (Platz):** Eine installierte Version belegt je nach Rolle 215 bis 360 KB (Leitstelle am meisten; jede Rolle bekommt nur ihre Module). Eine Aktualisierung braucht Platz fuer die neue Version neben der alten (und der Vorversion); auf der Leitstelle reicht der Platz fuer drei Kopien nicht. Reicht der Platz nicht, sagt der Installer "Zu wenig Platz" und bietet im Dialog "Vorversion loeschen und Platz schaffen" an (oder `installer --drop-prev ROLLE`). Das ist beabsichtigt; danach ist die Rueckkehr zur Vorversion nicht mehr moeglich.

Aufbau A (Signal-Node): ein Computer mit Rolle "Signal und Strecke", Kabelmodem mit mindestens zwei Signalen (eines davon an einer Stelle, an der ein Zug waehrend des Tests rot bekommen kann) und einem Beobachter; im Assistenten Schritt 4 jedem Gleis seine Signale und Beobachter zuordnen. Aufbau B (Knoten): ein Computer mit Rolle "Knotenpunkt" an einer T-Kreuzung; im Assistenten zuerst die Anschluesse (West, Ost, Sued), die Verbindungen (z.B. West->Ost, Sued->Ost, Ost->West) und die Konflikte eintragen, dann je Anschluss ein **Einfahrtsgleis** (Signal vor der Kreuzung + Beobachter an der Haltestelle vor dem Signal) und ein **Ausfahrtsgleis** (Beobachter hinter der Kreuzung, so dass er erst "train_passed" meldet, wenn das ganze Zug-Ende vorbei ist).

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 6.1 | Signal-Node starten, Seite "Signale" und auf der Leitstelle Seite "Signale" | Alle Signale mit nativem Zustand (ROT/GRUEN) und "keine zusaetzliche Sperre" | |
| 6.2 | Auf dem Signal-Node ein Signal waehlen, "Sperre" | Signal wird rot (Sichtpruefung am Signal); Seite zeigt "gesperrt, Sperre von bediener"; die Leitstelle zeigt es nach spaetestens 5 s | |
| 6.3 | **A09**: Dasselbe, waehrend ein Zug vor dem Signal wartet (Signal ist schon rot), danach "Aufheben" (zweimal tippen) | Nach dem Aufheben bleibt das Signal rot, solange der Zug den Abschnitt belegt (native Rotursache); nur die zusaetzliche Sperre ist weg. Bitte genau notieren, wann es gruen wird | |
| 6.4 | Leitstelle, Seite "Signale": "Sperre" und "Aufheben" | Wirkt wie 6.2, die Rueckmeldung "Sperre gesetzt." erscheint erst, wenn das Signal die Sperre zurueckgemeldet hat | |
| 6.5 | Eine Sperre setzen, dann das Signal ueber Redstone/anderes von Hand sperren und die Software-Sperre aufheben | "Sperre von ..." ist weg, das Signal bleibt gesperrt und zeigt **FREMDE SPERRE**; die Software hebt sie nicht auf. "Aufheben" (zweimal tippen) hebt sie auf Wunsch auf | |
| 6.6 | Signal-Node neu starten (`reboot`) mit gesetzter Sperre | Die Sperre bleibt stehen (kein Freigeben beim Start); Seite zeigt weiter den Besitzer | |
| 6.7 | **A10** (Messwert M17: Modem am Signal weg = Ausgangszustand, Computer egal): Modem direkt am Signal abziehen und wieder anstecken | Signal erscheint auf Node und Leitstelle als "nicht verfuegbar" (Stoerung); nach dem Anstecken wird die eigene Sperre selbststaendig neu gesetzt (spaetestens nach ca. 10 s); bei einem Knoten ist die Einfahrt waehrend des Ausfalls nicht gesperrt und wird angezeigt | |
| 6.8 | Signal im Spiel auf "INVALID" bringen (z.B. Block entfernen, falls moeglich) | Meldung "meldet INVALID" auf Node und Leitstelle, Signal als "GESTOERT" | |
| 6.9 | Knoten starten | Alle Einfahrtssignale sind sofort zusaetzlich gesperrt (rot); Seite "Knoten": "Der Knoten ist frei (nachgewiesen)." | |
| 6.10 | **A11**: Einen langen Zug aus West in Richtung Ost fahren lassen, ein zweiter Zug wartet an Sued | Der erste bekommt gruen (Signal West wird frei), nach dem Einfahren sofort wieder rot; Sued bleibt rot, bis der **ganze** erste Zug am Ost-Beobachter vorbei ist (auch wenn die Spitze schon laengst heraus ist). Dann wird Sued gruen | |
| 6.11 | Zwei Zuege in unabhaengigen Richtungen (kein Konflikt eingetragen, getrennte Ausgaenge) | Beide bekommen gleichzeitig gruen | |
| 6.12 | Beobachter-Ereignis fehlt (Beobachter kurz abziehen, waehrend ein Zug ausfaehrt) | Der Bereich bleibt belegt ("LANGE BELEGT" nach 5 Minuten), nichts wird allein wegen Zeit freigegeben. Seite "Knoten": die Nutzung waehlen, "Pruefen+frei" zweimal tippen, nachdem du den Bereich geprueft hast: der naechste Zug wird freigegeben, die Entscheidung steht im Protokoll | |
| 6.13 | Knoten neu starten, waehrend ein Zug im Bereich ist | Einfahrten bleiben rot, der wartende Zug wird nicht leichtfertig freigegeben; nach dem Raeumungsnachweis geht es weiter | |
| 6.14 | Ein Zug faehrt trotz Rot ueber den Einfahrtsbeobachter (z.B. Signal war defekt) | Meldung "eingefahren, ohne dass die Einfahrt freigegeben war"; andere Einfahrten bleiben gesperrt, bis er heraus ist | |
| 6.15 | Seite "Netz"/Leitstelle: Knotennutzung | Die Leitstelle kennt die Nutzungen des Knotens (Meldung alle 5 s) | |

Hinweis zu 6.10: Die Reihenfolge wartender Zuege am Knoten ist die der Ankuendigung (wer zuerst am Einfahrtsbeobachter erscheint). Prioritaeten der Leitstelle wirken hier noch nicht.

## Stufe 7: Depot und manuelle Zuege

Aufbau: wie Stufe 4 und zusaetzlich ein **Depot** (`depot1`, Rolle "Depot und Uebergabe", ein Gleis mit Create-Bahnhof "Depot Gleis 1" und Freigabeausgang). Der Zug `GZ-001` ist angemeldet und steht am Weizenhof. Die Leitstelle hat die Seiten "Depot" und "Fremde".

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 7.1 | Leitstelle, Seite "Depot": `GZ-001` waehlen, "Abstellen", Station `Depot Gleis 1`, "Abstellen" | Normale Fahrt (Seite "Auftraege": "Abstellen GZ-001"), Zug faehrt ohne Rueckfahrt ins Depot und wartet dort. Danach "abgestellt" in der Liste, Ausgaenge aus | |
| 7.2 | Leitstelle neu starten (`reboot`) | `GZ-001` bleibt "abgestellt"; es entsteht kein Auftrag. Bedarfstaste fuer diesen Zug: "nicht im gesteuerten Betrieb" | |
| 7.3 | Eine Linie, die `GZ-001` einsetzt, mehrere Termine lang laufen lassen | Der abgestellte Zug wird nicht gestartet ("kein Zug bereit am Start") | |
| 7.4 | Seite "Depot": `GZ-001` waehlen, "Aktivieren" | "Zug GZ-001 ist aktiv (gesteuert)." Zug ist wieder fuer Auftraege verfuegbar | |
| 7.5 | Vor 7.4 am Depotgleis den Zug umbenennen oder einen anderen Fahrplan setzen, dann "Aktivieren" | Abgelehnt mit Grund (anderer Zugname bzw. Fahrplan entspricht nicht dem Warteauftrag); der Zug bleibt abgestellt | |
| 7.6 | Waehrend ein Auftrag laeuft: "Ausschleusen" und "Abstellen" | Nicht moeglich ("laufender Auftrag") | |
| 7.7 | Zug steht am Bahnhof ohne Auftrag: "Ausschleusen" (zweimal tippen) | Zustand "ausgeschleust", Betriebsart manuell; Hinweis, dass der Create-Fahrplan im Zug bleibt. Bedarfstaste/Linie fassen den Zug nicht mehr an | |
| 7.8 | Ausgeschleusten Zug von Hand fahren lassen und an einem Bahnhof halten | Seite "Depot"/"Zuege": Position folgt den Meldungen (zuerst "unbekannt" unterwegs, dann der Bahnhof) | |
| 7.9 | "Aufnehmen" (zweimal tippen), Zug steht am Bahnhof, von Hand mit anderem Fahrplan | Der vereinbarte Warteauftrag ersetzt den alten Fahrplan (Uebergabe ist bestaetigt); Zustand "gesteuert", Betriebsart "bedarf" | |
| 7.10 | "Aufnehmen", obwohl der Zug nicht mehr am Gleis steht | Abgelehnt: "nicht nachgewiesen" | |
| 7.11 | "Art" (Betriebsart) am Haltepunkt: bedarf -> linie -> manuell -> bedarf | Wechselt nur am Haltepunkt und nicht waehrend eines Auftrags | |
| 7.12 | Fremden Zug (nicht registriert) in den Bahnhof fahren | Meldung "Unerwarteter Zug ..."; Seite "Fremde" zeigt ihn mit Ort; er wird keinem Auftrag zugeordnet; Zielwahl meidet das Gleis ("belegt von ...") | |
| 7.13 | Fremden Zug wegfahren lassen, dann auf "Fremde" "Vergessen" | Erst danach moeglich; Belegungen anderer Nachweise bleiben unveraendert | |

## Stufe 8: Stoerung, Wiederanlauf, Ersatzcomputer, Update

Aufbau: wie Stufe 4/5; zusaetzlich ein freier Computer (Funkmodem, wenn moeglich gleiche Create-Geraete angeschlossen wie am zu ersetzenden Bahnhof) fuer den Ersatz.

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 8.1 | Leitstelle, Seite "Stoerungen" ohne Stoerung | "Keine Stoerung bekannt." Unten die Zahl offener Auftraege | |
| 8.2 | **A15**: Fahrt starten, in "Abfahrt freigegeben" die Leitstelle neu starten | Derselbe Auftrag, kein zweiter; Ausgang bleibt an; die Fahrt endet normal | |
| 8.3 | Fahrt starten, unterwegs "Halten" (Seite Stoerungen) | Neue Fahrten und Linientermine werden nicht angenommen/gestartet; die laufende Fahrt faehrt weiter, bekommt am Ziel aber keine neue Freigabe zur Rueckfahrt; "Auftraege ... mit Freigabe/unterwegs" zaehlt mit | |
| 8.4 | "Fortsetzen" (zweimal tippen) | Die Rueckfahrt wird freigegeben und endet normal | |
| 8.5 | Leitstelle waehrend "Halten" neu starten | Halten bleibt bestehen | |
| 8.6 | Einen Bahnhofs-Node ausschalten (Strom/Chunk) | Nach ca. 60 s: Stoerung "meldet sich nicht"; keine Freigaben an ihn; Rest laeuft. Wieder einschalten: er meldet sich, nimmt Aufgaben aber erst nach der Abstimmung mit der Leitstelle an (wenige Sekunden) | |
| 8.7 | Das Create-Geraet eines Bahnhofs entfernen (Kabel/Block) | Stoerung "Geraet nicht verfuegbar", ein Auftrag mit Freigabe dort wird "Klaerung", das Gleis wird nicht als Ziel zugewiesen; nach dem Wiederanschliessen laeuft die Pruefung neu | |
| 8.8 | Zug waehrend eines Auftrags in Create umbenennen | Meldung "heisst jetzt ..."; Auftrag "Klaerung"; Zugposition "unbekannt"; kein anderer Zug wird "aehnlich" zugeordnet. Namen zurueckaendern: der Zug ist beim naechsten Zustandsbericht wieder am Gleis belegt | |
| 8.9 | Funkverbindung eines Bahnhofs kurz stoeren (Modem entfernen, Zug faehrt waehrend dessen ab oder kommt an) | Nach dem Wiederanschliessen holt der Bahnhof die Meldungen nach (Ankunft/Abfahrt werden wiederholt, bis bestaetigt); der Auftrag geht korrekt weiter | |
| 8.10 | **A17 Ersatz**: Auf dem Ersatzcomputer installieren (`installer`), Seite "Einrichtung" -> "Ersatz": Leitstelle und Node-Kennung eintragen, "Holen" | Solange der alte Computer laeuft: "noch aktiv". Nach Ausschalten (60 s) oder "Stilllegen" (Seite Netz, zweimal tippen): "Konfiguration ... empfangen" | |
| 8.11 | "Uebernehmen", Geraete pruefen, Schritt 5 Pruefungen, "Speichern und aktivieren" | Der Ersatz ist derselbe logische Node (gleiche Kennung), meldet sich bei der Leitstelle; die Leitstelle meldet, dass die alte Node nicht mehr laufen darf. Aufgaben mit alter Aufenthaltsnummer gehen in "Klaerung", nichts wird blind freigegeben | |
| 8.12 | Alte Node wieder einschalten | Meldung "Zwei Computer melden sich als ..." (Doppelbetrieb), die alte Node ist abzuschalten | |
| 8.13 | **A18 Update**: "Halten", warten bis keine Fahrt mehr "mit Freigabe/unterwegs" ist; auf allen Nodes `installer` mit der neuen Version; Neustart | Nodes starten; wurde das Modpack (Host/Methoden) geaendert, zeigt der Node "Pruefung noetig" und lehnt Aufgaben ab, bis auf der Seite Uebersicht "Pruefen" bestanden ist. Dann "Fortsetzen" | |
| 8.14 | Rueckkehr: `installer --rollback` nach einem Update, das das Datenformat geaendert hat (hier: Format 1; ab Format 2 relevant) | Ist das Format neuer als das Programm, startet die Automatik nicht (Seite Uebersicht: "Datenformat zu neu"); `crn/app/main datenstand` zeigt Sicherungen, `crn/app/main daten-zurueck N` spielt sie zurueck | |
| 8.15 | Datei beschaedigen (z.B. `/crn_data/register.lua` leeren, nur an einem Testsystem) | Beim Start wird die vorherige Generation geladen (Stufe 1), aktive Vorgaenge werden mit den Bahnhoefen abgeglichen | |

## Stufe 9: Betrieb im Grossen

Dies ist der Abschluss des grossen Tests. Alle Nodes laufen, mehrere Linien sind aktiv, mindestens ein Knoten ist eingerichtet. Automatisch geprueft sind bereits 312 Signale an 26 Computern (`tests/test_load.lua`: unter 6 Nachrichten je Sekunde im Ruhebetrieb, Berichte gesammelt je Node).

| Nr | Schritt | Erwartung | Ergebnis |
|---|---|---|---|
| 9.1 | Eine Stunde Betrieb mit mindestens zwei Linien und Bedarfsfahrten, niemand greift ein | Keine Meldung "Klaerung" ohne erkennbare Ursache; keine doppelten Auftraege; Seite "Stoerungen" bleibt leer oder erklaert jeden Eintrag | |
| 9.2 | Serverlast beobachten (TPS/Lag) waehrend 9.1, auf einem Signal-Node `crn/app/main selftest geraete` | Keine spuerbare Verlangsamung durch die Software; Zeiten aus Stufe 2 (Messwert M16: unter 5 ms je Aufruf) gelten weiter | |
| 9.3 | **A16** Einen Bahnhof oder Signal-Node ausserhalb geladener Chunks bringen (weit weglaufen, ohne Chunkloader), warten, zurueckkehren | Waehrend der Abwesenheit: "meldet sich nicht"; danach meldet er sich, gleicht sich ab (kein Freigeben auf Verdacht), offene Auftraege dort gehen in Klaerung oder laufen korrekt weiter. Bitte genau notieren, was der Computer ausserhalb geladener Chunks tut | |
| 9.4 | **A16** Chunkgrenze mit fahrendem Zug: Zug faehrt in einen ungeladenen Bereich und zurueck | Der Zug wird nicht doppelt freigegeben; Ankunft/Abfahrt kommen verspaetet oder ueber den Zustandsbericht an | |
| 9.5 | Alle Spieltest-Schritte aus Stufe 4 bis 8, die noch kein Ergebnis haben, nachholen | Ergebnisse eingetragen | |
| 9.6 | Rueckmeldung an den Entwickler | Diese Datei mit allen Ergebnissen, die Meldungen der Seite "Meldungen" der Leitstelle, die Ausgabe von `crn/app/main info` und `crn/app/main datenstand` je Computertyp, und alle Abweichungen (Fahrplan-JSON aus Schritt 4.20) | |
