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
