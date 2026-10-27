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
