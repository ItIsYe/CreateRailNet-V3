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
